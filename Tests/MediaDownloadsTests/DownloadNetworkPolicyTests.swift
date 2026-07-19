import XCTest
@testable import MediaDownloads

final class DownloadNetworkPolicyTests: XCTestCase {

    private let wifi = DownloadNetworkConditions(
        isSatisfied: true, isExpensive: false, isConstrained: false
    )
    private let cellular = DownloadNetworkConditions(
        isSatisfied: true, isExpensive: true, isConstrained: false
    )
    private let lowData = DownloadNetworkConditions(
        isSatisfied: true, isExpensive: false, isConstrained: true
    )

    func testWifiOnlyDefaultAllowsWifiBlocksCellular() {
        let policy = DownloadNetworkPolicy.default
        XCTAssertFalse(policy.allowsExpensiveNetwork)
        XCTAssertTrue(policy.allows(wifi))
        XCTAssertFalse(policy.allows(cellular))
    }

    func testAllowingExpensivePermitsCellular() {
        let policy = DownloadNetworkPolicy(allowsExpensiveNetwork: true)
        XCTAssertTrue(policy.allows(cellular))
    }

    func testConstrainedNetworkPausesByDefaultButCanBeAllowed() {
        XCTAssertFalse(DownloadNetworkPolicy.default.allows(lowData))
        let permissive = DownloadNetworkPolicy(pausesOnConstrainedNetwork: false)
        XCTAssertTrue(permissive.allows(lowData))
    }

    func testUnsatisfiedNetworkNeverAllows() {
        let policy = DownloadNetworkPolicy(allowsExpensiveNetwork: true, pausesOnConstrainedNetwork: false)
        XCTAssertFalse(policy.allows(.unsatisfied))
    }

    func testMaxConcurrencyClampedToAtLeastOne() {
        XCTAssertEqual(DownloadNetworkPolicy(maxConcurrentDownloads: 0).maxConcurrentDownloads, 1)
        XCTAssertEqual(DownloadNetworkPolicy(maxConcurrentDownloads: 4).maxConcurrentDownloads, 4)
    }

    func testPolicyIsCodable() throws {
        let policy = DownloadNetworkPolicy(
            allowsExpensiveNetwork: true,
            quality: .dataSaver,
            storageBudgetBytes: 5_000,
            maxConcurrentDownloads: 2
        )
        let data = try JSONEncoder().encode(policy)
        XCTAssertEqual(try JSONDecoder().decode(DownloadNetworkPolicy.self, from: data), policy)
    }
}
