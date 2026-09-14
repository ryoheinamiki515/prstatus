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

  /// Selected by every query that returns pull requests, so the viewer's queue and a
  /// reviewer lookup decode through one `Node`.
  static let pullRequestFragment = """
    fragment PullRequestFields on PullRequest {
      id
      number
      title
      url
      isDraft
      createdAt
      updatedAt
      additions
      deletions
      changedFiles
      repository { nameWithOwner }
      author { login avatarUrl }
      reviewRequests(first: 100) {
        nodes {
          requestedReviewer {
            __typename
            ... on User { login }
            ... on Team { name }
          }
        }
      }
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
    """

  static let queueQuery = """
    query($q: String!) {
      viewer { login }
      search(query: $q, type: ISSUE, first: 50) {
        issueCount
        nodes { ...PullRequestFields }
      }
    }
    """ + pullRequestFragment

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
    let data = try await Self.post(Self.queueQuery, variables: ["q": Self.searchQuery], token: token)
    return try Self.decode(data)
  }

  static func post(_ query: String, variables: [String: String], token: String) async throws
    -> Data
  {
    var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
    request.httpMethod = "POST"
    request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("PRStatus", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 20
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "query": query,
      "variables": variables,
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
    return data
  }

  // MARK: - Decode

  public static func decode(_ data: Data) throws -> GitHubFetchResult {
    guard case .found(let payload) = try unwrap(Payload.self, from: data) else {
      throw GitHubClientError.api("GitHub could not resolve the signed-in user.")
    }
    let viewerLogin = payload.viewer.login
    return GitHubFetchResult(viewerLogin: viewerLogin, items: payload.search.items(for: viewerLogin))
  }

  enum Unwrapped<Payload> {
    case found(Payload)
    /// GitHub answered, and the answer is that a named user or organization does not
    /// exist. It arrives as a null field plus a NOT_FOUND error, which is a fact about the
    /// name rather than a failure of the request.
    case notFound
  }

  /// Opens the GraphQL envelope: errors other than NOT_FOUND, or a missing `data`, are
  /// failures of the request as a whole.
  static func unwrap<Payload: Decodable>(_ type: Payload.Type, from data: Data) throws
    -> Unwrapped<Payload>
  {
    let envelope: Envelope<Payload>
    do {
      envelope = try JSONDecoder().decode(Envelope<Payload>.self, from: data)
    } catch {
      throw GitHubClientError.api("Unexpected response shape: \(error.localizedDescription)")
    }

    if let errors = envelope.errors, !errors.isEmpty {
      guard errors.allSatisfy({ $0.type == "NOT_FOUND" }) else {
        throw GitHubClientError.api(errors.map(\.message).joined(separator: " "))
      }
      return .notFound
    }
    guard let payload = envelope.data else {
      throw GitHubClientError.api("Response contained no data.")
    }
    return .found(payload)
  }

  // MARK: - Wire types

  struct Envelope<Payload: Decodable>: Decodable {
    let data: Payload?
    let errors: [Message]?
  }
  struct Message: Decodable {
    let message: String
    let type: String?
  }
  struct Payload: Decodable {
    let viewer: Viewer
    let search: Search
  }
  struct Viewer: Decodable { let login: String }

  /// `nodes` is absent when a query asks for the count alone.
  struct Search: Decodable {
    let issueCount: Int
    let nodes: [Node]?

    /// Oldest first, with every clock resolved for `reviewerLogin`.
    func items(for reviewerLogin: String) -> [PullRequestItem] {
      (nodes ?? []).compactMap { $0.toItem(reviewerLogin: reviewerLogin) }.oldestFirst()
    }

    /// Sizes only, for the reviewed-by search.
    var reviewedPullRequests: [ReviewedPullRequest] {
      (nodes ?? []).compactMap { node in
        guard let number = node.number else { return nil }
        return ReviewedPullRequest(
          number: number, changedLines: (node.additions ?? 0) + (node.deletions ?? 0))
      }
    }
  }

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
    let updatedAt: String?
    let additions: Int?
    let deletions: Int?
    let changedFiles: Int?
    let repository: Repository?
    let author: Author?
    let reviewRequests: ReviewRequests?
    let timelineItems: TimelineItems?

    func toItem(reviewerLogin: String) -> PullRequestItem? {
      guard let id, let number, let title,
        let urlString = url, let url = URL(string: urlString),
        let createdAtString = createdAt, let createdAt = Date(githubTimestamp: createdAtString)
      else { return nil }

      let events = (timelineItems?.nodes ?? []).compactMap { $0.toEvent() }
      let requestedUserLogins = (reviewRequests?.nodes ?? []).compactMap {
        $0.requestedReviewer?.login
      }
      return PullRequestItem(
        id: id,
        number: number,
        title: title,
        url: url,
        repository: repository?.nameWithOwner ?? "unknown",
        authorLogin: author?.login ?? "ghost",
        authorAvatarURL: author?.avatarUrl.flatMap(URL.init(string:)),
        isDraft: isDraft ?? false,
        // A PR that was never touched reports updatedAt == createdAt, so creation is the
        // floor rather than a guess when the field is absent.
        updatedAt: updatedAt.flatMap(Date.init(githubTimestamp:)) ?? createdAt,
        additions: additions ?? 0,
        deletions: deletions ?? 0,
        changedFiles: changedFiles ?? 0,
        requestKind: resolveRequestKind(
          requestedUserLogins: requestedUserLogins, reviewerLogin: reviewerLogin),
        waitingSince: resolveWaitingSince(
          events: events, reviewerLogin: reviewerLogin, createdAt: createdAt))
    }
  }

  struct Repository: Decodable { let nameWithOwner: String }
  struct Author: Decodable {
    let login: String?
    let avatarUrl: String?
  }
  /// Only `... on User { login }` is selected, so a bot or a team reviewer decodes with a
  /// nil login and never counts as a request naming the reviewer.
  struct ReviewRequests: Decodable { let nodes: [ReviewRequestNode]? }
  struct ReviewRequestNode: Decodable { let requestedReviewer: RequestedReviewer? }

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
  /// into the team branch of both `resolveWaitingSince` and `resolveRequestKind`.
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
