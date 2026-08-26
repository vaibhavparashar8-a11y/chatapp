// test/utils/media_albums_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/models/message.dart';
import 'package:chatapp/utils/media_albums.dart';

final _base = DateTime(2026, 8, 26, 10, 0);

Message msg(
  String id, {
  String sender = 'A',
  MessageType type = MessageType.image,
  int minutes = 0,
  String? mediaUrl = 'https://example.com/x.jpg',
  DateTime? at,
}) =>
    Message(
      id: id,
      sender: sender,
      text: '',
      type: type,
      mediaUrl: type == MessageType.text ? null : mediaUrl,
      timestamp: at ?? _base.add(Duration(minutes: minutes)),
    );

List<List<String>> ids(List<ChatRow> rows) =>
    rows.map((r) => r.messages.map((m) => m.id).toList()).toList();

void main() {
  group('buildChatRows', () {
    test('a lone message is a row of one', () {
      final rows = buildChatRows([msg('1', type: MessageType.text)]);
      expect(ids(rows), [
        ['1']
      ]);
      expect(rows.single.isAlbum, isFalse);
    });

    test('photos sent together collapse into one album row', () {
      final rows = buildChatRows([msg('1'), msg('2'), msg('3')]);
      expect(ids(rows), [
        ['1', '2', '3']
      ]);
      expect(rows.single.isAlbum, isTrue);
      expect(rows.single.anchor.id, '3'); // chrome sits on the newest
    });

    test('photos and videos stack in the same album', () {
      final rows = buildChatRows([
        msg('1'),
        msg('2', type: MessageType.video, mediaUrl: 'https://x/y.mp4'),
        msg('3'),
      ]);
      expect(ids(rows), [
        ['1', '2', '3']
      ]);
    });

    test('a gap wider than the album window starts a new row', () {
      final rows = buildChatRows([msg('1'), msg('2', minutes: 5)]);
      expect(ids(rows), [
        ['1'],
        ['2']
      ]);
    });

    test('a different sender breaks the album', () {
      final rows = buildChatRows([msg('1'), msg('2', sender: 'B')]);
      expect(ids(rows), [
        ['1'],
        ['2']
      ]);
    });

    test('text between two photos splits them', () {
      final rows = buildChatRows([
        msg('1'),
        msg('2', type: MessageType.text),
        msg('3'),
      ]);
      expect(ids(rows), [
        ['1'],
        ['2'],
        ['3']
      ]);
    });

    test('gifs never join an album — they animate', () {
      final rows = buildChatRows([
        msg('1'),
        msg('2', type: MessageType.gif, mediaUrl: 'https://x/y.gif'),
        msg('3'),
      ]);
      expect(ids(rows), [
        ['1'],
        ['2'],
        ['3']
      ]);
    });

    test('an uploading or failed message stays standalone', () {
      final rows = buildChatRows(
        [msg('1'), msg('2'), msg('3')],
        excludeIds: {'2'},
      );
      expect(ids(rows), [
        ['1'],
        ['2'],
        ['3']
      ]);
    });

    test('a message with no media url yet cannot be albumed', () {
      final rows = buildChatRows([msg('1'), msg('2', mediaUrl: null)]);
      expect(ids(rows), [
        ['1'],
        ['2']
      ]);
    });

    test('an album never spans a date separator', () {
      final rows = buildChatRows([
        msg('1', at: DateTime(2026, 8, 25, 23, 59)),
        msg('2', at: DateTime(2026, 8, 26, 0, 0)),
      ]);
      expect(ids(rows), [
        ['1'],
        ['2']
      ]);
      expect(rows[1].layout.showDateChip, isTrue);
    });

    test('the row takes its chip from the first member and its tail from the '
        'last', () {
      final rows = buildChatRows([
        msg('1'),
        msg('2', minutes: 1),
        msg('3', sender: 'B', minutes: 2),
      ]);
      final album = rows.first;
      expect(album.messages.length, 2);
      expect(album.layout.showDateChip, isTrue); // first message of the day
      expect(album.layout.isFirstInGroup, isTrue);
      // Sender changes right after, so the run ends on the album.
      expect(album.layout.isLastInGroup, isTrue);
    });

    test('every message ends up in exactly one row, in order', () {
      final input = [
        msg('1'),
        msg('2'),
        msg('3', type: MessageType.text),
        msg('4', sender: 'B'),
        msg('5', sender: 'B'),
      ];
      final flat = buildChatRows(input).expand((r) => r.messages).toList();
      expect(flat.map((m) => m.id).toList(), ['1', '2', '3', '4', '5']);
    });

    test('an empty list yields no rows', () {
      expect(buildChatRows(const []), isEmpty);
    });
  });
}
