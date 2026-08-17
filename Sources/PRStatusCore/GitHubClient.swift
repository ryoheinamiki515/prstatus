import Foundation

/// Failure modes are kept distinct because each needs a different action from the
/// user: install/locate `gh`, re-authenticate, or just retry.
public enum GitHubClientError: Error, Sendable, Equatable {
  case ghNotFound
  case notAuthenticated(String)
  case network(String)
  case api(String)

  public var title: String {
    switch self {
    case .ghNotFound: return "GitHub CLI not found"
    case .notAuthenticated: return "Not signed in to GitHub"
    case .network: return "Can't reach GitHub"
    case .api: return "GitHub returned an error"
    }
  }

  public var hint: String {
    switch self {
    case .ghNotFound:
      return "Install it with `brew install gh`, then sign in with `gh auth login`."
    case .notAuthenticated(let detail):
      return detail.isEmpty ? "Run `gh auth login` in a terminal." : detail
    case .network(let detail):
      return detail
    case .api(let detail):
      return detail
    }
  }
}

public struct GitHubFetchResult: Sendable, Equatable {
  public let viewerLogin: String
  public let items: [PullRequestItem]

  public init(viewerLogin: String, items: [PullRequestItem]) {
    self.viewerLogin = viewerLogin
    self.items = items
  }
}

public struct GitHubClient: Sendable {
  public init() {}

  static let searchQuery = "is:open is:pr review-requested:@me archived:false"

  static let graphQLQuery = """
    query($q: String!) {
      viewer { login }
      search(query: $q, type: ISSUE, first: 50) {
        issueCount
        nodes {
          ... on PullRequest {
            id
            number
            title
            url
            isDraft
            createdAt
            additions
            deletions
            changedFiles
            repository { nameWithOwner }
            author { login avatarUrl }
            timelineItems(last: 100, itemTypes: [REVIEW_REQUESTED_EVENT, READY_FOR_REVIEW_EVENT]) {
              nodes {
                __typename
                ... on ReviewRequestedEvent {
                  createdAt
                  requestedReviewer {
                    __typename
                    ... on User { login }
                    ... on Team { name }
                  }
                }
                ... on ReadyForReviewEvent { createdAt }
              }
            }
          }
        }
      }
    }
    """

  // MARK: - Token

  /// A Finder-launched .app gets a minimal PATH that excludes Homebrew, so the
  /// binary has to be located explicitly rather than resolved by name.
  static let ghCandidatePaths = [
    "/opt/homebrew/bin/gh",
    "/usr/local/bin/gh",
    "/usr/bin/gh",
  ]

  static func discoverGhPath() -> String? {
    let fileManager = FileManager.default
    for path in ghCandidatePaths where fileManager.isExecutableFile(atPath: path) {
      return path
    }
    guard let resolved = try? runProcess("/bin/zsh", ["-lc", "command -v gh"]) else { return nil }
    let trimmed = resolved.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard resolved.exitCode == 0, !trimmed.isEmpty,
      fileManager.isExecutableFile(atPath: trimmed)
    else { return nil }
    return trimmed
  }

  /// The returned token is passed straight into a request header and is never logged,
  /// printed, or written to disk.
  static func fetchToken() throws -> String {
    guard let ghPath = discoverGhPath() else { throw GitHubClientError.ghNotFound }

    let result: ProcessResult
    do {
      result = try runProcess(ghPath, ["auth", "token"])
    } catch {
      throw GitHubClientError.notAuthenticated("Could not run `gh auth token`.")
    }

    let token = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.exitCode == 0, !token.isEmpty else {
      let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
      throw GitHubClientError.notAuthenticated(
        detail.isEmpty ? "Run `gh auth login` in a terminal." : detail)
    }
    return token
  }

