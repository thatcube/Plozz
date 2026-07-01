#if canImport(Sentry)
import Foundation
import Sentry

/// Scrubs outgoing Sentry events and breadcrumbs so nothing that could identify
/// a user or reveal what they were watching leaves the device. Runs in Sentry's
/// `beforeSend`/`beforeBreadcrumb` hooks — the last gate before upload.
enum CrashRedaction {
    /// Drop PII-bearing containers from an event and scrub its breadcrumbs.
    static func scrub(_ event: Event) -> Event? {
        // Identity / network provenance we never want.
        event.user = nil
        event.request = nil
        event.serverName = nil
        // Free-form context/extra can accumulate titles, ids, URLs from any SDK
        // integration — drop wholesale. Our own coarse facts live in `tags`.
        event.context = nil
        event.extra = nil

        if let crumbs = event.breadcrumbs {
            event.breadcrumbs = crumbs.compactMap { scrub($0) }
        }
        return event
    }

    /// Drop network breadcrumbs entirely (URLs/hosts) and strip sensitive keys
    /// from anything else.
    static func scrub(_ crumb: Breadcrumb) -> Breadcrumb? {
        if crumb.type == "http" || crumb.category == "http" || crumb.category == "network" {
            return nil
        }
        if let data = crumb.data {
            var cleaned = data
            for key in ["url", "http.url", "server", "host", "hostname", "path", "query", "ip", "address"] {
                cleaned.removeValue(forKey: key)
            }
            crumb.data = cleaned.isEmpty ? nil : cleaned
        }
        return crumb
    }
}
#endif
