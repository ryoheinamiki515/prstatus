import PRStatusCore
import SwiftUI

/// The pane that asks the queue's question about somebody else: type a login or an
/// `org/team`, and see who has time to take a review.
struct LookupView: View {
  @ObservedObject var model: LookupModel
  let now: Date
  let thresholds: UrgencyThresholds
  var onOpen: (URL) -> Void

  var body: some View {
    VStack(spacing: 0) {
      field
      Divider()
      content
    }
  }

  private var field: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
      TextField("GitHub login, or org/team", text: $model.text)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .onSubmit(model.submit)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private var content: some View {
    switch model.submission {
    case .none:
      Notice(
        symbol: "person.2",
        title: "Who has time for a review?",
        detail: "Type a GitHub login, or a team as org/slug, and press Return.")
    case .unreadable(let text):
      Notice(
        symbol: "questionmark.circle",
        title: "Can't look up “\(text)”",
        detail: "A login has letters, digits and hyphens. A team is written as org/slug.")
    case .target:
      switch model.state {
      case .never, .loading:
        LoadingView()
      case .failed(let error):
        ErrorView(error: error, retry: model.refresh)
      case .loaded(let result, let at, let refreshError):
        VStack(spacing: 0) {
          if let refreshError {
            StaleBanner(error: refreshError, since: at, retry: model.refresh)
          }
          resultView(result)
        }
      }
    }
  }

  @ViewBuilder
  private func resultView(_ result: LookupResult) -> some View {
    switch result {
    case .notFound(.user(let login)):
      Notice(
        symbol: "person.slash",
        title: "No user named \(login)",
        detail: "Check the spelling. A team needs its organization, as org/slug.")
    case .notFound(.team(let organization, let slug)):
      Notice(
        symbol: "person.2.slash",
        title: "No team \(organization)/\(slug)",
        detail:
          "PRStatus sees only the teams of organizations your gh account belongs to, "
          + "and needs the read:org scope.")
    case .user(let load):
      ReviewerView(load: load, now: now, thresholds: thresholds, onOpen: onOpen)
    case .team(let team):
      TeamView(team: team, now: now, thresholds: thresholds, onOpen: onOpen)
    }
  }
}

// MARK: - One person

private struct ReviewerView: View {
  let load: ReviewerLoad
  let now: Date
  let thresholds: UrgencyThresholds
  var onOpen: (URL) -> Void

  var body: some View {
    VStack(spacing: 0) {
      SummaryRow(
        title: load.reviewer.login,
        subtitle: load.reviewer.name ?? "",
        help: "Open \(load.reviewer.login)'s review requests on GitHub",
        onTap: { onOpen(reviewQueueURL(login: load.reviewer.login)) },
        leading: { Avatar(url: load.reviewer.avatarURL, size: 26) },
        trailing: { LoadLabel(load: load, now: now) })
      Divider()
      if load.active.isEmpty {
        Notice(
          symbol: "checkmark.circle",
          title: "Nothing active for \(load.reviewer.login)",
          detail: [
            load.dormantCount == 0
              ? "No open PR requests their review by name." : dormantNote(load.dormantCount),
            reviewedNote(load),
          ].joined(separator: " "))
      } else {
        VStack(spacing: 0) {
          PRList(
            items: load.active, now: now, thresholds: thresholds, maxHeight: 320, onOpen: onOpen)
          Divider()
          VStack(spacing: 2) {
            if load.dormantCount > 0 { Text(dormantNote(load.dormantCount)) }
            Text(reviewedNote(load))
          }
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .padding(.vertical, 6)
        }
      }
    }
  }
}

/// Dormant PRs are counted, not listed: they are assigned but not moving, so they say
/// little about the person's time, and the point of the pane is their time.
private func dormantNote(_ count: Int) -> String {
  let days = Int(PullRequestItem.dormantAfter / 86400)
  return count == 1
    ? "1 more PR has had no activity for \(days) days."
    : "\(count) more PRs have had no activity for \(days) days."
}

private func reviewedNote(_ load: ReviewerLoad) -> String {
  let days = Int(recentReviewWindow / 86400)
  switch load.reviewedCount {
  case 0: return "Reviewed nothing in the last \(days) days."
  case 1: return "Reviewed 1 PR in the last \(days) days."
  default:
    return "Reviewed \(load.reviewedCount) PRs in the last \(days) days, "
      + "\(formatChangedLines(load.reviewedWeight)) lines."
  }
}

// MARK: - A team

private struct TeamView: View {
  let team: TeamLoad
  let now: Date
  let thresholds: UrgencyThresholds
  var onOpen: (URL) -> Void

  private var roster: TeamRoster { team.roster }

  private var subtitle: String {
    let members = roster.memberCount == 1 ? "1 member" : "\(roster.memberCount) members"
    switch roster.teamRequestedCount {
    case 0: return members
    case 1: return "\(members) · 1 PR asks the whole team"
    default: return "\(members) · \(roster.teamRequestedCount) PRs ask the whole team"
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      SummaryRow(
        title: roster.slug,
        subtitle: subtitle,
        help: "Open the PRs requested from the team on GitHub",
        onTap: { onOpen(roster.url) },
        leading: { TeamGlyph() },
        trailing: { EmptyView() })
      Divider()
      if team.members.isEmpty {
        Notice(
          symbol: "person.2.slash", title: "\(roster.slug) has no members",
          detail: "Nobody is on this team yet.")
      } else {
        memberList
      }
    }
  }

