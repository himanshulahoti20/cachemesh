# Changelog

## 1.0.2

Smarter Result integration — no breaking changes.

- **Failure-aware caching**: pass `cacheFailures: true` to `Cache` or to individual
  `get` / `refresh` calls to store failures in the cache (with TTL). The cached
  failure is returned on the next lookup instead of hitting the network. A
  successful re-fetch clears the stored failure automatically.
  `Cache.hasCachedFailure(key)` lets you check the state without fetching.
- **Retry hooks**: new `RetryOptions` type (`maxAttempts`, `retryWhen`, `delay`).
  Set a cache-wide default via `Cache(retryOptions: ...)` and override per call.
  `RetryOptions.noRetry` (single attempt) is the default, so existing code is
  unaffected. Built-in `retryWhen` predicate pattern makes it easy to skip
  retries on specific error types (e.g. auth errors).
- **Smarter SWR revalidation**: `staleWhileRevalidate` now only kicks off a
  background refresh when the cached entry is actually stale. Pass
  `alwaysRevalidate: true` to restore the pre-1.0.2 behaviour.
- **Cleaner failure propagation**: returned `Failure` and thrown exceptions both
  flow through the same retry loop and `CacheLogger.onError` call; the original
  error type and stack trace are preserved throughout.

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
