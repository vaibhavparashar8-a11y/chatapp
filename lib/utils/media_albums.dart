// lib/utils/media_albums.dart
//
// Collapses a run of consecutive photos/videos from the same sender into one
// "album" row, the way WhatsApp stacks a batch sent together instead of drawing
// one bubble per file. Pure and Flutter-free so the rules stay unit-testable.

import '../models/message.dart';
import 'message_grouping.dart';

/// One row of the chat list: either a single message, or an album of several.
class ChatRow {
  /// Oldest first. Length 1 for an ordinary message.
  final List<Message> messages;
  final MessageLayout layout;

  const ChatRow({required this.messages, required this.layout});

  bool get isAlbum => messages.length > 1;

  /// The message the row's bubble chrome (ticks, timestamp, long-press) uses —
  /// the newest of the run, matching where the clock already sits today.
  Message get anchor => messages.last;
}

/// Longest gap between two photos that still counts as one batch. Shorter than
/// the bubble-run window: a picture sent five minutes later is a new thought,
/// not part of the same album.
const Duration kAlbumWindow = Duration(minutes: 2);

/// Media types that stack. GIFs stay on their own — they animate, and shrinking
/// one into a grid tile throws that away.
bool isAlbumMedia(Message m) =>
    m.type == MessageType.image || m.type == MessageType.video;

/// Rows for [messages] (oldest first).
///
/// [excludeIds] are messages that must stay standalone — in practice the ones
/// still uploading or failed, which own a progress ring and a retry action that
/// an album tile has nowhere to put.
List<ChatRow> buildChatRows(
  List<Message> messages, {
  Set<String> excludeIds = const {},
  Duration albumWindow = kAlbumWindow,
}) {
  final layouts = layoutMessages(messages);
  final rows = <ChatRow>[];
  var i = 0;

  while (i < messages.length) {
    final start = messages[i];
    var end = i;

    if (_albumEligible(start, excludeIds)) {
      // Extend while the next message is more media from the same sender,
      // close enough in time, and not the first message under a new date chip.
      while (end + 1 < messages.length) {
        final next = messages[end + 1];
        if (!_albumEligible(next, excludeIds)) break;
        if (next.sender != start.sender) break;
        if (layouts[end + 1].showDateChip) break;
        if (next.timestamp.difference(messages[end].timestamp).abs() >
            albumWindow) {
          break;
        }
        end++;
      }
    }

    rows.add(ChatRow(
      messages: messages.sublist(i, end + 1),
      // The chip belongs to the first member and the tail to the last, so a
      // multi-message row takes one flag from each end.
      layout: MessageLayout(
        showDateChip: layouts[i].showDateChip,
        isFirstInGroup: layouts[i].isFirstInGroup,
        isLastInGroup: layouts[end].isLastInGroup,
      ),
    ));
    i = end + 1;
  }
  return rows;
}

bool _albumEligible(Message m, Set<String> excludeIds) =>
    isAlbumMedia(m) && m.mediaUrl != null && !excludeIds.contains(m.id);
