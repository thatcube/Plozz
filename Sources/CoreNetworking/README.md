# CoreNetworking

The shared HTTP transport and logging primitives. Lives between `CoreModels`
and every provider/feature that talks to a remote server.

## Responsibility

- `HTTPClient` protocol + `URLSessionHTTPClient` default conformer:
  - serializes an `Endpoint` against a `baseURL`,
  - returns `(Data, HTTPURLResponse)` or throws `AppError`,
  - exposes a typed `decode(_:from:baseURL:)` convenience.
- `Endpoint`: a transport-agnostic request description (method, path, query,
  headers, body) — providers build these, not raw `URLRequest`s.
- `ServerURLNormalizer`: turns user-typed addresses (with/without scheme,
  trailing slash, port) into a well-formed `URL` for both Jellyfin and Plex.
- `PlozzLog` (and the `PlozzLogger` category facade): the **single** logging
  entry point. Backed by `OSLog` on Apple platforms, no-op on non-Apple
  hosts. Must never log tokens, Quick Connect secrets, or full
  `Authorization` headers.

## Invariants

- **Secret-safe by default.** `Authorization`, Quick Connect codes, Plex
  tokens, etc. must not reach `PlozzLog` — pass redacted strings or omit.
- **Provider-agnostic.** No Jellyfin/Plex specifics here. Provider modules
  layer their own headers/DTOs on top.
- **Throws `AppError`, not transport errors.** Non-2xx responses map onto
  `AppError` so feature code only ever speaks one error currency.
- **Platform-portable.** Compiles on Linux for `swift test` — Foundation
  only, no UIKit/SwiftUI.

## Where to look first

- `HTTPClient.swift` — the transport seam every provider depends on.
- `Endpoint.swift` — request shape & query/body helpers.
- `PlozzLog.swift` — how to log without leaking secrets.
- `ServerURLNormalizer.swift` — how user-typed server addresses are accepted.
