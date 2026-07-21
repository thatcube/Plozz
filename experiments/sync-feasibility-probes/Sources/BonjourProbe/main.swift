// BonjourProbe — isolated feasibility probe for the Plozz "Sync & Setup" gate.
//
// Purpose: prove the Network.framework Bonjour discovery + pairing-transport
// wiring that the TV<->phone pairing UX depends on, and measure discovery +
// round-trip latency. Runs headless on macOS over the loopback interface so we
// get a REAL measured result without two physical devices. The exact same
// NWListener/NWBrowser/NWConnection API compiles unchanged for iOS/tvOS (where a
// device run additionally exercises the Local Network privacy prompt + declared
// NSBonjourServices — see README).
//
// NON-SECRET ONLY: the exchanged payload is a fake "presence beacon" — no tokens,
// no passwords, nothing wired to real stores.
//
// Modes:
//   swift run BonjourProbe                 # self-test: advertise + browse + exchange (default)
//   swift run BonjourProbe --advertise     # advertise only (run on the "TV" side)
//   swift run BonjourProbe --browse        # browse only (run on the "phone" side)

import Foundation
import Network

let serviceType = "_plozz-pair._tcp"
let serviceDomain = "local."
let discoveryTimeout: TimeInterval = 15

// A deliberately NON-SECRET placeholder — mirrors the presence beacon shape only.
struct FakePresenceBeacon: Codable {
    var setupExists = true
    var deviceName = "Brando TV (probe)"
    var serverCount = 2
    var schemaVersion = 1
    // NOTE: intentionally NO token, password, hostname, or account id.
}

func log(_ msg: String) {
    let t = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(t)] \(msg)\n".utf8))
}

// MARK: - Advertiser ("TV waiting screen" side)

final class Advertiser {
    private var listener: NWListener?
    let queue = DispatchQueue(label: "probe.advertiser")

    func start(serviceName: String, onReady: @escaping (UInt16) -> Void) throws {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let listener = try NWListener(using: params)
        listener.service = NWListener.Service(name: serviceName, type: serviceType)
        self.listener = listener

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let port = listener.port?.rawValue ?? 0
                log("advertiser: listener ready, advertising \(serviceType) name=\(serviceName) port=\(port)")
                onReady(port)
            case .failed(let err):
                log("advertiser: listener FAILED: \(err)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)
    }

    private func handle(_ conn: NWConnection) {
        conn.stateUpdateHandler = { state in
            if case .ready = state {
                // Receive the browser's hello, then reply with a fake beacon.
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    if let data, let hello = String(data: data, encoding: .utf8) {
                        log("advertiser: received hello: \(hello.trimmingCharacters(in: .whitespacesAndNewlines))")
                    }
                    let beacon = (try? JSONEncoder().encode(FakePresenceBeacon())) ?? Data()
                    conn.send(content: beacon, completion: .contentProcessed { _ in
                        log("advertiser: sent fake beacon (\(beacon.count) bytes)")
                    })
                }
            }
        }
        conn.start(queue: queue)
    }
}

// MARK: - Browser ("phone discovers the TV" side)

final class Browser {
    private var browser: NWBrowser?
    let queue = DispatchQueue(label: "probe.browser")
    private var didConnect = false

    func start(expectedName: String?, browseStart: Date, onDone: @escaping (Bool) -> Void) {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: params)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, !self.didConnect else { return }
            for result in results {
                if case let .service(name, _, _, _) = result.endpoint {
                    if let expectedName, name != expectedName { continue }
                    let discoveryLatency = Date().timeIntervalSince(browseStart)
                    log(String(format: "browser: DISCOVERED '%@' in %.3fs", name, discoveryLatency))
                    self.didConnect = true
                    self.connect(to: result.endpoint, browseStart: browseStart, onDone: onDone)
                    return
                }
            }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let err) = state { log("browser: FAILED: \(err)") ; onDone(false) }
        }
        browser.start(queue: queue)
        log("browser: browsing for \(serviceType) ...")
    }

    private func connect(to endpoint: NWEndpoint, browseStart: Date, onDone: @escaping (Bool) -> Void) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let hello = Data("hello-from-probe-browser\n".utf8)
                conn.send(content: hello, completion: .contentProcessed { _ in })
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    let rtt = Date().timeIntervalSince(browseStart)
                    if let data, let beacon = try? JSONDecoder().decode(FakePresenceBeacon.self, from: data) {
                        log(String(format: "browser: received beacon (setupExists=%@ device='%@' servers=%d) — total discover+exchange %.3fs",
                                   String(beacon.setupExists), beacon.deviceName, beacon.serverCount, rtt))
                        onDone(true)
                    } else {
                        log("browser: failed to decode beacon")
                        onDone(false)
                    }
                    conn.cancel()
                }
            case .failed(let err):
                log("browser: connection FAILED: \(err)")
                onDone(false)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }
}

// MARK: - Entry

let args = Set(CommandLine.arguments.dropFirst())
let serviceName = "PlozzProbe-\(Int.random(in: 1000...9999))"

func runForever() { dispatchMain() }

if args.contains("--advertise") {
    let adv = Advertiser()
    try adv.start(serviceName: serviceName) { _ in }
    log("advertise-only mode; Ctrl-C to stop")
    runForever()
} else if args.contains("--browse") {
    let br = Browser()
    br.start(expectedName: nil, browseStart: Date()) { ok in
        log(ok ? "browse-only: SUCCESS" : "browse-only: FAILED/timeout")
        exit(ok ? 0 : 1)
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + discoveryTimeout) {
        log("browse-only: TIMEOUT after \(discoveryTimeout)s")
        exit(2)
    }
    runForever()
} else {
    // Self-test: advertise, then browse for the same service, exchange, report.
    log("SELF-TEST: local advertise + browse over loopback")
    let adv = Advertiser()
    let br = Browser()
    try adv.start(serviceName: serviceName) { _ in
        let browseStart = Date()
        br.start(expectedName: serviceName, browseStart: browseStart) { ok in
            log(ok ? "SELF-TEST RESULT: SUCCESS ✅" : "SELF-TEST RESULT: FAILED ❌")
            exit(ok ? 0 : 1)
        }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + discoveryTimeout) {
        log("SELF-TEST: TIMEOUT after \(discoveryTimeout)s ❌")
        exit(2)
    }
    runForever()
}
