import Foundation

/// How badly a single pull request is overdue. A PR that exists is always at one of
/// these levels; "nothing is waiting" is the *absence* of items, represented as
/// `Urgency?` == nil at the aggregate level rather than a fourth case here.
public enum Urgency: Int, Comparable, Sendable {
  case fresh = 0
  case stale = 1
  case urgent = 2

  public static func < (lhs: Urgency, rhs: Urgency) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct UrgencyThresholds: Sendable, Equatable {
  public let stale: TimeInterval
  public let urgent: TimeInterval

  public init(stale: TimeInterval, urgent: TimeInterval) {
    self.stale = stale
    self.urgent = urgent
  }

  public static let standard = UrgencyThresholds(stale: 3600, urgent: 3 * 3600)

  /// Lets the aging behaviour be exercised end-to-end in seconds instead of hours
  /// (`PRSTATUS_THRESHOLDS=10,20`) without editing and rebuilding the app.
  public static func fromEnvironment(
    _ env: [String: String] = ProcessInfo.processInfo.environment
  ) -> UrgencyThresholds {
    guard let raw = env["PRSTATUS_THRESHOLDS"] else { return .standard }
    let parts = raw.split(separator: ",").compactMap {
      TimeInterval($0.trimmingCharacters(in: .whitespaces))
    }
    guard parts.count == 2, parts[0] > 0, parts[1] > parts[0] else { return .standard }
    return UrgencyThresholds(stale: parts[0], urgent: parts[1])
  }
}

/// How this PR reached the reviewer's queue. GitHub's `review-requested:` search matches
/// both routes, so the search alone cannot tell them apart.
public enum ReviewRequestKind: Sendable, Equatable {
  /// A pending review request names the reviewer.
  case direct
  /// No pending request names the reviewer. The PR is in the queue at all because a
  /// review request exists, so a team the reviewer belongs to carries it.
  case team
}

public enum TimelineEvent: Sendable, Equatable {
  /// `reviewerLogin` is nil when the request targeted a team rather than a person.
  case reviewRequested(at: Date, reviewerLogin: String?)
  case readyForReview(at: Date)
}

public struct PullRequestItem: Identifiable, Sendable, Equatable {
  public let id: String
  public let number: Int
  public let title: String
  public let url: URL
  public let repository: String
  public let authorLogin: String
  public let authorAvatarURL: URL?
  public let isDraft: Bool
  /// GitHub's last-activity stamp: any comment, push or review moves it.
  public let updatedAt: Date
  public let additions: Int
  public let deletions: Int
  public let changedFiles: Int
  /// Whether someone asked the reviewer by name — see `resolveRequestKind`.
  public let requestKind: ReviewRequestKind
  /// When this PR started waiting on the reviewer — see `resolveWaitingSince`.
  public let waitingSince: Date

  public init(
    id: String, number: Int, title: String, url: URL, repository: String,
    authorLogin: String, authorAvatarURL: URL?, isDraft: Bool, updatedAt: Date,
    additions: Int, deletions: Int, changedFiles: Int,
    requestKind: ReviewRequestKind, waitingSince: Date
  ) {
    self.id = id
    self.number = number
    self.title = title
    self.url = url
    self.repository = repository
    self.authorLogin = authorLogin
    self.authorAvatarURL = authorAvatarURL
    self.isDraft = isDraft
    self.updatedAt = updatedAt
    self.additions = additions
    self.deletions = deletions
    self.changedFiles = changedFiles
    self.requestKind = requestKind
    self.waitingSince = waitingSince
  }

  /// Built as a plain String because SwiftUI's `Text` interpolation would localise a bare
  /// Int and render PR 16062 as "#16,062".
  public var reference: String {
    "\(repository) #\(number)"
  }

