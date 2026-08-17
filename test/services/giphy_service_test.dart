import 'package:chatapp/constants.dart';
import 'package:chatapp/services/giphy_service.dart';
import 'package:chatapp/services/log_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() => LogService.testMode = true);
  tearDownAll(() => LogService.testMode = false);
  tearDown(() => giphyApiKey = '');

  group('isConfigured', () {
    // The GIF tab degrades to a "not set up" note rather than an error, so this
    // flag is what the whole feature hangs off.
    test('false without a key, and for a blank one', () {
      giphyApiKey = '';
      expect(GiphyService.isConfigured, isFalse);
      giphyApiKey = '   ';
      expect(GiphyService.isConfigured, isFalse);
    });

    test('true once Remote Config supplies a key', () {
      giphyApiKey = 'abc123';
      expect(GiphyService.isConfigured, isTrue);
    });
  });

  group('search', () {
    test('returns nothing and makes no request when unconfigured', () async {
      giphyApiKey = '';
      expect(await GiphyService.search('cats'), isEmpty);
    });
  });

  group('parseResponse', () {
    Map<String, dynamic> gifEntry(Map<String, dynamic> images) =>
        {'id': 'g1', 'images': images};

    test('prefers the small preview for the grid and a downsized send URL', () {
      final gifs = GiphyService.parseResponse({
        'data': [
          gifEntry({
            'fixed_width_small': {'url': 'https://g/small.gif'},
            'fixed_width': {'url': 'https://g/medium.gif'},
            'downsized': {'url': 'https://g/downsized.gif'},
            'original': {'url': 'https://g/original.gif'},
          }),
        ],
      });

      expect(gifs, hasLength(1));
      expect(gifs.single.id, 'g1');
      expect(gifs.single.previewUrl, 'https://g/small.gif');
      expect(gifs.single.url, 'https://g/downsized.gif');
    });

    test('falls back through the variant list when sizes are missing', () {
      final gifs = GiphyService.parseResponse({
        'data': [
          gifEntry({
            'original': {'url': 'https://g/original.gif'},
          }),
        ],
      });

      expect(gifs.single.previewUrl, 'https://g/original.gif');
      expect(gifs.single.url, 'https://g/original.gif');
    });

    // Giphy omits variants unpredictably; one bad entry must not cost the grid.
    test('skips entries with no usable url but keeps the rest', () {
      final gifs = GiphyService.parseResponse({
        'data': [
          gifEntry({'fixed_width_small': {}}),
          'not a map',
          {'id': 'no-images'},
          gifEntry({
            'original': {'url': 'https://g/good.gif'},
          }),
        ],
      });

      expect(gifs, hasLength(1));
      expect(gifs.single.url, 'https://g/good.gif');
    });

    test('malformed or empty payloads yield an empty list', () {
      expect(GiphyService.parseResponse(null), isEmpty);
      expect(GiphyService.parseResponse({}), isEmpty);
      expect(GiphyService.parseResponse({'data': 'nope'}), isEmpty);
      expect(GiphyService.parseResponse({'data': []}), isEmpty);
    });
  });
}
