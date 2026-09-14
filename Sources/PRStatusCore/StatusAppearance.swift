import Foundation

/// Separate cases rather than a value plus flags, so no consumer can render "no data yet",
/// "nothing waiting" and "the fetch failed" as if they were the same thing.
///
/// A refresh that fails while a value is already known keeps that value and records the
/// error in `refreshError`: GitHub 503s intermittently, and discarding what we know over
/// one blip is worse than showing it with a warning. `failed` therefore means "never got
/// data", not "the last attempt failed".
///
/// Generic over the value so the review queue and a reviewer lookup share one state
/// machine and one set of views for its four cases.
public enum LoadState<Value: Equatable & Sendable>: Equatable, Sendable {
  case never
  case loading
  case loaded(value: Value, at: Date, refreshError: GitHubClientError?)
  case failed(GitHubClientError)

  public var value: Value? {
    if case .loaded(let value, _, _) = self { return value }
    return nil
  }

  /// The fetch time, only while nothing has failed since. A stale value is dated by its
  /// banner instead, and two timestamps saying different things is worse than one.
  public var currentAsOf: Date? {
    if case .loaded(_, let at, .none) = self { return at }
    return nil
  }

  /// Transforms the loaded value and leaves the other cases untouched. The timestamp and
  /// the stale marker travel with the value, so a projection still knows how current it is.
  public func map<Transformed: Equatable & Sendable>(
    _ transform: (Value) -> Transformed
  ) -> LoadState<Transformed> {
    switch self {
    case .never: return .never
    case .loading: return .loading
    case .failed(let error): return .failed(error)
    case .loaded(let value, let at, let refreshError):
      return .loaded(value: transform(value), at: at, refreshError: refreshError)
    }
  }
}

public typealias ReviewQueueState = LoadState<[PullRequestItem]>

extension LoadState where Value == [PullRequestItem] {
  /// Oldest first — the order `GitHubClient` produces, so consumers never re-sort.
  public var items: [PullRequestItem] { value ?? [] }

  /// Drops the team-routed PRs when the popover asks for direct requests only.
  ///
  /// The whole state is narrowed, not just the row list, so the icon colour, the menu bar
  /// count and the rows cannot disagree about which PRs are in the queue. Both routes are
  /// always fetched, so turning the filter off needs no network round trip.
  public func showing(directRequestsOnly: Bool) -> ReviewQueueState {
    guard directRequestsOnly else { return self }
    return map { $0.filter { $0.requestKind == .direct } }
  }
}

/// What the menu bar icon should show. `unknown` and `unavailable` exist so that not
/// knowing the queue can never be drawn as an empty queue — a hollow "all clear" circle
/// while GitHub is unreachable is a silent failure that looks like good news.
public enum StatusAppearance: Equatable, Sendable {
  case unknown
  case idle
  case waiting(Urgency)
  case unavailable
}

public func statusAppearance(
  for state: ReviewQueueState,
  now: Date,
  thresholds: UrgencyThresholds
) -> StatusAppearance {
  switch state {
  case .never, .loading:
    return .unknown
  case .failed:
    return .unavailable
  case .loaded(let items, _, _):
    guard let worst = worstUrgency(of: items, now: now, thresholds: thresholds) else {
      return .idle
    }
    return .waiting(worst)
  }
}

/// Runs one fetch and folds every failure into a `GitHubClientError`, so a caller can hand
/// the result straight to `nextState`. Main-actor bound because the loaders it runs are
/// stored by main-actor models and need not be Sendable.
@MainActor
public func outcome<Value>(
  of load: () async throws -> Value
) async -> Result<Value, GitHubClientError> {
  do {
    return .success(try await load())
  } catch let error as GitHubClientError {
    return .failure(error)
  } catch {
    return .failure(.network(error.localizedDescription))
  }
}

/// Applies a fetch outcome. A failed refresh keeps whatever was already loaded — including
/// a known-empty queue, which is knowledge worth as much as a list of rows.
public func nextState<Value>(
  after previous: LoadState<Value>,
  result: Result<Value, GitHubClientError>,
  now: Date
) -> LoadState<Value> {
  switch result {
  case .success(let value):
    return .loaded(value: value, at: now, refreshError: nil)
  case .failure(let error):
    guard case .loaded(let value, let at, _) = previous else { return .failed(error) }
    return .loaded(value: value, at: at, refreshError: error)
  }
}
