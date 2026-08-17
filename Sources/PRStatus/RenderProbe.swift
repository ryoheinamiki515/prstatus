import AppKit
import PRStatusCore
import SwiftUI

/// PRSTATUS_RENDER=<dir> writes a PNG of each popover state. Offscreen rendering needs no
/// Screen Recording permission, so the UI can be inspected on a machine where screen
/// capture is unavailable.
@MainActor
enum RenderProbe {
  static func run(outputDirectory: String) {
    let directory = URL(fileURLWithPath: outputDirectory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let fixture = URL(fileURLWithPath: "Fixtures/response.json")
    let decoded = (try? GitHubClient.decode(Data(contentsOf: fixture)).items) ?? []
    // The fixture's timestamps are fixed, so with real time they all read as urgent. Ages
    // are spread across the thresholds here so a documentation shot shows every colour.
    let spread: [TimeInterval] = [
      12 * 60, 40 * 60, 75 * 60, 150 * 60, 4 * 3600, 3 * 86400 + 4 * 3600,
    ]
    let now = Date()
    let fixtureItems = decoded.enumerated().map { index, item in
      item.withWaitingSince(now.addingTimeInterval(-spread[index % spread.count]))
    }

    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      let suffix = appearance == .aqua ? "light" : "dark"
      render("01-loading-\(suffix)", model: model { try await never() }, appearance, directory)
      render("02-empty-\(suffix)", model: settled { [] }, appearance, directory)
      render("03-loaded-\(suffix)", model: settled { fixtureItems }, appearance, directory)
      render(
        "04-error-auth-\(suffix)",
        model: settled { throw GitHubClientError.notAuthenticated("") }, appearance, directory)
      render(
        "05-error-gh-missing-\(suffix)", model: settled { throw GitHubClientError.ghNotFound },
        appearance, directory)
      render(
        "06-single-item-\(suffix)", model: settled { Array(fixtureItems.prefix(1)) },
        appearance, directory)
      render("07-stale-\(suffix)", model: stale(fixtureItems), appearance, directory)
      render("08-stale-empty-\(suffix)", model: stale([]), appearance, directory)
    }
  }

  private static func never() async throws -> [PullRequestItem] {
    try await Task.sleep(nanoseconds: 60_000_000_000)
    return []
  }

  private static func model(
    _ load: @escaping () async throws -> [PullRequestItem]
  ) -> AppModel {
    AppModel(thresholds: .standard, loadItems: load)
  }

  /// Waits on the model reaching a terminal state rather than on a fixed delay, so a slow
  /// machine cannot silently render a spinner into a documentation image.
  private static func settled(
    _ load: @escaping () async throws -> [PullRequestItem]
  ) -> AppModel {
    let model = model(load)
    model.refresh()
    guard runLoop(until: { model.state != .loading }) else {
      fatalError("model never left .loading; refusing to render a spinner")
    }
    return model
  }

  /// Loads once, then fails — the state a queue reaches when GitHub goes away after a
  /// successful fetch, which is the only way to see the stale banner.
  private static func stale(_ items: [PullRequestItem]) -> AppModel {
    var served = false
    let model = settled {
      defer { served = true }
      if served { throw GitHubClientError.network("The request timed out.") }
      return items
    }
    model.refresh()
    guard runLoop(until: { if case .loaded(_, _, .some) = model.state { true } else { false } })
    else {
      fatalError("model never reached a stale state")
    }
    return model
  }

  /// Pumps the run loop in short slices until `condition` holds, returning false on timeout.
  private static func runLoop(
    until condition: () -> Bool, limit: TimeInterval = 10
  ) -> Bool {
    let deadline = Date().addingTimeInterval(limit)
    while !condition() {
      if Date() >= deadline { return false }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return true
  }

  /// Draws through a real NSHostingView in a window rather than SwiftUI's ImageRenderer:
  /// ImageRenderer leaves AppKit-backed content (ScrollView bodies, checkboxes) blank,
  /// which reads as a layout bug that is not there.
  private static func render(
    _ name: String, model: AppModel, _ appearanceName: NSAppearance.Name, _ directory: URL
  ) {
    if case .never = model.state { model.refresh() }
    let appearance = NSAppearance(named: appearanceName)
    // NSPopover supplies the background in the app; an opaque one is added here so the
    // capture is not transparent pixels over an assumed backdrop.
    let view = PRListView(model: model, onOpen: { _ in }, onQuit: {})
      .background(Color(nsColor: .windowBackgroundColor))
    let hosting = NSHostingView(rootView: view)
    hosting.appearance = appearance
    hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)

    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = hosting
    window.displayIfNeeded()
    hosting.layoutSubtreeIfNeeded()
    // Layout exposes no completion signal to wait on; the snapshot is inspected by eye.
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))

    let bounds = hosting.bounds
    guard bounds.width > 0, bounds.height > 0,
      let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds)
    else {
      print("render \(name): FAILED (bounds \(bounds.size))")
      return
    }
    hosting.cacheDisplay(in: bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
      print("render \(name): FAILED (no png)")
      return
    }
    let url = directory.appendingPathComponent("\(name).png")
    try? png.write(to: url)
    print("render \(name): \(Int(bounds.width))x\(Int(bounds.height)) -> \(url.path)")
  }
}
