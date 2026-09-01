import XCTest
@testable import CrashReporting

/// Covers automatic build-channel tagging and the reporter lifecycle.
final class CrashReportEnvironmentTests: XCTestCase {
    // MARK: - Context

    func testContextUsesTheSuppliedBuildChannel() {
        let context = CrashReportContext.make(
            bundleIdentifier: "com.thatcube.Plozz",
            version: "2026.8.26",
            build: "3322",
            providers: ["Plex"],
            environment: "testflight"
        )
        XCTAssertEqual(context.environment, "testflight")
    }

    /// The release name is what separates a per-branch sideload from the real app
    /// in Sentry, so it must keep carrying the bundle id.
    func testReleaseNameIdentifiesTheBundle() {
        let context = CrashReportContext.make(
            bundleIdentifier: "com.thatcube.Plozz.my-branch",
            version: "2026.8.26",
            build: "3322",
            providers: [],
            environment: "debug"
        )
        XCTAssertEqual(context.releaseName, "com.thatcube.Plozz.my-branch@2026.8.26+3322")
        XCTAssertEqual(context.build, "3322")
    }

    // MARK: - Reporter lifecycle

    @MainActor
    private final class SpyReporter: CrashReporter {
        var isActive = false
        var starts: [String] = []
        var updates: [String] = []
        var stops = 0

        func start(context: CrashReportContext) {
            isActive = true
            starts.append(context.environment)
        }
        func update(context: CrashReportContext) { updates.append(context.environment) }
        func stop() {
            isActive = false
            stops += 1
        }
    }

    @MainActor
    private func context(_ environment: String) -> CrashReportContext {
        CrashReportContext(
            releaseName: "com.thatcube.Plozz@1+1",
            version: "1",
            build: "1",
            environment: environment,
            systemVersion: "tvOS 26.6",
            deviceModel: "AppleTV14,1",
            providers: ["Plex"]
        )
    }

    @MainActor
    func testActiveReporterOnlyUpdates() {
        let spy = SpyReporter()
        let controller = CrashReportingController(reporter: spy, isConfigured: true)

        controller.apply(enabled: true, context: context("testflight"))
        controller.apply(enabled: true, context: context("testflight"))

        XCTAssertEqual(spy.starts, ["testflight"])
        XCTAssertEqual(spy.updates, ["testflight"])
        XCTAssertEqual(spy.stops, 0)
    }

    @MainActor
    func testOptOutStopsAndAllowsACleanRestart() {
        let spy = SpyReporter()
        let controller = CrashReportingController(reporter: spy, isConfigured: true)

        controller.apply(enabled: true, context: context("production"))
        controller.apply(enabled: false, context: context("production"))
        XCTAssertEqual(spy.stops, 1)

        controller.apply(enabled: true, context: context("production"))
        XCTAssertEqual(spy.starts, ["production", "production"])
    }

    /// A build with no DSN must stay inert no matter what consent says.
    @MainActor
    func testUnconfiguredBuildNeverStarts() {
        let spy = SpyReporter()
        let controller = CrashReportingController(reporter: spy, isConfigured: false)
        controller.apply(enabled: true, context: context("production"))
        XCTAssertTrue(spy.starts.isEmpty)
        XCTAssertFalse(spy.isActive)
    }
}
