#if os(iOS)
import CoreUI
import SwiftUI

struct PlozziOSAddShareView: View {
    let appModel: PlozziOSAppModel
    @State private var selectedProtocol: ShareProtocol?

    /// The share protocols offered, in display order. Backs the value-driven
    /// navigation below.
    private enum ShareProtocol: String, Hashable, CaseIterable, Identifiable {
        case smb, nfs, webdav, sftp, ftp
        var id: String { rawValue }
        /// Protocol names are brands, never translated. A translator handed "SMB"
        /// in a catalog has no way to know that, and some would translate it.
        var title: Text {
            switch self {
            case .smb: return Text(verbatim: "SMB")
            case .nfs: return Text(verbatim: "NFS")
            case .webdav: return Text(verbatim: "WebDAV")
            case .sftp: return Text(verbatim: "SFTP")
            case .ftp: return Text(verbatim: "FTP / FTPS")
            }
        }
        var systemImage: String {
            switch self {
            case .smb: return "externaldrive.connected.to.line.below"
            case .nfs: return "externaldrive"
            case .webdav: return "network"
            case .sftp: return "lock.shield"
            case .ftp: return "server.rack"
            }
        }
    }

    var body: some View {
        List {
            SettingsSectionGroup("Network protocol") {
                // Plain Buttons (not NavigationLink): SettingsSectionGroup re-emits its
                // children via Group(subviews:), which breaks NavigationLink (opens all /
                // opens none). A Button sets state; navigationDestination(item:) pushes
                // exactly the tapped protocol.
                ForEach(ShareProtocol.allCases) { proto in
                    Button {
                        selectedProtocol = proto
                    } label: {
                        HStack(spacing: 12) {
                            Label { proto.title } icon: { Image(systemName: proto.systemImage) }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .plozzForeground(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Add Network Share")
        .navigationDestination(item: $selectedProtocol) { proto in
            switch proto {
            case .smb: PlozziOSAddSMBShareView(appModel: appModel)
            case .nfs: PlozziOSAddNFSShareView(appModel: appModel)
            case .webdav: PlozziOSAddWebDAVShareView(appModel: appModel)
            case .sftp: PlozziOSAddSFTPShareView(appModel: appModel)
            case .ftp: PlozziOSAddFTPShareView(appModel: appModel)
            }
        }
    }
}
#endif
