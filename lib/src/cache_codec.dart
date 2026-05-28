/// Converts a cached value of type [T] to and from a JSON-encodable form.
///
/// A persistent cache can't serialize arbitrary objects on its own — register
/// a [CacheCodec] per key-prefix via `Cache.registerCodec` so the cache knows
/// how to write entries to disk and rebuild them on hydration.
///
/// [encode] must return something `jsonEncode` accepts (a `Map`, `List`,
/// `String`, `num`, `bool`, or `null`). [decode] receives exactly what
/// `jsonDecode` produced.
///
/// ```dart
/// final userCodec = CacheCodec<User>(
///   encode: (u) => u.toJson(),
///   decode: (json) => User.fromJson(json as Map<String, dynamic>),
/// );
/// cache.registerCodec<User>('user:', userCodec);
/// ```
///
/// New in v1.2.0.
class CacheCodec<T> {
  const CacheCodec({required this.encode, required this.decode});

  /// `T` → JSON-encodable value.
  final Object? Function(T value) encode;

  /// JSON value → `T`.
  final T Function(Object? json) decode;

  /// Encodes a value held as `dynamic` (used internally where the static type
  /// has been erased). Throws if [value] is not a [T].
  Object? encodeDynamic(Object? value) => encode(value as T);
}
