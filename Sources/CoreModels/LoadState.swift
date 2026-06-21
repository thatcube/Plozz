import Foundation

/// Generic async UI state used across features for consistent
/// loading / loaded / empty / error rendering.
///
/// Keeping this in `CoreModels` means every feature renders these states the
/// same way (a Phase 1 UX requirement) without duplicating the enum.
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

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

extension LoadState: Equatable where Value: Equatable {}
