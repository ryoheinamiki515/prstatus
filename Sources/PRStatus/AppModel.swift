import Foundation
import PRStatusCore

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var state: LoadState = .never
  /// Distinct from `.loading`: a background refresh while rows are already on screen must
  /// not blank the list out.
  @Published private(set) var isRefreshing = false
  /// Republished on every tick so both the relative times and the icon colour advance
  /// without needing a network round trip.
  @Published private(set) var now = Date()
  /// Populated by `syncLaunchAtLogin` before the popover is shown, so no
  /// ServiceManagement query runs on the launch path.
  @Published private(set) var launchAtLoginEnabled = false

  let thresholds: UrgencyThresholds
  /// Injected so the aging behaviour can be driven from a fixture instead of the network;
  /// the real app passes GitHubClient's fetch.
  private let loadItems: () async throws -> [PullRequestItem]
  private var timer: Timer?
  private var lastFetch: Date?

  /// Fetching is rate-limit friendly at once a minute, but the clock has to be re-read far
  /// more often than that when thresholds are seconds apart (the aging test).
  private let fetchInterval: TimeInterval = 60
  private var tickInterval: TimeInterval { max(1, min(15, thresholds.stale / 3)) }

  var items: [PullRequestItem] { state.items }

  var appearance: StatusAppearance {
    statusAppearance(for: state, now: now, thresholds: thresholds)
  }

  init(
    thresholds: UrgencyThresholds = .fromEnvironment(),
    loadItems: @escaping () async throws -> [PullRequestItem]
  ) {
    self.thresholds = thresholds
    self.loadItems = loadItems
  }

  func start() {
    let timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) {
      [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    timer.tolerance = tickInterval / 4
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    refresh()
  }

  private func tick() {
    now = Date()
    guard let lastFetch else {
      refresh()
      return
    }
    if now.timeIntervalSince(lastFetch) >= fetchInterval { refresh() }
  }

  /// Called on wake: a lid closed for four hours must not leave a stale green circle.
  func wakeFromSleep() {
    now = Date()
    refresh()
  }

  /// Re-read rather than cached, so the checkbox reflects changes made in System Settings.
  func syncLaunchAtLogin() {
    let enabled = LaunchAtLogin.isEnabled
    guard enabled != launchAtLoginEnabled else { return }
    launchAtLoginEnabled = enabled
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    LaunchAtLogin.setEnabled(enabled)
    syncLaunchAtLogin()
  }

  func refresh() {
    guard !isRefreshing else { return }
    isRefreshing = true
    if case .loaded = state {} else { state = .loading }

    Task { @MainActor in
      defer { isRefreshing = false }
      let result: Result<[PullRequestItem], GitHubClientError>
      do {
        result = .success(try await loadItems())
      } catch let error as GitHubClientError {
        result = .failure(error)
      } catch {
        result = .failure(.network(error.localizedDescription))
      }
      let completedAt = Date()
      lastFetch = completedAt
      now = completedAt
      state = nextState(after: state, result: result, now: completedAt)
    }
  }
}
