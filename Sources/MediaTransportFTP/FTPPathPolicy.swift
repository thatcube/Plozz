import Foundation
import MediaTransportCore

/// Path containment policy for FTP. FTP addresses resources by **literal,
/// decoded** absolute paths (a filesystem transport, like SMB — not URL
/// percent-encoding). Every transport-relative path is anchored under the
/// configured root and proven traversal-free before a command is sent, as
/// defense-in-depth on top of `NetworkFileLocator`/scanner normalization.
public enum FTPPathPolicy {
    /// Normalizes a configured root into an absolute, `..`-free path beginning
    /// with `/` and without a trailing slash (except the bare root `/`).
    public static func normalizeRoot(_ rawRoot: String) throws -> String {
        let replaced = rawRoot.replacingOccurrences(of: "\\", with: "/")
        var components: [String] = []
        for component in replaced.split(separator: "/", omittingEmptySubsequences: true) {
            let value = String(component)
            guard value != ".", value != "..", !value.contains("\0") else {
                throw MediaTransportError.invalidInput(reason: "FTP root traversal")
            }
            components.append(value)
        }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    /// Builds the absolute server path for a transport-relative path, anchored
    /// under `root`, and asserts it is normalized and contained by `root`.
    public static func absolutePath(root: String, relative: String) throws -> String {
        let rootBase = try normalizeRoot(root)
        let trimmedRelative = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components: [String] = []
        for component in trimmedRelative.split(separator: "/", omittingEmptySubsequences: true) {
            let value = String(component)
            guard value != ".", value != "..", !value.contains("\0"),
                  !value.contains("\r"), !value.contains("\n") else {
                throw MediaTransportError.invalidInput(reason: "FTP path escapes root")
            }
            components.append(value)
        }
        guard !trimmedRelative.isEmpty else { return rootBase }
        if rootBase == "/" {
            return "/" + components.joined(separator: "/")
        }
        return rootBase + "/" + components.joined(separator: "/")
    }

    /// Joins a parent transport-relative path with a child name from a listing.
    public static func childRelativePath(parent: String, name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0"),
              !name.contains("\r"), !name.contains("\n") else {
            throw MediaTransportError.protocolViolation(reason: "invalid FTP listing name")
        }
        let trimmedParent = parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmedParent.isEmpty ? name : trimmedParent + "/" + name
    }
}
