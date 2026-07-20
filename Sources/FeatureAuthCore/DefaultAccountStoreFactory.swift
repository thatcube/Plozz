import CoreModels

public enum DefaultAccountStoreFactory {
    public static func make() throws -> AccountStore {
        #if canImport(Security)
        let secureStore = KeychainStore()
        let localStateStore = try DurableLocalStateStoreFactory.userIndependent()
        return AccountStore(
            secureStore: secureStore,
            mediaCredentialVault: MediaCredentialVault(secureStore: secureStore),
            credentialJournal: try CredentialMutationJournal(store: localStateStore)
        )
        #else
        return AccountStore(secureStore: InMemorySecureStore())
        #endif
    }

    public static func makeCredentialOnlyFallback() -> AccountStore {
        #if canImport(Security)
        AccountStore(secureStore: KeychainStore())
        #else
        AccountStore(secureStore: InMemorySecureStore())
        #endif
    }
}
