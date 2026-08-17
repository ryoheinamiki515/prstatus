import Foundation
import PRStatusCore

/// Where the popover's rows come from: GitHub, or a captured response whose clocks start
/// at launch so the aging behaviour runs on demand.
enum ItemSource {
  static func resolve(
    _ env: [String: String] = ProcessInfo.processInfo.environment
  ) -> () async throws -> [PullRequestItem] {
    guard let fixturePath = env["PRSTATUS_FIXTURE"] else {
      let client = GitHubClient()
      return { try await client.fetch().items }
    }
    let launchedAt = Date()
    return { try fixtureItems(path: fixturePath, anchoredTo: launchedAt) }
  }

  /// Rewrites `waitingSince` to the process start so every run begins at age zero and
  /// walks the thresholds in real time.
  private static func fixtureItems(path: String, anchoredTo anchor: Date) throws
    -> [PullRequestItem]
  {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try GitHubClient.decode(data).items.map { $0.withWaitingSince(anchor) }
  }
}
