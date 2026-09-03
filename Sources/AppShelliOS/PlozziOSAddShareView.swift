#if os(iOS)
import SwiftUI

struct PlozziOSAddShareView: View {
    let appModel: PlozziOSAppModel

    var body: some View {
        PlozziOSUnifiedAddShareView(
            appModel: appModel,
            embedsNavigationStack: false
        )
    }
}
#endif