  private var memberList: some View {
    ScrollView {
        VStack(spacing: 0) {
          ForEach(team.members) { load in
            MemberRow(load: load, scale: team.members.map(\.load).max() ?? 0, now: now) {
              onOpen(reviewQueueURL(login: load.reviewer.login))
            }
            if load.id != team.members.last?.id {
              Divider().padding(.leading, 14)
            }
          }
          if roster.memberCount > team.members.count {
            Text("Showing \(team.members.count) of \(roster.memberCount) members.")
              .font(.system(size: 10))
              .foregroundStyle(.tertiary)
              .padding(.vertical, 6)
          }
        }
      }
      .frame(maxHeight: 360)
  }
}

private struct TeamGlyph: View {
  var body: some View {
    ZStack {
      Circle().fill(Color.secondary.opacity(0.18))
      Image(systemName: "person.2.fill")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
    .frame(width: 26, height: 26)
  }
}

/// One member, least loaded at the top: the login, what waits on them and what they got
/// through this week, with a bar so the whole team compares at a glance.
private struct MemberRow: View {
  let load: ReviewerLoad
  let scale: Int
  let now: Date
  let onTap: () -> Void

  @State private var isHovering = false

  private var tint: Color { loadTint(load, scale: scale) }

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 9) {
        Avatar(url: load.reviewer.avatarURL, size: 22)
        VStack(alignment: .leading, spacing: 2) {
          Text(load.reviewer.login)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
          Text(workLine(load))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
          if let waitLine = waitLine(load, now: now) {
            Text(waitLine)
              .font(.system(size: 10))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 8)
        LoadBar(load: load.load, scale: scale, tint: tint)
        Text(formatChangedLines(load.load))
          .font(.system(size: 12, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(load.load == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
          .frame(width: 34, alignment: .trailing)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(isHovering ? Color.primary.opacity(0.07) : Color.clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(help)
  }

  private var help: String {
    let name = load.reviewer.name.map { "\($0) — " } ?? ""
    return "\(name)\(formatChangedLines(load.load)) lines of review work: "
      + "\(formatChangedLines(load.pendingWeight)) waiting, "
      + "\(formatChangedLines(load.reviewedWeight)) reviewed in the last "
      + "\(Int(recentReviewWindow / 86400)) days. Click to open their requests on GitHub."
  }
}

/// "1 waiting · 11 reviewed": the counts behind the load, so the number stays explainable.
private func workLine(_ load: ReviewerLoad) -> String {
  let waiting = load.activeCount == 1 ? "1 waiting" : "\(load.activeCount) waiting"
  let reviewed = load.reviewedCount == 1 ? "1 reviewed" : "\(load.reviewedCount) reviewed"
  return "\(waiting) · \(reviewed)"
}

/// "oldest 8m · 2 dormant", or nil when there is nothing to say.
private func waitLine(_ load: ReviewerLoad, now: Date) -> String? {
  var parts: [String] = []
  if let age = load.oldestAge(now: now) { parts.append("oldest \(formatWaitingDuration(age))") }
  if load.dormantCount > 0 { parts.append("\(load.dormantCount) dormant") }
  return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

/// Grey when there is no load; otherwise the load colour on the same scale as the bar.
private func loadTint(_ load: ReviewerLoad, scale: Int) -> Color {
  guard let level = LoadLevel(load: load.load, scale: scale) else {
    return Color.secondary.opacity(0.4)
  }
  return Color(StatusIcon.color(for: level))
}

/// Proportional to the busiest member, so the bars answer "compared to whom?" rather than
/// an absolute scale nobody has in mind.
private struct LoadBar: View {
  let load: Int
  let scale: Int
  let tint: Color

  private let width: CGFloat = 64

  var body: some View {
    ZStack(alignment: .leading) {
      Capsule().fill(Color.secondary.opacity(0.12))
      if load > 0, scale > 0 {
        Capsule()
          .fill(tint)
          .frame(width: max(6, width * CGFloat(load) / CGFloat(scale)))
      }
    }
    .frame(width: width, height: 5)
  }
}

/// The load for one person alone on screen, coloured against the scale floor, with the
/// counts behind it underneath.
private struct LoadLabel: View {
  let load: ReviewerLoad
  let now: Date

  var body: some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(load.load == 0 ? "no load" : "\(formatChangedLines(load.load)) lines")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(loadTint(load, scale: load.load))
      Text(workLine(load))
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
      if let waitLine = waitLine(load, now: now) {
        Text(waitLine)
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// The line above a result's rows: who or what was looked up, and the headline number.
private struct SummaryRow<Leading: View, Trailing: View>: View {
  let title: String
  let subtitle: String
  let help: String
  let onTap: () -> Void
  @ViewBuilder let leading: () -> Leading
  @ViewBuilder let trailing: () -> Trailing

  @State private var isHovering = false

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 9) {
        leading()
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
          if !subtitle.isEmpty {
            Text(subtitle)
              .font(.system(size: 10))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 8)
        trailing()
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(isHovering ? Color.primary.opacity(0.07) : Color.clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(help)
  }
}
