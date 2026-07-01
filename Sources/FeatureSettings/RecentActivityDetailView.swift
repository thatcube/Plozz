#if canImport(SwiftUI)
import SwiftUI
import CoreNetworking
import CoreUI

/// Full-page, scrollable view of the recent-activity log.
///
/// Previously this lived as one giant panel inside the Help & Diagnostics page.
/// On tvOS that panel was a single focus target: the user could land on it but
/// not scroll *within* it, so anything past the first screenful was unreadable,
/// and the fixed panel height forced the text small. Here every line is its own
/// focusable row, so pressing down walks the log and the `ScrollView` follows —
/// giving a proper, readable console. Newest entries are shown first.
///
/// The lines come straight from `PlozzLog`'s ring buffer, which is already
/// redacted at the source (tokens/secrets stripped), so nothing sensitive is
/// shown here.
struct RecentActivityDetailView: View {
    private let entries = PlozzLog.recentEntries(limit: 500)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if entries.isEmpty {
                    Text("No activity recorded yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(entries.reversed()) { entry in
                            RecentActivityRow(entry: entry)
                        }
                    }
                }
            }
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Activity")
                .font(.largeTitle.weight(.semibold))
            Text("The most recent app log lines, kept only on this Apple TV and already stripped of tokens and secrets. Newest first — a maintainer may ask what Plozz was doing when a bug happened.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One log line, rendered as a focusable console row so the page scrolls on
/// tvOS. Uses the same soft, theme-tinted outline focus look as the rest of
/// Settings (avatars / cast tiles / focusable panels) rather than inverting
/// contrast, and shows the full message (wrapping, never truncated).
private struct RecentActivityRow: View {
    let entry: PlozzLog.LogEntry

    @FocusState private var isFocused: Bool
    @Environment(\.themePalette) private var palette

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var levelColor: Color {
        switch entry.level {
        case .error: return .red
        case .info: return .primary
        case .debug: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(Self.timeFormatter.string(from: entry.date))
                    .foregroundStyle(.secondary)
                Text(entry.level.rawValue.uppercased())
                    .foregroundStyle(levelColor)
                Text(entry.category)
                    .foregroundStyle(.secondary)
            }
            .font(.system(.caption2, design: .monospaced))

            Text(entry.message)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isFocused ? palette.accent.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.accent, lineWidth: 3)
                .opacity(isFocused ? 1 : 0)
        )
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .accessibilityElement(children: .combine)
    }
}
#endif
