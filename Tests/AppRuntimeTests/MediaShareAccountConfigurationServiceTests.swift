import AppRuntime
import CoreModels
import FeatureAuthCore
import XCTest

final class MediaShareAccountConfigurationServiceTests: XCTestCase {
    func testSaveNFSPersistsStableAccountAndCredentialEnvelope() throws {
        let store = try makeStore()
        let service = MediaShareAccountConfigurationService(accountStore: store)

        let prepared = try service.saveNFS(
            host: "NAS.Local",
            port: 2_049,
            exportPath: "volume/Movies/",
            displayName: ""
        )

        XCTAssertEqual(
            prepared.account.id,
            "share:nfs://nas.local:2049/volume/Movies#anon"
        )
        XCTAssertEqual(prepared.account.server.name, "Movies (NFS)")
        XCTAssertEqual(
            prepared.account.server.baseURL.absoluteString,
            "nfs://NAS.Local:2049/volume/Movies/"
        )
        XCTAssertEqual(store.loadAccounts(), [prepared.account])
        let credential = try store.mediaShareCredential(
            for: prepared.account.id,
            revision: prepared.account.credentialRevision
        )
        XCTAssertEqual(credential.transport, .nfs)
        XCTAssertEqual(credential.authentication, .noCredentials)
    }

    func testPrepareNFSRejectsBlankHostWithoutPersisting() throws {
        let store = try makeStore()
        let service = MediaShareAccountConfigurationService(accountStore: store)

        XCTAssertThrowsError(
            try service.prepareNFS(
                host: " ",
                port: nil,
                exportPath: "/media",
                displayName: ""
            )
        ) { error in
            XCTAssertEqual(
                error as? MediaShareAccountConfigurationError,
                .invalidAddress
            )
        }
        XCTAssertTrue(store.loadAccounts().isEmpty)
    }

    private func makeStore() throws -> AccountStore {
        let secureStore = InMemorySecureStore()
        return AccountStore(
            secureStore: secureStore,
            mediaCredentialVault: MediaCredentialVault(secureStore: secureStore),
            credentialJournal: try CredentialMutationJournal(
                store: DurableLocalStateStore(secureStore: InMemorySecureStore())
            )
        )
    }
}
