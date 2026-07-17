import MetadataKit

enum ShareExternalResolverKind: Equatable {
    case keyless
    case tvdb
}

enum ShareExternalResolverSelection {
    static func kind(for config: TVDBConfig) -> ShareExternalResolverKind {
        config.isConfigured ? .tvdb : .keyless
    }

    static func make(for config: TVDBConfig) -> any ShareMetadataResolving {
        switch kind(for: config) {
        case .keyless:
            return KeylessShareResolver()
        case .tvdb:
            return TVDBShareResolver(tvdb: TVDBClient(config: config))
        }
    }
}
