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
  public let additions: Int
  public let deletions: Int
  public let changedFiles: Int
  /// When this PR started waiting on *me* — see `resolveWaitingSince`.
  public let waitingSince: Date

  public init(
    id: String, number: Int, title: String, url: URL, repository: String,
    authorLogin: String, authorAvatarURL: URL?, isDraft: Bool,
    additions: Int, deletions: Int, changedFiles: Int, waitingSince: Date
  ) {
    self.id = id
    self.number = number
    self.title = title
    self.url = url
    self.repository = repository
    self.authorLogin = authorLogin
    self.authorAvatarURL = authorAvatarURL
    self.isDraft = isDraft
    self.additions = additions
    self.deletions = deletions
    self.changedFiles = changedFiles
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
      additions: additions, deletions: deletions, changedFiles: changedFiles,
      waitingSince: date)
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

/// Picks the moment a PR entered my review queue.
///
/// `updatedAt` cannot serve here: a bot comment on an otherwise untouched PR resets
/// it, so the icon would never age to yellow. Priority order:
///   1. the most recent review request naming me
///   2. else the most recent review request of any kind — a request routed through a
///      team carries the team's name, not mine, so without this branch team-assigned
///      PRs would read as age-zero forever
///   3. else the draft -> ready transition
///   4. else PR creation
public func resolveWaitingSince(
  events: [TimelineEvent],
  viewerLogin: String,
  createdAt: Date
) -> Date {
  var mine: [Date] = []
  var anyRequest: [Date] = []
  var readyForReview: [Date] = []

  for event in events {
    switch event {
    case .reviewRequested(let at, let reviewerLogin):
      anyRequest.append(at)
      if let reviewerLogin, reviewerLogin.caseInsensitiveCompare(viewerLogin) == .orderedSame {
        mine.append(at)
      }
    case .readyForReview(let at):
      readyForReview.append(at)
    }
  }

  return mine.max() ?? anyRequest.max() ?? readyForReview.max() ?? createdAt
}

/// nil means nothing is waiting, which is what drives the hollow circle.
public func worstUrgency(
  of items: [PullRequestItem],
  now: Date,
  thresholds: UrgencyThresholds = .standard
) -> Urgency? {
  items.map { $0.urgency(now: now, thresholds: thresholds) }.max()
}
