import AppKit
import PRStatusCore

enum StatusIcon {
  /// nil urgency means nothing is waiting, drawn as a hollow template circle so the
  /// menu bar tints it for light/dark itself. The filled states opt out of templating
  /// because their colour *is* the signal.
  static func image(for urgency: Urgency?) -> NSImage? {
    let base = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)

    guard let urgency else {
      let image = NSImage(systemSymbolName: "circle", accessibilityDescription: "No PRs waiting")
      image?.isTemplate = true
      return image?.withSymbolConfiguration(base)
    }

    let image = NSImage(
      systemSymbolName: "circle.fill",
      accessibilityDescription: accessibilityDescription(for: urgency))
    let colored = image?.withSymbolConfiguration(
      base.applying(NSImage.SymbolConfiguration(paletteColors: [color(for: urgency)])))
    colored?.isTemplate = false
    return colored
  }

  static func color(for urgency: Urgency) -> NSColor {
    switch urgency {
    case .fresh: return .systemGreen
    case .stale: return .systemYellow
    case .urgent: return .systemRed
    }
  }

  static func accessibilityDescription(for urgency: Urgency) -> String {
    switch urgency {
    case .fresh: return "PRs waiting for review"
    case .stale: return "PRs waiting over an hour"
    case .urgent: return "PRs waiting over three hours"
    }
  }
}
