#if os(iOS)
import CoreUI
import SwiftUI

struct PlozziOSAddShareView: View {
    let appModel: PlozziOSAppModel

    var body: some View {
        List {
            SettingsSectionGroup("Network protocol") {
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
                NavigationLink {
                    PlozziOSAddSFTPShareView(appModel: appModel)
                } label: {
                    Label("SFTP", systemImage: "lock.shield")
                }
                NavigationLink {
                    PlozziOSAddFTPShareView(appModel: appModel)
                } label: {
                    Label("FTP / FTPS", systemImage: "server.rack")
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Add Network Share")
    }
}
#endif
