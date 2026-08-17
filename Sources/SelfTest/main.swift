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

func item(_ id: String, waitingSince: Date) -> PullRequestItem {
  PullRequestItem(
    id: id, number: 1, title: "t", url: URL(string: "https://example.com")!,
    repository: "acme/service", authorLogin: "dev", authorAvatarURL: nil, isDraft: false,
    additions: 0, deletions: 0, changedFiles: 0, waitingSince: waitingSince)
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
    additions: 0, deletions: 0, changedFiles: 0, waitingSince: epoch
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
    ], viewerLogin: "reviewer-me", createdAt: createdAt), mineEarly)

equal(
  "1b. latest request naming me wins (re-request resets the clock)",
  resolveWaitingSince(
    events: [
      .reviewRequested(at: mineEarly, reviewerLogin: "reviewer-me"),
      .reviewRequested(at: mineLate, reviewerLogin: "reviewer-me"),
    ], viewerLogin: "reviewer-me", createdAt: createdAt), mineLate)

equal(
  "1c. another user's later request does not move my clock",
  resolveWaitingSince(
    events: [
      .reviewRequested(at: mineEarly, reviewerLogin: "reviewer-me"),
      .reviewRequested(at: mineLate, reviewerLogin: "someone-else"),
    ], viewerLogin: "reviewer-me", createdAt: createdAt), mineEarly)

equal(
  "1d. login comparison is case-insensitive",
  resolveWaitingSince(
    events: [.reviewRequested(at: mineEarly, reviewerLogin: "Reviewer-ME")],
    viewerLogin: "reviewer-me", createdAt: createdAt), mineEarly)

equal(
  "2. team-only request falls back to any request, not createdAt",
  resolveWaitingSince(
    events: [
      .readyForReview(at: readyAt),
      .reviewRequested(at: teamAt, reviewerLogin: nil),
    ], viewerLogin: "reviewer-me", createdAt: createdAt), teamAt)

equal(
  "2b. request naming a different user still counts as any-request",
  resolveWaitingSince(
    events: [.reviewRequested(at: teamAt, reviewerLogin: "someone-else")],
    viewerLogin: "reviewer-me", createdAt: createdAt), teamAt)

equal(
  "3. ready-for-review only",
  resolveWaitingSince(
    events: [.readyForReview(at: readyAt)],
    viewerLogin: "reviewer-me", createdAt: createdAt), readyAt)

equal(
  "4. no events falls back to createdAt",
  resolveWaitingSince(events: [], viewerLogin: "reviewer-me", createdAt: createdAt), createdAt)

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
} catch {
  check("mixed node response decodes", false, "\(error)")
}

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

// MARK: - Summary

print("\n\(passed) passed, \(failures.count) failed")
if !failures.isEmpty {
  print("\nfailures:")
  for failure in failures { print("  - \(failure)") }
  exit(1)
}