  /// Same PR, different clock start.
  public func withWaitingSince(_ date: Date) -> PullRequestItem {
    PullRequestItem(
      id: id, number: number, title: title, url: url, repository: repository,
      authorLogin: authorLogin, authorAvatarURL: authorAvatarURL, isDraft: isDraft,
      updatedAt: updatedAt, additions: additions, deletions: deletions,
      changedFiles: changedFiles, requestKind: requestKind, waitingSince: date)
  }

  /// Same PR, different last activity.
  public func withUpdatedAt(_ date: Date) -> PullRequestItem {
    PullRequestItem(
      id: id, number: number, title: title, url: url, repository: repository,
      authorLogin: authorLogin, authorAvatarURL: authorAvatarURL, isDraft: isDraft,
      updatedAt: date, additions: additions, deletions: deletions,
      changedFiles: changedFiles, requestKind: requestKind, waitingSince: waitingSince)
  }

  /// Nothing has happened on the PR for this long. Somebody is still requested, but the
  /// request is not being worked, so it says little about how busy they are.
  public static let dormantAfter: TimeInterval = 3 * 86400

  public func isDormant(asOf now: Date) -> Bool {
    now.timeIntervalSince(updatedAt) > Self.dormantAfter
  }

  public func age(now: Date) -> TimeInterval {
    max(0, now.timeIntervalSince(waitingSince))
  }

  public func urgency(now: Date, thresholds: UrgencyThresholds = .standard) -> Urgency {
    Urgency(age: age(now: now), thresholds: thresholds)
  }
}

extension Urgency {
  public init(age: TimeInterval, thresholds: UrgencyThresholds) {
    if age > thresholds.urgent {
      self = .urgent
    } else if age > thresholds.stale {
      self = .stale
    } else {
      self = .fresh
    }
  }
}

/// Separates "someone asked this reviewer" from "someone asked a team they belong to".
///
/// `requestedUserLogins` holds the logins of the reviewers currently requested on the PR,
/// so a request that was later removed does not count. Team reviewers carry a name and no
/// login, which is why they never appear here.
public func resolveRequestKind(
  requestedUserLogins: [String],
  reviewerLogin: String
) -> ReviewRequestKind {
  let namesMe = requestedUserLogins.contains {
    $0.caseInsensitiveCompare(reviewerLogin) == .orderedSame
  }
  return namesMe ? .direct : .team
}

/// Picks the moment a PR entered the reviewer's queue.
///
/// `updatedAt` cannot serve here: a bot comment on an otherwise untouched PR resets
/// it, so the icon would never age to yellow. Priority order:
///   1. the most recent review request naming the reviewer
///   2. else the most recent review request of any kind — a request routed through a
///      team carries the team's name, not the reviewer's, so without this branch
///      team-assigned PRs would read as age-zero forever
///   3. else the draft -> ready transition
///   4. else PR creation
public func resolveWaitingSince(
  events: [TimelineEvent],
  reviewerLogin: String,
  createdAt: Date
) -> Date {
  var mine: [Date] = []
  var anyRequest: [Date] = []
  var readyForReview: [Date] = []

  for event in events {
    switch event {
    case .reviewRequested(let at, let requestedLogin):
      anyRequest.append(at)
      if let requestedLogin,
        requestedLogin.caseInsensitiveCompare(reviewerLogin) == .orderedSame
      {
        mine.append(at)
      }
    case .readyForReview(let at):
      readyForReview.append(at)
    }
  }

  return mine.max() ?? anyRequest.max() ?? readyForReview.max() ?? createdAt
}

extension Array where Element == PullRequestItem {
  /// The order every list in the app shows: the PR that has waited longest at the top.
  public func oldestFirst() -> [PullRequestItem] {
    sorted { $0.waitingSince < $1.waitingSince }
  }
}

/// nil means nothing is waiting, which is what drives the hollow circle.
public func worstUrgency(
  of items: [PullRequestItem],
  now: Date,
  thresholds: UrgencyThresholds = .standard
) -> Urgency? {
  items.map { $0.urgency(now: now, thresholds: thresholds) }.max()
}
