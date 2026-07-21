// swift-tools-version: 5.9
//
// ISOLATED FEASIBILITY PROBES — NOT part of the Plozz app.
//
// This is a standalone SwiftPM package that is deliberately NOT referenced by the
// app's root Package.swift or project.yml. It exists only to empirically verify
// platform behavior for the cross-device "Sync & Setup" experiment gate. Nothing
// here touches real account/credential stores or production onboarding. All
// payloads are FAKE, non-secret placeholders.
//
// Safe to delete wholesale.

import PackageDescription

let package = Package(
    name: "SyncFeasibilityProbes",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BonjourProbe"
        ),
        .executableTarget(
            name: "PairingCryptoProbe"
        )
    ]
)
