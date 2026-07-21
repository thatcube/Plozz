// PlozzSyncUXPrototype — clickable mock of the "Sync & Setup" start-anywhere flows.
// Pure UI: no networking, no iCloud, no credentials. For feel + critique only.

import SwiftUI

@main
struct PlozzSyncUXPrototypeApp: App {
    var body: some Scene { WindowGroup { HomeView() } }
}

// MARK: - Home / scenario picker

struct HomeView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Start on iPhone / iPad") {
                    link("First-time setup on iPhone", "iphone", FirstSetupFlow())
                    link("Open on iPad (same Apple ID)", "ipad", SameAppleIDAutoView())
                }
                Section("Bring setup to the Apple TV") {
                    link("Set up Apple TV from phone (discovery)", "appletv", TVDiscoveryFlow())
                    link("Off-network: type the TV code", "keyboard", ManualCodeFlow())
                    link("What the Apple TV shows (waiting)", "tv", TVWaitingScreen())
                }
                Section("Reverse: TV first, then phone") {
                    link("“You already set up on Apple TV — bring it here?”", "sparkles.tv", BeaconContinueFlow())
                }
            }
            .navigationTitle("Sync & Setup — UX")
            .listStyle(.insetGrouped)
        }
    }

    private func link<V: View>(_ title: String, _ symbol: String, _ dest: V) -> some View {
        NavigationLink(destination: dest) {
            Label(title, systemImage: symbol)
        }
    }
}

// MARK: - Reusable pieces

struct BigButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

struct Stepper: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
    }
}

struct SuccessView: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72)).foregroundStyle(.green)
            Text(title).font(.title2.bold())
            Text(subtitle).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding()
    }
}

// MARK: - Flow 1: first setup on iPhone

