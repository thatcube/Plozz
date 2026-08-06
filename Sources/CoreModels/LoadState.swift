import Foundation

/// Generic async UI state used across features for consistent
/// loading / loaded / empty / error rendering.
///
/// Keeping this in `CoreModels` means every feature renders these states the
/// same way without duplicating the enum.
public enum LoadState<Value: Sendable>: Sendable {
    case idle
    case loading
    case loaded(Value)
    case empty
    case failed(AppError)

    public var value: Value? {
        if case let .loaded(value) = self { return value }
        return nil
    }

    /// A short, value-free name for telemetry. Deliberately omits the payload:
    /// a diagnostic line must never print library or title names.
    public var diagnosticName: String {
        switch self {
        case .idle: return "idle"
        case .loading: return "loading"
        case .loaded: return "loaded"
        case .empty: return "empty"
        case .failed: return "failed"
        }
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

extension LoadState: Equatable where Value: Equatable {}
