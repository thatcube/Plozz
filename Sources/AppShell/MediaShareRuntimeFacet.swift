import Foundation
import Observation
import AppRuntime
import CoreModels
import CoreNetworking
import FeatureHome
import MediaTransportCore
import ProviderShare

/// The media-share **runtime** facet, extracted from `AppState`.
///
/// Owns the one atomic media-share runtime generation — the catalog/transport
/// coordinator, its network-file resolver, the account-lifecycle service, and the
/// app-wide scan/enrich status — plus the "which shares are active" preferred-key
/// propagation and the Settings "Scan now" entry point.
///
/// This is the surface the Metadata team builds their future local-artwork
/// sidecars (Step 4) against, so its public interface is intentionally small and
/// stable: observe the active share accounts, resolve the shared runtime/resolver,
/// read live scan status, and trigger a rescan. There is deliberately **no**
/// device-wide cache-policy state today — see the documented Step-4 seam in
/// ``setActiveShareAccounts(_:accounts:)``.
///
/// It depends INTO the `AccountsProvidersModel` hub via that hub's typed interface
/// (accounts, registry, provider-resolution context, token seam) for the rescan
/// path, and never reaches back into `AppState`. Kept `@MainActor @Observable` so
/// `activeShareAccounts` / `scanStatus` observation is identical to before.
@MainActor
@Observable
public final class MediaShareRuntimeFacet {
    /// The account keys of the media shares currently in the active set — the
    /// preferred-account keys last propagated to the runtime. Observable so
    /// artwork / media-share surfaces can react to which shares are active without
    /// touching the whole `AppState`.
    public private(set) var activeShareAccounts: Set<String> = []

    /// Live status of media-share background scans/enrichment, so Home can show an
    /// "Updating library…" banner and Settings can show last-scanned / Scan now.
    /// App-wide (a share and its scan are household-global, not per-profile).
    public let scanStatus: ShareScanStatusModel

    /// The shared media-share runtime/coordinator (catalog + transport composition
    /// + network-file resolver). The single owner of that generation.
    @ObservationIgnored
    public let runtime: any MediaShareRuntime

    /// Media-share account lifecycle policy (retire / invalidate), routed through
    /// the same runtime generation. Used by the account-removal flows on `AppState`.
    /// Internal (not part of the Metadata Step-4 public contract).
    @ObservationIgnored
    let accountService: MediaShareAccountService

    /// The accounts + providers hub (typed). Read for the rescan path (accounts,
    /// registry, provider-resolution context, and the effective token seam).
    @ObservationIgnored
    private let accountsProviders: AccountsProvidersModel
    @ObservationIgnored
    private let rescanService: MediaShareRescanService

    /// Monotonic revision for preferred-account-key updates so a stale, out-of-
    /// order propagation can't overwrite a newer active set on the runtime.
    @ObservationIgnored
    private var sharePriorityRevision: UInt64 = 0

    /// The network-file resolver used for direct-file share playback. Forwards to
    /// the runtime so there is a single owner of the resolver instance.
    public var networkFileResolver: any MediaTransportNetworkFileResolving {
        runtime.networkFileResolver
    }

    public init(
        runtime: any MediaShareRuntime,
        accountsProviders: AccountsProvidersModel,
        scanStatus: ShareScanStatusModel? = nil
    ) {
        self.runtime = runtime
        self.accountsProviders = accountsProviders
        self.rescanService = MediaShareRescanService(
            accountsProviders: accountsProviders
        )
        let resolvedScanStatus = scanStatus ?? ShareScanStatusModel()
        self.scanStatus = resolvedScanStatus
        self.accountService = MediaShareAccountService(runtime: runtime)
        // Wire the scan/enrich progress reporter into the runtime's catalog
        // coordinator, so the first share query (from Home) reports into
        // `scanStatus` and the "Updating library…" banner + Settings last-scanned
        // line light up. The reporter is a Sendable value; capture it before the Task.
        let reporter = resolvedScanStatus.reporter()
        Task { [runtime] in await runtime.configure(reporter: reporter) }
    }

    /// Recomputes the active media-share account set from the resolved active
    /// accounts and pushes it to the runtime as its preferred-account keys.
    /// Called by `AppState` after the accounts hub recomputes the active set.
    public func setActiveShareAccounts(_ resolved: Set<String>, accounts: [Account]) {
        sharePriorityRevision &+= 1
        let priorityRevision = sharePriorityRevision
        let preferredShareIDs = Set(
            accounts
                .filter {
                    resolved.contains($0.id)
                        && $0.server.provider == .mediaShare
                }
                .map(\.id)
        )
        activeShareAccounts = preferredShareIDs
        // Step 4 (Metadata): device-wide media-share cache policy hook goes here —
        // the active-share set is exactly the input a cache-eviction/retention
        // policy would key off. Intentionally NOT implemented in this facet; its
        // design is the Metadata team's Step-4 scope, co-designed with them. Do not
        // fabricate cache-policy state here.
        Task { [runtime] in
            await runtime.setPreferredAccountKeys(
                preferredShareIDs,
                revision: priorityRevision
            )
        }
    }

    /// Force a fresh scan + enrichment of a media share now (Settings "Scan now").
    /// Builds the share's provider directly from its account (tolerating an empty
    /// token for a guest share, which `provider(forAccountID:)` would reject) and
    /// asks it to rescan — registering its catalog/scanner if needed, so this works
    /// even when Home never queried the share, and it drives the scan indicator.
    public func rescanShare(accountID: String) {
        rescanService.rescan(accountID: accountID)
    }
}
