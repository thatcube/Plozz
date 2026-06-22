import Foundation

/// Lightweight stderr breadcrumb tracer. In DEBUG builds the app redirects
/// stderr into a file inside its container (see `PlozzApp.redirectStandardError`),
/// so these lines survive an on-device crash and can be pulled afterwards with
/// `xcrun devicectl device copy from --domain-type appDataContainer`. This is the
/// only reliable way to see *what code path was executing* at the moment of a
/// SwiftUI/AttributeGraph `abort()` whose reason never reaches the `.ips` report.
/// Compiles to a no-op in release builds.
#if DEBUG
@inline(__always)
public func plozzTrace(_ message: @autoclosure () -> String,
                       file: String = #fileID,
                       line: Int = #line) {
    let ts = ISO8601DateFormatter().string(from: Date())
    fputs("[TRACE \(ts)] \(message()) (\(file):\(line))\n", stderr)
    fflush(stderr)
}
#else
@inline(__always)
public func plozzTrace(_ message: @autoclosure () -> String,
                       file: String = #fileID,
                       line: Int = #line) {}
#endif
