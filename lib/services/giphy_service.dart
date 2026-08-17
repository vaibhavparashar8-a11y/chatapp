// lib/services/giphy_service.dart

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import '../constants.dart';
import 'log_service.dart';

/// One GIF from a Giphy response.
class GiphyGif {
  final String id;

  /// Small looping preview for the picker grid — kept tiny on purpose, the
  /// grid shows a couple of dozen at once.
  final String previewUrl;

  /// Full-size GIF actually sent to the chat.
  final String url;

  const GiphyGif({required this.id, required this.previewUrl, required this.url});
}

/// Giphy search/trending for the GIF picker.
///
/// Needs an API key in Remote Config under `giphy_api_key` (create one free at
/// developers.giphy.com). Without it every call returns an empty list and
/// [isConfigured] is false, which the picker shows as a "not set up" message
/// rather than an error — the rest of the composer keeps working.
///
/// Note this is the one feature that sends anything the user types to a third
/// party: search terms go to Giphy. Trending needs no term.
class GiphyService {
  static const _base = 'https://api.giphy.com/v1/gifs';

  /// Keeps the grid light and the send quick.
  static const _limit = 24;

  /// Set in tests; [searchResults] is then returned without any network call.
  static bool testMode = false;

  @visibleForTesting
  static List<GiphyGif> searchResults = [];

  @visibleForTesting
  static Dio dio = Dio();

  static bool get isConfigured => giphyApiKey.trim().isNotEmpty;

  /// Trending GIFs, or the results for [query] when it is not blank.
  static Future<List<GiphyGif>> search(String query) async {
    if (testMode) return searchResults;
    if (!isConfigured) {
      LogService.w('Giphy', 'no giphy_api_key in Remote Config — GIF picker off');
      return const [];
    }
    final trimmed = query.trim();
    final endpoint = trimmed.isEmpty ? '$_base/trending' : '$_base/search';
    try {
      final res = await dio.get<Map<String, dynamic>>(
        endpoint,
        queryParameters: {
          'api_key': giphyApiKey.trim(),
          'limit': _limit,
          'rating': 'pg-13',
          if (trimmed.isNotEmpty) 'q': trimmed,
        },
      );
      return parseResponse(res.data);
    } catch (e) {
      LogService.e('Giphy', 'search("$trimmed") failed: $e');
      return const [];
    }
  }

  /// Pulls the two URLs the picker needs out of a Giphy payload.
  ///
  /// Pure and lenient: Giphy omits `images` variants unpredictably, and one
  /// malformed entry must not cost the whole grid.
  @visibleForTesting
  static List<GiphyGif> parseResponse(Map<String, dynamic>? body) {
    final data = body?['data'];
    if (data is! List) return const [];
    final gifs = <GiphyGif>[];
    for (final entry in data) {
      if (entry is! Map) continue;
      final images = entry['images'];
      if (images is! Map) continue;
      final preview = _urlIn(images, const [
        'fixed_width_small',
        'fixed_width',
        'preview_gif',
        'downsized',
        'original',
      ]);
      final full = _urlIn(images, const [
        'downsized',
        'fixed_width',
        'original',
      ]);
      if (preview == null || full == null) continue;
      gifs.add(GiphyGif(
        id: '${entry['id'] ?? 'gif${gifs.length}'}',
        previewUrl: preview,
        url: full,
      ));
    }
    return gifs;
  }

  /// First usable `url` among [keys], in preference order.
  static String? _urlIn(Map images, List<String> keys) {
    for (final key in keys) {
      final variant = images[key];
      if (variant is Map) {
        final url = variant['url'];
        if (url is String && url.isNotEmpty) return url;
      }
    }
    return null;
  }
}
