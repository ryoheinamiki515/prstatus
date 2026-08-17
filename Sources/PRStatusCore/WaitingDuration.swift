import Foundation

/// Compact "how long has this sat there" label for the popover rows: `4m`, `2h 14m`,
/// `3d 4h`. Kept here rather than in the view so the rounding edges are testable.
public func formatWaitingDuration(_ interval: TimeInterval) -> String {
  let total = Int(interval.rounded(.down))
  guard total >= 60 else { return "just now" }

  let minutes = (total / 60) % 60
  let hours = (total / 3600) % 24
  let days = total / 86400

  if days > 0 {
    return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
  }
  if hours > 0 {
    return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
  }
  return "\(minutes)m"
}
