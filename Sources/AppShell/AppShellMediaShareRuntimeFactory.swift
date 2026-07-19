import AppRuntime
import CoreModels
import CoreUI
import EnginePlozzigen
import FeatureAuthCore
import ProviderShare

enum AppShellMediaShareRuntimeFactory {
    static func make(accountStore: any AccountPersisting) -> DefaultMediaShareRuntime {
        let artworkCacheLifecycle = MediaShareLocalArtworkCacheLifecycle()
        let runtime = DefaultMediaShareRuntime.make(
            accountStore: accountStore,
            artworkCacheLifecycle: artworkCacheLifecycle
        ) { resolver in
            PlozzigenNetworkFileStreamProber(resolver: resolver)
        }
        ArtworkImageCache.shared.configure(
            networkFileService: runtime.artworkNetworkFileService
        )
        return runtime
    }
}

private struct MediaShareLocalArtworkCacheLifecycle: ShareLocalArtworkCacheLifecycle {
    func setPreferredAccountKeys(_ accountKeys: Set<String>, revision: UInt64) async {
        await ArtworkImageCache.shared.setPreferredNetworkArtworkAccounts(
            accountKeys,
            revision: revision
        )
    }

    func purge(accountID: String) async {
        await ArtworkImageCache.shared.purgeNetworkArtwork(accountID: accountID)
    }

    func purge(accountID: String, credentialRevision: CredentialRevision) async {
        await ArtworkImageCache.shared.purgeNetworkArtwork(
            accountID: accountID,
            credentialRevision: credentialRevision
        )
    }
}
