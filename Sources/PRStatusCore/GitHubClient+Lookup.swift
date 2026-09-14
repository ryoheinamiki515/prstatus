import Foundation

extension GitHubClient {
  /// The reviewed-by search needs only sizes, so it selects far less than a queue row.
  static let reviewedFragment = """
    fragment ReviewedFields on PullRequest { number additions deletions }
    """

  static let userLookupQuery = """
    query($login: String!, $q: String!, $r: String!) {
      user(login: $login) { login name avatarUrl }
      search(query: $q, type: ISSUE, first: 30) {
        issueCount
        nodes { ...PullRequestFields }
      }
      reviewed: search(query: $r, type: ISSUE, first: 50) {
        issueCount
        nodes { ...ReviewedFields }
      }
    }
    """ + pullRequestFragment + reviewedFragment

  static let teamQuery = """
    query($organization: String!, $slug: String!, $q: String!) {
      organization(login: $organization) {
        team(slug: $slug) {
          name
          combinedSlug
          members(first: 100) {
            totalCount
            nodes { login name avatarUrl }
          }
        }
      }
      search(query: $q, type: ISSUE, first: 1) { issueCount }
    }
    """

  /// GitHub runs the searches in one request one after another and cuts the request off
  /// with a 502 at ten seconds. Each member costs two searches, and a reviewed-by search
  /// runs over a second; three members per request stays inside the limit. The batches
  /// run concurrently, so a team of forty takes about as long as a team of three.
  static let loadBatchSize = 3

  /// Two aliased searches per member — `m0` for what waits on them, `r0` for what they
  /// reviewed — over variables `$q0` and `$r0`. Aliases are positional, so `decodeLoads`
  /// must receive the same member list in the same order.
  public static func loadQuery(memberCount: Int) -> String {
    let declarations = (0..<memberCount).map { "$q\($0): String!, $r\($0): String!" }
      .joined(separator: ", ")
    let searches = (0..<memberCount).map { index in
      "  m\(index): search(query: $q\(index), type: ISSUE, first: 30) "
        + "{ issueCount nodes { ...PullRequestFields } }\n"
        + "  r\(index): search(query: $r\(index), type: ISSUE, first: 50) "
        + "{ issueCount nodes { ...ReviewedFields } }"
    }.joined(separator: "\n")
    return "query(\(declarations)) {\n\(searches)\n}\n" + pullRequestFragment
      + reviewedFragment
  }

  /// `user-review-requested:` matches only requests naming the login, not those routed
  /// through a team — the same split as the viewer's Direct only filter, made by GitHub.
  /// Most recently updated first, so when the page is cut at 30 every active PR is on it
  /// and only dormant ones fall off; `ReviewerLoad` counts those from the total.
  static func requestedSearch(login: String) -> String {
    "is:open is:pr user-review-requested:\(login) archived:false sort:updated-desc"
  }

  /// PRs the person reviewed, by anyone's authorship but their own, that moved inside the
  /// window. `reviewed-by:` matches a review from any time, so a PR touched this week that
  /// they reviewed months ago counts once — accepted, since the alternative API hides other
  /// people's private activity.
  public static func reviewedSearch(login: String, asOf now: Date) -> String {
    let since = now.addingTimeInterval(-recentReviewWindow)
    let day = ISO8601DateFormatter()
    day.formatOptions = [.withFullDate, .withDashSeparatorInDate]
    return "is:pr reviewed-by:\(login) -author:\(login) updated:>=\(day.string(from: since)) "
      + "archived:false"
  }

  static func teamRequestedSearch(slug: String) -> String {
    "is:open is:pr team-review-requested:\(slug) archived:false"
  }

  // MARK: - Fetch

  public func lookup(_ target: LookupTarget) async throws -> LookupResult {
    let token = try Self.fetchToken()
    switch target {
    case .user(let login):
      let now = Date()
      let data = try await Self.post(
        Self.userLookupQuery,
        variables: [
          "login": login,
          "q": Self.requestedSearch(login: login),
          "r": Self.reviewedSearch(login: login, asOf: now),
        ],
        token: token)
      return try Self.decodeUserLookup(data, login: login, asOf: now)

    case .team(let organization, let slug):
      let data = try await Self.post(
        Self.teamQuery,
        variables: [
          "organization": organization,
          "slug": slug,
          "q": Self.teamRequestedSearch(slug: "\(organization)/\(slug)"),
        ],
        token: token)
      guard let roster = try Self.decodeTeam(data) else { return .notFound(target) }
      let members = try await Self.fetchLoads(of: roster.members, token: token, asOf: Date())
      return .team(TeamLoad(roster: roster, members: members))
    }
  }

