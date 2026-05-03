import 'dart:async';

import 'cache_entry.dart';
import 'cache_exception.dart';
import 'cache_logger.dart';
import 'cache_policy.dart';
import 'cache_state.dart';
import 'cache_store.dart';
import 'memory_cache_store.dart';
import 'result.dart';

/// A function that produces a fresh value asynchronously.
///
/// Fetchers should return a [Result] rather than throwing — but raised
/// exceptions are caught and converted to a [Failure] regardless.
typedef Fetcher<T> = Future<Result<T>> Function();

/// The unified cache + data orchestration entry point.
///
/// One [Cache] manages a keyed [CacheStore], coordinates concurrent fetches
/// (single-flight), and broadcasts updates to [watch] subscribers.
class Cache {
  Cache({
    CacheStore? store,
    Duration? defaultTtl,
    DateTime Function()? clock,
    CacheLogger? logger,
  })  : _store = store ?? MemoryCacheStore(),
        _defaultTtl = defaultTtl,
        _now = clock ?? DateTime.now,
        _logger = logger ?? const CacheLogger();

  final CacheStore _store;
  final Duration? _defaultTtl;
  final DateTime Function() _now;
  final CacheLogger _logger;

  final Map<String, Future<Result<dynamic>>> _inflight = {};
  final Map<String, StreamController<Result<dynamic>>> _watchers = {};

  /// Reads from / writes to the cache for [key] according to [policy].
  ///
  /// [fetch] is the source of truth used when the policy needs fresh data.
  /// [ttl] overrides the cache-wide [Cache.new]'s `defaultTtl` for this entry;
  /// passing `null` falls back to that default (and `null` there means no
  /// expiration).
  Future<Result<T>> get<T>({
    required String key,
    required Fetcher<T> fetch,
    CachePolicy policy = CachePolicy.cacheFirst,
    Duration? ttl,
  }) async {
    final effectiveTtl = ttl ?? _defaultTtl;
    final now = _now();

    switch (policy) {
      case CachePolicy.cacheOnly:
        final entry = _store.read(key);
        if (entry == null) {
          _logger.onMiss(key);
          return Failure<T>(CacheMissException(key));
        }
        if (entry.isExpiredAt(now)) {
          _logger.onMiss(key);
          return Failure<T>(CacheExpiredException(key));
        }
        _logger.onHit(key);
        return Success<T>(entry.value as T);

      case CachePolicy.networkOnly:
        return _runFetch<T>(
          key,
          fetch,
          persist: false,
          ttl: effectiveTtl,
          source: RefreshSource.policy,
        );

      case CachePolicy.cacheFirst:
        final entry = _store.read(key);
        if (entry != null && !entry.isExpiredAt(now)) {
          _logger.onHit(key);
          return Success<T>(entry.value as T);
        }
        _logger.onMiss(key);
        return _runFetch<T>(
          key,
          fetch,
          persist: true,
          ttl: effectiveTtl,
          source: RefreshSource.cacheMiss,
        );

      case CachePolicy.networkFirst:
        final fresh = await _runFetch<T>(
          key,
          fetch,
          persist: true,
          ttl: effectiveTtl,
          source: RefreshSource.policy,
        );
        if (fresh.isSuccess) return fresh;
        final entry = _store.read(key);
        if (entry != null) {
          _logger.onHit(key);
          return Success<T>(entry.value as T);
        }
        return fresh;

      case CachePolicy.staleWhileRevalidate:
        final entry = _store.read(key);
        if (entry != null) {
          _logger.onHit(key);
          // Only kick off a background refresh if one isn't already in flight.
          // Single-flight would dedup it anyway, but skipping the call avoids
          // an unnecessary microtask round-trip and keeps logs clean.
          if (!_inflight.containsKey(key)) {
            unawaited(
              _runFetch<T>(
                key,
                fetch,
                persist: true,
                ttl: effectiveTtl,
                source: RefreshSource.background,
              ),
            );
          }
          return Success<T>(entry.value as T);
        }
        _logger.onMiss(key);
        return _runFetch<T>(
          key,
          fetch,
          persist: true,
          ttl: effectiveTtl,
          source: RefreshSource.cacheMiss,
        );
    }
  }

  /// Forces a fetch, writes to the cache, and notifies watchers.
  Future<Result<T>> refresh<T>({
    required String key,
    required Fetcher<T> fetch,
    Duration? ttl,
  }) =>
      _runFetch<T>(
        key,
        fetch,
        persist: true,
        ttl: ttl ?? _defaultTtl,
        source: RefreshSource.refresh,
      );