  struct ProcessResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
  }

  static func runProcess(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ProcessResult(
      exitCode: process.terminationStatus,
      standardOutput: String(decoding: outData),
      standardError: String(decoding: errData))
  }

  // MARK: - Fetch

  public func fetch() async throws -> GitHubFetchResult {
    let token = try Self.fetchToken()

    var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
    request.httpMethod = "POST"
    request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("PRStatus", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 20
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "query": Self.graphQLQuery,
      "variables": ["q": Self.searchQuery],
    ])

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw GitHubClientError.network(error.localizedDescription)
    }

    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
      if http.statusCode == 401 {
        throw GitHubClientError.notAuthenticated(
          "GitHub rejected the token. Run `gh auth login` again.")
      }
      throw GitHubClientError.api("HTTP \(http.statusCode) from api.github.com.")
    }

    return try Self.decode(data)
  }

  // MARK: - Decode

  public static func decode(_ data: Data) throws -> GitHubFetchResult {
    let decoder = JSONDecoder()
    let envelope: Envelope
    do {
      envelope = try decoder.decode(Envelope.self, from: data)
    } catch {
      throw GitHubClientError.api("Unexpected response shape: \(error.localizedDescription)")
    }

    if let errors = envelope.errors, !errors.isEmpty {
      throw GitHubClientError.api(errors.map(\.message).joined(separator: " "))
    }
    guard let payload = envelope.data else {
      throw GitHubClientError.api("Response contained no data.")
    }

    let viewerLogin = payload.viewer.login
    let items = payload.search.nodes.compactMap { $0.toItem(viewerLogin: viewerLogin) }
    return GitHubFetchResult(viewerLogin: viewerLogin, items: items)
  }

  // MARK: - Wire types

  struct Envelope: Decodable {
    let data: Payload?
    let errors: [Message]?
  }
  struct Message: Decodable { let message: String }
  struct Payload: Decodable {
    let viewer: Viewer
    let search: Search
  }
  struct Viewer: Decodable { let login: String }
  struct Search: Decodable { let nodes: [Node] }

  /// `search(type: ISSUE)` can yield nodes that are not pull requests, which arrive as
  /// empty objects. Every field is optional so one such node cannot fail the whole
  /// decode; `toItem` drops anything lacking the essentials.
  struct Node: Decodable {
    let id: String?
    let number: Int?
    let title: String?
    let url: String?
    let isDraft: Bool?
    let createdAt: String?
    let additions: Int?
    let deletions: Int?
    let changedFiles: Int?
    let repository: Repository?
    let author: Author?
    let timelineItems: TimelineItems?

    func toItem(viewerLogin: String) -> PullRequestItem? {
      guard let id, let number, let title,
        let urlString = url, let url = URL(string: urlString),
        let createdAtString = createdAt, let createdAt = Date(githubTimestamp: createdAtString)
      else { return nil }

      let events = (timelineItems?.nodes ?? []).compactMap { $0.toEvent() }
      return PullRequestItem(
        id: id,
        number: number,
        title: title,
        url: url,
        repository: repository?.nameWithOwner ?? "unknown",
        authorLogin: author?.login ?? "ghost",
        authorAvatarURL: author?.avatarUrl.flatMap(URL.init(string:)),
        isDraft: isDraft ?? false,
        additions: additions ?? 0,
        deletions: deletions ?? 0,
        changedFiles: changedFiles ?? 0,
        waitingSince: resolveWaitingSince(
          events: events, viewerLogin: viewerLogin, createdAt: createdAt))
    }
  }

  struct Repository: Decodable { let nameWithOwner: String }
  struct Author: Decodable {
    let login: String?
    let avatarUrl: String?
  }
  struct TimelineItems: Decodable { let nodes: [TimelineNode]? }

  struct TimelineNode: Decodable {
    let typename: String?
    let createdAt: String?
    let requestedReviewer: RequestedReviewer?

    enum CodingKeys: String, CodingKey {
      case typename = "__typename"
      case createdAt
      case requestedReviewer
    }

    func toEvent() -> TimelineEvent? {
      guard let createdAtString = createdAt,
        let at = Date(githubTimestamp: createdAtString)
      else { return nil }
      switch typename {
      case "ReviewRequestedEvent":
        return .reviewRequested(at: at, reviewerLogin: requestedReviewer?.login)
      case "ReadyForReviewEvent":
        return .readyForReview(at: at)
      default:
        return nil
      }
    }
  }

  /// A team reviewer has `name` but no `login`; leaving `login` nil is what routes it
  /// into the team branch of `resolveWaitingSince`.
  struct RequestedReviewer: Decodable {
    let typename: String?
    let login: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
      case typename = "__typename"
      case login
      case name
    }
  }
}

extension String {
  init(decoding data: Data) {
    self = String(data: data, encoding: .utf8) ?? ""
  }
}

extension Date {
  /// GitHub emits `2026-07-31T21:24:30Z`; the fractional-seconds variant is accepted
  /// too so a server-side format change does not blank the list.
  public init?(githubTimestamp: String) {
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: githubTimestamp) {
      self = date
      return
    }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: githubTimestamp) {
      self = date
      return
    }
    return nil
  }
}
