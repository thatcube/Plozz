#if os(iOS)
import SwiftUI

struct PlozziOSAddShareView: View {
    let appModel: PlozziOSAppModel

    var body: some View {
        List {
            Section("Network protocol") {
                NavigationLink {
                    PlozziOSAddSMBShareView(appModel: appModel)
                } label: {
                    Label("SMB", systemImage: "externaldrive.connected.to.line.below")
                }
                NavigationLink {
                    PlozziOSAddNFSShareView(appModel: appModel)
                } label: {
                    Label("NFS", systemImage: "externaldrive")
                }
                NavigationLink {
                    PlozziOSAddWebDAVShareView(appModel: appModel)
                } label: {
                    Label("WebDAV", systemImage: "network")
                }
            }
        }
        .navigationTitle("Add Network Share")
    }
}
#endif
