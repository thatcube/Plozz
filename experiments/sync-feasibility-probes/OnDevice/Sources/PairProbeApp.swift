// PlozzPairProbe — on-device Bonjour discovery feasibility probe (throwaway).
//
// tvOS build: advertises `_plozz-pair._tcp`, answers with a FAKE non-secret beacon.
// iOS build: browses, connects to the discovered TV, exchanges the fake beacon.
// Both log to os_log (subsystem com.thatcube.pairprobe) AND on screen, so the real
// discovery + Local Network permission flow can be observed on device and in console.
//
// No iCloud, no credentials, no real stores. Non-secret payload only.

import SwiftUI
import Network
import os

let probeLog = Logger(subsystem: "com.thatcube.pairprobe", category: "probe")
let kServiceType = "_plozz-pair._tcp"

struct FakeBeacon: Codable {
    var setupExists = true
    var deviceName = "PairProbe device"
    var serverCount = 2
}

final class ProbeEngine: ObservableObject, @unchecked Sendable {
    @Published var lines: [String] = []
    @Published var status: String = "starting…"

    private let q = DispatchQueue(label: "pairprobe.net")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private let connectLock = NSLock()
    private var didConnect = false

    private func setStatus(_ s: String) {
        DispatchQueue.main.async { self.status = s }
    }

    func log(_ s: String) {
        probeLog.log("\(s, privacy: .public)")
        DispatchQueue.main.async {
            self.lines.append(s)
            if self.lines.count > 200 { self.lines.removeFirst() }
        }
    }

    // MARK: tvOS role — advertise
    func startAdvertising(name: String) {
        setStatus("Advertising \(kServiceType)")
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        do {
            let l = try NWListener(using: params)
            l.service = NWListener.Service(name: name, type: kServiceType)
            l.stateUpdateHandler = { [weak self] st in
                if case .ready = st { self?.log("ADVERTISER ready: '\(name)'") }
                if case .failed(let e) = st { self?.log("ADVERTISER failed: \(e)") }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: q)
            listener = l
        } catch { log("ADVERTISER start error: \(error)") }
    }

    private func accept(_ c: NWConnection) {
        c.stateUpdateHandler = { [weak self] st in
            if case .ready = st {
                self?.log("ADVERTISER: peer connected, sending beacon")
                let beacon = (try? JSONEncoder().encode(FakeBeacon())) ?? Data()
                c.send(content: beacon, completion: .contentProcessed { _ in })
            }
        }
        c.start(queue: q)
    }

    // MARK: iOS role — browse + exchange
    func startBrowsing() {
        setStatus("Browsing for \(kServiceType) (may prompt Local Network)")
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: kServiceType, domain: nil), using: params)
        let start = Date()
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.connectLock.lock(); defer { self.connectLock.unlock() }
            if self.didConnect { return }
            for r in results {
                if case let .service(name, _, _, _) = r.endpoint {
                    let dt = Date().timeIntervalSince(start)
                    self.log(String(format: "BROWSER discovered '%@' in %.2fs", name, dt))
                    self.didConnect = true
                    self.connect(r.endpoint, start: start)
                    return
                }
            }
        }
        b.stateUpdateHandler = { [weak self] st in
            if case .failed(let e) = st { self?.log("BROWSER failed: \(e)") }
            if case .ready = st { self?.log("BROWSER ready") }
        }
        b.start(queue: q)
        browser = b
    }

    private func connect(_ ep: NWEndpoint, start: Date) {
        let c = NWConnection(to: ep, using: .tcp)
        c.stateUpdateHandler = { [weak self] st in
            if case .ready = st {
                c.send(content: Data("hello\n".utf8), completion: .contentProcessed { _ in })
                c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    let dt = Date().timeIntervalSince(start)
                    if let data, let bea = try? JSONDecoder().decode(FakeBeacon.self, from: data) {
                        self?.log(String(format: "BROWSER got beacon (device='%@' servers=%d) total %.2fs OK",
                                         bea.deviceName, bea.serverCount, dt))
                        self?.setStatus("SUCCESS discovered + exchanged")
                    } else {
                        self?.log("BROWSER decode failed")
                    }
                    c.cancel()
                }
            }
            if case .failed(let e) = st { self?.log("BROWSER connection failed: \(e)") }
        }
        c.start(queue: q)
    }
}

struct ContentView: View {
    @StateObject private var engine = ProbeEngine()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PlozzPairProbe").font(.title.bold())
            Text(engine.status).font(.headline).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(engine.lines.enumerated()), id: \.offset) { _, l in
                        Text(l).font(.system(.footnote, design: .monospaced))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(40)
        .onAppear {
            #if os(tvOS)
            engine.startAdvertising(name: "BrandoTV-PairProbe")
            #else
            engine.startBrowsing()
            #endif
        }
    }
}

@main
struct PlozzPairProbeApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
