import Foundation

/// Settings that survive a relaunch.
enum Preferences {
  private static let directRequestsOnlyKey = "directRequestsOnly"
  private static let lookupTextKey = "lookupText"

  /// Off by default: a new build must not hide a PR that the previous build showed.
  static var directRequestsOnly: Bool {
    UserDefaults.standard.bool(forKey: directRequestsOnlyKey)
  }

  static func setDirectRequestsOnly(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: directRequestsOnlyKey)
  }

  /// The last name submitted to the lookup field, so the popover reopens on the same team.
  static var lookupText: String {
    UserDefaults.standard.string(forKey: lookupTextKey) ?? ""
  }

  static func setLookupText(_ text: String) {
    UserDefaults.standard.set(text, forKey: lookupTextKey)
  }
}
