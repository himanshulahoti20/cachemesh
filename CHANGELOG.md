# Changelog

## 1.0.0

Initial release.

- `Result<T>` sealed type (`Success<T>` / `Failure<T>`) with `fold` and `map`.
- `Cache` with five policies: `cacheFirst`, `networkFirst`,
  `staleWhileRevalidate`, `networkOnly`, `cacheOnly`.
- In-memory `MemoryCacheStore` with per-entry TTL.
- Single-flight deduplication of concurrent fetches per key.
- Reactive `watch(key)` broadcast streams.
- Manual control: `refresh`, `prefetch`, `invalidate`, `clear`, `peek`.
- Pluggable `CacheStore` interface (disk adapters land in 1.2.0).
