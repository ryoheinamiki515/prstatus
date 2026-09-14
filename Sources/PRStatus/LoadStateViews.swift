import PRStatusCore
import SwiftUI

// The bodies every pane shares, so a spinner, an error, a stale banner and an explanation
// look the same whichever question the popover is answering.

struct LoadingView: View {
  var body: some View {
    Centered {
      ProgressView().controlSize(.small)
      Text("Checking GitHub…")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
  }
}

struct ErrorView: View {
  let error: GitHubClientError
  let retry: () -> Void

  var body: some View {
    Centered {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 20, weight: .light))
        .foregroundStyle(.orange)
      Text(error.title)
        .font(.system(size: 12, weight: .medium))
      Text(error.hint)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Button("Try Again", action: retry)
        .controlSize(.small)
        .padding(.top, 2)
    }
  }
}

/// Rows are still worth showing when a refresh fails; the banner says so rather than
/// letting them pass for current.
struct StaleBanner: View {
  let error: GitHubClientError
  let since: Date
  let retry: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "exclamationmark.circle")
        .font(.system(size: 10, weight: .semibold))
      Text("\(error.title) — showing \(formatAsOfTime(since))")
        .font(.system(size: 10))
      Spacer(minLength: 0)
      Button("Retry", action: retry)
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .medium))
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 14)
    .padding(.vertical, 5)
    .background(Color.orange.opacity(0.12))
  }
}

/// An explanation in place of rows: an empty queue, an unknown name, a field that could
/// not be read.
struct Notice: View {
  let symbol: String
  let title: String
  let detail: String

  var body: some View {
    Centered {
      Image(systemName: symbol)
        .font(.system(size: 22, weight: .light))
        .foregroundStyle(.secondary)
      Text(title)
        .font(.system(size: 12, weight: .medium))
        .multilineTextAlignment(.center)
      Text(detail)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct Centered<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(spacing: 6) {
      Spacer(minLength: 0)
      content()
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, minHeight: 132)
    .padding(.horizontal, 24)
    .padding(.vertical, 12)
  }
}
