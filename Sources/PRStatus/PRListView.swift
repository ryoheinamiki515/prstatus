import AppKit
import PRStatusCore
import SwiftUI

struct PRListView: View {
  @ObservedObject var model: AppModel
  var onOpen: (URL) -> Void
  var onQuit: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      content
      Divider()
      footer
    }
    .frame(width: 380)
  }

  // MARK: - Header

  private var queueTitle: String {
    model.items.isEmpty ? "Your queue" : "Your queue · \(model.items.count)"
  }

  private var isRefreshing: Bool {
    switch model.pane {
    case .queue: return model.isRefreshing
    case .lookup: return model.lookup.isRefreshing
    }
  }

  private func refresh() {
    switch model.pane {
    case .queue: model.refresh()
    case .lookup: model.lookup.refresh()
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Picker(
        "Pane",
        selection: Binding(
          get: { model.pane },
          set: { model.showPane($0) })
      ) {
        Text(queueTitle).tag(PopoverPane.queue)
        Text("Look up").tag(PopoverPane.lookup)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .controlSize(.small)
      .fixedSize()
      Spacer()
      if isRefreshing {
        ProgressView()
          .controlSize(.small)
          .scaleEffect(0.7)
          .frame(width: 14, height: 14)
      } else {
        Button(action: refresh) {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Refresh now")
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    switch model.pane {
    case .queue:
      queue
    case .lookup:
      LookupView(
        model: model.lookup, now: model.now, thresholds: model.thresholds, onOpen: onOpen)
    }
  }

  @ViewBuilder
  private var queue: some View {
    switch model.state {
    case .never, .loading:
      LoadingView()
    case .failed(let error):
      ErrorView(error: error, retry: model.refresh)
    case .loaded(let items, let at, let refreshError):
      // The banner wraps both bodies: a queue known to be empty is knowledge worth
      // keeping when a refresh fails, and it needs the same "this is not current" mark.
      VStack(spacing: 0) {
        if let refreshError {
          StaleBanner(error: refreshError, since: at, retry: model.refresh)
        }
        if items.isEmpty {
          Notice(symbol: "checkmark.circle", title: "Nothing waiting on you", detail: emptyDetail)
        } else {
          PRList(items: items, now: model.now, thresholds: model.thresholds, onOpen: onOpen)
        }
      }
    }
  }

  /// An empty list with rows behind the filter is a different fact from an empty queue,
  /// and reads as a bug unless it says so.
  private var emptyDetail: String {
    switch model.hiddenCount {
    case 0: return "No open PRs have requested your review."
    case 1: return "1 PR requested from your team is hidden."
    default: return "\(model.hiddenCount) PRs requested from your team are hidden."
    }
  }

  // MARK: - Footer

  /// The visible pane's fetch time. Suppressed while stale: the banner already states the
  /// same time, and two timestamps saying different things is worse than one.
  private var updatedAt: Date? {
    switch model.pane {
    case .queue: return model.state.currentAsOf
    case .lookup: return model.lookup.state.currentAsOf
    }
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Toggle(
        "Open at Login",
        isOn: Binding(
          get: { model.launchAtLoginEnabled },
          set: { model.setLaunchAtLogin($0) })
      )
      .toggleStyle(.checkbox)
      .font(.system(size: 11))
      Toggle(
        "Direct only",
        isOn: Binding(
          get: { model.directRequestsOnly },
          set: { model.setDirectRequestsOnly($0) })
      )
      .toggleStyle(.checkbox)
      .font(.system(size: 11))
      .help(
        "Show only the PRs that request your review by name. This hides the PRs that "
          + "GitHub requested from a team you belong to.")
      Spacer()
      if let updatedAt {
        Text("Updated \(formatAsOfTime(updatedAt))")
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
      }
      Button("Quit", action: onQuit)
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }
}
