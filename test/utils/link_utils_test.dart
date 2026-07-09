import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/utils/link_utils.dart';

void main() {
  group('splitLinks', () {
    test('plain text yields a single non-link chunk', () {
      final chunks = splitLinks('hello there');
      expect(chunks, hasLength(1));
      expect(chunks.first.isLink, isFalse);
      expect(chunks.first.text, 'hello there');
    });

    test('a bare URL yields a single link chunk', () {
      final chunks = splitLinks('https://example.com/page');
      expect(chunks, hasLength(1));
      expect(chunks.first.isLink, isTrue);
      expect(chunks.first.url, 'https://example.com/page');
    });

    test('URL mid-sentence splits into three chunks in order', () {
      final chunks = splitLinks('see https://a.com for info');
      expect(chunks.map((c) => c.text).toList(),
          ['see ', 'https://a.com', ' for info']);
      expect(chunks.map((c) => c.isLink).toList(), [false, true, false]);
    });

    test('multiple URLs are all detected', () {
      final chunks = splitLinks('http://a.com and https://b.org');
      final links = chunks.where((c) => c.isLink).map((c) => c.text).toList();
      expect(links, ['http://a.com', 'https://b.org']);
    });

    test('www-prefixed link gets an https scheme in url', () {
      final chunks = splitLinks('visit www.example.com today');
      final link = chunks.firstWhere((c) => c.isLink);
      expect(link.text, 'www.example.com');
      expect(link.url, 'https://www.example.com');
    });

    test('trailing sentence punctuation is not part of the link', () {
      final chunks = splitLinks('go to https://a.com/x.');
      final link = chunks.firstWhere((c) => c.isLink);
      expect(link.text, 'https://a.com/x');
      // The stripped dot stays in the following plain chunk.
      expect(chunks.last.text, '.');
      expect(chunks.last.isLink, isFalse);
    });

    test('empty string yields one empty plain chunk', () {
      final chunks = splitLinks('');
      expect(chunks, hasLength(1));
      expect(chunks.first.isLink, isFalse);
    });
  });
}