  static func fetchLoads(of members: [ReviewerProfile], token: String, asOf now: Date)
    async throws -> [ReviewerLoad]
  {
    let batches = stride(from: 0, to: members.count, by: loadBatchSize).map { start in
      Array(members[start..<min(start + loadBatchSize, members.count)])
    }
    return try await withThrowingTaskGroup(of: (Int, [ReviewerLoad]).self) { group in
      for (index, batch) in batches.enumerated() {
        group.addTask {
          var variables: [String: String] = [:]
          for (position, member) in batch.enumerated() {
            variables["q\(position)"] = requestedSearch(login: member.login)
            variables["r\(position)"] = reviewedSearch(login: member.login, asOf: now)
          }
          let data = try await post(
            loadQuery(memberCount: batch.count), variables: variables, token: token)
          return (index, try decodeLoads(data, members: batch, asOf: now))
        }
      }
      var loads = [[ReviewerLoad]](repeating: [], count: batches.count)
      for try await (index, batch) in group { loads[index] = batch }
      return loads.flatMap { $0 }
    }
  }

  // MARK: - Decode

  /// `now` fixes the active-versus-dormant split, so a fixture decodes the same way on any
  /// day.
  public static func decodeUserLookup(_ data: Data, login: String, asOf now: Date) throws
    -> LookupResult
  {
    guard case .found(let payload) = try unwrap(UserLookupPayload.self, from: data),
      let user = payload.user
    else { return .notFound(.user(login: login)) }
    return .user(
      ReviewerLoad(
        reviewer: user.profile,
        requestedCount: payload.search.issueCount,
        items: payload.search.items(for: user.login),
        reviewedCount: payload.reviewed.issueCount,
        reviewed: payload.reviewed.reviewedPullRequests,
        asOf: now))
  }

  /// nil when the organization or the team does not exist. An unknown organization comes
  /// back as NOT_FOUND; an unknown team inside a known organization is a plain null.
  public static func decodeTeam(_ data: Data) throws -> TeamRoster? {
    guard case .found(let payload) = try unwrap(TeamPayload.self, from: data),
      let team = payload.organization?.team
    else { return nil }
    return TeamRoster(
      slug: team.combinedSlug,
      name: team.name,
      memberCount: team.members.totalCount,
      members: team.members.nodes.map(\.profile),
      teamRequestedCount: payload.search.issueCount)
  }

  public static func decodeLoads(_ data: Data, members: [ReviewerProfile], asOf now: Date)
    throws -> [ReviewerLoad]
  {
    guard case .found(let searches) = try unwrap([String: Search].self, from: data) else {
      throw GitHubClientError.api("GitHub could not resolve a member's review requests.")
    }
    return try members.enumerated().map { index, member in
      guard let requested = searches["m\(index)"], let reviewed = searches["r\(index)"] else {
        throw GitHubClientError.api("Response is missing a search for \(member.login).")
      }
      return ReviewerLoad(
        reviewer: member,
        requestedCount: requested.issueCount,
        items: requested.items(for: member.login),
        reviewedCount: reviewed.issueCount,
        reviewed: reviewed.reviewedPullRequests,
        asOf: now)
    }
  }

  // MARK: - Wire types

  struct UserLookupPayload: Decodable {
    let user: UserNode?
    let search: Search
    let reviewed: Search
  }

  struct UserNode: Decodable {
    let login: String
    let name: String?
    let avatarUrl: String?

    var profile: ReviewerProfile {
      ReviewerProfile(
        login: login, name: name, avatarURL: avatarUrl.flatMap(URL.init(string:)))
    }
  }

  struct TeamPayload: Decodable {
    let organization: OrganizationNode?
    let search: Search
  }
  struct OrganizationNode: Decodable { let team: TeamNode? }
  struct TeamNode: Decodable {
    let name: String
    let combinedSlug: String
    let members: Members
  }
  struct Members: Decodable {
    let totalCount: Int
    let nodes: [UserNode]
  }
}
