import Foundation
import ServiceManagement

/// SMAppService is the supported route, but it validates the bundle's signature and this
/// app is only ad-hoc signed (no Developer ID). When registration is refused we fall back
/// to a LaunchAgent plist, which has no signing requirement.
enum LaunchAtLogin {
  private static let agentLabel = "ai.outtake.prstatus"

  private static var agentURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
  }

  static var isEnabled: Bool {
    if SMAppService.mainApp.status == .enabled { return true }
    return FileManager.default.fileExists(atPath: agentURL.path)
  }

  static func setEnabled(_ enabled: Bool) {
    enabled ? enable() : disable()
  }

  private static func enable() {
    do {
      try SMAppService.mainApp.register()
      if SMAppService.mainApp.status == .enabled { return }
    } catch {
      NSLog("PRStatus: SMAppService.register failed (%@); using LaunchAgent", "\(error)")
    }
    writeLaunchAgent()
  }

  private static func disable() {
    if SMAppService.mainApp.status == .enabled {
      try? SMAppService.mainApp.unregister()
    }
    removeLaunchAgent()
  }

  private static func writeLaunchAgent() {
    let executable = Bundle.main.executableURL?.path ?? ProcessInfo.processInfo.arguments[0]
    let plist: [String: Any] = [
      "Label": agentLabel,
      "ProgramArguments": [executable],
      "RunAtLoad": true,
      "ProcessType": "Interactive",
    ]
    do {
      let directory = agentURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
      let data = try PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0)
      try data.write(to: agentURL, options: .atomic)
    } catch {
      NSLog("PRStatus: could not write LaunchAgent: %@", "\(error)")
    }
  }

  private static func removeLaunchAgent() {
    try? FileManager.default.removeItem(at: agentURL)
  }

  /// PRSTATUS_LOGIN_PROBE=1 exercises enable/disable and reports which mechanism took
  /// effect, so the ad-hoc-signing risk around SMAppService is answered by observation
  /// rather than left to chance. Ends with the setting back where it started.
  static func runProbe() {
    let started = isEnabled
    print("initial: isEnabled=\(started) smStatus=\(statusName) agentExists=\(agentExists)")

    setEnabled(true)
    let mechanism =
      SMAppService.mainApp.status == .enabled
      ? "SMAppService" : (agentExists ? "LaunchAgent fallback" : "NEITHER")
    print("after enable: isEnabled=\(isEnabled) smStatus=\(statusName) via=\(mechanism)")

    setEnabled(false)
    print("after disable: isEnabled=\(isEnabled) smStatus=\(statusName) agentExists=\(agentExists)")

    if started { setEnabled(true) }
  }

  private static var agentExists: Bool {
    FileManager.default.fileExists(atPath: agentURL.path)
  }

  private static var statusName: String {
    switch SMAppService.mainApp.status {
    case .notRegistered: return "notRegistered"
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notFound: return "notFound"
    @unknown default: return "unknown"
    }
  }
}
