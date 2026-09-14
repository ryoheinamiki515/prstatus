import Foundation
import PRStatusCore

// Runnable stand-in for a unit-test target: the Command Line Tools ship neither
// XCTest nor swift-testing, so `swift test` cannot run on this machine.
// Covers PRStatusCore only; the AppKit/SwiftUI layer is verified by hand.

var failures: [String] = []
var passed = 0

@MainActor
func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
  if condition {
    passed += 1
    print("  ok   \(name)")
  } else {
    let suffix = detail().isEmpty ? "" : " — \(detail())"
    failures.append("\(name)\(suffix)")
    print("  FAIL \(name)\(suffix)")
  }
}

@MainActor
func equal<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
  check(name, actual == expected, "got \(actual), expected \(expected)")
}

func section(_ title: String) { print("\n\(title)") }

func date(_ iso: String) -> Date {
  guard let d = Date(githubTimestamp: iso) else {
    fatalError("test fixture bug: unparseable date \(iso)")
  }
  return d
}

let epoch = date("2026-08-17T12:00:00Z")
let standard = UrgencyThresholds.standard

// MARK: - Threshold boundaries

section("Urgency thresholds (stale > 1h, urgent > 3h)")
equal("age 0s -> fresh", Urgency(age: 0, thresholds: standard), .fresh)
equal("age 59m59s -> fresh", Urgency(age: 3599, thresholds: standard), .fresh)
equal("age exactly 1h -> fresh", Urgency(age: 3600, thresholds: standard), .fresh)
equal("age 1h00m01s -> stale", Urgency(age: 3601, thresholds: standard), .stale)
equal("age 2h59m59s -> stale", Urgency(age: 10799, thresholds: standard), .stale)
equal("age exactly 3h -> stale", Urgency(age: 10800, thresholds: standard), .stale)
equal("age 3h00m01s -> urgent", Urgency(age: 10801, thresholds: standard), .urgent)
equal("age 5d -> urgent", Urgency(age: 432_000, thresholds: standard), .urgent)

// MARK: - Aggregate

func item(
  _ id: String, waitingSince: Date, requestKind: ReviewRequestKind = .direct
) -> PullRequestItem {
  PullRequestItem(
    id: id, number: 1, title: "t", url: URL(string: "https://example.com")!,
    repository: "acme/service", authorLogin: "dev", authorAvatarURL: nil, isDraft: false,
    additions: 0, deletions: 0, changedFiles: 0, requestKind: requestKind,
    waitingSince: waitingSince)
}

section("Aggregate urgency (drives the menu bar circle)")
check(
  "empty list -> nil (hollow circle)",
  worstUrgency(of: [], now: epoch, thresholds: standard) == nil)
equal(
  "all fresh -> fresh",
  worstUrgency(
    of: [
      item("a", waitingSince: epoch.addingTimeInterval(-60)),
      item("b", waitingSince: epoch.addingTimeInterval(-120)),
    ], now: epoch, thresholds: standard), .fresh)
equal(
  "one urgent among four fresh -> urgent",
  worstUrgency(
    of: [
      item("a", waitingSince: epoch.addingTimeInterval(-60)),
      item("b", waitingSince: epoch.addingTimeInterval(-120)),
      item("c", waitingSince: epoch.addingTimeInterval(-180)),
      item("d", waitingSince: epoch.addingTimeInterval(-4 * 3600)),
    ], now: epoch, thresholds: standard), .urgent)
equal(
  "stale beats fresh but not urgent",
  worstUrgency(
    of: [
      item("a", waitingSince: epoch.addingTimeInterval(-60)),
      item("b", waitingSince: epoch.addingTimeInterval(-2 * 3600)),
    ], now: epoch, thresholds: standard), .stale)
equal(
  "clock skew: future waitingSince clamps to age 0",
  item("a", waitingSince: epoch.addingTimeInterval(3600)).age(now: epoch), 0)

section("PR reference label")
equal(
  "four-digit number", item("a", waitingSince: epoch).reference, "acme/service #1")
check(
  "five-digit number is not grouped",
  PullRequestItem(
    id: "x", number: 16062, title: "t", url: URL(string: "https://example.com")!,
    repository: "acme/service", authorLogin: "dev", authorAvatarURL: nil, isDraft: false,
    additions: 0, deletions: 0, changedFiles: 0, requestKind: .direct, waitingSince: epoch
  ).reference == "acme/service #16062",
  "thousands separator must not appear in a PR number")

