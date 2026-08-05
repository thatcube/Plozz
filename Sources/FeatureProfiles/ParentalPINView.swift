#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

/// The PIN screen for the household's Parental PIN.
///
/// Shown when leaving a Kids Profile for a grown-up one, and when opening the
/// Grown-ups section inside a Kids Profile. One view for both shells and both
/// uses, so the child never learns to tell the two gates apart.
///
/// Deliberately the same `PINEntryScaffold` as ``ProfileLockPINView``. They ask
/// different questions — "may you open this profile" versus "may you leave the
/// child's" — but they're the same *gesture*, and giving the parental one its own
/// look would only suggest a different system is involved.
public struct ParentalPINView: View {
    private let title: LocalizedStringResource
    private let destination: Profile?
    private let errorMessage: LocalizedStringResource?
    private let sequenceStep: PINSequenceStep?
    private let onSubmit: (String) -> Void
    private let onCancel: () -> Void

    /// - Parameter destination: the profile being opened, when this gate is
    ///   holding a switch. Naming it answers "why am I being asked?" without a
    ///   sentence of explanation. `nil` when unlocking settings in place.
    public init(
        title: LocalizedStringResource = KidsProfileCopy.parentalPINEnter,
        destination: Profile? = nil,
        errorMessage: LocalizedStringResource?,
        sequenceStep: PINSequenceStep? = nil,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.destination = destination
        self.errorMessage = errorMessage
        self.sequenceStep = sequenceStep
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    public var body: some View {
        PINEntryScaffold(
            title: title,
            name: destination.map { Text(verbatim: $0.name) } ?? Text(KidsProfileCopy.parentalPIN),
            errorMessage: errorMessage,
            sequenceStep: sequenceStep,
            onSubmit: onSubmit,
            onCancel: onCancel
        ) {
            if let destination {
                ProfileAvatarView(profile: destination, size: PINLayout.badgeSize)
            } else {
                PINBadge {
                    Image(systemName: "figure.and.child.holdinghands")
                        .font(.system(size: PINLayout.badgeSize * 0.45, weight: .semibold))
                }
            }
        }
    }
}
#endif
