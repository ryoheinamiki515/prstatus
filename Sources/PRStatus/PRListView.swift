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

  private var header: some View {
    HStack(spacing: 8) {
      Text("Waiting on your review")
        .font(.system(size: 13, weight: .semibold))
      if !model.items.isEmpty {
        Text("\(model.items.count)")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 1)
          .background(Color.secondary.opacity(0.15), in: Capsule())
      }
      Spacer()
      if model.isRefreshing {
        ProgressView()
          .controlSize(.small)
          .scaleEffect(0.7)
          .frame(width: 14, height: 14)
      } else {
        Button(action: model.refresh) {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Refresh now")
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .never, .loading:
      centered {
        ProgressView().controlSize(.small)
        Text("Checking GitHub…")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
    case .failed(let error):
      errorView(error)
    case .loaded(let items, _) where items.isEmpty:
      centered {
        Image(systemName: "checkmark.circle")
          .font(.system(size: 22, weight: .light))
          .foregroundStyle(.secondary)
        Text("Nothing waiting on you")
          .font(.system(size: 12, weight: .medium))
        Text("No open PRs have requested your review.")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    case .loaded:
      list
    }
  }

  private var list: some View {
    ScrollView {
      VStack(spacing: 0) {
        ForEach(model.items) { item in
          PRRow(item: item, now: model.now, thresholds: model.thresholds) {
            onOpen(item.url)
          }
          if item.id != model.items.last?.id {
            Divider().padding(.leading, 14)
          }
        }
      }
    }
    // Caps the popover so a long queue scrolls instead of growing off screen.
    .frame(maxHeight: 420)
  }

  private func errorView(_ error: GitHubClientError) -> some View {
    centered {
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
      Button("Try Again", action: model.refresh)
        .controlSize(.small)
        .padding(.top, 2)
    }
  }

  private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(spacing: 6) {
      Spacer(minLength: 0)
      content()
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, minHeight: 132)
    .padding(.horizontal, 24)
    .padding(.vertical, 12)
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: 10) {
      LaunchAtLoginToggle()
      Spacer()
      if case .loaded(_, let at) = model.state {
        Text("Updated \(at.formatted(date: .omitted, time: .shortened))")
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

private struct LaunchAtLoginToggle: View {
  @State private var enabled = LaunchAtLogin.isEnabled

  var body: some View {
    Toggle("Open at Login", isOn: $enabled)
      .toggleStyle(.checkbox)
      .font(.system(size: 11))
      .onChange(of: enabled) { _, newValue in
        LaunchAtLogin.setEnabled(newValue)
        // Re-read rather than trusting the write: registration can be refused.
        enabled = LaunchAtLogin.isEnabled
      }
  }
}

// MARK: - Row

private struct PRRow: View {
  let item: PullRequestItem
  let now: Date
  let thresholds: UrgencyThresholds
  let onTap: () -> Void

  @State private var isHovering = false

  private var urgency: Urgency { item.urgency(now: now, thresholds: thresholds) }

  var body: some View {
    Button(action: onTap) {
      HStack(alignment: .top, spacing: 9) {
        Circle()
          .fill(Color(StatusIcon.color(for: urgency)))
          .frame(width: 7, height: 7)
          .padding(.top, 4)

        VStack(alignment: .leading, spacing: 3) {
          HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(item.title)
              .font(.system(size: 12, weight: .medium))
              .lineLimit(2)
              .multilineTextAlignment(.leading)
              .fixedSize(horizontal: false, vertical: true)
            if item.isDraft {
              Text("DRAFT")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            }
          }

          HStack(spacing: 4) {
            Text(item.reference)
              .lineLimit(1)
              .truncationMode(.middle)
            Text("·")
            Text(item.authorLogin).lineLimit(1)
            Text("·")
            Text(formatWaitingDuration(item.age(now: now)))
              .foregroundStyle(Color(StatusIcon.color(for: urgency)))
              .fontWeight(.medium)
          }
          .font(.system(size: 10))
          .foregroundStyle(.secondary)

          HStack(spacing: 5) {
            Text("+\(item.additions)").foregroundStyle(.green)
            Text("−\(item.deletions)").foregroundStyle(.red)
            Text(item.changedFiles == 1 ? "1 file" : "\(item.changedFiles) files")
              .foregroundStyle(.tertiary)
          }
          .font(.system(size: 10, design: .monospaced))
        }

        Spacer(minLength: 0)

        Avatar(url: item.authorAvatarURL)
          .padding(.top, 1)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(isHovering ? Color.primary.opacity(0.07) : Color.clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help("Open \(item.reference) in your browser")
  }
}

private struct Avatar: View {
  let url: URL?

  var body: some View {
    ZStack {
      Circle().fill(Color.secondary.opacity(0.18))
      if let url {
        AsyncImage(url: url) { phase in
          if let image = phase.image {
            image.resizable().scaledToFill()
          } else {
            Image(systemName: "person.fill")
              .font(.system(size: 8))
              .foregroundStyle(.secondary)
          }
        }
      } else {
        Image(systemName: "person.fill")
          .font(.system(size: 8))
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: 18, height: 18)
    .clipShape(Circle())
  }
}
