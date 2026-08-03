// The keychain primitives moved down to `CoreSecureStore` so the tracker
// services can share them without reaching up into a Feature module. Re-exported
// here so the modules that already import FeatureAuthCore for `KeychainStore`
// keep compiling unchanged.
@_exported import CoreSecureStore
