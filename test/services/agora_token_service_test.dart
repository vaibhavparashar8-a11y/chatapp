import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chatapp/constants.dart';
import 'package:chatapp/services/agora_token_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const tokenKey = 'agora_token_cache';
  const fetchedAtKey = 'agora_token_fetched_at';

  int fetchCalls = 0;
  String? fetchResult;

  setUp(() {
    fetchCalls = 0;
    fetchResult = 'fresh-token';
    agoraToken = '';
    AgoraTokenService.fetchOverride = () async {
      fetchCalls++;
      if (fetchResult == null) throw Exception('network down');
      return fetchResult;
    };
  });

  tearDown(() {
    AgoraTokenService.fetchOverride = null;
    agoraToken = '';
  });

  group('needsRefresh', () {
    test('true when never fetched', () {
      expect(AgoraTokenService.needsRefresh(null, DateTime.now()), isTrue);
    });

    test('false when fetched recently', () {
      final now = DateTime(2030, 1, 1, 12);
      final recent = now.subtract(const Duration(hours: 11));
      expect(AgoraTokenService.needsRefresh(recent, now), isFalse);
    });

    test('true when fetched 12h or more ago', () {
      final now = DateTime(2030, 1, 1, 12);
      final old = now.subtract(const Duration(hours: 12));
      expect(AgoraTokenService.needsRefresh(old, now), isTrue);
    });
  });

  group('init', () {
    test('fetches and caches when nothing is stored', () async {
      SharedPreferences.setMockInitialValues({});
      await AgoraTokenService.init();

      expect(fetchCalls, 1);
      expect(agoraToken, 'fresh-token');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(tokenKey), 'fresh-token');
      expect(prefs.getInt(fetchedAtKey), isNotNull);
    });

    test('uses cache without fetching when fresh (<12h)', () async {
      SharedPreferences.setMockInitialValues({
        tokenKey: 'cached-token',
        fetchedAtKey: DateTime.now()
            .subtract(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      });
      await AgoraTokenService.init();

      expect(fetchCalls, 0, reason: 'fresh cache must not hit the network');
      expect(agoraToken, 'cached-token');
    });

    test('refreshes a stale cache (>12h) and replaces the token', () async {
      SharedPreferences.setMockInitialValues({
        tokenKey: 'stale-token',
        fetchedAtKey: DateTime.now()
            .subtract(const Duration(hours: 13))
            .millisecondsSinceEpoch,
      });
      await AgoraTokenService.init();

      expect(fetchCalls, 1);
      expect(agoraToken, 'fresh-token');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(tokenKey), 'fresh-token');
    });

    test('keeps the stale cached token when the fetch fails', () async {
      fetchResult = null; // fetchOverride throws
      SharedPreferences.setMockInitialValues({
        tokenKey: 'stale-token',
        fetchedAtKey: DateTime.now()
            .subtract(const Duration(hours: 13))
            .millisecondsSinceEpoch,
      });
      await AgoraTokenService.init();

      expect(fetchCalls, 1);
      expect(agoraToken, 'stale-token',
          reason: 'a 13h-old token is still valid for 11 more hours');
    });

    test('empty fetch result does not clobber the cached token', () async {
      fetchResult = '';
      SharedPreferences.setMockInitialValues({
        tokenKey: 'stale-token',
        fetchedAtKey: DateTime.now()
            .subtract(const Duration(hours: 13))
            .millisecondsSinceEpoch,
      });
      await AgoraTokenService.init();

      expect(agoraToken, 'stale-token');
    });
  });
}