// MARK: - waitingSince cascade

section("waitingSince cascade")
let mineEarly = date("2026-08-12T20:15:52Z")
let mineLate = date("2026-08-14T19:31:44Z")
let teamAt = date("2026-08-13T10:00:00Z")
let readyAt = date("2026-08-11T09:00:00Z")
let createdAt = date("2026-08-10T08:00:00Z")

equal(
  "1. request naming me wins over team and ready",
  resolveWaitingSince(
    events: [
      .readyForReview(at: readyAt),
      .reviewRequested(at: teamAt, reviewerLogin: nil),
      .reviewRequested(at: mineEarly, reviewerLogin: "reviewer-me"),
    ], reviewerLogin: "reviewer-me", createdAt: createdAt), mineEarly)

equal(
  "1b. latest request naming me wins (re-request resets the clock)",
  resolveWaitingSince(
    events: [
      .reviewRequested(at: mineEarly, reviewerLogin: "reviewer-me"),
      .reviewRequested(at: mineLate, reviewerLogin: "reviewer-me"),
    ], reviewerLogin: "reviewer-me", createdAt: createdAt), mineLate)

equal(
  "1c. another user's later request does not move my clock",
  resolveWaitingSince(
    events: [
      .reviewRequested(at: mineEarly, reviewerLogin: "reviewer-me"),
      .reviewRequested(at: mineLate, reviewerLogin: "someone-else"),
    ], reviewerLogin: "reviewer-me", createdAt: createdAt), mineEarly)

equal(
  "1d. login comparison is case-insensitive",
  resolveWaitingSince(
    events: [.reviewRequested(at: mineEarly, reviewerLogin: "Reviewer-ME")],
    reviewerLogin: "reviewer-me", createdAt: createdAt), mineEarly)

equal(
  "2. team-only request falls back to any request, not createdAt",
  resolveWaitingSince(
    events: [
      .readyForReview(at: readyAt),
      .reviewRequested(at: teamAt, reviewerLogin: nil),
    ], reviewerLogin: "reviewer-me", createdAt: createdAt), teamAt)

equal(
  "2b. request naming a different user still counts as any-request",
  resolveWaitingSince(
    events: [.reviewRequested(at: teamAt, reviewerLogin: "someone-else")],
    reviewerLogin: "reviewer-me", createdAt: createdAt), teamAt)

equal(
  "3. ready-for-review only",
  resolveWaitingSince(
    events: [.readyForReview(at: readyAt)],
    reviewerLogin: "reviewer-me", createdAt: createdAt), readyAt)

equal(
  "4. no events falls back to createdAt",
  resolveWaitingSince(events: [], reviewerLogin: "reviewer-me", createdAt: createdAt), createdAt)

// MARK: - Direct vs team review requests

section("Request kind (drives the direct-only filter)")
equal(
  "a pending request naming me is direct",
  resolveRequestKind(requestedUserLogins: ["reviewer-me"], reviewerLogin: "reviewer-me"), .direct)
equal(
  "my login among other people's is still direct",
  resolveRequestKind(
    requestedUserLogins: ["dev1", "reviewer-me", "dev2"], reviewerLogin: "reviewer-me"), .direct)
equal(
  "login comparison is case-insensitive",
  resolveRequestKind(requestedUserLogins: ["Reviewer-ME"], reviewerLogin: "reviewer-me"), .direct)
equal(
  "only other people named -> team",
  resolveRequestKind(requestedUserLogins: ["dev1", "dev2"], reviewerLogin: "reviewer-me"), .team)
// Team reviewers carry a name and no login, so they never reach this list. A PR is in the
// queue only because a request exists, so no user login means a team carries it.
equal(
  "no user reviewers -> team",
  resolveRequestKind(requestedUserLogins: [], reviewerLogin: "reviewer-me"), .team)
equal(
  "a login that merely contains mine is not mine",
  resolveRequestKind(requestedUserLogins: ["reviewer-me-2"], reviewerLogin: "reviewer-me"), .team)

// MARK: - Threshold override parsing

section("PRSTATUS_THRESHOLDS override")
equal(
  "valid pair parses",
  UrgencyThresholds.fromEnvironment(["PRSTATUS_THRESHOLDS": "10,20"]),
  UrgencyThresholds(stale: 10, urgent: 20))
equal("absent -> standard", UrgencyThresholds.fromEnvironment([:]), .standard)
equal(
  "malformed -> standard", UrgencyThresholds.fromEnvironment(["PRSTATUS_THRESHOLDS": "abc"]),
  .standard)
