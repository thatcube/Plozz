import AppRuntime
import CoreModels
import FeatureAuthCore
import XCTest

final class MediaShareAccountConfigurationServiceTests: XCTestCase {
    func testSaveFTPAndImplicitFTPSPersistExpectedSecurityMaterial() throws {
        let store = try makeStore()
        let service = MediaShareAccountConfigurationService(accountStore: store)

        let plain = try service.saveFTP(
            baseURL: try XCTUnwrap(URL(string: "ftp://files.example/Movies/")),
            auth: .anonymous,
            displayName: ""
        )
        XCTAssertEqual(plain.account.id, "share:ftp://files.example/Movies#anon")
        XCTAssertEqual(plain.account.server.name, "Movies (FTP)")

        let secure = try service.saveFTP(
            baseURL: try XCTUnwrap(URL(string: "ftps://files.example:990/TV")),
            auth: .password(username: "Brandon", password: "secret"),
            displayName: "Secure TV"
        )
        XCTAssertEqual(
            secure.account.id,
            "share:ftps://files.example:990/TV#Brandon"
        )
        let credential = try store.mediaShareCredential(
            for: secure.account.id,
            revision: secure.account.credentialRevision
        )
        XCTAssertEqual(credential.transport, .ftp)
        XCTAssertEqual(
            credential.authentication,
            .password(username: "Brandon", password: "secret")
        )
    }

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

    func testSaveSMBPreservesNestedFolderCaseInURLAndIdentity() throws {
        let store = try makeStore()
        let service = MediaShareAccountConfigurationService(accountStore: store)

        let prepared = try service.saveSMB(
            host: "NAS.Local",
            port: nil,
            share: "Multimedia",
            username: "",
            password: "",
            displayName: "",
            subpath: "Movies/Anime"
        )

        XCTAssertEqual(
            prepared.account.id,
            "share:smb://nas.local/multimedia/Movies/Anime#guest"
        )
        XCTAssertEqual(prepared.account.server.name, "Anime (SMB)")
        XCTAssertEqual(
            prepared.account.server.baseURL.absoluteString,
            "smb://NAS.Local/Multimedia/Movies/Anime"
        )
    }

    func testSMBDefaultPortDoesNotForkAccountIdentity() throws {
        let store = try makeStore()
        let service = MediaShareAccountConfigurationService(accountStore: store)

        let implicit = try service.prepareSMB(
            host: "nas.local",
            port: nil,
            share: "Media",
            username: "",
            password: "",
            displayName: ""
        )
        let explicit = try service.prepareSMB(
            host: "nas.local",
            port: 445,
            share: "Media",
            username: "",
            password: "",
            displayName: ""
        )

        XCTAssertEqual(implicit.account.id, explicit.account.id)
        XCTAssertEqual(
            explicit.account.server.baseURL.absoluteString,
            "smb://nas.local/Media"
        )
    }

    func testNestedSMBReusesLegacyFullyLowercasedAccountIdentity() throws {
        let store = try makeStore()
        let legacyID = "share:nas.local/multimedia/movies#guest"
        let legacyAccount = Account(
            id: legacyID,
            server: MediaServer(
                id: legacyID,
                name: "Movies",
                baseURL: URL(string: "smb://nas.local/Multimedia/Movies")!,
                provider: .mediaShare
            ),
            userID: "guest",
            userName: "",
            deviceID: store.deviceID()
        )
        try store.addMediaShare(
            legacyAccount,
            credential: MediaShareCredentialEnvelope(
                transport: .smb,
                authentication: .anonymous
            ),
            generatedPrivateKey: nil
        )
        let service = MediaShareAccountConfigurationService(accountStore: store)

        let prepared = try service.prepareSMB(
            host: "nas.local",
            port: 445,
            share: "Multimedia",
            username: "",
            password: "",
            displayName: "",
            subpath: "Movies"
        )

        XCTAssertEqual(prepared.account.id, legacyID)
        XCTAssertEqual(prepared.previousAccount?.id, legacyID)
    }

    func testNestedSMBDoesNotReuseLegacyIdentityForDifferentPathCase() throws {
        let store = try makeStore()
        let legacyID = "share:nas.local/multimedia/movies#guest"
        let legacyAccount = Account(
            id: legacyID,
            server: MediaServer(
                id: legacyID,
                name: "Movies",
                baseURL: URL(string: "smb://nas.local/Multimedia/Movies")!,
                provider: .mediaShare
            ),
            userID: "guest",
            userName: "",
            deviceID: store.deviceID()
        )
        try store.addMediaShare(
            legacyAccount,
            credential: MediaShareCredentialEnvelope(
                transport: .smb,
                authentication: .anonymous
            ),
            generatedPrivateKey: nil
        )
        let service = MediaShareAccountConfigurationService(accountStore: store)

        let prepared = try service.prepareSMB(
            host: "nas.local",
            port: nil,
            share: "Multimedia",
            username: "",
            password: "",
            displayName: "",
            subpath: "movies"
        )

        XCTAssertEqual(
            prepared.account.id,
            "share:smb://nas.local/multimedia/movies#guest"
        )
        XCTAssertNil(prepared.previousAccount)
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
            "share:nfs://nas.local/volume/Movies#anon"
        )
        XCTAssertEqual(prepared.account.server.name, "Movies (NFS)")
        XCTAssertEqual(
            prepared.account.server.baseURL.absoluteString,
            "nfs://NAS.Local/volume/Movies"
        )
        XCTAssertEqual(store.loadAccounts(), [prepared.account])
        let credential = try store.mediaShareCredential(
            for: prepared.account.id,
            revision: prepared.account.credentialRevision
        )
        XCTAssertEqual(credential.transport, .nfs)
        XCTAssertEqual(credential.authentication, .noCredentials)
        XCTAssertNil(credential.transportRootPath)
    }

    func testSaveNFSKeepsExportBoundaryBelowSelectedFolder() throws {
        let store = try makeStore()
        let service = MediaShareAccountConfigurationService(accountStore: store)

        let prepared = try service.saveNFS(
            host: "NAS.Local",
            port: 2_049,
            exportPath: "/volume1/Media",
            subpath: "Movies/Family",
            displayName: ""
        )

        XCTAssertEqual(
            prepared.account.id,
            "share:nfs://nas.local/volume1/Media/Movies/Family#anon"
        )
        XCTAssertEqual(prepared.account.server.name, "Family (NFS)")
        XCTAssertEqual(
            prepared.account.server.baseURL.absoluteString,
            "nfs://NAS.Local/volume1/Media/Movies/Family"
        )
        let credential = try store.mediaShareCredential(
            for: prepared.account.id,
            revision: prepared.account.credentialRevision
        )
        XCTAssertEqual(credential.transportRootPath, "/volume1/Media")
    }

    func testNFSDefaultPortDoesNotForkAccountIdentity() throws {
        let store = try makeStore()
        let service = MediaShareAccountConfigurationService(accountStore: store)

        let implicit = try service.prepareNFS(
            host: "nas.local",
            port: nil,
            exportPath: "/volume1/Media",
            displayName: ""
        )
        let explicit = try service.prepareNFS(
            host: "nas.local",
            port: 2_049,
            exportPath: "/volume1/Media",
            displayName: ""
        )

        XCTAssertEqual(implicit.account.id, explicit.account.id)
        XCTAssertEqual(
            explicit.account.server.baseURL.absoluteString,
            "nfs://nas.local/volume1/Media"
        )
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
