#if DEBUG
#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// **DEBUG-only** live-preview harness for the subtitle renderer.
///
/// Renders the real ``SubtitleOverlayView`` over a choice of backdrops (including
/// an HDR-bright test card) with animated mock cues, and exposes every
/// ``SubtitleStyle`` knob as a focusable control. The whole point is to design
/// the subtitle look on the Apple TV *without starting playback* — and to do it
/// at runtime, so most tweaks need no rebuild.
///
/// This is not throwaway: the same control surface becomes the in-player
/// appearance panel's live preview later. It is gated entirely behind `#if DEBUG`
/// and reached from a DEBUG-only tab in `MainTabView`.
public struct SubtitleLabView: View {
    public init() {}

    @State private var style = SubtitleStyle.default
    @State private var backdrop: Backdrop = .hdrTestCard
    @State private var dualEnabled = false
    @State private var presetIndex = 0

    private let loop: Double = 14   // seconds before the mock script repeats

    public var body: some View {
        ZStack(alignment: .trailing) {
            backdrop.view.ignoresSafeArea()

            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: loop)
                SubtitleOverlayView(
                    primary: Self.primaryCues.active(at: t),
                    secondary: dualEnabled ? Self.secondaryCues.active(at: t) : [],
                    style: effectiveStyle,
                    isHDR: backdrop.isHDR
                )
                .ignoresSafeArea()
            }

            controlPanel
                .frame(width: 640)
                .frame(maxHeight: .infinity)
                .background(.black.opacity(0.55))
                .ignoresSafeArea()
        }
    }

    /// The style actually rendered: dual-sub secondary is toggled in here so the
    /// stored `style.secondary` is preserved when the user flips it off/on.
    private var effectiveStyle: SubtitleStyle {
        var s = style
        s.secondary = dualEnabled ? (style.secondary ?? .init()) : nil
        return s
    }

    // MARK: - Controls

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Subtitle Lab")
                    .font(.system(size: 30, weight: .bold))
                    .padding(.bottom, 2)

                cycleRow("Backdrop", value: backdrop.name) { backdrop = backdrop.next }
                cycleRow("Preset", value: SubtitleStyle.presets[presetIndex].name) {
                    presetIndex = (presetIndex + 1) % SubtitleStyle.presets.count
                    style = SubtitleStyle.presets[presetIndex].style
                }

                group("Size & position") {
                    adjust("Font scale", style.fontScale, "%.2f×", 0.5, 2.5, 0.05, set: { style.fontScale = $0 })
                    adjust("Vertical pos", style.verticalPosition, "%.0f%%", 0, 0.45, 0.01, scale: 100, set: { style.verticalPosition = $0 })
                    adjust("H offset", style.horizontalOffset, "%+.2f", -1, 1, 0.1, set: { style.horizontalOffset = $0 })
                }

                group("Colour & opacity") {
                    cycleRow("Text colour", value: colorName(style.textColor)) {
                        style.textColor = nextColor(after: style.textColor)
                    }
                    adjust("Opacity", style.opacity, "%.0f%%", 0.2, 1, 0.1, scale: 100, set: { style.opacity = $0 })
                    adjust("HDR brightness", style.hdrLuminanceScale, "%.0f%%", 0.2, 1, 0.05, scale: 100, set: { style.hdrLuminanceScale = $0 })
                }

                group("Background") {
                    Toggle("Background box", isOn: $style.background.isEnabled)
                    adjust("BG opacity", style.background.color.alpha, "%.0f%%", 0, 1, 0.1, scale: 100, set: { style.background.color.alpha = $0 })
                    adjust("Corner radius", style.background.cornerRadius, "%.0f", 0, 40, 2, set: { style.background.cornerRadius = $0 })
                }

                group("Edge (shadow)") {
                    cycleRow("Edge style", value: style.edge.style.displayName) {
                        style.edge.style = nextEdge(after: style.edge.style)
                    }
                    adjust("Edge thickness", style.edge.thickness, "%.1f", 0, 8, 0.5, set: { style.edge.thickness = $0 })
                }

                group("Border (outline)") {
                    Toggle("Explicit border", isOn: $style.border.isEnabled)
                    adjust("Border width", style.border.width, "%.1f", 0, 6, 0.5, set: { style.border.width = $0 })
                }

                group("Dual subtitles") {
                    Toggle("Enable second track", isOn: $dualEnabled)
                }

                Button("Reset to default") { style = .default; presetIndex = 0 }
                    .padding(.top, 6)
            }
            .padding(28)
            .font(.system(size: 22))
            .foregroundStyle(.white)
        }
    }

    // MARK: Control builders

    @ViewBuilder
    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 6)
            content()
        }
    }

    private func cycleRow(_ label: String, value: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                Spacer()
                Text(value).foregroundStyle(.cyan)
            }
        }
        .buttonStyle(.card)
    }

    /// A −/＋ stepper row. `scale` lets a 0–1 model value display as a percentage.
    private func adjust(
        _ label: String,
        _ value: Double,
        _ format: String,
        _ lo: Double,
        _ hi: Double,
        _ step: Double,
        scale: Double = 1,
        set: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 230, alignment: .leading)
            Button("−") { set(max(lo, value - step)) }.buttonStyle(.card)
            Text(String(format: format, value * scale))
                .monospacedDigit()
                .frame(width: 96)
            Button("＋") { set(min(hi, value + step)) }.buttonStyle(.card)
        }
    }

    // MARK: Cyclers

    private func colorName(_ c: SubtitleStyle.Color) -> String {
        CaptionSettings.RGBAColor.presets.first { $0.color == c }?.name ?? "Custom"
    }

    private func nextColor(after c: SubtitleStyle.Color) -> SubtitleStyle.Color {
        let palette = CaptionSettings.RGBAColor.presets.map(\.color)
        guard let i = palette.firstIndex(of: c) else { return palette.first ?? .white }
        return palette[(i + 1) % palette.count]
    }

    private func nextEdge(after e: SubtitleStyle.EdgeStyle) -> SubtitleStyle.EdgeStyle {
        let all = SubtitleStyle.EdgeStyle.allCases
        guard let i = all.firstIndex(of: e) else { return .none }
        return all[(i + 1) % all.count]
    }
}

