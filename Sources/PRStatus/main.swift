import AppKit

// Built as a plain executable rather than with @main so the delegate is installed before
// the app finishes launching.
if ProcessInfo.processInfo.environment["PRSTATUS_LOGIN_PROBE"] == "1" {
  LaunchAtLogin.runProbe()
  exit(0)
}

if let renderDirectory = ProcessInfo.processInfo.environment["PRSTATUS_RENDER"] {
  // NSApplication has to exist before SwiftUI will render, but the app never runs.
  _ = NSApplication.shared
  RenderProbe.run(outputDirectory: renderDirectory)
  exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
