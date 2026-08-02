import CoreUI
import XCTest

@MainActor
final class TransientStatusPresenterTests: XCTestCase {
    func testPresentationTimingAutoDismissAndAnnouncement() async {
        let sleeper = ControlledTransientStatusSleeper()
        var announcements: [String] = []
        let presenter = TransientStatusPresenter(
            sleeper: { duration in await sleeper.sleep(for: duration) },
            announcement: {
                announcements.append(String(localized: $0))
            }
        )
        let text = LocalizedStringResource(
            "test.transient.added",
            defaultValue: "Added",
            comment: "Test-only transient status text."
        )

        presenter.present(icon: "bookmark", text: text)
        await waitUntilAsync { await sleeper.requestCount == 1 }

        XCTAssertEqual(presenter.message?.icon, "bookmark")
        XCTAssertEqual(
            presenter.message.map { String(localized: $0.text) },
            "Added"
        )
        XCTAssertEqual(announcements, ["Added"])
        let firstDuration = await sleeper.firstDuration
        XCTAssertEqual(
            firstDuration,
            TransientStatusPresenter.defaultDisplayDuration
        )
        XCTAssertEqual(
            TransientStatusPresenter.presentationAnimationDuration,
            0.2
        )
        XCTAssertEqual(
            TransientStatusPresenter.dismissalAnimationDuration,
            0.3
        )

        await sleeper.resumeFirst()
        await waitUntilMainActor { presenter.message == nil }
    }

    func testReplacementResetsTimerAndOldTimerCannotDismissNewMessage() async {
        let sleeper = ControlledTransientStatusSleeper()
        let presenter = TransientStatusPresenter(
            sleeper: { duration in await sleeper.sleep(for: duration) },
            announcement: { _ in }
        )
        let first = LocalizedStringResource(
            "test.transient.first",
            defaultValue: "First",
            comment: "Test-only first transient status."
        )
        let second = LocalizedStringResource(
            "test.transient.second",
            defaultValue: "Second",
            comment: "Test-only replacement transient status."
        )

        presenter.present(icon: "1.circle", text: first)
        await waitUntilAsync { await sleeper.requestCount == 1 }
        presenter.present(icon: "2.circle", text: second)
        await waitUntilAsync { await sleeper.requestCount == 2 }

        await sleeper.resumeFirst()
        await Task.yield()
        XCTAssertEqual(
            presenter.message.map { String(localized: $0.text) },
            "Second"
        )

        await sleeper.resumeFirst()
        await waitUntilMainActor { presenter.message == nil }
    }

    private func waitUntilAsync(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<200 {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for transient status state")
    }

    private func waitUntilMainActor(
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for transient status state")
    }
}

private actor ControlledTransientStatusSleeper {
    private struct Request {
        let duration: Duration
        let continuation: CheckedContinuation<Void, Never>
    }

    private var requests: [Request] = []

    var requestCount: Int { requests.count }
    var firstDuration: Duration? { requests.first?.duration }

    func sleep(for duration: Duration) async {
        await withCheckedContinuation { continuation in
            requests.append(Request(
                duration: duration,
                continuation: continuation
            ))
        }
    }

    func resumeFirst() {
        guard !requests.isEmpty else { return }
        requests.removeFirst().continuation.resume()
    }
}
