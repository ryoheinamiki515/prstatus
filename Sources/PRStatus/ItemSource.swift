import Foundation
import PRStatusCore

/// Where the popover's rows come from. The live path talks to GitHub; the fixture path
/// exists because the aging behaviour has to be observable on demand, and that cannot be
/// arranged by waiting for someone to request a review at a convenient moment.
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
    return try GitHubClient.decode(data).items.map { item in
      PullRequestItem(
        id: item.id, number: item.number, title: item.title, url: item.url,
        repository: item.repository, authorLogin: item.authorLogin,
        authorAvatarURL: item.authorAvatarURL, isDraft: item.isDraft,
        additions: item.additions, deletions: item.deletions,
        changedFiles: item.changedFiles, waitingSince: anchor)
    }
  }
}
