import AppKit
import Combine
import PRStatusCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let model = AppModel(loadItems: ItemSource.resolve())
  private var statusItem: NSStatusItem!
  private var popover: NSPopover!
  private var cancellable: AnyCancellable?
  /// PRSTATUS_TRACE=1 prints each icon state change and the status item's screen frame.
  private let isTracing = ProcessInfo.processInfo.environment["PRSTATUS_TRACE"] == "1"
  private var lastTrace = ""
  private var lastDrawn: (StatusAppearance, Int)?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.imagePosition = .imageLeading
    statusItem.button?.target = self
    statusItem.button?.action = #selector(togglePopover)

    popover = NSPopover()
    popover.behavior = .transient
    popover.animates = false
    popover.contentViewController = NSHostingController(
      rootView: PRListView(
        model: model,
        onOpen: { [weak self] url in
          NSWorkspace.shared.open(url)
          self?.popover.performClose(nil)
        },
        onQuit: { NSApp.terminate(nil) }))

    // Any published change re-renders the icon, so the colour tracks the same `now` the
    // rows do instead of drifting on its own schedule.
    cancellable = model.objectWillChange.sink { [weak self] _ in
      Task { @MainActor in self?.updateStatusItem() }
    }

    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(handleWake),
      name: NSWorkspace.didWakeNotification, object: nil)

    updateStatusItem()
    model.start()

    // The status item is not positioned at first paint, so its frame is reported once the
    // menu bar has placed it. Used to crop a capture to the icon.
    if isTracing {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        guard let frame = self?.statusItem.button?.window?.frame else { return }
        print(
          "statusItemFrame=\(Int(frame.minX)),\(Int(frame.minY)),"
            + "\(Int(frame.width)),\(Int(frame.height))")
        fflush(stdout)
      }
    }
  }

  private func updateStatusItem() {
    guard let button = statusItem.button else { return }
    let appearance = model.appearance
    let count = model.state.items.count

    // `now` republishes every tick, so most calls here change nothing. Rebuilding the
    // NSImage anyway would dirty the status item several times a minute for no reason.
    if lastDrawn.map({ $0 != appearance || $1 != count }) ?? true {
      lastDrawn = (appearance, count)
      button.image = StatusIcon.image(for: appearance)
      button.title = count > 0 ? " \(count)" : ""
    }
    // Not guarded: the tooltip carries a duration that advances between redraws.
    button.toolTip = "PRStatus — \(tooltipDetail)"

    guard isTracing else { return }
    let stateName: String
    switch model.state {
    case .never: stateName = "never"
    case .loading: stateName = "loading"
    case .loaded(_, _, let refreshError):
      stateName = refreshError.map { "loaded(stale: \($0.title))" } ?? "loaded"
    case .failed(let error): stateName = "failed(\(error.title): \(error.hint))"
    }
    let trace =
      "\(appearance) count=\(count) state=\(stateName) image=\(button.image != nil) "
      + "title=\"\(button.title)\""
    guard trace != lastTrace else { return }
    lastTrace = trace
    let stamp = Date().formatted(date: .omitted, time: .standard)
    // Screen frame lets a capture be cropped to the icon without hunting for it.
    let frame = button.window?.frame ?? .zero
    print(
      "[\(stamp)] icon=\(trace) frame=\(Int(frame.origin.x)),\(Int(frame.origin.y)),"
        + "\(Int(frame.width)),\(Int(frame.height))")
    fflush(stdout)
  }

  /// Switches on the state rather than the appearance: the appearance is the icon's
  /// decision and deliberately drops the error and the timestamp this needs.
  private var tooltipDetail: String {
    switch model.state {
    case .never, .loading:
      return "checking GitHub…"
    case .failed(let error):
      return error.title
    case .loaded(let items, let at, let refreshError):
      let stale = refreshError.map { "\($0.title.lowercased()) — showing \(formatAsOfTime(at))" }
      guard let oldest = items.first else {
        return stale ?? "nothing waiting on you"
      }
      let summary =
        "\(items.count) waiting on your review, "
        + "oldest \(formatWaitingDuration(oldest.age(now: model.now)))"
      return stale.map { "\(summary) (\($0))" } ?? summary
    }
  }

  @objc private func handleWake() {
    model.wakeFromSleep()
  }

  @objc private func togglePopover() {
    guard let button = statusItem.button else { return }
    if popover.isShown {
      popover.performClose(nil)
      return
    }
    model.refresh()
    model.syncLaunchAtLogin()
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    // Without this the popover opens behind the frontmost app and swallows the first click.
    popover.contentViewController?.view.window?.makeKey()
  }
}