  /// Like [refresh] but framed as a warmup: fetches and caches eagerly so a
  /// subsequent [get] is an instant cache hit.
  Future<Result<T>> prefetch<T>({
    required String key,
    required Fetcher<T> fetch,
    Duration? ttl,
  }) =>
      _runFetch<T>(
        key,
        fetch,
        persist: true,
        ttl: ttl ?? _defaultTtl,
        source: RefreshSource.prefetch,
      );

  /// Drops the entry for [key]. Watchers remain subscribed but do not receive
  /// an emission for the removal.
  void invalidate(String key) {
    _store.delete(key);
    _logger.onInvalidate(key);
  }

  /// Drops every entry from the underlying store.
  void clear() {
    _store.clear();
    _logger.onClear();
  }

  /// Subscribes to updates for [key].
  ///
  /// The returned stream is broadcast: emissions happen whenever the cache is
  /// updated for [key] (via [get], [refresh], [prefetch], or a background
  /// refresh from [CachePolicy.staleWhileRevalidate]). Subscribers do not
  /// receive the current cached value on subscription — call [get] (or
  /// [peek]) for that.
  Stream<Result<T>> watch<T>(String key) {
    final controller = _watchers.putIfAbsent(
      key,
      () => StreamController<Result<dynamic>>.broadcast(),
    );
    return controller.stream.map(_castResult<T>);
  }

  /// Synchronous, non-fetching read of the cache.
  ///
  /// Returns `null` if [key] is absent or (when [allowExpired] is `false`)
  /// expired. Use this to seed UI state from cache without triggering a fetch.
  T? peek<T>(String key, {bool allowExpired = false}) {
    final entry = _store.read(key);
    if (entry == null) return null;
    if (!allowExpired && entry.isExpiredAt(_now())) return null;
    return entry.value as T;
  }

  /// Returns a [CacheState] snapshot describing what the cache currently
  /// holds for [key]. Never triggers a fetch. New in v1.0.1.
  CacheState<T> inspect<T>(String key) {
    final entry = _store.read(key);
    final now = _now();
    if (entry == null) {
      return CacheState<T>(key: key, now: now);
    }
    return CacheState<T>(
      key: key,
      now: now,
      value: entry.value as T,
      createdAt: entry.createdAt,
      ttl: entry.ttl,
    );
  }

  /// Closes any open watcher streams. Safe to call multiple times.
  Future<void> dispose() async {
    final controllers = List.of(_watchers.values);
    _watchers.clear();
    for (final c in controllers) {
      await c.close();
    }
  }

  Future<Result<T>> _runFetch<T>(
    String key,
    Fetcher<T> fetch, {
    required bool persist,
    required Duration? ttl,
    required RefreshSource source,
  }) async {
    final existing = _inflight[key];
    if (existing != null) {
      final shared = await existing;
      return _castResult<T>(shared);
    }

    _logger.onRefresh(key, source);
    final future = _fetchAndStore<T>(key, fetch, persist: persist, ttl: ttl);
    _inflight[key] = future;
    try {
      return await future;
    } finally {
      // Only clear if the entry still points at our future — a re-entrant
      // fetch may have replaced it.
      if (identical(_inflight[key], future)) {
        _inflight.remove(key);
      }
    }
  }

  Future<Result<T>> _fetchAndStore<T>(
    String key,
    Fetcher<T> fetch, {
    required bool persist,
    required Duration? ttl,
  }) async {
    Result<T> result;
    try {
      result = await fetch();
    } catch (e, st) {
      result = Failure<T>(e, st);
    }

    if (result is Failure<T>) {
      _logger.onError(key, result.error, result.stackTrace);
      return result;
    }

    if (persist && result is Success<T>) {
      _store.write(
        key,
        CacheEntry<T>(value: result.value, createdAt: _now(), ttl: ttl),
      );
      _logger.onWrite(key, ttl: ttl);
      _emit<T>(key, result);
    }
    return result;
  }

  void _emit<T>(String key, Result<T> result) {
    final controller = _watchers[key];
    if (controller != null && !controller.isClosed) {
      controller.add(result);
    }
  }

  static Result<T> _castResult<T>(Result<dynamic> r) => switch (r) {
        Success() => Success<T>(r.value as T),
        Failure(:final error, :final stackTrace) =>
          Failure<T>(error, stackTrace),
      };
}
