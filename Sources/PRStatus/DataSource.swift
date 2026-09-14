import Foundation
import PRStatusCore

/// Where the popover's data comes from: GitHub, or captured responses whose clocks start
/// at launch so the aging behaviour runs on demand.
struct DataSource {
  let queue: () async throws -> [PullRequestItem]
  let lookup: (LookupTarget) async throws -> LookupResult

  static func resolve(
    _ env: [String: String] = ProcessInfo.processInfo.environment
  ) -> DataSource {
    guard let fixturePath = env["PRSTATUS_FIXTURE"] else {
      let client = GitHubClient()
      return DataSource(
        queue: { try await client.fetch().items },
        lookup: { try await client.lookup($0) })
    }
    let fixtures = FixtureStore(queueResponse: URL(fileURLWithPath: fixturePath))
    // Rewrites every clock to the process start so each run begins at age zero and walks
    // the thresholds in real time.
    let launchedAt = Date()
    return DataSource(
      queue: { try fixtures.queueItems().map { $0.withWaitingSince(launchedAt) } },
      lookup: {
        try fixtures.lookup($0).mapItems(asOf: launchedAt) {
          $0.withWaitingSince(launchedAt).withUpdatedAt(launchedAt)
        }
      })
  }
}

/// Captured GraphQL responses standing in for the network. The queue response is named
/// explicitly; the lookup responses are its siblings, so one path configures the set.
struct FixtureStore {
  let queueResponse: URL

  private var directory: URL { queueResponse.deletingLastPathComponent() }

  func queueItems() throws -> [PullRequestItem] {
    try GitHubClient.decode(Data(contentsOf: queueResponse)).items
  }

  /// Answers any login with the captured user and any org/slug with the captured team:
  /// the fixture demonstrates the shapes, not GitHub's directory.
  func lookup(_ target: LookupTarget) throws -> LookupResult {
    switch target {
    case .user(let login):
      return try GitHubClient.decodeUserLookup(
        read("lookup-user.json"), login: login, asOf: Date())
    case .team:
      guard let roster = try GitHubClient.decodeTeam(read("lookup-team.json")) else {
        return .notFound(target)
      }
      let members = try GitHubClient.decodeLoads(
        read("lookup-team-load.json"), members: roster.members, asOf: Date())
      return .team(TeamLoad(roster: roster, members: members))
    }
  }

  private func read(_ name: String) throws -> Data {
    try Data(contentsOf: directory.appendingPathComponent(name))
  }
}
