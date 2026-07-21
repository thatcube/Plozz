# Sync & Setup — findings, on-device procedures, threat model, go/no-go

Status: **experiment gate**. This records what has been verified so far and what
still needs real devices/iCloud/servers. No production sync or credential-transfer
code exists. Full product/UX reasoning lives in the session plan.

## 1. Measured results (headless, this machine)

| Probe | What it proves | Result |
| --- | --- | --- |
| `BonjourProbe` (loopback) | `NWListener` advertise + `NWBrowser` discover + `NWConnection` exchange of a non-secret beacon | ✅ discovered in ~0.9 s; discover+exchange ~3 s (incl. loopback TCP setup) |
| `PairingCryptoProbe` | HPKE seal→open to the target device key; wrong device can't open; pairing-context binding blocks replay | ✅ all checks pass; seal+open ~0.24 ms; ciphertext 70 B, encap 32 B |

## 1a. Measured results (ON REAL HARDWARE — Brando TV, this LAN)

| Test | What it proves | Result |
| --- | --- | --- |
| tvOS advertiser deployed to Brando TV (`OnDevice/PlozzPairProbeTV`) + Mac browses the real Wi-Fi | An Apple TV genuinely advertising `_plozz-pair._tcp` is discoverable by another device over the physical LAN | ✅ **Mac discovered `BrandoTV-PairProbe` in 0.009 s** |
| iPhone browser (`OnDevice/PlozzPairProbeiOS`) discovers the TV + exchanges + Local Network prompt | The full user-facing phone→TV pairing discovery | ⏸️ **not completed autonomously** — iPhone was locked (install needs unlock; the Local Network permission prompt needs a physical tap). App builds + signs; run `OnDevice/run-ondevice.sh` with the phone unlocked to finish. |

Notes: the Mac→TV *connect* after discovery did not complete in the autonomous run
(tvOS suspends the backgrounded probe app; the full exchange is designed for
iPhone↔TV with both apps foreground). Discovery — the core mechanism — is validated
on real hardware and is effectively instant on this LAN. On-device iOS builds sign
with the "Apple Development" identity via automatic provisioning + the ASC API key.


## 2. Platform evidence (from Apple docs + forums; see session plan for citations)

| Question | Answer | Impact |
| --- | --- | --- |
| iCloud Keychain sync to/from **tvOS**? | **No** — tvOS is excluded in both directions (`kSecAttrSynchronizable` is a no-op there) | TV can't auto-inherit or auto-export a login via iCloud; needs pairing |
| CloudKit `encryptedValues` (E2E) on tvOS? | **Cannot decrypt on tvOS** (keys rooted in iCloud Keychain circle) | Don't use Apple-E2E fields to reach the TV |
| CloudKit / CKSyncEngine on tvOS? | **Yes, 17+**, for plaintext non-secret records (private/shared DB) | Non-secret config + presence beacon can sync to TV |
| `NSUbiquitousKeyValueStore` on tvOS? | Available (tvOS relies on it for small prefs) | Candidate transport for the non-secret presence beacon — verify on device |
| Provider token binding | Plex `X-Plex-Client-Identifier`; Jellyfin `DeviceId`; Jellyfin has no refresh token | Each device should mint its own token; don't copy tokens |
| Native device linking | Jellyfin **Quick Connect**; Plex **plex.tv/link** | Passwordless per-device sign-in already exists → the safe v1 path |

## 3. On-device procedures (still TODO — need hardware/iCloud/servers)

**P1 — Bonjour iPhone↔Apple TV + Local Network prompt.** Add `NSBonjourServices`
(`_plozz-pair._tcp`) and `NSLocalNetworkUsageDescription` to a throwaway iOS + tvOS
build; run the advertiser on the TV, the browser on the phone; confirm the one-time
Local Network permission prompt, discovery on the same Wi-Fi, and behavior on
guest/AP-isolation networks. (Reuse `BonjourProbe` source.)

**P2 — CloudKit plaintext on tvOS 18.** Minimal throwaway app writing a plaintext
`CKRecord` to the **private** DB on iPhone (same Apple ID), then read it on a tvOS 18
device signed into the same Apple ID. Measure propagation latency; confirm no
`encryptedValues` are relied on.

**P3 — Presence beacon.** Same as P2 but the record is the non-secret beacon
`{ setupExists, deviceName, serverCount, schemaVersion }`, written **from the tvOS
device** and read on a fresh iOS device (and vice-versa). Also try
`NSUbiquitousKeyValueStore`. Verify it can drive a "bring your setup here" prompt.

**P4 — Providers.** Against a test Jellyfin + Plex: confirm a second device minting
its own token (Quick Connect / plex.tv/link) does **not** evict the first device's
session; confirm Jellyfin token is refused when presented with a different `DeviceId`.
No real credentials persisted or transferred.

## 4. Threat model (candidate credential-adjacent pairing flow)

Scope: a *future* phone↔TV pairing that transfers config and (only if later approved)
credentials. **v1 does NOT transfer raw credentials** (native provider linking +
manual shares); this model exists so the option is reviewable, not to greenlight it.

Assets: provider tokens, media-share passwords, non-secret config, the presence beacon.

Adversaries & mitigations:
- **Same-network attacker (café/dorm Wi-Fi).** Bonjour discovery is unauthenticated,
  so anyone can *find* the TV. → The QR/short code carries a high-entropy pairing key;
  the transfer is HPKE-sealed to the TV's ephemeral key and bound to the ceremony
  context (nonce, provider, expiry) — a bystander who didn't see the code can't
  decrypt or inject. (`PairingCryptoProbe` demonstrates device-targeting + binding.)
- **MITM / relay.** Bind to the target's ephemeral public key + a short authentication
  string compared out-of-band (or the QR carries the key). Single-use + short expiry.
- **Confused deputy (fake "approve this device" prompt).** Never auto-approve; the
  human confirms a code/QR that is bound to the actual target key. No silent approval
  via a cloud record.
- **Cloud-readable secret leak.** Never place a secret in an Apple/CloudKit-readable
  field; only device-targeted sealed blobs (our key) may transit CloudKit, and only
  under an approved protocol. Presence beacon is non-secret by construction.
- **Endpoint retargeting.** Synced descriptors are split from local authorization;
  remote data may never change a server endpoint for an already-authorized credential.
- **Replay / stale ceremony.** Nonce + expiry + single-use; context binding (verified).

Primitive selection: **CryptoKit HPKE, Curve25519 KEM + ChaChaPoly** (works iOS 17+/
tvOS 17+; Plozz targets 18). High-entropy key via QR; short codes would require a PAKE
and are not used to key encryption directly. **No custom protocol carries secrets
before an independent security review.**

## 5. Revised go/no-go (evidence-based, pending on-device probes)

- **GO (v1, safe):** non-secret config sync (CloudKit, same Apple ID) + **native
  provider linking** for sign-in (Quick Connect / Plex link) + **manual** media-share
  passwords + the non-secret **presence beacon** to offer "continue setup here".
  Bonjour discovery + one-tap/one-scan pairing for the *non-secret* handoff on TV.
- **DEFER (needs the on-device probes + independent review):** transferring provider
  tokens over the pairing channel (removes the one TV sign-in tap); any media-share
  password transfer. HPKE is a sound primitive candidate, but the full protocol must
  be reviewed before it carries secrets.
- **NO-GO:** secrets in Apple/CloudKit-readable form; iCloud Keychain to reach tvOS;
  silent enrollment approval; remote endpoint retargeting or remote Keychain deletion.

Open blockers before a production decision: P1–P4 above.
