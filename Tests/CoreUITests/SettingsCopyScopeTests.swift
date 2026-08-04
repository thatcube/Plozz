import XCTest
@testable import CoreUI

/// The scope subtitles are the entire mechanism by which someone can tell what a
/// settings section actually covers, so the selection between them is worth
/// pinning down.
///
/// Resolving a `LocalizedStringResource` to a `String` here reads the default
/// value (no translations are loaded in a unit test), which is exactly what we
/// want to assert.
final class SettingsCopyScopeTests: XCTestCase {

    private func resolve(_ resource: LocalizedStringResource) -> String {
        String(localized: resource)
    }

    // MARK: Reach clause selection

    func testProfileScopeSaysAllYourDevicesWhenSyncing() {
        let copy = resolve(SettingsCopy.profileScope(syncEnabled: true, deviceName: "Apple TV"))
        XCTAssertTrue(copy.contains("all your devices"), copy)
        XCTAssertFalse(copy.contains("Apple TV"), copy)
    }

    /// With sync off the settings genuinely are device-only, and the copy has to
    /// say so — naming the device is the whole point of this variant.
    func testProfileScopeNamesTheDeviceWhenNotSyncing() {
        let copy = resolve(SettingsCopy.profileScope(syncEnabled: false, deviceName: "Apple TV"))
        XCTAssertTrue(copy.contains("this Apple TV"), copy)
        XCTAssertFalse(copy.contains("all your devices"), copy)
    }

    func testEveryoneScopeSaysAllYourDevicesWhenSyncing() {
        let copy = resolve(SettingsCopy.everyoneScope(syncEnabled: true, deviceName: "iPhone"))
        XCTAssertTrue(copy.contains("every profile"), copy)
        XCTAssertTrue(copy.contains("all your devices"), copy)
    }

    func testEveryoneScopeNamesTheDeviceWhenNotSyncing() {
        let copy = resolve(SettingsCopy.everyoneScope(syncEnabled: false, deviceName: "iPhone"))
        XCTAssertTrue(copy.contains("every profile"), copy)
        XCTAssertTrue(copy.contains("this iPhone"), copy)
    }

    func testDeviceNameIsInterpolatedNotHardcoded() {
        let tv = resolve(SettingsCopy.everyoneScope(syncEnabled: false, deviceName: "Apple TV"))
        let pad = resolve(SettingsCopy.everyoneScope(syncEnabled: false, deviceName: "iPad"))
        XCTAssertTrue(tv.contains("Apple TV"), tv)
        XCTAssertTrue(pad.contains("iPad"), pad)
        XCTAssertNotEqual(tv, pad)
    }

    // MARK: Headings

    /// Guards the naming decision itself. "Household" is Netflix's password-
    /// sharing enforcement term, "Family" is Apple's own Family Sharing feature
    /// on this very device, "Home" collides with our Home tab, and "Shared"
    /// collides with SMB/NFS media shares — so if someone renames this section,
    /// these are the words to not reach for.
    func testEveryoneHeadingAvoidsTakenVocabulary() {
        let heading = resolve(SettingsCopy.everyone)
        for taken in ["Household", "Family", "Home", "Shared"] {
            XCTAssertFalse(heading.contains(taken), "'\(taken)' is claimed by another product or by our own UI")
        }
    }

    /// The heading names the audience, so it must NOT name the hardware —
    /// otherwise it goes stale the moment iCloud Sync is switched on.
    func testEveryoneHeadingDoesNotNameTheHardware() {
        let heading = resolve(SettingsCopy.everyone)
        XCTAssertFalse(heading.contains("Apple TV"), heading)
        XCTAssertFalse(heading.contains("iPhone"), heading)
        XCTAssertFalse(heading.contains("Device"), heading)
    }
}
