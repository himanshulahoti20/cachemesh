/// Lifecycle scope of a cached entry.
///
/// Scopes are how `cachemesh` reasons about *when* an entry should disappear
/// without anyone asking. Combine with [Cache.setActiveUser] and
/// [Cache.endSession] (new in v1.1.0) to wire session/user lifecycle into
/// the cache cleanly.
enum CacheScope {
  /// Survives logout and user switches. Use for app-wide, non-personal data
  /// (feature flags, config, public catalog). This is the default.
  global,

  /// Cleared when the session ends (typically logout). Survives transient
  /// background/foreground transitions but not authentication boundaries.
  session,

  /// Tied to the currently active user. Cleared automatically when the
  /// active user changes (e.g. logout → login as another user) so personal
  /// data never bleeds across accounts.
  ///
  /// Requires the cache to have an active user set via
  /// [Cache.setActiveUser] before storing or reading user-scoped entries.
  user,
}