// MARK: - Backdrops

extension SubtitleLabView {
    enum Backdrop: CaseIterable {
        case hdrTestCard, brightSky, darkScene, busyGradient

        var isHDR: Bool { self == .hdrTestCard }

        var name: String {
            switch self {
            case .hdrTestCard: return "HDR Test Card"
            case .brightSky: return "Bright Sky"
            case .darkScene: return "Dark Scene"
            case .busyGradient: return "Busy Gradient"
            }
        }

        var next: Backdrop {
            let all = Backdrop.allCases
            return all[(all.firstIndex(of: self)! + 1) % all.count]
        }

        @ViewBuilder
        var view: some View {
            switch self {
            case .hdrTestCard:
                // Full-white panels are the worst case for HDR sub glare.
                ZStack {
                    Color.white
                    HStack(spacing: 0) {
                        ForEach(0..<6) { i in
                            [Color.white, .red, .green, .blue, .yellow, .cyan][i]
                        }
                    }
                    .opacity(0.9)
                    .frame(height: 360)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            case .brightSky:
                LinearGradient(colors: [.white, .cyan, .blue],
                               startPoint: .top, endPoint: .bottom)
            case .darkScene:
                LinearGradient(colors: [.black, Color(white: 0.12)],
                               startPoint: .top, endPoint: .bottom)
            case .busyGradient:
                LinearGradient(colors: [.purple, .orange, .green, .pink],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}

// MARK: - Mock cue script

extension SubtitleLabView {
    /// A short looping script exercising the renderer: long & short lines, an
    /// italic line, CJK glyphs, and independently-positioned ASS-style "signs"
    /// (top-centre + top-left) that must render at their own planes **without**
    /// dragging the simultaneous bottom dialogue with them. The top-centre sign
    /// also carries a `rawASS` payload to prove rich markup survives the pipeline.
    static let primaryCues: [SubtitleCue] = [
        SubtitleCue(id: 1, start: 0.3, end: 3.2,
                    body: .text(.init("This is a long subtitle line to check wrapping, padding and the background box at couch distance."))),
        SubtitleCue(id: 2, start: 3.6, end: 5.6,
                    body: .text(.init("Short line.", isItalic: true))),
        SubtitleCue(id: 3, start: 6.0, end: 9.0,
                    body: .text(.init("日本語の字幕テスト — CJK glyph rendering."))),
        SubtitleCue(id: 4, start: 6.0, end: 9.0,
                    body: .text(.init("⟪ SIGN: PLATFORM 9¾ ⟫", alignment: .topCenter,
                                      rawASS: #"Dialogue: 0,0:00:06.00,0:00:09.00,Sign,,0,0,0,,{\an8\pos(960,90)}⟪ SIGN: PLATFORM 9¾ ⟫"#))),
        SubtitleCue(id: 5, start: 9.4, end: 13.6,
                    body: .text(.init("Bright white over HDR — this should be comfortable, not searing.", isBold: true))),
        SubtitleCue(id: 6, start: 9.4, end: 13.6,
                    body: .text(.init("↖ EXIT", alignment: .topLeft)))
    ]

    /// Secondary (dual-subtitle) track — the learner's-language counterpart.
    static let secondaryCues: [SubtitleCue] = [
        SubtitleCue(id: 101, start: 0.3, end: 3.2, body: .text(.init("これは長い字幕の行です。"))),
        SubtitleCue(id: 102, start: 3.6, end: 5.6, body: .text(.init("短い行。"))),
        SubtitleCue(id: 103, start: 6.0, end: 9.0, body: .text(.init("Japanese subtitle test."))),
        SubtitleCue(id: 105, start: 9.4, end: 13.6, body: .text(.init("HDRでも見やすい明るさ。")))
    ]
}
#endif
#endif
