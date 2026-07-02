#if canImport(SwiftUI)
import SwiftUI
import CoreNetworking
import CoreUI
import CrashReporting

/// One-tap "send my recent activity to the developer" card, shared by the Help &
/// Diagnostics page (so it's discoverable without digging) and the Recent
/// Activity page (next to the log it sends).
///
/// It piggybacks on the opt-in crash-reporting pipe, so it can only send when
/// crash reporting is both configured in the build *and* enabled by the user.
/// When it can't, the card becomes a focusable explainer pointing at the toggle
/// rather than a dead, unreachable panel.
struct SendDiagnosticsCard: View {
    /// Whether sending is possible right now (crash reporting configured + on).
    let canSend: Bool
    /// Context-specific one-liner shown before the user has sent anything.
    let idleDescription: String
    /// Context-specific explainer shown when sending is unavailable. Defaults to
    /// pointing at Help & Diagnostics (correct from anywhere); the Help page
    /// passes a "below" variant since the toggle is right there.
    var disabledDescription: String = "Turn on Share Crash Reports in Help & Diagnostics to enable this. Your recent activity is then sent anonymously — no logins, tokens, servers, or titles."

    private enum SendState { case idle, sent, failed }
    @State private var sendState: SendState = .idle

    var body: some View {
        if canSend {
            SettingsPanel(title: "Send to Developer", footer: footer) {
                Button {
                    let ok = CrashDiagnostics.send(
                        logText: PlozzLog.recentLogText(limit: 500),
                        note: "User diagnostics report"
                    )
                    sendState = ok ? .sent : .failed
                } label: {
                    Label(
                        sendState == .sent ? "Sent" : "Send to Developer",
                        systemImage: sendState == .sent ? "checkmark.circle.fill" : "paperplane.fill"
                    )
                    .font(.headline)
                }
                .buttonStyle(PlozzOpaquePillButtonStyle())
                .disabled(sendState == .sent)
            }
        } else {
            FocusableSettingsPanel(
                title: "Send to Developer",
                footer: disabledDescription
            ) {
                Label("Send to Developer", systemImage: "paperplane")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .opacity(0.5)
            }
        }
    }

    private var footer: String {
        switch sendState {
        case .idle:
            return idleDescription
        case .sent:
            return "Thanks! Your recent activity was sent to the developer."
        case .failed:
            return "Couldn't send — crash reporting isn't active. Turn on Share Crash Reports below and try again."
        }
    }
}
#endif
