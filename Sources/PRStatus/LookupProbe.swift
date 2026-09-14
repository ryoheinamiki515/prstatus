import Foundation
import PRStatusCore

/// PRSTATUS_LOOKUP_PROBE=<name> runs one lookup against GitHub and prints what the pane
/// would show, so the request path can be checked without clicking through the popover.
enum LookupProbe {
  static func run(_ text: String) -> Int32 {
    guard let target = LookupTarget(parsing: text) else {
      print("cannot read \"\(text)\" as a login or an org/slug")
      return 1
    }
    let finished = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var exitCode: Int32 = 0
    // Detached rather than main-actor: the main thread is about to block on the semaphore.
    Task.detached {
      let started = Date()
      do {
        let result = try await GitHubClient().lookup(target)
        report(result, elapsed: Date().timeIntervalSince(started))
      } catch {
        print("failed after \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(error)")
        exitCode = 1
      }
      finished.signal()
    }
    finished.wait()
    return exitCode
  }

  private static func report(_ result: LookupResult, elapsed: TimeInterval) {
    let now = Date()
    print("\(String(format: "%.1f", elapsed))s")
    switch result {
    case .notFound(let target):
      print("not found: \(target.displayName)")
    case .user(let load):
      print("\(load.reviewer.login): \(describe(load, now: now))")
    case .team(let team):
      print(
        "\(team.roster.slug): \(team.roster.memberCount) members, "
          + "\(team.roster.teamRequestedCount) requested from the team")
      for load in team.members {
        print("  \(load.reviewer.login.padding(toLength: 24, withPad: " ", startingAt: 0))"
            + describe(load, now: now))
      }
    }
  }

  private static func describe(_ load: ReviewerLoad, now: Date) -> String {
    let dormant = load.dormantCount == 0 ? "" : ", \(load.dormantCount) dormant"
    guard let age = load.oldestAge(now: now) else { return "0 active\(dormant)" }
    return "\(load.activeCount) active, oldest \(formatWaitingDuration(age))\(dormant)"
  }
}
