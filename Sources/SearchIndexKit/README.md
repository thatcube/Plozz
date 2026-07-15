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
  episodes, including provider metadata timestamps.
- Plex exposes section-scoped type 1/2/4 pages for movies, series, and episodes.
- `ShareSearchCatalogAdapter` reads only an existing committed
  `ShareCatalogStore`, covering SMB, WebDAV, NFS, SFTP, and FTP/FTPS without
  rescanning files or acquiring transport leases.
- Failed or cancelled page loops retain their cursor and never prune old rows.
  Only a complete library/kind generation performs mark-and-sweep deletion.

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
