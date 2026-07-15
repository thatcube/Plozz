# SearchIndexKit

Provider-independent, fully local natural-language search foundations.

## Responsibilities

- Build searchable documents from `MediaItem` metadata.
- Generate sentence embeddings through Apple's on-device `NLEmbedding`.
- Normalize, encode, persist, and rank vectors without an external service.
- Parse deterministic constraints such as media kind, series, episode, year,
  genre, and runtime.
- Persist a rebuildable SQLite index under the active profile's cache namespace.
- Consume any `SearchCatalogProviding` source through a resumable, resource-
  admitted page loop with serial 20-document embedding slices.

## Invariants

- Queries and media metadata never leave the device.
- Literal provider search remains available when this module is unavailable.
- Vectors from different languages or model revisions are never compared.
- Provider construction, catalog crawling, and UI integration live outside this
  module.

## Phase 2 provider ingestion

- Jellyfin exposes rich, recursive pages separately for movies, series, and
  episodes.
- Plex exposes section-scoped type 1/2/4 pages for movies, series, and episodes.
- `ShareSearchCatalogAdapter` reads only an existing committed
  `ShareCatalogStore`, covering SMB, WebDAV, NFS, SFTP, and FTP/FTPS without
  rescanning files or acquiring transport leases.
- Failed or cancelled page loops retain their cursor and never prune old rows.
  Only a complete library/kind generation performs mark-and-sweep deletion.

## Phase 2.5 hardening

- SQLite failures are typed. Only proven corruption/not-a-database errors rebuild
  the cache; transient locks and future schema versions preserve it.
- A stepped migration ladder preserves documents/vectors across schema changes.
- Full scans reconcile unique current-generation rows against stable provider
  totals before pruning. Empty partitions require two completed scans.
- Unsupported provider partitions close without completing or pruning.
- Warmed vectors represent the last completed generation while page writes run;
  the cache invalidates once that generation commits.
- Embedding freshness is checked once per 20-document slice rather than once per
  item, and single-kind searches load only that kind's vectors.
- Production semantic/lexical scoring is centralized in `HybridRankingPolicy`.
- Synthetic corpus and device-memory tooling live in
  `SearchIndexBenchmarkSupport`, not the shipping search module.

Post-hardening Brando TV measurements:

- Float16 SQLite build: ~3.2s / 17.5s / 34.6s at 10k / 50k / 100k.
- Warm-up: ~0.56s / 3.03s / 6.05s for the all-kind plus episode-only caches.
- Unfiltered query: ~36ms / 83ms / 129ms.
- Episode-kind filtered query: ~32ms / 60ms / 96ms.
- Quality remains 80% top-1 and 100% top-5 across Float32, Float16, and Int8.

## Phase 0 findings

Measured on the tvOS 27 Simulator and Brando TV (Apple TV 4K, 3rd generation)
while targeting tvOS 18:

- English sentence embeddings are available as revision 1 with 512 dimensions.
- The other probed sentence languages returned no model, so semantic search must
  remain language-model scoped and literal search is the fallback.
- The committed synthetic episode corpus reached 80% top-1 and 100% top-5 with
  the hybrid semantic/lexical scorer.
- Float32, Float16, and Int8 preserved identical winners on that corpus. Float16
  is the conservative default because it halves persisted vector bytes without
  the wider validation required before selecting Int8.
- On physical hardware, `NLEmbedding` generated about 184 documents/second.
- Warm in-memory Accelerate ranking took approximately 16/78/140 ms for
  10k/50k/100k vectors.
- Float32 candidate memory increased by approximately 34/135/169 MB at those
  sizes. The 50k target stays under the 150 MB gate; 100k behavior is measured
  rather than silently capped.
- The Float16 SQLite index built 10k/50k/100k documents in approximately
  3.1/15.4/32.4 seconds, warmed vectors once in 0.35/1.77/3.75 seconds, and then
  answered in 36/92/175 ms. Database sizes were about 21/107/215 MB.

Brando TV is the only physical Apple TV currently paired with this development
machine. Older tvOS 18 hardware remains a release-validation target, not an
unmeasured assumption.
