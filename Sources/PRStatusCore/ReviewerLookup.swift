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

/// How much review work one PR represents: its changed lines, capped so one generated
/// file does not count as ten real reviews.
public let reviewWeightCap = 2000

public func reviewWeight(changedLines: Int) -> Int {
  min(max(0, changedLines), reviewWeightCap)
}

/// How far back a review still counts as this week's work.
public let recentReviewWindow: TimeInterval = 7 * 86400

/// A PR the person reviewed inside the window, kept only as far as its size.
public struct ReviewedPullRequest: Equatable, Sendable {
  public let number: Int
  public let changedLines: Int

  public init(number: Int, changedLines: Int) {
    self.number = number
    self.changedLines = changedLines
  }
}

/// One person's review work: what waits on them, and what they got through this week —
/// the same question the menu bar answers for the viewer, asked about somebody else, and
/// widened so that clearing a queue quickly does not read as having nothing to do.
///
/// Split at construction into active and dormant, as of the fetch: a PR nobody has touched
/// for `PullRequestItem.dormantAfter` is assigned but not being reviewed, so only the
/// active ones measure how busy the person is.
public struct ReviewerLoad: Equatable, Sendable, Identifiable {
  public let reviewer: ReviewerProfile
  /// The search's total, active and dormant together. `items` holds only the first page,
  /// so this can be larger.
  public let requestedCount: Int
  /// Oldest first, with each clock resolved for `reviewer` rather than for the viewer.
  public let items: [PullRequestItem]
  /// The items still moving, oldest first.
  public let active: [PullRequestItem]
  /// Everything requested that is not active. Exact even past the first page, because the
  /// page is the most recently updated PRs, so the ones it cuts are dormant.
  public let dormantCount: Int
  /// The search's total of PRs the person reviewed that moved inside the window.
  public let reviewedCount: Int
  /// The first page of those, for their sizes.
  public let reviewed: [ReviewedPullRequest]

  public var id: String { reviewer.login }

  public init(
    reviewer: ReviewerProfile, requestedCount: Int, items: [PullRequestItem],
    reviewedCount: Int, reviewed: [ReviewedPullRequest], asOf now: Date
  ) {
    self.reviewer = reviewer
    self.requestedCount = requestedCount
    self.items = items.oldestFirst()
    self.active = self.items.filter { !$0.isDormant(asOf: now) }
    self.dormantCount = max(0, requestedCount - active.count)
    self.reviewedCount = reviewedCount
    self.reviewed = reviewed
  }

  public var activeCount: Int { active.count }

  /// Capped lines waiting on the person.
  public var pendingWeight: Int {
    active.reduce(0) { $0 + reviewWeight(changedLines: $1.changedLines) }
  }

  /// Capped lines the person reviewed this week.
  public var reviewedWeight: Int {
    reviewed.reduce(0) { $0 + reviewWeight(changedLines: $1.changedLines) }
  }

  /// Work in flight plus work done this week, in capped lines. What the ranking, the bar
  /// and the colour read.
  public var load: Int { pendingWeight + reviewedWeight }

  /// nil when nothing active is waiting on this person.
  public var oldestWaitingSince: Date? { active.first?.waitingSince }

  public func oldestAge(now: Date) -> TimeInterval? { active.first?.age(now: now) }

  public func withItems(_ items: [PullRequestItem], asOf now: Date) -> ReviewerLoad {
    ReviewerLoad(
      reviewer: reviewer, requestedCount: requestedCount, items: items,
      reviewedCount: reviewedCount, reviewed: reviewed, asOf: now)
  }
}

/// How loaded one reviewer is next to the busiest one on the same screen. The scale is cut
/// in thirds, with a floor of one capped PR so a single small review never reads as heavy.
/// Unlike the queue's colours this says nothing about age: the pane's question is who is
/// free, and the wait stays in the text.
public enum LoadLevel: Equatable, Sendable {
  case light
  case moderate
  case heavy

  public static let scaleFloor = reviewWeightCap

  /// nil when there is no load. `scale` is the largest load on screen.
  public init?(load: Int, scale: Int) {
    guard load > 0 else { return nil }
    let scale = max(scale, Self.scaleFloor, load)
    if load * 3 <= scale {
      self = .light
    } else if load * 3 <= 2 * scale {
      self = .moderate
    } else {
      self = .heavy
    }
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

/// Least load first. Among equals, fewer active requests, then the person whose oldest
/// active request is newest, then fewer dormant requests, then login, so the order is
/// stable between refreshes.
public func rankByAvailability(_ loads: [ReviewerLoad]) -> [ReviewerLoad] {
  loads.sorted { lhs, rhs in
    if lhs.load != rhs.load {
      return lhs.load < rhs.load
    }
    if lhs.activeCount != rhs.activeCount {
      return lhs.activeCount < rhs.activeCount
    }
    switch (lhs.oldestWaitingSince, rhs.oldestWaitingSince) {
    case (nil, nil): break
    case (nil, _): return true
    case (_, nil): return false
    case (let l?, let r?) where l != r: return l > r
    default: break
    }
    if lhs.dormantCount != rhs.dormantCount {
      return lhs.dormantCount < rhs.dormantCount
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

  /// Rewrites every PR's clocks, for a fixture whose timestamps are fixed. Each load is
  /// re-split and the team re-ranked as of `now`, because both depend on the clocks.
  public func mapItems(
    asOf now: Date, _ transform: (PullRequestItem) -> PullRequestItem
  ) -> LookupResult {
    switch self {
    case .user(let load):
      return .user(load.withItems(load.items.map(transform), asOf: now))
    case .team(let team):
      return .team(
        TeamLoad(
          roster: team.roster,
          members: team.members.map { $0.withItems($0.items.map(transform), asOf: now) }))
    case .notFound:
      return self
    }
  }
}
