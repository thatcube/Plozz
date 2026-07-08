# Contributing to Plozz

Thanks for your interest in Plozz — a free, open-source Apple TV client for
Jellyfin, Plex, and local shares. It's a small, solo-maintained project, so this
guide stays lightweight.

## Reporting bugs & requesting features

Everything starts with an issue. [**Open one**](https://github.com/thatcube/Plozz/issues/new/choose)
and pick a template:

- **🐞 Bug report** — captures what makes a bug fixable: steps to reproduce,
  expected vs actual, which backend is affected (Jellyfin / Plex / SMB), and your
  Plozz, tvOS, and Apple TV versions.
- **✨ Feature request** — a short form for problems worth solving.

Please search [existing issues](https://github.com/thatcube/Plozz/issues) first,
and never paste tokens, passwords, or credentialed server URLs.

## Development pipeline

The habit here: when a **real** bug turns up — a genuine defect, not a flaky
test — file a bug-report issue first, then fix it and reference the issue in your
commit or PR (e.g. `Fixes #123`). That keeps a searchable trail of what broke and
why. Keep it lightweight, but do file the issue.

## Development setup

The technical setup lives in the [README](README.md) — no need to duplicate it here:

- **Building & running** — see [Building & running](README.md#building--running).
  Builds go through the repo's tools (`tools/generate-project.sh` to regenerate
  the Xcode project, `tools/deploy-tv.sh` to build/install on an Apple TV).
- **Tests** — run them with `tools/run-tests.sh [SchemeName]` on a tvOS
  Simulator (not `swift test` — the playback engine's frameworks are tvOS-only).

## The dual-provider invariant

Plozz treats **Jellyfin and Plex as co-equal, first-class backends**. Any
contribution that touches data, playback, auth, metadata, search, or navigation
must work for **both** — neither is a "phase 2" afterthought. Everything above
the provider layer talks to the `MediaProvider` protocol rather than a specific
backend; see [Architecture](README.md#architecture). If a change can only work
for one backend, call that out explicitly in the issue/PR.

## Coding norms

Keep changes focused and match the surrounding style. That's about it — open an
issue if you're unsure whether something's a good fit before investing a lot of
time.
