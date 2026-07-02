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
    /// Whether the on-demand "Send to Developer" upload is possible right now —
    /// i.e. the build shipped with a crash-reporting endpoint AND the user has
    /// opted in (Help & Diagnostics ▸ Share Crash Reports). When false the button
    /// is replaced by a short note explaining how to enable it, because there is
    /// nowhere to send the log.
    var canSendDiagnostics: Bool = false

    private let entries = PlozzLog.recentEntries(limit: 500)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                sendSection

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

    /// The whole point of this page for real debugging: hand the *full* log off
    /// to the developer's crash-reporting service in one click, so it can be read
    /// on a computer instead of squinting at (or trying to QR-scan) a TV. Shared
    /// with the Help & Diagnostics page via `SendDiagnosticsCard`.
    private var sendSection: some View {
        SendDiagnosticsCard(
            canSend: canSendDiagnostics,
            idleDescription: "Uploads the full log below so it can be read on a computer instead of scrolling here. Sent anonymously — no logins, tokens, servers, or titles are included."
        )
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(Self.timeFormatter.string(from: entry.date))
                    .foregroundStyle(.secondary)
                Text(entry.level.rawValue.uppercased())
                    .foregroundStyle(levelColor)
                Text(entry.category)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 14, design: .monospaced))

            Text(entry.message)
                .font(.system(size: 17, design: .monospaced))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 14)
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
