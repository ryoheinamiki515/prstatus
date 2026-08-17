import AppKit
import PRStatusCore

enum StatusIcon {
  /// Only `waiting` is drawn in colour, because colour is the signal. The other three are
  /// template images so the menu bar tints them for light or dark itself.
  static func image(for appearance: StatusAppearance) -> NSImage? {
    let (symbol, label) = art(for: appearance)
    let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)

    guard case .waiting(let urgency) = appearance else {
      image?.isTemplate = true
      return image?.withSymbolConfiguration(configuration)
    }

    let colored = image?.withSymbolConfiguration(
      configuration.applying(NSImage.SymbolConfiguration(paletteColors: [color(for: urgency)])))
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

  private static func art(for appearance: StatusAppearance) -> (symbol: String, label: String) {
    switch appearance {
    case .unknown:
      return ("circle.dashed", "Checking for pull requests")
    case .idle:
      return ("circle", "No pull requests waiting for review")
    case .unavailable:
      return ("exclamationmark.circle", "Cannot reach GitHub")
    case .waiting(.fresh):
      return ("circle.fill", "Pull requests waiting for review")
    case .waiting(.stale):
      return ("circle.fill", "Pull requests waiting over an hour")
    case .waiting(.urgent):
      return ("circle.fill", "Pull requests waiting over three hours")
    }
  }
}
