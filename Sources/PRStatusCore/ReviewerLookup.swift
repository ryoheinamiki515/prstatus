import Foundation

/// What the lookup field names: one person, or one team written as `org/slug`.
public enum LookupTarget: Equatable, Sendable {
  case user(login: String)
  case team(organization: String, slug: String)

  /// Accepts `login`, `@login`, `org/slug` and `@org/slug`. Returns nil for anything
  /// GitHub could not name: empty text, a second slash, or a character outside a login.
  public init?(parsing text: String) {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("@") { trimmed.removeFirst() }
    let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.allSatisfy(Self.isNamePart) else { return nil }
    switch parts.count {
    case 1: self = .user(login: parts[0])
    case 2: self = .team(organization: parts[0], slug: parts[1])
    default: return nil
    }
  }

  /// GitHub logins and team slugs are ASCII letters, digits, hyphens and underscores.
  /// Anything else would also break the search qualifier the name is spliced into.
  private static func isNamePart(_ part: String) -> Bool {
    !part.isEmpty
      && part.utf8.allSatisfy { byte in
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
          || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
          || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
          || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
      }
  }

  public var displayName: String {
    switch self {
    case .user(let login): return login
    case .team(let organization, let slug): return "\(organization)/\(slug)"
    }
  }

  /// GitHub's own list of the PRs behind the number, for a click on the result.
  public var url: URL {
    switch self {
    case .user(let login): return reviewQueueURL(login: login)
    case .team: return teamQueueURL(slug: displayName)
    }
  }
}

/// The open PRs whose pending review requests name `login`, on github.com.
public func reviewQueueURL(login: String) -> URL {
  searchURL("is:open is:pr user-review-requested:\(login) archived:false")
}

/// The open PRs requested from the team `org/slug` itself, on github.com.
public func teamQueueURL(slug: String) -> URL {
  searchURL("is:open is:pr team-review-requested:\(slug) archived:false")
}

private func searchURL(_ query: String) -> URL {
  var components = URLComponents(string: "https://github.com/pulls")!
  components.queryItems = [URLQueryItem(name: "q", value: query)]
  return components.url!
}

public struct ReviewerProfile: Equatable, Sendable, Identifiable {
  public let login: String
  /// nil when the account has no display name set, which GitHub allows.
  public let name: String?
  public let avatarURL: URL?

  public var id: String { login }

  public init(login: String, name: String?, avatarURL: URL?) {
    self.login = login
    self.name = name
    self.avatarURL = avatarURL
  }
}

/// The PRs whose pending review requests name one person — the same question the menu
/// bar answers for the viewer, asked about somebody else.
public struct ReviewerLoad: Equatable, Sendable, Identifiable {
  public let reviewer: ReviewerProfile
  /// The search's total. `items` holds only the first page, so this can be larger.
  public let requestedCount: Int
  /// Oldest first, with each clock resolved for `reviewer` rather than for the viewer.
  public let items: [PullRequestItem]

  public var id: String { reviewer.login }

  public init(reviewer: ReviewerProfile, requestedCount: Int, items: [PullRequestItem]) {
    self.reviewer = reviewer
    self.requestedCount = requestedCount
    self.items = items.oldestFirst()
  }

  /// nil when nothing is waiting on this person.
  public var oldestWaitingSince: Date? { items.first?.waitingSince }

  public func oldestAge(now: Date) -> TimeInterval? { items.first?.age(now: now) }

  /// How overdue the longest wait is; nil when nothing is waiting.
  public func urgency(now: Date, thresholds: UrgencyThresholds) -> Urgency? {
    worstUrgency(of: items, now: now, thresholds: thresholds)
  }

  public func withItems(_ items: [PullRequestItem]) -> ReviewerLoad {
    ReviewerLoad(reviewer: reviewer, requestedCount: requestedCount, items: items)
  }
}

/// A team as GitHub lists it, before anyone's load is known.
public struct TeamRoster: Equatable, Sendable {
  /// `org/slug`, as typed and as GitHub's `combinedSlug` reports it.
  public let slug: String
  public let name: String
  /// GitHub's total, which can exceed `members.count` when the roster is cut at one page.
  public let memberCount: Int
  public let members: [ReviewerProfile]
  /// PRs requested from the team itself. Every member shares these, so they say nothing
  /// about who to pick and are reported once rather than added to each row.
  public let teamRequestedCount: Int

  public init(
    slug: String, name: String, memberCount: Int, members: [ReviewerProfile],
    teamRequestedCount: Int
  ) {
    self.slug = slug
    self.name = name
    self.memberCount = memberCount
    self.members = members
    self.teamRequestedCount = teamRequestedCount
  }

  public var url: URL { teamQueueURL(slug: slug) }
}

public struct TeamLoad: Equatable, Sendable {
  public let roster: TeamRoster
  /// Ranked by `rankByAvailability`, so the best person to ask sits at the top.
  public let members: [ReviewerLoad]

  public init(roster: TeamRoster, members: [ReviewerLoad]) {
    self.roster = roster
    self.members = rankByAvailability(members)
  }
}

/// Fewest pending requests first. Among equals, the person whose oldest request is newest
/// is less behind, so they rank higher; nothing waiting ranks above anything waiting.
/// Login breaks the last tie so the order is stable between refreshes.
public func rankByAvailability(_ loads: [ReviewerLoad]) -> [ReviewerLoad] {
  loads.sorted { lhs, rhs in
    if lhs.requestedCount != rhs.requestedCount {
      return lhs.requestedCount < rhs.requestedCount
    }
    switch (lhs.oldestWaitingSince, rhs.oldestWaitingSince) {
    case (nil, nil): break
    case (nil, _): return true
    case (_, nil): return false
    case (let l?, let r?) where l != r: return l > r
    default: break
    }
    return lhs.reviewer.login.localizedCaseInsensitiveCompare(rhs.reviewer.login)
      == .orderedAscending
  }
}

public enum LookupResult: Equatable, Sendable {
  case user(ReviewerLoad)
  case team(TeamLoad)
  /// GitHub knows no such user or team. An answer, not a failure: it does not mean GitHub
  /// was unreachable, so it must not be drawn like one.
  case notFound(LookupTarget)

  /// Rewrites every PR's clock, for a fixture whose timestamps are fixed. Team members are
  /// re-ranked, because the oldest wait is part of the ranking.
  public func mapItems(_ transform: (PullRequestItem) -> PullRequestItem) -> LookupResult {
    switch self {
    case .user(let load):
      return .user(load.withItems(load.items.map(transform)))
    case .team(let team):
      return .team(
        TeamLoad(
          roster: team.roster,
          members: team.members.map { $0.withItems($0.items.map(transform)) }))
    case .notFound:
      return self
    }
  }
}
