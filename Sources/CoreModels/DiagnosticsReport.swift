import Foundation

/// Secret-free environment context and prefilled GitHub issue URL.
public struct DiagnosticsReport {
    public let appVersion: String
    public let appBuild: String
    public let providers: String
    public let repoURL: String
    public let recentLogTail: String

    public init(
        appVersion: String,
        appBuild: String,
        providers: String,
        repoURL: String,
        recentLogTail: String = ""
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.providers = providers
        self.repoURL = repoURL
        self.recentLogTail = recentLogTail.count > 400
            ? "…" + String(recentLogTail.suffix(400))
            : recentLogTail
    }

    public var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let number = version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return "\(Self.platformName) \(number)"
    }

    public var deviceModel: String {
        var info = utsname()
        uname(&info)
        let bytes = Mirror(reflecting: info.machine).children
            .compactMap { $0.value as? Int8 }
            .filter { $0 != 0 }
            .map { UInt8(bitPattern: $0) }
        let model = String(decoding: bytes, as: UTF8.self)
        return model.isEmpty ? "Apple device" : model
    }

    public var environmentBlock: String {
        """
        - Plozz: \(appVersion) (build \(appBuild))
        - \(systemVersion)
        - Device: \(deviceModel)
        - Provider(s): \(providers)
        """
    }

    public var newIssueURLString: String {
        let base = repoURL.hasSuffix("/") ? String(repoURL.dropLast()) : repoURL
        guard var components = URLComponents(string: base + "/issues/new") else {
            return base + "/issues/new"
        }
        components.queryItems = [
            URLQueryItem(name: "labels", value: "bug"),
            URLQueryItem(name: "title", value: "[Bug] "),
            URLQueryItem(name: "body", value: issueBody)
        ]
        return components.url?.absoluteString ?? (base + "/issues/new")
    }

    public var newIssueURL: URL? {
        URL(string: newIssueURLString)
    }

    public var newIssueShortURL: String {
        let base = repoURL.hasSuffix("/") ? String(repoURL.dropLast()) : repoURL
        return base.replacingOccurrences(of: "https://", with: "") + "/issues/new"
    }

    private var issueBody: String {
        var body = """
        **What happened?**


        **Steps to reproduce**
        1.\u{0020}

        **What did you expect?**


        ---
        _Environment (auto-filled by Plozz — please keep):_
        \(environmentBlock)
        """
        if !recentLogTail.isEmpty {
            body += """


            <details><summary>Recent activity (auto-filled)</summary>

            ```
            \(recentLogTail)
            ```
            </details>
            """
        }
        return body
    }

    private static var platformName: String {
        #if os(tvOS)
        "tvOS"
        #elseif os(iOS)
        "iOS"
        #else
        "Apple OS"
        #endif
    }
}
