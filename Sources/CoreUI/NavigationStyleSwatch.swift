#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Fixed, theme-independent colours for the navigation-style preview swatch. A
/// *picture* of the chrome, so it never adapts to the applied theme.
private enum NavigationPreviewColors {
    static let bgTop = Color(red: 0.17, green: 0.17, blue: 0.19)
    static let bgBottom = Color(red: 0.10, green: 0.10, blue: 0.12)
    /// The tab bar / sidebar chrome surface + its hairline border.
    static let chrome = Color(red: 0.26, green: 0.26, blue: 0.30)
    static let chromeBorder = Color.white.opacity(0.14)
    /// Idle tab items; the active one is painted in the fixed brand blue.
    static let itemIdle = Color.white.opacity(0.32)
    static let tileBorder = Color.white.opacity(0.12)

    /// One fixed poster gradient for the mock page content — identical in both
    /// variants, since the pages are byte-for-byte the same and only the chrome
    /// changes.
    static let tileArt: [Color] = [
        Color(red: 0.24, green: 0.52, blue: 0.62),
        Color(red: 0.14, green: 0.28, blue: 0.44)
    ]
}

/// A tiny mock app window painted with fixed colours, illustrating one
/// `NavigationStyle`:
/// - `.tabBar` ("Top Bar"): a pill of tabs across the top, page content beneath.
/// - `.sidebar` ("Sidebar"): a collapsible left rail of tabs, page content to its
///   right.
///
/// The page content (a row of mock posters) is identical in both, so the two
/// cards differ only in *where* the tab chrome sits — exactly the choice the
/// setting makes. Fills whatever frame the caller gives it and stays proportionate
/// at the compact and full sizes.
private struct NavigationStyleMini: View {
    let style: NavigationStyle

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pad = min(w, h) * 0.09

            Group {
                switch style {
                case .tabBar: topBarLayout(w: w, h: h, pad: pad)
                case .sidebar: sidebarLayout(w: w, h: h, pad: pad)
                }
            }
            .padding(pad)
            .frame(width: w, height: h, alignment: .topLeading)
            .background(
                LinearGradient(
                    colors: [NavigationPreviewColors.bgTop, NavigationPreviewColors.bgBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    // MARK: Top bar

    private func topBarLayout(w: CGFloat, h: CGFloat, pad: CGFloat) -> some View {
        let gap = h * 0.08
        let barH = max(10, (h - pad * 2) * 0.16)
        return VStack(spacing: gap) {
            tabPill(height: barH, activeIndex: 1)
            posterRow()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    /// The centred top tab bar: a rounded chrome pill holding a row of tab
    /// "labels", the active one brand-blue.
    private func tabPill(height: CGFloat, activeIndex: Int) -> some View {
        let itemH = height * 0.42
        let corner = height * 0.5
        return HStack(spacing: height * 0.55) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(i == activeIndex ? ThemePalette.brandBlue : NavigationPreviewColors.itemIdle)
                    .frame(width: height * (i == activeIndex ? 2.2 : 1.5), height: itemH)
            }
        }
        .padding(.horizontal, height * 0.7)
        .frame(height: height)
        .background(
            Capsule(style: .continuous).fill(NavigationPreviewColors.chrome)
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(NavigationPreviewColors.chromeBorder, lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
    }

    // MARK: Sidebar

    private func sidebarLayout(w: CGFloat, h: CGFloat, pad: CGFloat) -> some View {
        let gap = w * 0.06
        let railW = max(14, (w - pad * 2) * 0.24)
        return HStack(spacing: gap) {
            sidebarRail(width: railW)
            posterRow()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    /// The collapsed left rail: a tall rounded chrome column with a stack of tab
    /// items, the active one brand-blue.
    private func sidebarRail(width: CGFloat) -> some View {
        let itemH = width * 0.30
        let corner = width * 0.30
        return VStack(spacing: width * 0.34) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(i == 0 ? ThemePalette.brandBlue : NavigationPreviewColors.itemIdle)
                    .frame(width: width * (i == 0 ? 0.62 : 0.48), height: itemH)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.vertical, width * 0.34)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(NavigationPreviewColors.chrome)
        )
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(NavigationPreviewColors.chromeBorder, lineWidth: 1)
        )
    }

    // MARK: Shared page content

    /// A leading-aligned row of mock poster tiles filling the content region — the
    /// same in both variants.
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
                                colors: NavigationPreviewColors.tileArt,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .saturation(0.5)
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
