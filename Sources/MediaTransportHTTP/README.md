# MediaTransportHTTP

**Status: HTTP/WebDAV adapter foundation — NOT wired into `AppShell` or the
shipping app graph.** Shared ownership, identity, resolver, and byte-source
contracts now live in `MediaTransportCore`; HTTP/WebDAV-specific errors,
security, and protocol primitives remain isolated in this target. Nothing in
this module is reachable from the running app yet.

## Adapter guarantees

- **Origin discipline**: exact scheme/host/port normalization
  (``TransportOrigin``) and a pure, unit-testable same-origin **redirect
  policy** (``RedirectPolicy``) that refuses cross-origin hops and
  HTTPS→HTTP downgrades and never forwards `Authorization` off-origin.
- **Credential preflight**: password and Bearer credentials are refused
  before any request executes unless the origin is HTTPS
  (``CredentialPreflight``); anonymous access is allowed over plain HTTP.
  Passwords go through an immutable ``PasswordAuthPolicy``
  (`.automatic` / `.digestOnly` / `.basicAllowed`) enforced from the
  `URLSession` challenge callback, with `URLCredential` persistence pinned to
  `.none`. Descriptions, session keys, and errors do not expose secret values
  (see `redacted*` helpers and ``TransportError``).
- **TLS trust**: system trust by default; an explicitly-accepted trust
  override pins the SHA-256 of the **exact leaf certificate DER** for one
  origin/trust revision (``TrustPolicy/pinnedLeaf(sha256:revision:)``) — not
  SPKI, and not "trust all". A mismatch fails closed
  (``TransportError/trustPinMismatch``).
- **Session isolation**: ``TransportSessionRegistry`` hands out one ephemeral
  `URLSession` per ``TransportSessionKey`` (account ID + credential revision +
  origin + trust revision + role). Changing *any* dimension yields a brand
  new session — no auth/cookie/keep-alive reuse leaks across accounts,
  re-auths, trust decisions, hosts, or scanner/playback roles. Every session
  disables the shared cookie jar, `URLCache`, and `URLCredentialStorage`, and
  exposes `invalidate`/`drainAll` lifecycle APIs.
- **WebDAV protocol surface**: `OPTIONS` capability probe and bounded
  `PROPFIND` (`Depth: 0`/`1` only — never `Infinity`) request construction
  (``PropfindRequestBuilder``), plus a namespace-tolerant, bounded,
  external-entity-free `XMLParser`-based multistatus parser
  (``PropfindXMLParser``) that normalizes absolute/relative/percent-encoded
  hrefs against a configured root, rejects path-traversal/root escapes, drops
  the collection's self-entry, and enforces explicit byte/entry limits
  (never silently truncating).
- **Range safety**: an identity-encoded, strong-ETag-gated ranged-read
  validator (``RangeProbe``) that requires an exact `206`, matching
  `Content-Range`/body length, and a matching strong `ETag` on every read,
  binds reads to the probe's final resource URL, and maps `412`/validator
  mismatches to `TransportError.sourceChanged`.

## What this does **not** prove

This is Foundation-only, offline, `URLProtocol`/loopback-style unit
coverage. It does **not** exercise a real WebDAV server, real TLS handshakes,
real Digest/NTLM negotiation quirks, cross-network interoperability, or any
on-device/Apple TV behavior. Treat every claim above as "the primitive is
implemented and unit-tested in isolation," not "WebDAV support works
end-to-end." Wiring this into a real `MediaProvider` (auth UI, discovery,
server compatibility matrix, physical-device verification) is future,
separate work.

## Why it's not linked anywhere

`Package.swift` declares `MediaTransportHTTP`/`MediaTransportHTTPTests` as an
ordinary target/test pair so `tools/run-tests.sh` exercises it like every
other module, but no product depends on it — `AppShell` does not list it,
and `project.yml`'s app target only links `AppShell` + `PlozzTopShelf`. It
stays invisible to the shipping app until a follow-up phase deliberately
adopts it.
