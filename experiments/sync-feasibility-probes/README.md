# Sync & Setup — feasibility probes (ISOLATED, throwaway)

These probes support the cross-device **"Sync & Setup"** experiment gate for Plozz
(iOS/iPadOS/tvOS). They are a **standalone SwiftPM package**, deliberately **not**
referenced by the app's root `Package.swift` or `project.yml`. Nothing here touches
real account/credential stores or production onboarding. **All payloads are fake,
non-secret placeholders.** Safe to delete wholesale.

See `FINDINGS.md` for measured results, the platform-evidence table, on-device
procedures for the probes that need real devices/iCloud/servers, and the threat
model + revised go/no-go.

## Run the headless probes (macOS)

```bash
cd experiments/sync-feasibility-probes
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"   # Plozz sandbox git fix
swift run BonjourProbe          # LAN discovery + non-secret exchange self-test
swift run PairingCryptoProbe    # HPKE pairing-primitive validation
```

### BonjourProbe
Advertises `_plozz-pair._tcp` via `NWListener`, discovers it via `NWBrowser`, opens
an `NWConnection`, and exchanges a **fake** presence beacon. Proves the discovery +
pairing-transport wiring the TV↔phone pairing UX depends on, and measures latency.
The same Network.framework API compiles unchanged for iOS/tvOS.

- `swift run BonjourProbe` — self-test (advertise + browse in one process, loopback)
- `swift run BonjourProbe --advertise` — advertise only (the "TV" side)
- `swift run BonjourProbe --browse` — browse only (the "phone" side)

### PairingCryptoProbe
Validates the **candidate** pairing crypto primitive (CryptoKit **HPKE**, RFC 9180)
that a future, separately-reviewed credential-transfer protocol *might* use — with
**no** production credential transfer. Demonstrates: seal-to-target-device-key,
wrong-device-cannot-open, and pairing-context binding that defeats replay.

## On-device probes (need real hardware / iCloud / servers)
Documented step-by-step in `FINDINGS.md`:
- Bonjour discovery iPhone↔Apple TV incl. the **Local Network** permission prompt
  (requires `NSBonjourServices` + `NSLocalNetworkUsageDescription` in the app targets).
- Plaintext CloudKit private-record sync on **tvOS 18** + same Apple ID.
- Non-secret **presence-beacon** propagation (CloudKit / `NSUbiquitousKeyValueStore`),
  including a **tvOS write → iOS read**.
- Provider capability checks (Jellyfin device token / Quick Connect; Plex second-device
  token / link).
