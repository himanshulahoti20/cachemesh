# Changelog

## 1.0.1

Stability & observability — no breaking changes.

- **Cache logger**: pluggable `CacheLogger` (hits, misses, writes, refreshes,
  invalidations, clears, errors) with `RefreshSource` for filtering. Includes
  `PrintCacheLogger` for quick wiring.
- **Cache state insights**: new `Cache.inspect<T>(key)` returns a `CacheState<T>`
  snapshot — `isPresent`, `isFresh`, `isStale`, `age`, `timeToExpiry`, `expiresAt`.
- **Safer expiry**: SWR no longer kicks off a redundant background refresh
  while one is already in flight. Tightens single-flight semantics.
- **Better error propagation**: fetcher failures (returned `Failure` *or*
  thrown exceptions) are routed through `CacheLogger.onError` with their
  original stack trace.

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