struct FirstSetupFlow: View {
    enum Step { case server, signIn, profile, consent, done }
    @State private var step: Step = .server
    var body: some View {
        VStack(spacing: 24) {
            switch step {
            case .server:
                header("Add your server", "We found a Jellyfin server on your Wi-Fi.")
                serverCard(found: true)
                BigButton(title: "Use “Home Server”", systemImage: "server.rack") { step = .signIn }
                Button("Enter address / sign in to Plex instead") { step = .signIn }
            case .signIn:
                header("Sign in", "On your phone’s keyboard — the easy part.")
                BigButton(title: "Use Quick Connect", systemImage: "qrcode") { step = .profile }
                Button("Type username & password") { step = .profile }
            case .profile:
                header("Make it yours", "Create a profile and pick your settings.")
                BigButton(title: "Create profile “Brandon”", systemImage: "person.crop.circle") { step = .consent }
            case .consent:
                header("Sync to your other devices?", "")
                Text("Securely syncs your login and settings through your private iCloud (end-to-end encrypted). You can turn this off any time.")
                    .foregroundStyle(.secondary)
                BigButton(title: "Turn On Sync", systemImage: "icloud") { step = .done }
                Button("Not now") { step = .done }
            case .done:
                SuccessView(title: "You’re set up",
                            subtitle: "Your iPad will sign itself in automatically. For the Apple TV, open Plozz on it and tap “Set up from iPhone.”")
            }
            Spacer()
        }
        .padding().navigationTitle("iPhone setup").navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Flow 2: same Apple ID (automatic)

struct SameAppleIDAutoView: View {
    @State private var loading = true
    var body: some View {
        VStack(spacing: 20) {
            if loading {
                Stepper(text: "Restoring from your iCloud…")
            } else {
                SuccessView(title: "Already signed in",
                            subtitle: "Your servers, profiles, and settings are here — nothing to scan. (Same Apple ID as your iPhone.)")
            }
            Spacer()
        }
        .padding().navigationTitle("iPad").navigationBarTitleDisplayMode(.inline)
        .task { try? await Task.sleep(nanoseconds: 1_400_000_000); loading = false }
    }
}

// MARK: - Flow 3: phone discovers + sets up the Apple TV

struct TVDiscoveryFlow: View {
    enum Step { case searching, found, verify, transferring, done }
    @State private var step: Step = .searching
    private let code = "4193"
    var body: some View {
        VStack(spacing: 22) {
            switch step {
            case .searching:
                header("Looking for your Apple TV", "Make sure it’s on and on the same Wi-Fi.")
                Stepper(text: "Searching your network…")
            case .found:
                header("Found your Apple TV", "")
                deviceRow("Living Room", "appletv")
                BigButton(title: "Set up “Living Room”", systemImage: "arrow.down.circle") { step = .verify }
            case .verify:
                header("Confirm it’s your TV", "Check the code shown on the TV matches.")
                Text(code).font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
                BigButton(title: "It matches", systemImage: "checkmark") { step = .transferring }
                Button("Codes don’t match") { step = .searching }
            case .transferring:
                header("Setting up your Apple TV", "")
                Stepper(text: "Sending your servers, profiles & sign-in…")
            case .done:
                SuccessView(title: "Apple TV is ready",
                            subtitle: "Signed in and fully configured. You didn’t type anything on the TV.")
            }
            Spacer()
        }
        .padding().navigationTitle("Set up Apple TV").navigationBarTitleDisplayMode(.inline)
        .task(id: String(describing: step)) {
            if step == .searching { try? await Task.sleep(nanoseconds: 1_500_000_000); if step == .searching { step = .found } }
            if step == .transferring { try? await Task.sleep(nanoseconds: 1_800_000_000); if step == .transferring { step = .done } }
        }
    }
}

// MARK: - Flow 4: off-network manual code

struct ManualCodeFlow: View {
    enum Step { case entry, transferring, done }
    @State private var step: Step = .entry
    @State private var entered = ""
    var body: some View {
        VStack(spacing: 22) {
            switch step {
            case .entry:
                header("Type the code from your TV", "Use this when the phone and TV aren’t on the same Wi-Fi.")
                TextField("4-digit code", text: $entered)
                    .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                    .font(.system(.title, design: .rounded))
                BigButton(title: "Continue", systemImage: "arrow.right") { step = .transferring }
                    .disabled(entered.count < 4)
            case .transferring:
                Stepper(text: "Pairing with your Apple TV…")
            case .done:
                SuccessView(title: "Apple TV is ready", subtitle: "Paired and configured over the internet, still end-to-end encrypted.")
            }
            Spacer()
        }
        .padding().navigationTitle("Type TV code").navigationBarTitleDisplayMode(.inline)
        .task(id: String(describing: step)) {
            if step == .transferring { try? await Task.sleep(nanoseconds: 1_600_000_000); if step == .transferring { step = .done } }
        }
    }
}

// MARK: - Flow 5: what the TV shows

struct TVWaitingScreen: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("Set up with your iPhone").font(.title2.bold())
            RoundedRectangle(cornerRadius: 12).fill(.quaternary).frame(width: 180, height: 180)
                .overlay(Image(systemName: "qrcode").resizable().scaledToFit().padding(24).foregroundStyle(.primary))
            Text("or enter code").foregroundStyle(.secondary)
            Text("4193").font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
            Divider().padding(.vertical, 8)
            Text("No phone? Sign in on this TV")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Label("Quick Connect", systemImage: "qrcode")
                Label("Plex link", systemImage: "link")
            }.font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .padding().navigationTitle("Apple TV screen").navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Flow 6: presence beacon "continue on this device"

struct BeaconContinueFlow: View {
    enum Step { case prompt, wakeTV, transferring, done }
    @State private var step: Step = .prompt
    var body: some View {
        VStack(spacing: 22) {
            switch step {
            case .prompt:
                Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(.tint)
                header("Continue where you left off?", "We found a Plozz setup on your Apple TV “Living Room.”")
                BigButton(title: "Bring it to this device", systemImage: "square.and.arrow.down") { step = .wakeTV }
                Button("Set up fresh instead") { }
            case .wakeTV:
                header("Turn on your Apple TV", "Your logins live only on your devices — we’ll copy them from the TV.")
                Stepper(text: "Waiting for “Living Room”…")
            case .transferring:
                Stepper(text: "Copying servers, profiles & sign-in…")
            case .done:
                SuccessView(title: "All set on this device",
                            subtitle: "Config came from iCloud; your logins came securely from the Apple TV.")
            }
            Spacer()
        }
        .padding().navigationTitle("Continue setup").navigationBarTitleDisplayMode(.inline)
        .task(id: String(describing: step)) {
            if step == .wakeTV { try? await Task.sleep(nanoseconds: 1_600_000_000); if step == .wakeTV { step = .transferring } }
            if step == .transferring { try? await Task.sleep(nanoseconds: 1_600_000_000); if step == .transferring { step = .done } }
        }
    }
}

// MARK: - small helpers

@ViewBuilder
func header(_ title: String, _ subtitle: String) -> some View {
    VStack(spacing: 8) {
        Text(title).font(.title2.bold()).multilineTextAlignment(.center)
        if !subtitle.isEmpty {
            Text(subtitle).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}

@ViewBuilder
func serverCard(found: Bool) -> some View {
    HStack {
        Image(systemName: "server.rack").font(.title2)
        VStack(alignment: .leading) {
            Text("Home Server").fontWeight(.semibold)
            Text(found ? "Jellyfin • 192.168.1.x" : "Not found").font(.footnote).foregroundStyle(.secondary)
        }
        Spacer()
        if found { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
    }
    .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
}

@ViewBuilder
func deviceRow(_ name: String, _ symbol: String) -> some View {
    HStack {
        Image(systemName: symbol).font(.title2)
        Text(name).fontWeight(.semibold)
        Spacer()
        Image(systemName: "chevron.right").foregroundStyle(.secondary)
    }
    .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
}
