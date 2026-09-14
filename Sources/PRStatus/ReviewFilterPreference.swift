import Foundation

/// Remembers the popover's review filter across launches.
///
/// The default is off: a new build must not hide a PR that the previous build showed.
enum ReviewFilterPreference {
  private static let key = "directRequestsOnly"

  static var directRequestsOnly: Bool {
    UserDefaults.standard.bool(forKey: key)
  }

  static func setDirectRequestsOnly(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: key)
  }
}
