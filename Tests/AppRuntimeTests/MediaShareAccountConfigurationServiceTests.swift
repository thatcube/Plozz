import AppRuntime
import CoreModels
import FeatureAuthCore
import XCTest

final class MediaShareAccountConfigurationServiceTests: XCTestCase {
    func testSaveSFTPPersistsPasswordAndMandatoryHostKeyPin() throws {
        let store = try makeStore()
        let service = MediaShareAccountConfigurationService(accountStore: store)
        let pin = try SHA256Fingerprint(bytes: Data(repeating: 9, count: 32))

        let prepared = try service.saveSFTP(
            host: "SFTP.Example",
            port: 22,
            path: "Media/Movies/",
            username: "Brandon",
            password: "secret",
            hostKeyPin: pin,
            displayName: ""
        )

        XCTAssertEqual(
            prepared.account.id,
            "share:sftp://sftp.example:22/Media/Movies#Brandon"
        )
        XCTAssertEqual(prepared.account.server.name, "Movies (SFTP)")
        let credential = try store.mediaShareCredential(
            for: prepared.account.id,
            revision: prepared.account.credentialRevision
        )
        XCTAssertEqual(
            credential.authentication,
            .password(username: "Brandon", password: "secret")
        )
        XCTAssertEqual(credential.trust.sshHostKeySHA256, pin)
    }

    func testSaveWebDAVPersistsBearerAndPinnedTrust() throws {
        let store = try makeStore()
        let service = MediaShareAccountConfigurationService(accountStore: store)
        let pin = try SHA256Fingerprint(bytes: Data(repeating: 7, count: 32))

        let prepared = try service.saveWebDAV(
            baseURL: try XCTUnwrap(URL(string: "https://DAV.Example:443/media/")),
            auth: .bearer(token: "token"),
            trustPin: pin,
            displayName: ""
        )

        XCTAssertEqual(
            prepared.account.id,
            "share:https://dav.example/media#bearer"
        )
        XCTAssertEqual(prepared.account.server.name, "media (WebDAV)")
        let credential = try store.mediaShareCredential(
            for: prepared.account.id,
            revision: prepared.account.credentialRevision
        )
        XCTAssertEqual(credential.authentication, .bearer(token: "token"))
        XCTAssertEqual(credential.trust.tlsLeafCertificateSHA256, pin)
    }

    func testSaveSMBPersistsPasswordCredentialAndStableIdentity() throws {
        let store = try makeStore()
        let service = MediaShareAccountConfigurationService(accountStore: store)

        let prepared = try service.saveSMB(
            host: "NAS.Local",
            port: nil,
            share: "/Media/",
            username: "Brandon",
            password: "secret",
            displayName: ""
        )

        XCTAssertEqual(
            prepared.account.id,
            "share:nas.local/media#brandon"
        )
        XCTAssertEqual(prepared.account.server.name, "Media (SMB)")
        XCTAssertEqual(prepared.account.server.baseURL.absoluteString, "smb://NAS.Local/Media")
        let credential = try store.mediaShareCredential(
            for: prepared.account.id,
            revision: prepared.account.credentialRevision
        )
        XCTAssertEqual(credential.transport, .smb)
        XCTAssertEqual(
            credential.authentication,
            .password(username: "Brandon", password: "secret")
        )
    }

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
