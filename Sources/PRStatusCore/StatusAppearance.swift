import Foundation

/// Separate cases rather than an items array plus flags, so no consumer can render "no data
/// yet", "nothing waiting" and "the fetch failed" as if they were the same thing.
///
/// A refresh that fails while a queue is already known keeps that queue and records the
/// error in `refreshError`: GitHub 503s intermittently, and discarding what we know over
/// one blip is worse than showing it with a warning. `failed` therefore means "never got
/// data", not "the last attempt failed".
public enum LoadState: Equatable, Sendable {
  case never
  case loading
  case loaded(items: [PullRequestItem], at: Date, refreshError: GitHubClientError?)
  case failed(GitHubClientError)

  /// Oldest first, ordered once in `nextState` so consumers can read without re-sorting.
  public var items: [PullRequestItem] {
    if case .loaded(let items, _, _) = self { return items }
    return []
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
  for state: LoadState,
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

/// Applies a fetch outcome. A failed refresh keeps whatever was already loaded — including
/// a known-empty queue, which is knowledge worth as much as a list of rows.
public func nextState(
  after previous: LoadState,
  result: Result<[PullRequestItem], GitHubClientError>,
  now: Date
) -> LoadState {
  switch result {
  case .success(let items):
    let oldestFirst = items.sorted { $0.waitingSince < $1.waitingSince }
    return .loaded(items: oldestFirst, at: now, refreshError: nil)
  case .failure(let error):
    guard case .loaded(let items, let at, _) = previous else { return .failed(error) }
    return .loaded(items: items, at: at, refreshError: error)
  }
}
