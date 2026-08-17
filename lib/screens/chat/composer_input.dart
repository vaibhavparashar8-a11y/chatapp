part of '../chat_screen.dart';

// ── Composer input: emoji, GIFs, keyboard stickers ───────────────────────────

/// Handlers behind the emoji/GIF panel and the system keyboard's sticker key.
/// Split out of chat_screen.dart to keep it readable; none of these call
/// setState, so an extension works (see the file-size guidance in CLAUDE.md).
extension ChatComposerInput on _ChatScreenState {
  /// Emoji go into the message field at the caret, never straight to the chat —
  /// they are usually part of a sentence.
  void _insertEmoji(String emoji) {
    final value = _textController.value;
    final start = value.selection.start < 0 ? value.text.length : value.selection.start;
    final end = value.selection.end < 0 ? value.text.length : value.selection.end;
    final text = value.text.replaceRange(start, end, emoji);
    _textController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
    _ctrl.onTypingChanged(text);
  }

  /// Deletes one character before the caret — the emoji panel usually replaces
  /// the on-screen keyboard, so there is no other way back.
  void _backspace() {
    final value = _textController.value;
    final end = value.selection.end < 0 ? value.text.length : value.selection.end;
    if (end == 0) return;
    final start = value.selection.start < 0 ? end : value.selection.start;
    // Step back over a full grapheme cluster, so one tap removes one visible
    // emoji rather than half a surrogate pair.
    final from = start == end ? _graphemeStart(value.text, end) : start;
    _textController.value = TextEditingValue(
      text: value.text.replaceRange(from, end, ''),
      selection: TextSelection.collapsed(offset: from),
    );
  }

  /// Start index of the character ending at [end] — walks back over the low
  /// half of a surrogate pair and any combining marks (ZWJ sequences, skin
  /// tones, variation selectors) so 👩‍❤️‍👨 deletes as one.
  static int _graphemeStart(String text, int end) {
    var i = end;
    while (i > 0) {
      i -= 1;
      final unit = text.codeUnitAt(i);
      final isLowSurrogate = unit >= 0xDC00 && unit <= 0xDFFF;
      final isCombining = unit == 0x200D || unit == 0xFE0F;
      if (isLowSurrogate && i > 0) {
        i -= 1; // consume the high surrogate too
      } else if (!isCombining) {
        break;
      }
      // A ZWJ/variation selector means the sequence continues — keep walking.
      if (i > 0 && (text.codeUnitAt(i - 1) == 0x200D)) continue;
      if (!isCombining) break;
    }
    return i;
  }

  /// Downloads the chosen GIF and sends it. Giphy serves a URL; the chat stores
  /// its own copy in Firebase Storage like any other media.
  Future<void> _sendGif(GiphyGif gif) async {
    _ctrl.setShowEmojiPanel(false);
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/giphy_${gif.id}.gif';
      await Dio().download(gif.url, path);
      await _ctrl.sendMedia(File(path), MessageType.gif,
          fileName: 'giphy_${gif.id}.gif');
    } catch (e) {
      LogService.e('Giphy', 'sending gif ${gif.id} failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not send that GIF'),
        duration: Duration(seconds: 2),
      ));
    }
  }

  /// Stickers and GIFs inserted from the system keyboard (Gboard's emoji/GIF
  /// key, and any sticker pack installed from the Play Store — they all deliver
  /// through Android's commitContent API, which Flutter surfaces here).
  Future<void> _onKeyboardContent(KeyboardInsertedContent content) async {
    final data = content.data;
    if (data == null) return;
    try {
      final dir = await getTemporaryDirectory();
      final name = content.uri.split('/').last.split('?').first;
      final safeName = name.contains('.')
          ? name
          : '$name.${content.mimeType.split('/').last}';
      final file = File('${dir.path}/$safeName');
      await file.writeAsBytes(data);
      await _ctrl.sendMedia(
        file,
        content.mimeType == 'image/gif' ? MessageType.gif : MessageType.image,
        fileName: safeName,
      );
    } catch (e) {
      LogService.e('Chat', 'keyboard content insert failed: $e');
    }
  }
}
