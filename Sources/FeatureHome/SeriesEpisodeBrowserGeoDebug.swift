#if canImport(SwiftUI)
import SwiftUI
import CoreNetworking

// TEMPORARY diagnostics: logs global layout frames so the series stage can be
// verified on device. Remove once the placement is settled.
extension View {
    @ViewBuilder
    func plzGeoLog(_ tag: String) -> some View {
        self.onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { rect in
            PlozzLog.app.info(
                "PLZGEO \(tag) y=\(Int(rect.minY))..\(Int(rect.maxY)) h=\(Int(rect.height))"
            )
        }
    }
}
#endif

#if canImport(SwiftUI)
func plzGeoNote(_ message: String) {
    PlozzLog.app.info("PLZGEO \(message)")
}
#endif
