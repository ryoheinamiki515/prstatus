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
  /// PRSTATUS_TRACE=1 prints each icon state change, which is how the colour transitions
  /// get verified on a machine where screen capture is unavailable.
  private let isTracing = ProcessInfo.processInfo.environment["PRSTATUS_TRACE"] == "1"
  private var lastTrace = ""

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
    let urgency = model.urgency
    button.image = StatusIcon.image(for: urgency)
    let count = model.state.items.count
    button.title = count > 0 ? " \(count)" : ""

    if case .failed(let error) = model.state {
      button.toolTip = "PRStatus — \(error.title)"
    } else if count == 0 {
      button.toolTip = "PRStatus — nothing waiting on you"
    } else {
      let oldest = model.items.first.map { formatWaitingDuration($0.age(now: model.now)) } ?? ""
      button.toolTip =
        "PRStatus — \(count) waiting on your review, oldest \(oldest)"
    }

    guard isTracing else { return }
    let name = urgency.map { "\($0)" } ?? "empty"
    let stateName: String
    switch model.state {
    case .never: stateName = "never"
    case .loading: stateName = "loading"
    case .loaded: stateName = "loaded"
    case .failed(let error): stateName = "failed(\(error.title): \(error.hint))"
    }
    let trace =
      "\(name) count=\(count) state=\(stateName) image=\(button.image != nil) "
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
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    // Without this the popover opens behind the frontmost app and swallows the first click.
    popover.contentViewController?.view.window?.makeKey()
  }
}
