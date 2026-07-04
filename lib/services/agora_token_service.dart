import 'package:cloud_functions/cloud_functions.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants.dart';
import 'log_service.dart';

/// Fetch-on-open caching of the Agora RTC token.
///
/// The getAgoraToken Cloud Function mints a 24h wildcard (uid 0) token.
/// This service runs at app startup: it immediately restores the cached
/// token into [agoraToken] (so calls work offline / when the fetch fails),
/// then refreshes from the function if the cache is older than 12 hours.
/// The Cloud Function cold start (~1-3s) happens here, invisibly — never
/// at call time.
class AgoraTokenService {
  static const _tokenKey = 'agora_token_cache';
  static const _fetchedAtKey = 'agora_token_fetched_at';

  /// Refresh threshold — half the 24h token TTL, so a token in active use
  /// is always at least 12h away from expiry.
  static const refreshAfter = Duration(hours: 12);

  /// Test seam — replaces the Cloud Function call in widget/unit tests.
  static Future<String?> Function()? fetchOverride;

  /// Call once on startup, after RemoteConfigService.init() (so the fetched
  /// token wins over any manually pasted Remote Config token) and after
  /// anonymous sign-in (the callable requires auth).
  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();

    // Restore cache first: even a stale-ish token (12-24h old) is valid,
    // and it keeps calls working if the network fetch below fails.
    final cached = prefs.getString(_tokenKey);
    if (cached != null && cached.isNotEmpty) {
      agoraToken = cached;
    }

    final fetchedAtMs = prefs.getInt(_fetchedAtKey);
    final fetchedAt = fetchedAtMs != null
        ? DateTime.fromMillisecondsSinceEpoch(fetchedAtMs)
        : null;
    if (!needsRefresh(fetchedAt, DateTime.now())) return;

    try {
      final fresh = await _fetch();
      if (fresh != null && fresh.isNotEmpty) {
        agoraToken = fresh;
        await prefs.setString(_tokenKey, fresh);
        await prefs.setInt(
            _fetchedAtKey, DateTime.now().millisecondsSinceEpoch);
        LogService.i('AgoraToken', 'Token refreshed');
      }
    } catch (e) {
      // Keep the cached/Remote Config token — calls may still work.
      LogService.w('AgoraToken', 'Token fetch failed: $e');
    }
  }

  /// True when there is no recorded fetch or it is older than [refreshAfter].
  static bool needsRefresh(DateTime? fetchedAt, DateTime now) =>
      fetchedAt == null || now.difference(fetchedAt) >= refreshAfter;

  static Future<String?> _fetch() async {
    if (fetchOverride != null) return fetchOverride!();
    final result = await FirebaseFunctions.instance
        .httpsCallable('getAgoraToken')
        .call<Map<dynamic, dynamic>>({
      'appId': agoraAppId,
      'channel': agoraChannel,
    });
    return result.data['token'] as String?;
  }
}
