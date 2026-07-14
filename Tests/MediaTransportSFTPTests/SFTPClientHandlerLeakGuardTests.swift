import NIOCore
import NIOEmbedded
import MediaTransportCore
import XCTest

@testable import MediaTransportSFTP

/// Regression guard for the onboarding "wrong username" crash.
///
/// When an SFTP connect's `sftp` subsystem channel never opens — SSH auth was
/// rejected, or the host key was refused before user-auth — the
/// `SFTPClientHandler` is created but NEVER added to a pipeline, so nothing on the
/// pipeline path (`channelInactive` → `failAll0`) will ever complete its
/// `readyPromise`. Left unfulfilled, that promise leaks and NIO traps with
/// "leaking promise created at ..." in debug builds — the exact SIGTRAP a wrong
/// username reproduced. `failReadyPromise` is the guard `connect()` calls on that
/// never-attached path.
final class SFTPClientHandlerLeakGuardTests: XCTestCase {
    func testFailReadyPromiseCompletesNeverAttachedHandler() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        let handler = SFTPClientHandler(eventLoop: loop)

        var completed = false
        handler.readyFuture.whenComplete { _ in completed = true }

        // Simulate the never-attached failure path.
        handler.failReadyPromise(error: MediaTransportError.authentication(reason: "rejected"))
        loop.run()

        // The promise MUST be completed now; otherwise it would leak and trap.
        XCTAssertTrue(completed, "readyPromise must be completed to avoid a leaked-promise trap")
    }
}
