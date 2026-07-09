#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Fixed, theme-independent colours for the navigation-style preview swatch. A
/// *picture* of the chrome, so it never adapts to the applied theme.
private enum NavigationPreviewColors {
    static let bgTop = Color(red: 0.17, green: 0.17, blue: 0.19)
    static let bgBottom = Color(red: 0.10, green: 0.10, blue: 0.12)
    /// The tab bar / sidebar chrome surface + its hairline border.
    static let chrome = Color(red: 0.28, green: 0.28, blue: 0.32)
    static let chromeBorder = Color.white.opacity(0.16)
    /// Idle tab items; the active one is painted in the fixed brand blue.
    static let itemIdle = Color.white.opacity(0.34)
    /// Deliberately neutral (grey) placeholder posters so the tab chrome — the
    /// actual subject of this picker — is what stands out, not the page content.
    static let tileTop = Color(white: 0.30)
    static let tileBottom = Color(white: 0.22)
    static let tileBorder = Color.white.opacity(0.10)
}

/// A tiny mock app window painted with fixed colours, illustrating one
/// `NavigationStyle`:
/// - `.tabBar` ("Top Bar"): a centred pill of tabs across the top, page content
///   beneath.
/// - `.sidebar` ("Sidebar"): a compact top-left rail of tabs, page content to its
///   right.
///
/// The tab "items" are the *same* small pill size in both variants (only their
/// arrangement — a row vs a short column — differs), and the page content (a row
/// of neutral mock posters) is identical, so the two cards read as the same app
/// wearing different chrome. Fills whatever frame the caller gives it and stays
/// proportionate at the compact and full sizes.
private struct NavigationStyleMini: View {
    let style: NavigationStyle

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pad = min(w, h) * 0.10
            let availW = max(0, w - pad * 2)
            let availH = max(0, h - pad * 2)

            Group {
                switch style {
                case .tabBar: topBar(availW: availW, availH: availH)
                case .sidebar: sidebar(availW: availW, availH: availH)
                }
            }
            .frame(width: availW, height: availH, alignment: .topLeading)
            .padding(pad)
            .frame(width: w, height: h)
            .background(
                LinearGradient(
                    colors: [NavigationPreviewColors.bgTop, NavigationPreviewColors.bgBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    // MARK: Shared tab-item metrics
    //
    // Derived from the content height so a tab pill is the SAME size whether it
    // sits in the top bar or the sidebar — only the arrangement differs.

    private func tabThickness(_ availH: CGFloat) -> CGFloat { max(4, availH * 0.055) }
    private func tabLengthIdle(_ availH: CGFloat) -> CGFloat { availH * 0.15 }
    private func tabLengthActive(_ availH: CGFloat) -> CGFloat { availH * 0.22 }
    private func tabGap(_ availH: CGFloat) -> CGFloat { tabThickness(availH) * 1.2 }

    /// One tab pill. `active` paints it brand-blue and gives it the longer
    /// "selected" length; idle pills are shorter and muted.
    private func tabPill(availH: CGFloat, active: Bool) -> some View {
        let thick = tabThickness(availH)
        return Capsule(style: .continuous)
            .fill(active ? ThemePalette.brandBlue : NavigationPreviewColors.itemIdle)
            .frame(width: active ? tabLengthActive(availH) : tabLengthIdle(availH), height: thick)
    }

    // MARK: Top bar

    private func topBar(availW: CGFloat, availH: CGFloat) -> some View {
        let thick = tabThickness(availH)
        let chromePadV = thick * 0.75
        let chromePadH = thick * 1.3
        return VStack(spacing: availH * 0.09) {
            // Centred pill of tabs (active in the middle).
            HStack(spacing: tabGap(availH)) {
                ForEach(0..<4, id: \.self) { i in
                    tabPill(availH: availH, active: i == 1)
                }
            }
            .padding(.vertical, chromePadV)
            .padding(.horizontal, chromePadH)
            .background(Capsule(style: .continuous).fill(NavigationPreviewColors.chrome))
            .overlay(Capsule(style: .continuous).strokeBorder(NavigationPreviewColors.chromeBorder, lineWidth: 1))
            .frame(maxWidth: .infinity, alignment: .center)

            posterRow()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    // MARK: Sidebar

    private func sidebar(availW: CGFloat, availH: CGFloat) -> some View {
        let thick = tabThickness(availH)
        let railPadV = thick * 1.0
        let railPadH = thick * 1.1
        return HStack(alignment: .top, spacing: availW * 0.06) {
            // A compact top-left rail: the same tab pills stacked vertically. Sized
            // to its content, it naturally stands about half the window tall.
            VStack(alignment: .leading, spacing: tabGap(availH)) {
                ForEach(0..<4, id: \.self) { i in
                    tabPill(availH: availH, active: i == 0)
                }
            }
            .padding(.vertical, railPadV)
            .padding(.horizontal, railPadH)
            .background(
                RoundedRectangle(cornerRadius: thick * 1.6, style: .continuous)
                    .fill(NavigationPreviewColors.chrome)
            )
            .overlay(
                RoundedRectangle(cornerRadius: thick * 1.6, style: .continuous)
                    .strokeBorder(NavigationPreviewColors.chromeBorder, lineWidth: 1)
            )

            posterRow()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    // MARK: Shared page content

    /// A leading-aligned row of neutral mock poster tiles filling the content
    /// region — identical in both variants.
    private func posterRow() -> some View {
        GeometryReader { geo in
            let regionH = geo.size.height
            let regionW = geo.size.width
            let tileH = regionH
            let tileW = tileH * (2.0 / 3.0)
            let gap = max(5, tileW * 0.14)
            let count = max(1, min(3, Int((regionW + gap) / (tileW + gap))))
            let corner = tileW * 0.12

            HStack(spacing: gap) {
                ForEach(0..<count, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [NavigationPreviewColors.tileTop, NavigationPreviewColors.tileBottom],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: corner, style: .continuous)
                                .strokeBorder(NavigationPreviewColors.tileBorder, lineWidth: 1)
                        )
                        .frame(width: tileW, height: tileH)
                }
            }
            .frame(width: regionW, height: regionH, alignment: .leading)
        }
    }
}

/// The per-option preview graphic for the navigation-style picker: a mock app
/// window shown with a top tab bar or a left sidebar. Fills the caller's frame, so
/// it scales for both the full and compact card sizes, mirroring `ThemeSwatch` /
/// `CardStyleSwatch`.
public struct NavigationStyleSwatch: View {
    private let style: NavigationStyle
    private let cornerRadius: CGFloat

    public init(style: NavigationStyle, cornerRadius: CGFloat = 16) {
        self.style = style
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        NavigationStyleMini(style: style)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(white: 0.5).opacity(0.35), lineWidth: 1)
            )
    }
}
#endif
