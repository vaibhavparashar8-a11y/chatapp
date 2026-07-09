/// Pure link-detection helpers for chat message text — no Flutter imports,
/// unit-testable like time_utils.dart.

/// One piece of a message: either plain text or a tappable URL.
class TextChunk {
  final String text;
  final bool isLink;
  const TextChunk(this.text, {required this.isLink});

  /// The URL to open for a link chunk. Bare `www.` links need an explicit
  /// scheme or `launchUrl` rejects them.
  String get url => text.startsWith('www.') ? 'https://$text' : text;
}

// http(s) URLs or bare www. domains. Trailing punctuation that usually ends a
// sentence (.,!?;:) is excluded from the match so "check https://a.com."
// doesn't produce a broken link.
final RegExp _linkRegExp = RegExp(
  r'(https?://[^\s]+|www\.[^\s]+)',
  caseSensitive: false,
);

const _trailingPunctuation = ['.', ',', '!', '?', ';', ':', ')', ']'];

/// Split [text] into plain and link chunks, in original order.
/// Returns a single plain chunk when the text contains no URLs.
List<TextChunk> splitLinks(String text) {
  final chunks = <TextChunk>[];
  int last = 0;
  for (final m in _linkRegExp.allMatches(text)) {
    var link = m.group(0)!;
    var end = m.end;
    // Strip sentence punctuation stuck to the end of the URL.
    while (link.isNotEmpty && _trailingPunctuation.contains(link[link.length - 1])) {
      link = link.substring(0, link.length - 1);
      end--;
    }
    if (link.isEmpty) continue;
    if (m.start > last) {
      chunks.add(TextChunk(text.substring(last, m.start), isLink: false));
    }
    chunks.add(TextChunk(link, isLink: true));
    last = end;
  }
  if (last < text.length) {
    chunks.add(TextChunk(text.substring(last), isLink: false));
  }
  if (chunks.isEmpty) chunks.add(TextChunk(text, isLink: false));
  return chunks;
}
