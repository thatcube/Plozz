import Foundation

/// The resources the full-timeline VOD origin serves, plus the pure mapping from a
/// request path to a route and from a route to its canonical resource name and
/// MIME type. Kept as a small value type with no I/O so the routing — which the
/// server's "never 404 a declared segment" guarantee depends on — is unit-testable
/// on any platform.
public enum RemuxRoute: Equatable, Sendable {
    case master
    case media
    case initSegment
    case segment(Int)

    public static let masterName = "master.m3u8"
    public static let mediaName = "media.m3u8"
    public static let initName = "init.mp4"

    public static func segmentName(_ index: Int) -> String { "seg\(index).m4s" }

    /// Parses a request path (with or without a leading slash and with any query
    /// string already stripped) into a route, or `nil` for an unknown resource.
    public static func parse(path: String) -> RemuxRoute? {
        var name = path
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        if let q = name.firstIndex(of: "?") {
            name = String(name[..<q])
        }
        switch name {
        case masterName: return .master
        case mediaName: return .media
        case initName: return .initSegment
        default:
            guard name.hasPrefix("seg"), name.hasSuffix(".m4s") else { return nil }
            let middle = name.dropFirst(3).dropLast(4)
            guard !middle.isEmpty, let index = Int(middle), index >= 0 else { return nil }
            return .segment(index)
        }
    }

    /// The canonical resource name this route maps to.
    public var resourceName: String {
        switch self {
        case .master: return Self.masterName
        case .media: return Self.mediaName
        case .initSegment: return Self.initName
        case .segment(let i): return Self.segmentName(i)
        }
    }

    /// The HTTP `Content-Type` for the route. fMP4 init/media segments use
    /// `video/mp4`; the playlists use the Apple HLS MIME type.
    public var contentType: String {
        switch self {
        case .master, .media: return "application/vnd.apple.mpegurl"
        case .initSegment, .segment: return "video/mp4"
        }
    }
}