equal(
  "inverted pair -> standard",
  UrgencyThresholds.fromEnvironment(["PRSTATUS_THRESHOLDS": "30,10"]), .standard)
equal(
  "single value -> standard", UrgencyThresholds.fromEnvironment(["PRSTATUS_THRESHOLDS": "10"]),
  .standard)

// MARK: - Duration labels

section("Waiting duration labels")
equal("0s", formatWaitingDuration(0), "just now")
equal("59s rounds to just now", formatWaitingDuration(59), "just now")
equal("60s -> 1m", formatWaitingDuration(60), "1m")
equal("11m30s truncates down", formatWaitingDuration(11 * 60 + 30), "11m")
equal("59m -> 59m", formatWaitingDuration(59 * 60), "59m")
equal("exactly 1h omits minutes", formatWaitingDuration(3600), "1h")
equal("2h14m", formatWaitingDuration(2 * 3600 + 14 * 60), "2h 14m")
equal("23h59m", formatWaitingDuration(23 * 3600 + 59 * 60), "23h 59m")
equal("exactly 1d omits hours", formatWaitingDuration(86400), "1d")
equal("3d4h", formatWaitingDuration(3 * 86400 + 4 * 3600), "3d 4h")
equal("days drop stray minutes", formatWaitingDuration(2 * 86400 + 30 * 60), "2d")
equal("negative clamps to just now", formatWaitingDuration(-5), "just now")

// MARK: - Decoding the captured API response

section("Decode captured GraphQL response")
let packageRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()  // SelfTest
  .deletingLastPathComponent()  // Sources
  .deletingLastPathComponent()  // package root
let fixtureURL = packageRoot.appendingPathComponent("Fixtures/response.json")

do {
  let data = try Data(contentsOf: fixtureURL)
  let result = try GitHubClient.decode(data)

  equal("viewer login", result.viewerLogin, "reviewer-me")
  equal("item count", result.items.count, 6)
  check(
    "items arrive oldest first",
    result.items.map(\.waitingSince) == result.items.map(\.waitingSince).sorted())

  func find(_ number: Int) -> PullRequestItem? { result.items.first { $0.number == number } }

  if let pr = find(16135) {
    equal("16135 waitingSince = my request", pr.waitingSince, date("2026-08-17T13:37:05Z"))
    equal("16135 repository", pr.repository, "acme/service")
    equal("16135 changedFiles", pr.changedFiles, 50)
    equal("16135 additions", pr.additions, 2394)
    check("16135 not draft", pr.isDraft == false)
    check("16135 url parsed", pr.url.absoluteString.hasSuffix("/pull/16135"))
    check("16135 avatar parsed", pr.authorAvatarURL != nil)
  } else {
    check("16135 present", false)
  }

  if let pr = find(15916) {
    equal(
      "15916 waitingSince = my later re-request", pr.waitingSince,
      date("2026-08-14T19:31:44Z"))
  } else {
    check("15916 present", false)
  }

  if let pr = find(16131) {
    equal("16131 waitingSince = ready-for-review", pr.waitingSince, date("2026-08-16T01:01:37Z"))
  } else {
    check("16131 present", false)
  }

  if let pr = find(16062) {
    equal("16062 waitingSince = createdAt", pr.waitingSince, date("2026-08-13T22:02:52Z"))
  } else {
    check("16062 present", false)
  }

  if let pr = find(16200) {
    equal(
      "16200 waitingSince = team request (branch 2)", pr.waitingSince,
      date("2026-08-17T13:37:05Z"))
  } else {
    check("16200 present", false)
  }

  if let pr = find(16201) {
    check("16201 is draft", pr.isDraft)
    check("16201 long title preserved", pr.title.count > 100)
  } else {
    check("16201 present", false)
  }

  equal("16135 pending request names me -> direct", find(16135)?.requestKind, .direct)
  equal("15916 pending request names me -> direct", find(15916)?.requestKind, .direct)
  equal("16200 team reviewer only -> team", find(16200)?.requestKind, .team)
  equal("16131 team reviewer only -> team", find(16131)?.requestKind, .team)
  equal(
    "fixture splits two direct from four team",
    result.items.filter { $0.requestKind == .direct }.count, 2)

  // The team-routed PR must age even though no event carries my login — the bug that
  // branch 2 exists to prevent.
  if let pr = find(16200) {
    let fourHoursLater = date("2026-08-17T13:37:05Z").addingTimeInterval(4 * 3600)
    equal(
      "16200 ages to urgent 4h after the team request",
      pr.urgency(now: fourHoursLater, thresholds: standard), .urgent)
  }
} catch {
  check("fixture decodes", false, "\(error)")
}

