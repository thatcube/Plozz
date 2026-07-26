import XCTest

/// Guards the app targets' Info.plist secret wiring, which has no other net.
///
/// A key that is present for one platform and absent for another produces no
/// build error, no runtime error, and no log line — the affected provider simply
/// returns nothing forever. `TVDBAPIKey` was missing from the iPhone/iPad target
/// while the Apple TV had it, and since TheTVDB and TMDb are the only bundled
/// providers that cover MOVIES (the keyless sources are anime- or TV-only, and
/// Wikipedia's API withholds non-free images, so film posters are unreachable
/// there), roughly half a mainstream library rendered blank on iOS while tvOS
/// looked perfect.
final class ProjectMetadataKeyParityTests: XCTestCase {
    /// Every `Key: "$(BUILD_SETTING)"` entry inside a target's `info.properties`.
    private func substitutedInfoKeys(in yaml: String, target: String) throws -> Set<String> {
        let lines = yaml.components(separatedBy: "\n")
        // `Plozz` also names a local package, so anchor to the `targets:` section
        // rather than the first two-space `Plozz:` in the file.
        guard let targetsSection = lines.firstIndex(of: "targets:") else {
            throw XCTSkip("project.yml has no targets: section")
        }
        guard let start = lines[targetsSection...].firstIndex(of: "  \(target):") else {
            throw XCTSkip("target \(target) not found in project.yml")
        }
        // The target's block ends at the next top-level (two-space) key.
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex(where: { line in
            guard let first = line.first, first == " " else { return !line.isEmpty }
            return line.hasPrefix("  ") && !line.hasPrefix("   ") && line.hasSuffix(":")
        }) ?? lines.endIndex

        var keys: Set<String> = []
        for line in lines[start..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let name = String(trimmed[trimmed.startIndex..<colon])
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("\"$(") , value.hasSuffix(")\"") else { continue }
            keys.insert(name)
        }
        return keys
    }

    private func projectYAML() throws -> String {
        // Tests run from a build directory, so locate the repo by walking up from
        // this file rather than from the working directory.
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("project.yml")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw XCTSkip("project.yml not reachable from \(#filePath)")
    }

    func testTheAppleTVAndIOSTargetsShipTheSameSubstitutedInfoKeys() throws {
        let yaml = try projectYAML()
        let tvOS = try substitutedInfoKeys(in: yaml, target: "Plozz")
        let iOS = try substitutedInfoKeys(in: yaml, target: "PlozziOS")
        XCTAssertFalse(tvOS.isEmpty, "parsed no keys — the parser has drifted from project.yml")

        let missingOnIOS = tvOS.subtracting(iOS).sorted()
        let missingOnTVOS = iOS.subtracting(tvOS).sorted()
        XCTAssertEqual(missingOnIOS, [], "Info.plist keys present on tvOS but missing on iOS")
        XCTAssertEqual(missingOnTVOS, [], "Info.plist keys present on iOS but missing on tvOS")
    }

    /// The two providers that can answer for a movie must be wired on both
    /// platforms; without them a film has no poster source at all.
    func testBothTargetsCarryTheMovieCapableProviderKeys() throws {
        let yaml = try projectYAML()
        for target in ["Plozz", "PlozziOS"] {
            let keys = try substitutedInfoKeys(in: yaml, target: target)
            XCTAssertTrue(keys.contains("TVDBAPIKey"), "\(target) is missing TVDBAPIKey")
            XCTAssertTrue(keys.contains("TMDBBearerToken"), "\(target) is missing TMDBBearerToken")
        }
    }
}
