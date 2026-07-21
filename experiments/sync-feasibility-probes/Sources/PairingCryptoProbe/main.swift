// PairingCryptoProbe — isolated feasibility probe for the Plozz "Sync & Setup" gate.
//
// Purpose: validate the *candidate* pairing crypto primitive (CryptoKit HPKE) that
// a future, separately-reviewed credential-transfer protocol MIGHT use — WITHOUT
// implementing any production credential transfer. It demonstrates:
//   1. Sealing a payload to a target device's ephemeral public key (HPKE), so only
//      that device can open it — the property needed for phone->TV pairing that
//      works on tvOS (our key, not Apple's iCloud-Keychain-rooted key).
//   2. Binding the ciphertext to a pairing CONTEXT (nonce, provider, expiry, target
//      key) via HPKE `info` + authenticated associated data, so a captured blob
//      can't be replayed into a different ceremony (anti-confused-deputy / anti-MITM).
//   3. That tampering with the context makes decryption FAIL (binding is real).
//
// HPKE (RFC 9180) via CryptoKit is available on macOS 14+, iOS 17+, tvOS 17+ — so
// it compiles for every Plozz target. This is a THROWAWAY probe: the "credential"
// is a fake, non-secret placeholder string. No real tokens/passwords, no stores.
//
//   swift run PairingCryptoProbe

import Foundation
import CryptoKit

func line(_ s: String) { print(s) }

let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

// A pairing context that both sides derive from the QR/short-code + session.
// Binding the crypto to this prevents replay into a different pairing.
struct PairingContext: Codable {
    let ceremonyID: String      // random per ceremony (from the QR)
    let provider: String        // e.g. "jellyfin" (illustrative only)
    let expiresAtEpoch: Int      // short expiry
    let protocolVersion: Int
    func infoData() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

func makeContext() -> PairingContext {
    PairingContext(
        ceremonyID: UUID().uuidString,
        provider: "jellyfin",
        expiresAtEpoch: Int(Date().timeIntervalSince1970) + 120,
        protocolVersion: 1
    )
}

var allPassed = true
func check(_ name: String, _ condition: Bool) {
    line("  [\(condition ? "PASS" : "FAIL")] \(name)")
    if !condition { allPassed = false }
}

line("PairingCryptoProbe — HPKE pairing-primitive validation (fake payload only)\n")

// The "TV" (recipient) creates an ephemeral key pair; its public key is conveyed
// to the phone during pairing (e.g. embedded in / bound to the QR).
let tvPrivate = Curve25519.KeyAgreement.PrivateKey()
let tvPublic = tvPrivate.publicKey

// A deliberately NON-SECRET placeholder standing in for a future envelope.
let fakePayload = Data(#"{"placeholder":"NOT-A-REAL-CREDENTIAL","kind":"probe"}"#.utf8)

// --- 1. Happy path: seal to TV pubkey with a bound context, TV opens it. ---
do {
    let ctx = makeContext()
    let info = ctx.infoData()
    let aad = Data("plozz-pairing-v1".utf8)

    var sender = try HPKE.Sender(recipientKey: tvPublic, ciphersuite: suite, info: info)
    let start = Date()
    let ciphertext = try sender.seal(fakePayload, authenticating: aad)
    let encapsulated = sender.encapsulatedKey

    var recipient = try HPKE.Recipient(privateKey: tvPrivate, ciphersuite: suite, info: info, encapsulatedKey: encapsulated)
    let opened = try recipient.open(ciphertext, authenticating: aad)
    let elapsedMs = Date().timeIntervalSince(start) * 1000

    check("seal+open round-trips to the target device key", opened == fakePayload)
    line(String(format: "        (seal+open took %.2f ms; ciphertext %d bytes, encap %d bytes)",
                elapsedMs, ciphertext.count, encapsulated.count))
}

// --- 2. Wrong recipient: a DIFFERENT device cannot open it. ---
do {
    let ctx = makeContext()
    let info = ctx.infoData()
    let aad = Data("plozz-pairing-v1".utf8)
    var sender = try HPKE.Sender(recipientKey: tvPublic, ciphersuite: suite, info: info)
    let ciphertext = try sender.seal(fakePayload, authenticating: aad)
    let encapsulated = sender.encapsulatedKey

    let attackerPrivate = Curve25519.KeyAgreement.PrivateKey()
    var openedByAttacker: Data? = nil
    do {
        var recipient = try HPKE.Recipient(privateKey: attackerPrivate, ciphersuite: suite, info: info, encapsulatedKey: encapsulated)
        openedByAttacker = try recipient.open(ciphertext, authenticating: aad)
    } catch {
        openedByAttacker = nil
    }
    check("a different device CANNOT open the sealed blob", openedByAttacker == nil)
}

// --- 3. Context binding: tampering the pairing context makes decryption FAIL. ---
do {
    let ctx = makeContext()
    let info = ctx.infoData()
    let aad = Data("plozz-pairing-v1".utf8)
    var sender = try HPKE.Sender(recipientKey: tvPublic, ciphersuite: suite, info: info)
    let ciphertext = try sender.seal(fakePayload, authenticating: aad)
    let encapsulated = sender.encapsulatedKey

    // Recipient uses a DIFFERENT ceremony context (replay into another pairing).
    let tamperedInfo = makeContext().infoData()
    var openedWithTamperedContext: Data? = nil
    do {
        var recipient = try HPKE.Recipient(privateKey: tvPrivate, ciphersuite: suite, info: tamperedInfo, encapsulatedKey: encapsulated)
        openedWithTamperedContext = try recipient.open(ciphertext, authenticating: aad)
    } catch {
        openedWithTamperedContext = nil
    }
    check("replay into a DIFFERENT pairing context FAILS (binding works)", openedWithTamperedContext == nil)
}

line("\nRESULT: \(allPassed ? "ALL CHECKS PASSED ✅" : "SOME CHECKS FAILED ❌")")
exit(allPassed ? 0 : 1)
