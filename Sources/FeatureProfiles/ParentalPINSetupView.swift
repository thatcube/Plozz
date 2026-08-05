#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

/// Creates or replaces the household's Parental PIN: enter it, then enter it
/// again.
///
/// Simpler than ``ProfileLockSetupView`` on purpose. That screen also has to ask
/// whether the PIN is the same as a Plex Home user's, because a profile can be
/// bound to one. A Parental PIN belongs to the household rather than to any
/// server identity, so there is nothing to reconcile — and adding the question
/// would only suggest there is.
public struct ParentalPINSetupView: View {
    private let isReplacing: Bool
    private let onComplete: (ParentalPIN) -> Void
    private let onCancel: () -> Void

    /// - Parameter isReplacing: whether a PIN already exists, which only changes
    ///   the title. The old PIN isn't asked for: reaching this screen already
    ///   required it (from inside a Kids Profile) or a grown-up profile the
    ///   child can't open.
    public init(
        isReplacing: Bool = false,
        onComplete: @escaping (ParentalPIN) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.isReplacing = isReplacing
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    /// The first entry, held while the second is collected.
    ///
    /// Kept in its own state rather than doubling as the "which step am I on"
    /// flag — deriving presentation from the stored digits is what made the
    /// profile lock setup lose a confirmed PIN mid-flow.
    @State private var firstEntry: String?
    @State private var errorMessage: String?

    public var body: some View {
        PINEntryScaffold(
            title: firstEntry == nil
                ? (isReplacing
                    ? KidsProfileCopy.parentalPINChange
                    : KidsProfileCopy.parentalPINSetTitle)
                : KidsProfileCopy.parentalPINConfirmTitle,
            subtitle: firstEntry == nil ? KidsProfileCopy.parentalPINExplanation : nil,
            name: String(localized: KidsProfileCopy.parentalPIN),
            errorMessage: errorMessage,
            sequenceStep: .init(current: firstEntry == nil ? 1 : 2, total: 2),
            onSubmit: submit,
            onCancel: onCancel
        ) {
            PINBadge {
                Image(systemName: "figure.and.child.holdinghands")
                    .font(.system(size: PINLayout.badgeSize * 0.45, weight: .semibold))
            }
        }
    }

    private func submit(_ pin: String) {
        guard let first = firstEntry else {
            errorMessage = nil
            firstEntry = pin
            return
        }
        guard pin == first, let created = ParentalPIN.make(pin: pin) else {
            firstEntry = nil
            errorMessage = String(localized: ProfileLockCopy.mismatch)
            return
        }
        errorMessage = nil
        firstEntry = nil
        onComplete(created)
    }
}
#endif
