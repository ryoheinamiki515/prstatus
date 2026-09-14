import PRStatusCore
import SwiftUI

/// One pull request, in the viewer's queue or in somebody else's.
struct PRRow: View {
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

        Avatar(url: item.authorAvatarURL, size: 18)
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

/// A list of rows with a divider between neighbours, capped so a long queue scrolls
/// instead of growing off screen.
struct PRList: View {
  let items: [PullRequestItem]
  let now: Date
  let thresholds: UrgencyThresholds
  var maxHeight: CGFloat = 420
  var onOpen: (URL) -> Void

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        ForEach(items) { item in
          PRRow(item: item, now: now, thresholds: thresholds) { onOpen(item.url) }
          if item.id != items.last?.id {
            Divider().padding(.leading, 14)
          }
        }
      }
    }
    .frame(maxHeight: maxHeight)
  }
}

struct Avatar: View {
  let url: URL?
  let size: CGFloat

  var body: some View {
    ZStack {
      Circle().fill(Color.secondary.opacity(0.18))
      if let url {
        AsyncImage(url: url) { phase in
          if let image = phase.image {
            image.resizable().scaledToFill()
          } else {
            placeholder
          }
        }
      } else {
        placeholder
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
  }

  private var placeholder: some View {
    Image(systemName: "person.fill")
      .font(.system(size: size * 0.45))
      .foregroundStyle(.secondary)
  }
}
