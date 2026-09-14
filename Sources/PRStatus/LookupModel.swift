import Foundation
import PRStatusCore

/// What the field last submitted, and what came of reading it.
enum LookupSubmission: Equatable {
  case none
  /// Text GitHub could not name: a space, a second slash, a stray character.
  case unreadable(String)
  case target(LookupTarget)
}

/// Answers "how many PRs are waiting on this person, or on each member of this team" for
/// whatever name the field holds.
@MainActor
final class LookupModel: ObservableObject {
  /// What the field shows. Editing changes nothing until `submit`.
  @Published var text: String
  @Published private(set) var submission: LookupSubmission
  /// Describes the target in `submission`, and is `.never` whenever there is none.
  @Published private(set) var state: LoadState<LookupResult> = .never
  @Published private(set) var isRefreshing = false

  private let perform: (LookupTarget) async throws -> LookupResult
  /// Advanced by every fetch and by every change of name, so an answer that lands after
  /// either is dropped rather than filed under the wrong name.
  private var generation = 0

  var target: LookupTarget? {
    if case .target(let target) = submission { return target }
    return nil
  }

  init(text: String, perform: @escaping (LookupTarget) async throws -> LookupResult) {
    self.text = text
    self.submission = Self.read(text)
    self.perform = perform
  }

  private static func read(_ text: String) -> LookupSubmission {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .none }
    guard let target = LookupTarget(parsing: trimmed) else { return .unreadable(trimmed) }
    return .target(target)
  }

  func submit() {
    Preferences.setLookupText(text)
    let submission = Self.read(text)
    if submission != self.submission {
      self.submission = submission
      state = .never
      generation += 1
      isRefreshing = false
    }
    refresh()
  }

  func refresh() {
    guard let target, !isRefreshing else { return }
    isRefreshing = true
    if case .loaded = state {} else { state = .loading }
    generation += 1
    let generation = self.generation

    Task { @MainActor in
      let result = await outcome { try await perform(target) }
      guard generation == self.generation else { return }
      isRefreshing = false
      state = nextState(after: state, result: result, now: Date())
    }
  }
}
