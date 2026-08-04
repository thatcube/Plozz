#if os(iOS)
import CoreUI
import SwiftUI

/// Stands in for the withheld shared settings group while a Kids Profile is
/// active.
///
/// Rendering nothing would be worse than rendering this: a grown-up who picks up
/// the phone and finds Servers missing needs to be told where it went, not left
/// to conclude the app is broken.
struct PlozziOSKidsProfileNote: View {
    var body: some View {
        SettingsSectionGroup(KidsProfileCopy.title) {
            Label {
                Text(KidsProfileCopy.restrictedHere)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "figure.and.child.holdinghands")
            }
            .foregroundStyle(.secondary)
        }
    }
}
#endif
