import Foundation

/// Minimal secure key/value abstraction visible to `CoreModels`.
///
/// `CoreModels` can't depend on `FeatureAuth` (where the concrete Keychain lives),
/// but `ProfileStore` needs to optionally persist the household's shared profile
/// set into the same user-independent Keychain that backs the shared sign-in.
/// `FeatureAuth.SecureStore` refines this protocol, so a single `KeychainStore`
/// can be handed to both the account store and the profile store.
public protocol SecureStoring: Sendable {
    func setString(_ value: String, for key: String) throws
    func string(for key: String) -> String?
    func removeValue(for key: String) throws
}
