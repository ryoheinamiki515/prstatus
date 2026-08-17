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

  /// Kicks off the load and lets the run loop settle so the model reaches its terminal
  /// state before the snapshot is taken.
  private static func settled(
    _ load: @escaping () async throws -> [PullRequestItem]
  ) -> AppModel {
    let model = model(load)
    model.refresh()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    return model
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
    // Lets AsyncImage placeholders and any pending layout settle before the snapshot.
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