// MARK: - Error and tolerance paths

section("Decode error handling")
func decodeError(_ json: String) -> GitHubClientError? {
  do {
    _ = try GitHubClient.decode(Data(json.utf8))
    return nil
  } catch let error as GitHubClientError {
    return error
  } catch {
    return nil
  }
}

check(
  "graphql errors array surfaces as .api",
  {
    if case .api = decodeError(#"{"errors":[{"message":"Bad credentials"}]}"#) { return true }
    return false
  }())
check(
  "missing data surfaces as .api",
  {
    if case .api = decodeError(#"{}"#) { return true }
    return false
  }())
check(
  "garbage surfaces as .api",
  {
    if case .api = decodeError("not json at all") { return true }
    return false
  }())

do {
  // search(type: ISSUE) can return non-PR nodes as empty objects; one must not sink
  // the whole response.
  let mixed = #"""
    {"data":{"viewer":{"login":"me"},"search":{"issueCount":2,"nodes":[
      {},
      {"id":"PR_1","number":7,"title":"real","url":"https://github.com/acme/service/pull/7",
       "isDraft":false,"createdAt":"2026-08-17T10:00:00Z","additions":1,"deletions":2,
       "changedFiles":3,"repository":{"nameWithOwner":"acme/service"},
       "author":{"login":"dev","avatarUrl":null},"timelineItems":{"nodes":[]}}
    ]}}}
    """#
  let result = try GitHubClient.decode(Data(mixed.utf8))
  equal("non-PR node dropped, real PR kept", result.items.count, 1)
  equal("kept PR number", result.items.first?.number, 7)
  check("null avatar tolerated", result.items.first?.authorAvatarURL == nil)
  equal("absent reviewRequests -> team", result.items.first?.requestKind, .team)
} catch {
  check("mixed node response decodes", false, "\(error)")
}

do {
  // Only `... on User { login }` is selected, so a bot or a team reviewer decodes without
  // a login. Reading one as a request naming me would defeat the filter.
  let nonUsers = #"""
    {"data":{"viewer":{"login":"me"},"search":{"issueCount":1,"nodes":[
      {"id":"PR_1","number":7,"title":"real","url":"https://github.com/acme/service/pull/7",
       "isDraft":false,"createdAt":"2026-08-17T10:00:00Z","additions":1,"deletions":2,
       "changedFiles":3,"repository":{"nameWithOwner":"acme/service"},
       "author":{"login":"dev","avatarUrl":null},
       "reviewRequests":{"nodes":[
         {"requestedReviewer":{"__typename":"Team","name":"me"}},
         {"requestedReviewer":{"__typename":"Bot"}},
         {"requestedReviewer":null}
       ]},
       "timelineItems":{"nodes":[]}}
    ]}}}
    """#
  let result = try GitHubClient.decode(Data(nonUsers.utf8))
  equal("a team whose name equals my login is not a direct request",
    result.items.first?.requestKind, .team)
} catch {
  check("non-user reviewer response decodes", false, "\(error)")
}

// MARK: - Menu bar appearance

section("Menu bar appearance")
let fresh = item("a", waitingSince: epoch.addingTimeInterval(-60))
let old = item("b", waitingSince: epoch.addingTimeInterval(-4 * 3600))
let emptyQueue = ReviewQueueState.loaded(value: [], at: epoch, refreshError: nil)

func appearance(_ state: ReviewQueueState, at now: Date = epoch) -> StatusAppearance {
  statusAppearance(for: state, now: now, thresholds: standard)
}

equal("never -> unknown", appearance(.never), .unknown)
equal("loading -> unknown", appearance(.loading), .unknown)
equal("failed -> unavailable", appearance(.failed(.ghNotFound)), .unavailable)
equal("loaded empty -> idle", appearance(emptyQueue), .idle)
equal(
  "loaded with items -> waiting at worst urgency",
  appearance(.loaded(value: [fresh, old], at: epoch, refreshError: nil)), .waiting(.urgent))

// The bug this enum exists to prevent: a hollow "all clear" circle while GitHub is
// unreachable is a silent failure that reads as good news.
check(
  "an unreachable GitHub never looks like an empty queue",
  appearance(.failed(.network("offline"))) != appearance(emptyQueue))
check(
  "not-yet-loaded never looks like an empty queue",
  appearance(.loading) != appearance(emptyQueue))

section("Fetch outcome transitions")
let loadedEarlier = ReviewQueueState.loaded(value: [fresh], at: epoch, refreshError: nil)
let offline = GitHubClientError.network("503")

equal(
  "success replaces items and clears any prior error",
  nextState(after: .failed(.ghNotFound), result: .success([old]), now: epoch),
  .loaded(value: [old], at: epoch, refreshError: nil))
equal(
  "success stores the value as given",
  nextState(after: .never, result: .success([fresh, old]), now: epoch).items.map(\.id),
  ["a", "b"])
equal(
  "failure with rows on screen keeps them and records the error",
  nextState(after: loadedEarlier, result: .failure(offline), now: epoch),
  .loaded(value: [fresh], at: epoch, refreshError: offline))
equal(
  "failure with no prior data surfaces the error",
  nextState(after: ReviewQueueState.loading, result: .failure(.ghNotFound), now: epoch),
  .failed(.ghNotFound))
// A queue we successfully learned was empty is knowledge; losing it to one 503 would
// swap a true "nothing waiting" for a false "cannot reach GitHub".
equal(
  "failure after an empty load keeps the known-empty queue and marks it stale",
  nextState(after: emptyQueue, result: .failure(offline), now: epoch),
  .loaded(value: [], at: epoch, refreshError: offline))
equal(
  "a known-empty queue still reads as idle while stale",
  appearance(.loaded(value: [], at: epoch, refreshError: offline)), .idle)
equal(
  "a recovered refresh clears the stale marker",
  nextState(
    after: .loaded(value: [fresh], at: epoch, refreshError: offline),
    result: .success([fresh]), now: epoch),
  .loaded(value: [fresh], at: epoch, refreshError: nil))
equal(
  "kept rows still age while refreshes fail",
  appearance(
    nextState(after: loadedEarlier, result: .failure(offline), now: epoch),
    at: epoch.addingTimeInterval(4 * 3600)), .waiting(.urgent))

// MARK: - Direct-requests-only filter

// The filter narrows the whole state, so the rows, the count and the icon colour all read
// the same queue. These cover the consequences a row-only filter would get wrong.
section("Direct-requests-only filter")
let directFresh = item("direct", waitingSince: epoch.addingTimeInterval(-60))
let teamUrgent = item(
  "team", waitingSince: epoch.addingTimeInterval(-4 * 3600), requestKind: .team)
let mixedQueue = ReviewQueueState.loaded(
  value: [teamUrgent, directFresh], at: epoch, refreshError: nil)

equal(
  "filter off keeps every PR",
  mixedQueue.showing(directRequestsOnly: false).items.map(\.id), ["team", "direct"])
equal(
  "filter on keeps only the PRs naming me",
  mixedQueue.showing(directRequestsOnly: true).items.map(\.id), ["direct"])
equal(
  "filter preserves the oldest-first order",
  ReviewQueueState.loaded(
    value: [
      item("a", waitingSince: epoch.addingTimeInterval(-3 * 3600)),
      item("t", waitingSince: epoch.addingTimeInterval(-2 * 3600), requestKind: .team),
      item("b", waitingSince: epoch.addingTimeInterval(-60)),
    ], at: epoch, refreshError: nil
  ).showing(directRequestsOnly: true).items.map(\.id), ["a", "b"])

// The whole point of narrowing the state rather than the row list: a team PR that aged to
// red must not keep the menu bar red while the filter hides it.
equal(
  "a hidden urgent PR does not colour the icon",
  appearance(mixedQueue.showing(directRequestsOnly: true)), .waiting(.fresh))
equal(
  "the same queue unfiltered still reads urgent",
  appearance(mixedQueue.showing(directRequestsOnly: false)), .waiting(.urgent))
equal(
  "a queue of team PRs only reads as idle under the filter",
  appearance(
    ReviewQueueState.loaded(value: [teamUrgent], at: epoch, refreshError: nil)
      .showing(directRequestsOnly: true)), .idle)

// A filtered-to-empty queue must stay distinguishable from a failure, which is what
// `showing` returning the state's own case preserves.
equal(
  "the filter keeps the stale marker and the timestamp",
  ReviewQueueState.loaded(value: [teamUrgent], at: epoch, refreshError: offline)
    .showing(directRequestsOnly: true),
  .loaded(value: [], at: epoch, refreshError: offline))
equal("the filter leaves a failure alone", ReviewQueueState.failed(.ghNotFound)
  .showing(directRequestsOnly: true), .failed(.ghNotFound))
equal("the filter leaves loading alone", ReviewQueueState.loading.showing(directRequestsOnly: true),
  .loading)
equal(
  "the filter leaves never alone", ReviewQueueState.never.showing(directRequestsOnly: true), .never)

// MARK: - Error presentation

// Each mode has to name a different remedy; the .ghNotFound and .network cases are
// covered here only, since triggering them live would mean removing `gh` or the network.
section("Error presentation")
let allErrors: [GitHubClientError] = [
  .ghNotFound, .notAuthenticated(""), .network("offline"), .api("boom"),
]
check("titles are all distinct", Set(allErrors.map(\.title)).count == allErrors.count)
check("every error has a non-empty hint", allErrors.allSatisfy { !$0.hint.isEmpty })
equal("ghNotFound title", GitHubClientError.ghNotFound.title, "GitHub CLI not found")
check(
  "ghNotFound hint names brew and auth login",
  GitHubClientError.ghNotFound.hint.contains("brew install gh")
    && GitHubClientError.ghNotFound.hint.contains("gh auth login"))
check(
  "empty auth detail falls back to an actionable hint",
  GitHubClientError.notAuthenticated("").hint.contains("gh auth login"))
equal(
  "auth detail is passed through when present",
  GitHubClientError.notAuthenticated("token expired").hint, "token expired")
equal("network detail surfaces verbatim", GitHubClientError.network("offline").hint, "offline")
equal("api detail surfaces verbatim", GitHubClientError.api("boom").hint, "boom")

// MARK: - LoadState projections

section("LoadState projections")
equal(
  "map carries the timestamp and the stale marker",
  LoadState.loaded(value: 2, at: epoch, refreshError: offline).map { $0 * 2 },
  .loaded(value: 4, at: epoch, refreshError: offline))
equal(
  "map leaves a failure alone",
  LoadState<Int>.failed(.ghNotFound).map { $0 + 1 }, .failed(.ghNotFound))
equal("map leaves loading alone", LoadState<Int>.loading.map { $0 + 1 }, .loading)
equal(
  "currentAsOf dates a current value",
  LoadState.loaded(value: 1, at: epoch, refreshError: nil).currentAsOf, epoch)
check(
  "currentAsOf is hidden while stale, so the banner is the only timestamp",
  LoadState.loaded(value: 1, at: epoch, refreshError: offline).currentAsOf == nil)
check("currentAsOf is nil before any load", LoadState<Int>.loading.currentAsOf == nil)

// MARK: - Lookup target parsing

section("Lookup target parsing")
equal("login", LookupTarget(parsing: "jdoe"), .user(login: "jdoe"))
equal("@login", LookupTarget(parsing: "@jdoe"), .user(login: "jdoe"))
equal("surrounding whitespace is trimmed", LookupTarget(parsing: "  jdoe \n"), .user(login: "jdoe"))
equal(
  "org/slug", LookupTarget(parsing: "acme/platform-reviewers"),
  .team(organization: "acme", slug: "platform-reviewers"))
equal(
  "@org/slug", LookupTarget(parsing: "@acme/platform-reviewers"),
  .team(organization: "acme", slug: "platform-reviewers"))
check("blank -> nil", LookupTarget(parsing: "   ") == nil)
check("a space inside -> nil", LookupTarget(parsing: "two words") == nil)
check("a second slash -> nil", LookupTarget(parsing: "a/b/c") == nil)
check("an empty organization -> nil", LookupTarget(parsing: "/team") == nil)
check("an empty slug -> nil", LookupTarget(parsing: "acme/") == nil)
check("non-ASCII letters -> nil", LookupTarget(parsing: "jösé") == nil)
// A colon or a space would be read as another search qualifier once spliced into the query.
check("search syntax is rejected", LookupTarget(parsing: "is:open") == nil)
equal(
  "display name", LookupTarget.team(organization: "acme", slug: "x").displayName, "acme/x")
check(
  "a user's url is GitHub's own list of the same PRs",
  LookupTarget.user(login: "jdoe").url.absoluteString.hasPrefix("https://github.com/pulls?q=")
    && (LookupTarget.user(login: "jdoe").url.query ?? "").contains("user-review-requested:jdoe"))
check(
  "a team's url searches the team qualifier",
  (LookupTarget.team(organization: "acme", slug: "x").url.query ?? "")
    .contains("team-review-requested:acme/x"))
equal(
  "a roster's url is the same list its target opens",
  TeamRoster(slug: "acme/x", name: "x", memberCount: 0, members: [], teamRequestedCount: 0).url,
  LookupTarget.team(organization: "acme", slug: "x").url)

// MARK: - Ranking

section("Ranking by availability (least loaded first)")
func profile(_ login: String) -> ReviewerProfile {
  ReviewerProfile(login: login, name: nil, avatarURL: nil)
}
func load(_ login: String, _ count: Int, oldest: TimeInterval?) -> ReviewerLoad {
  ReviewerLoad(
    reviewer: profile(login), requestedCount: count,
    items: oldest.map { [item(login, waitingSince: epoch.addingTimeInterval(-$0))] } ?? [])
}
let idle = load("zed", 0, oldest: nil)
let oneRecent = load("amy", 1, oldest: 3600)
let oneOld = load("bob", 1, oldest: 5 * 3600)
let busy = load("cat", 4, oldest: 60)

equal(
  "fewest requests first",
  rankByAvailability([busy, oneOld, oneRecent, idle]).map(\.id), ["zed", "amy", "bob", "cat"])
equal(
  "count outranks age: four fresh requests still sit below one old one",
  rankByAvailability([busy, oneOld]).map(\.id), ["bob", "cat"])
equal(
  "among equal counts the shorter longest-wait ranks higher",
  rankByAvailability([oneOld, oneRecent]).map(\.id), ["amy", "bob"])
equal(
  "full ties fall back to login, case-insensitively",
  rankByAvailability([load("bob", 0, oldest: nil), load("Amy", 0, oldest: nil)]).map(\.id),
  ["Amy", "bob"])
check("nothing waiting -> nil urgency", idle.urgency(now: epoch, thresholds: standard) == nil)
equal(
  "urgency follows the oldest request", oneOld.urgency(now: epoch, thresholds: standard),
  .urgent)
equal(
  "items are kept oldest first however they arrive",
  ReviewerLoad(
    reviewer: profile("x"), requestedCount: 2,
    items: [
      item("new", waitingSince: epoch.addingTimeInterval(-60)),
      item("old", waitingSince: epoch.addingTimeInterval(-3600)),
    ]
  ).items.map(\.id), ["old", "new"])
let roster = TeamRoster(
  slug: "acme/x", name: "x", memberCount: 2, members: [profile("cat"), profile("zed")],
  teamRequestedCount: 0)
equal(
  "TeamLoad ranks on construction",
  TeamLoad(roster: roster, members: [busy, idle]).members.map(\.id), ["zed", "cat"])
equal(
  "mapItems re-ranks, because the oldest wait is part of the order",
  LookupResult.team(TeamLoad(roster: roster, members: [oneRecent, oneOld]))
    .mapItems { $0.id == "amy" ? $0.withWaitingSince(epoch.addingTimeInterval(-9 * 3600)) : $0 },
  .team(
    TeamLoad(
      roster: roster,
      members: [
        load("amy", 1, oldest: 9 * 3600), oneOld,
      ])))
check(
  "mapItems leaves not-found alone",
  LookupResult.notFound(.user(login: "x")).mapItems { $0 } == .notFound(.user(login: "x")))

// MARK: - Lookup decoding

section("Decode lookup fixtures")
func fixture(_ name: String) throws -> Data {
  try Data(contentsOf: packageRoot.appendingPathComponent("Fixtures/\(name)"))
}

do {
  let result = try GitHubClient.decodeUserLookup(fixture("lookup-user.json"), login: "dev1")
  if case .user(let load) = result {
    equal("user login", load.reviewer.login, "dev1")
    equal("user display name", load.reviewer.name, "Dev One")
    check("user avatar parsed", load.reviewer.avatarURL != nil)
    equal("user requested count", load.requestedCount, 3)
    equal("user items", load.items.count, 3)
    check(
      "user items are oldest first",
      load.items.map(\.waitingSince) == load.items.map(\.waitingSince).sorted())
    // `user-review-requested:` guarantees a pending request naming dev1, and the clock
    // is resolved for dev1 rather than for the viewer.
    check("every item names dev1 directly", load.items.allSatisfy { $0.requestKind == .direct })
  } else {
    check("user fixture decodes to .user", false, "got \(result)")
  }
} catch {
  check("user fixture decodes", false, "\(error)")
}

do {
  if let roster = try GitHubClient.decodeTeam(fixture("lookup-team.json")) {
    equal("team slug", roster.slug, "acme/platform-reviewers")
    equal("team name", roster.name, "platform-reviewers")
    equal("team member count", roster.memberCount, 5)
    equal(
      "team members keep GitHub's order, which the load aliases rely on",
      roster.members.map(\.login), ["dev2", "dev1", "reviewer-me", "dev4", "dev3"])
    check("a member without a display name decodes", roster.members[3].name == nil)
    equal("PRs requested from the team itself", roster.teamRequestedCount, 5)

    let loads = try GitHubClient.decodeLoads(fixture("lookup-team-load.json"), members: roster.members)
    equal("one load per member", loads.map(\.reviewer.login), roster.members.map(\.login))
    equal("per-member counts", loads.map(\.requestedCount), [0, 3, 2, 7, 0])
    check(
      "every load's items fit its count",
      loads.allSatisfy { $0.items.count <= $0.requestedCount })
    check(
      "a member with nothing waiting has no oldest wait",
      loads[0].oldestWaitingSince == nil && loads[4].oldestWaitingSince == nil)
    equal(
      "the team ranks least loaded first, ties by login",
      TeamLoad(roster: roster, members: loads).members.map(\.id),
      ["dev2", "dev3", "reviewer-me", "dev1", "dev4"])

    let tooMany = roster.members + [profile("dev9")]
    check(
      "a roster longer than the response is a failure, not a silent zero",
      {
        do {
          _ = try GitHubClient.decodeLoads(fixture("lookup-team-load.json"), members: tooMany)
          return false
        } catch let error as GitHubClientError {
          if case .api = error { return true }
          return false
        } catch { return false }
      }())
  } else {
    check("team fixture decodes to a roster", false)
  }
} catch {
  check("team fixture decodes", false, "\(error)")
}

let threeMembers = GitHubClient.loadQuery(memberCount: 3)
check(
  "load query declares one variable per member",
  threeMembers.contains("query($q0: String!, $q1: String!, $q2: String!)"))
check(
  "load query aliases one search per member",
  threeMembers.contains("m2: search(query: $q2") && !threeMembers.contains("m3:"))
check("load query carries the shared fragment", threeMembers.contains("fragment PullRequestFields"))

section("Lookup: not found is an answer, not a failure")
let missingUser = #"""
  {"data":{"user":null,"search":{"issueCount":0,"nodes":[]}},
   "errors":[{"type":"NOT_FOUND","path":["user"],
   "message":"Could not resolve to a User with the login of 'nobody'."}]}
  """#
equal(
  "an unknown user decodes to .notFound",
  try? GitHubClient.decodeUserLookup(Data(missingUser.utf8), login: "nobody"),
  .notFound(.user(login: "nobody")))
let missingOrg = #"""
  {"data":{"organization":null,"search":{"issueCount":0}},
   "errors":[{"type":"NOT_FOUND","path":["organization"],
   "message":"Could not resolve to an Organization with the login of 'nowhere'."}]}
  """#
check(
  "an unknown organization decodes to no roster",
  (try? GitHubClient.decodeTeam(Data(missingOrg.utf8))) == nil)
let missingTeam = #"{"data":{"organization":{"team":null},"search":{"issueCount":0}}}"#
check(
  "an unknown team in a known organization decodes to no roster",
  {
    do { return try GitHubClient.decodeTeam(Data(missingTeam.utf8)) == nil } catch { return false }
  }())
func teamDecodeError(_ json: String) -> GitHubClientError? {
  do {
    _ = try GitHubClient.decodeTeam(Data(json.utf8))
    return nil
  } catch let error as GitHubClientError {
    return error
  } catch {
    return nil
  }
}
equal(
  "any other GraphQL error is still a failure",
  teamDecodeError(#"{"data":null,"errors":[{"type":"RATE_LIMITED","message":"slow down"}]}"#),
  .api("slow down"))
equal(
  "NOT_FOUND mixed with another error is a failure",
  teamDecodeError(
    #"{"data":null,"errors":[{"type":"NOT_FOUND","message":"a"},{"message":"b"}]}"#),
  .api("a b"))

// MARK: - Summary

print("\n\(passed) passed, \(failures.count) failed")
if !failures.isEmpty {
  print("\nfailures:")
  for failure in failures { print("  - \(failure)") }
  exit(1)
}
