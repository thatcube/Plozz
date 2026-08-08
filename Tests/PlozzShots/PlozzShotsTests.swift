import XCTest

/// Captures the marketing/website screenshots by driving the real app.
///
/// This is not a test of anything — it is the capture rig. It exists as a UI
/// test bundle because that is the only supported way to press the Siri Remote,
/// and because XCTest hands frames back as attachments at full device
/// resolution (3840x2160 on an Apple TV 4K simulator).
///
/// The app launches already signed in: `ScreenshotSeed` reads the NFS share out
/// of the launch environment and completes the first-run steps, so these tests
/// start on Home instead of walking onboarding. See `tools/capture-shots.sh`,
/// which owns the simulator, runs this bundle, and extracts the attachments.
///
/// Navigation is deliberately conservative. tvOS focus moves one cell at a time
/// and the layout depends on what the library actually contains, so each step
/// waits for the UI to settle rather than assuming a fixed geometry, and each
/// screen is captured independently — one screen failing to appear does not
/// lose the rest.
final class PlozzShotsTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true

        app = XCUIApplication()
        let environment = ProcessInfo.processInfo.environment
        app.launchEnvironment["PLOZZ_SHOTS_NFS_HOST"] =
            environment["PLOZZ_SHOTS_NFS_HOST"] ?? "192.168.68.71"
        app.launchEnvironment["PLOZZ_SHOTS_NFS_EXPORT"] =
            environment["PLOZZ_SHOTS_NFS_EXPORT"] ?? "/mnt/user/Media"
        app.launchEnvironment["PLOZZ_SHOTS_NFS_NAME"] =
            environment["PLOZZ_SHOTS_NFS_NAME"] ?? "Brandoland"
        app.launch()
    }

    // MARK: - Capture

    /// Saves the current screen under `name`, at full device resolution.
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits until the screen stops changing, which is the only honest signal
    /// that artwork has finished arriving — rows fill in progressively, so a
    /// fixed sleep either wastes time or captures a half-drawn shelf.
    @discardableResult
    private func settle(timeout: TimeInterval = 90, stableFrames: Int = 3) -> Bool {
        var previous = Data()
        var stable = 0
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            Thread.sleep(forTimeInterval: 2)
            let data = XCUIScreen.main.screenshot().pngRepresentation
            if data == previous {
                stable += 1
                if stable >= stableFrames { return true }
            } else {
                stable = 0
            }
            previous = data
        }
        return false
    }

    private func press(_ button: XCUIRemote.Button, times: Int = 1, pause: TimeInterval = 0.6) {
        for _ in 0..<times {
            XCUIRemote.shared.press(button)
            Thread.sleep(forTimeInterval: pause)
        }
    }

    // MARK: - Screens

    /// Home, with the library shelf populated.
    func testCaptureHome() throws {
        // A first launch against a fresh container scans and enriches the whole
        // share, which takes far longer than any UI wait should — the capture
        // script is responsible for having done that already.
        settle(timeout: 240, stableFrames: 4)
        capture("plozz-tv-home")
    }

    /// Walks into the library grid, then into a title's detail page.
    ///
    /// Focus starts on the first library card, so Select opens the grid and
    /// Select again opens whatever title focus landed on. Which title that is
    /// depends on the library's sort order, so the capture script picks the
    /// frames it wants rather than this test hard-coding a name.
    func testCaptureLibraryAndDetail() throws {
        settle(timeout: 240, stableFrames: 4)

        press(.select)
        guard settle(timeout: 120) else {
            XCTFail("library grid never settled")
            return
        }
        capture("plozz-tv-library")

        press(.select)
        guard settle(timeout: 120) else {
            XCTFail("detail page never settled")
            return
        }
        capture("plozz-tv-detail")

        // Step down the detail page to bring the cast/ratings rails on screen.
        press(.down, times: 2)
        settle(timeout: 60)
        capture("plozz-tv-detail-rails")

        press(.menu)
        settle(timeout: 60)
    }
}
