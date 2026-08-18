import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/constants.dart';
import 'package:chatapp/controllers/chat_controller.dart';
import 'package:chatapp/models/message.dart';
import 'package:chatapp/services/log_service.dart';
import '../helpers/fake_chat_repository.dart';

void main() {
  // Set a stable sender ID for all tests
  setUpAll(() {
    mySenderId = 'A';
    LogService.testMode = true;
  });

  tearDownAll(() => LogService.testMode = false);

  group('ChatController — init', () {
    test('enters chat and subscribes to streams on init()', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);

      await ctrl.init();

      expect(repo.enterCount, 1);
      ctrl.dispose();
      repo.close();
    });

    test('messages are empty before stream emits', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      expect(ctrl.messages, isEmpty);
      ctrl.dispose();
      repo.close();
    });

    test('messages reflect what the stream emits', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      final msgs = [makeMessage(id: 'm1', text: 'hi')];
      repo.emitMessages(msgs);
      await Future.delayed(Duration.zero); // let listener run

      expect(ctrl.messages.length, 1);
      expect(ctrl.messages.first.text, 'hi');
      ctrl.dispose();
      repo.close();
    });
  });

  group('ChatController — optimistic UI', () {
    test('sendText adds pending message immediately (before Firestore confirms)', () async {
      final repo = FakeChatRepository()..autoConfirm = false;
      final ctrl = ChatController(repo);
      await ctrl.init();

      // Start send but do NOT await — we want to inspect state mid-flight
      // Everything before the first `await` in sendText runs synchronously
      final future = ctrl.sendText('hello');
      expect(ctrl.pendingIds, isNotEmpty);
      expect(ctrl.messages.any((m) => m.text == 'hello'), true);

      await future;
      ctrl.dispose();
      repo.close();
    });

    test('pending message is removed once stream confirms with matching clientId', () async {
      final repo = FakeChatRepository()..autoConfirm = true;
      final ctrl = ChatController(repo);
      await ctrl.init();

      await ctrl.sendText('confirmed');
      await Future.delayed(Duration.zero); // stream listener

      expect(ctrl.pendingIds, isEmpty);
      expect(ctrl.failedIds, isEmpty);
      // Confirmed message still present via stream
      expect(ctrl.messages.any((m) => m.text == 'confirmed'), true);
      ctrl.dispose();
      repo.close();
    });

    test('message lands in failedIds when send throws', () async {
      final repo = FakeChatRepository()
        ..autoConfirm = false
        ..throwOnSend = true;
      final ctrl = ChatController(repo);
      await ctrl.init();

      await ctrl.sendText('fail me');
      await Future.delayed(Duration.zero);

      expect(ctrl.failedIds, isNotEmpty);
      expect(ctrl.pendingIds, isEmpty);
      expect(ctrl.messages.any((m) => m.text == 'fail me'), true);
      ctrl.dispose();
      repo.close();
    });
  });

  group('ChatController — media upload', () {
    // The composer used to be disabled for the whole upload, with only a
    // banner to show for it. The bubble now carries the preview and progress.
    test('the bubble appears before the upload starts, with a local preview',
        () async {
      final repo = FakeChatRepository()..mediaProgressGate = Completer<void>();
      final ctrl = ChatController(repo);
      await ctrl.init();

      final future = ctrl.sendMedia(File('/pics/cat.jpg'), MessageType.image);

      expect(ctrl.messages.length, 1);
      final bubble = ctrl.messages.single;
      expect(bubble.type, MessageType.image);
      expect(bubble.previewPath, '/pics/cat.jpg');
      expect(bubble.mediaUrl, isNull); // nothing uploaded yet
      expect(ctrl.pendingIds, contains(bubble.id));

      repo.mediaProgressGate!.complete();
      await future;
      ctrl.dispose();
      repo.close();
    });

    test('progress is reported against that one message id', () async {
      final repo = FakeChatRepository()..mediaProgressGate = Completer<void>();
      final ctrl = ChatController(repo);
      await ctrl.init();

      final future = ctrl.sendMedia(File('/pics/cat.jpg'), MessageType.image);
      final id = ctrl.messages.single.id;
      expect(ctrl.uploadProgressFor(id), 0.5);
      expect(ctrl.uploadProgressFor('some-other-message'), isNull);

      repo.mediaProgressGate!.complete();
      await future;
      ctrl.dispose();
      repo.close();
    });

    // A received video used to sit blank while a network VideoPlayerController
    // spun up just to produce a first frame. The sender's own preview frame is
    // uploaded alongside it instead.
    test('a photo is sent without a thumbnail', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      await ctrl.sendMedia(File('/pics/cat.jpg'), MessageType.image,
          fileName: 'cat.jpg');
      await Future.delayed(Duration.zero);

      expect(repo.sentThumbnails, [null]);
      ctrl.dispose();
      repo.close();
    });

    test('the optimistic bubble is replaced by the confirmed message',
        () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      await ctrl.sendMedia(File('/pics/cat.jpg'), MessageType.image,
          fileName: 'cat.jpg');
      await Future.delayed(Duration.zero);

      expect(repo.sentMedia, ['cat.jpg']);
      // The clientId is what lets the stream retire the optimistic copy —
      // without it the sender would see the photo twice.
      expect(repo.mediaClientIds.single, isNotNull);
      expect(ctrl.pendingIds, isEmpty);
      expect(ctrl.messages.single.mediaUrl, isNotNull);
      expect(ctrl.uploadProgressFor(ctrl.messages.single.id), isNull);

      ctrl.dispose();
      repo.close();
    });

    test('a failed upload keeps its bubble and can be retried', () async {
      final repo = FakeChatRepository()..throwOnSend = true;
      final errors = <String>[];
      final ctrl = ChatController(repo, onUploadError: errors.add);
      await ctrl.init();

      await ctrl.sendMedia(File('/pics/cat.jpg'), MessageType.image,
          fileName: 'cat.jpg');

      final failedId = ctrl.failedIds.single;
      expect(errors, isNotEmpty);
      expect(ctrl.messages.single.previewPath, '/pics/cat.jpg');
      expect(ctrl.uploadProgressFor(failedId), isNull); // ring gone, not stuck

      repo.throwOnSend = false;
      await ctrl.retryMessage(failedId);
      await Future.delayed(Duration.zero);

      expect(repo.sentMedia, ['cat.jpg', 'cat.jpg']); // re-uploaded, not re-sent as text
      expect(ctrl.failedIds, isEmpty);
      expect(ctrl.pendingIds, isEmpty);
      ctrl.dispose();
      repo.close();
    });

    test('a second upload runs alongside the first, each with its own ring',
        () async {
      final repo = FakeChatRepository()..mediaProgressGate = Completer<void>();
      final ctrl = ChatController(repo);
      await ctrl.init();

      final first = ctrl.sendMedia(File('/pics/one.jpg'), MessageType.image);
      await Future.delayed(Duration.zero);
      final second = ctrl.sendMedia(File('/pics/two.jpg'), MessageType.image);
      await Future.delayed(Duration.zero);

      expect(ctrl.messages.length, 2);
      final ids = ctrl.messages.map((m) => m.id).toList();
      expect(ctrl.uploadProgressFor(ids[0]), 0.5);
      expect(ctrl.uploadProgressFor(ids[1]), 0.5);

      repo.mediaProgressGate!.complete();
      await Future.wait([first, second]);
      ctrl.dispose();
      repo.close();
    });
  });

  group('ChatController — retry', () {
    test('retryMessage re-sends text and removes from failedIds on success', () async {
      final repo = FakeChatRepository()
        ..autoConfirm = false
        ..throwOnSend = true;
      final ctrl = ChatController(repo);
      await ctrl.init();

      await ctrl.sendText('retry me');
      await Future.delayed(Duration.zero);

      final failedId = ctrl.failedIds.first;
      expect(ctrl.failedIds, contains(failedId));

      // Fix the repo and retry
      repo.throwOnSend = false;
      repo.autoConfirm = true;
      await ctrl.retryMessage(failedId);
      await Future.delayed(Duration.zero);

      expect(ctrl.failedIds, isEmpty);
      ctrl.dispose();
      repo.close();
    });

    test('retryMessage re-enters failedIds if send throws again', () async {
      final repo = FakeChatRepository()
        ..autoConfirm = false
        ..throwOnSend = true;
      final ctrl = ChatController(repo);
      await ctrl.init();

      await ctrl.sendText('double fail');
      await Future.delayed(Duration.zero);

      final failedId = ctrl.failedIds.first;
      // Keep throwOnSend = true
      await ctrl.retryMessage(failedId);
      await Future.delayed(Duration.zero);

      expect(ctrl.failedIds, contains(failedId));
      ctrl.dispose();
      repo.close();
    });
  });

  group('ChatController — pagination', () {
    test('loadMoreMessages prepends older messages to the list', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      // Emit a recent message so the controller has a starting point
      final recent = makeMessage(id: 'recent', timestamp: DateTime(2024, 6, 10));
      repo.emitMessages([recent]);
      await Future.delayed(Duration.zero);

      // Configure older messages
      final older = [
        makeMessage(id: 'old1', text: 'old1', timestamp: DateTime(2024, 6, 1)),
        makeMessage(id: 'old2', text: 'old2', timestamp: DateTime(2024, 6, 5)),
      ];
      repo.olderMessages = older;

      await ctrl.loadMoreMessages();

      final ids = ctrl.messages.map((m) => m.id).toList();
      expect(ids.indexOf('old1'), lessThan(ids.indexOf('recent')));
      expect(ids.indexOf('old2'), lessThan(ids.indexOf('recent')));
      ctrl.dispose();
      repo.close();
    });

    test('hasMoreMessages becomes false when fetch returns empty', () async {
      final repo = FakeChatRepository()..olderMessages = [];
      final ctrl = ChatController(repo);
      await ctrl.init();

      repo.emitMessages([makeMessage(id: 'r1')]);
      await Future.delayed(Duration.zero);

      expect(ctrl.hasMoreMessages, true);
      await ctrl.loadMoreMessages();
      expect(ctrl.hasMoreMessages, false);
      ctrl.dispose();
      repo.close();
    });

    test('loadMoreMessages is a no-op when loadingMore or no messages', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      // No messages yet — should not call fetchOlderMessages
      await ctrl.loadMoreMessages();
      // No crash; hasMoreMessages unchanged
      expect(ctrl.hasMoreMessages, true);
      ctrl.dispose();
      repo.close();
    });

    test('duplicate messages are deduplicated when paginating', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      final msg = makeMessage(id: 'shared', timestamp: DateTime(2024, 6, 10));
      repo.emitMessages([msg]);
      await Future.delayed(Duration.zero);

      // fetchOlderMessages returns the same message (overlap)
      repo.olderMessages = [msg];
      await ctrl.loadMoreMessages();

      final ids = ctrl.messages.map((m) => m.id).toList();
      expect(ids.where((id) => id == 'shared').length, 1);
      ctrl.dispose();
      repo.close();
    });
  });

  group('ChatController — debounced markRead', () {
    test('markRead is called once per message burst from the other person', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      // Emit 5 messages from the other person in rapid succession
      for (int i = 0; i < 5; i++) {
        repo.emitMessages(
          List.generate(i + 1, (j) => makeMessage(id: 'm$j', sender: 'B')),
        );
        await Future.delayed(Duration.zero);
      }

      // markRead should NOT be called yet (still within debounce window)
      expect(repo.markReadCount, 0);

      // Wait past the 500ms debounce window
      await Future.delayed(const Duration(milliseconds: 600));

      // Only one call despite 5 rapid stream events
      expect(repo.markReadCount, 1);
      ctrl.dispose();
      repo.close();
    });

    test('markRead is NOT called when stream re-emits the same messages (re-open bug fix)',
        () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      // First open — B has one message. markRead fires exactly once.
      final bMsg = makeMessage(id: 'b1', sender: 'B');
      repo.emitMessages([bMsg]);
      await Future.delayed(Duration.zero);
      await Future.delayed(const Duration(milliseconds: 600));
      expect(repo.markReadCount, 1);

      // Chat re-opened (Firestore stream re-emits same snapshot).
      // readAt must NOT be overwritten — still same message, not "new".
      repo.emitMessages([bMsg]);
      await Future.delayed(Duration.zero);
      await Future.delayed(const Duration(milliseconds: 600));
      expect(repo.markReadCount, 1, reason: 're-open must not overwrite readAt');

      ctrl.dispose();
      repo.close();
    });

    test('markRead is NOT called after an app restart when no new messages arrive',
        () async {
      // Simulate a previous session having already read message 'b1'.
      final repo = FakeChatRepository()..lastReadMsgId = 'b1';
      final ctrl = ChatController(repo);
      await ctrl.init();

      // Fresh app launch re-opens the chat — same message re-emitted.
      // readAt must NOT be re-stamped, or the sender's "Read HH:mm" would jump.
      repo.emitMessages([makeMessage(id: 'b1', sender: 'B')]);
      await Future.delayed(Duration.zero);
      await Future.delayed(const Duration(milliseconds: 600));
      expect(repo.markReadCount, 0,
          reason: 'restart re-open must not overwrite readAt');

      // A genuinely new message after restart still fires markRead once, and
      // the newly-read id is persisted for the next launch.
      repo.emitMessages([
        makeMessage(id: 'b1', sender: 'B'),
        makeMessage(id: 'b2', sender: 'B'),
      ]);
      await Future.delayed(Duration.zero);
      await Future.delayed(const Duration(milliseconds: 600));
      expect(repo.markReadCount, 1);
      expect(repo.lastReadMsgId, 'b2');

      ctrl.dispose();
      repo.close();
    });

    test('markRead is NOT called when only my own messages arrive', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      // With the ID-tracking fix, init() no longer unconditionally writes.
      // Baseline should be 0 (no B messages emitted yet).
      await Future.delayed(const Duration(milliseconds: 600));
      final baselineCount = repo.markReadCount;

      // Emit only messages from myself — no additional markRead should fire.
      for (int i = 0; i < 3; i++) {
        repo.emitMessages(
          List.generate(i + 1, (j) => makeMessage(id: 'm$j', sender: 'A')),
        );
        await Future.delayed(Duration.zero);
      }

      await Future.delayed(const Duration(milliseconds: 600));

      // Count must not have increased beyond the init() baseline.
      expect(repo.markReadCount, baselineCount);
      ctrl.dispose();
      repo.close();
    });

    test('message stream self-heals after a listener error (no restart needed)',
        () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(
        repo,
        messageResubscribeDelay: const Duration(milliseconds: 30),
      );
      await ctrl.init();

      repo.emitMessages([makeMessage(id: 'm1', sender: 'B')]);
      await Future.delayed(Duration.zero);
      expect(ctrl.messages.any((m) => m.id == 'm1'), isTrue);

      // Simulate a Firestore listener disruption (e.g. bulk server-side delete).
      repo.emitMessagesError('listener disrupted');
      await Future.delayed(const Duration(milliseconds: 60)); // await resubscribe

      // The stream re-subscribed, so new messages flow again instead of freezing.
      repo.emitMessages([
        makeMessage(id: 'm1', sender: 'B'),
        makeMessage(id: 'm2', sender: 'B'),
      ]);
      await Future.delayed(Duration.zero);
      expect(ctrl.messages.any((m) => m.id == 'm2'), isTrue,
          reason: 'chat must recover without an app restart');

      ctrl.dispose();
      repo.close();
    });

    test('does NOT mark read while backgrounded, then marks read on return',
        () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      // Read an initial message while present in the chat.
      repo.emitMessages([makeMessage(id: 'b1', sender: 'B')]);
      await Future.delayed(const Duration(milliseconds: 600));
      expect(repo.markReadCount, 1);

      // User leaves (app backgrounded). The message stream stays live.
      await ctrl.leave();

      // A new message from the other person arrives while we're away — its
      // read receipt must NOT advance (the sender must not see "Read").
      repo.emitMessages([
        makeMessage(id: 'b1', sender: 'B'),
        makeMessage(id: 'b2', sender: 'B'),
      ]);
      await Future.delayed(const Duration(milliseconds: 600));
      expect(repo.markReadCount, 1,
          reason: 'no read receipt should fire while backgrounded');
      expect(repo.lastReadMsgId, 'b1');

      // Returning to the foreground marks the missed message read, once.
      await ctrl.enter();
      await Future.delayed(const Duration(milliseconds: 600));
      expect(repo.markReadCount, 2,
          reason: 'enter() marks the message seen on return');
      expect(repo.lastReadMsgId, 'b2');

      ctrl.dispose();
      repo.close();
    });
  });

  group('ChatController — typing', () {
    test('sends typing=true when text is entered, false after 2s idle', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      ctrl.onTypingChanged('hello');
      expect(repo.typingLog, contains(true));
      ctrl.dispose();
      repo.close();
    });

    test('reflects otherTyping from stream', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      expect(ctrl.otherTyping, false);
      repo.emitTyping(true);
      await Future.delayed(Duration.zero);
      expect(ctrl.otherTyping, true);

      repo.emitTyping(false);
      await Future.delayed(Duration.zero);
      expect(ctrl.otherTyping, false);
      ctrl.dispose();
      repo.close();
    });
  });

  group('ChatController — clearMyView', () {
    test('pre-existing clearedAt from init() filters old messages', () async {
      final repo = FakeChatRepository()
        // Set before init() so the controller loads it on startup
        ..clearedAt = DateTime(2024, 6, 1);
      final ctrl = ChatController(repo);
      await ctrl.init();

      final old = makeMessage(id: 'old', timestamp: DateTime(2024, 1, 1));
      final fresh = makeMessage(id: 'fresh', timestamp: DateTime(2025, 1, 1));
      repo.emitMessages([old, fresh]);
      await Future.delayed(Duration.zero);

      expect(ctrl.messages.any((m) => m.id == 'old'), false);
      expect(ctrl.messages.any((m) => m.id == 'fresh'), true);
      ctrl.dispose();
      repo.close();
    });

    test('clearMyView() hides all messages with timestamps before now', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      // All messages have past timestamps — they will be hidden after clearing
      repo.emitMessages([
        makeMessage(id: 'old1', timestamp: DateTime(2020, 1, 1)),
        makeMessage(id: 'old2', timestamp: DateTime(2021, 1, 1)),
      ]);
      await Future.delayed(Duration.zero);
      expect(ctrl.messages.length, 2);

      // clearMyView sets clearedAt = DateTime.now() in the fake
      await ctrl.clearMyView();

      expect(ctrl.messages, isEmpty);
      ctrl.dispose();
      repo.close();
    });

    test('olderMessages are cleared when clearMyView is called', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      final recent = makeMessage(id: 'r1', timestamp: DateTime(2024, 6, 10));
      repo.emitMessages([recent]);
      await Future.delayed(Duration.zero);
      repo.olderMessages = [makeMessage(id: 'o1', timestamp: DateTime(2024, 6, 1))];
      await ctrl.loadMoreMessages();
      expect(ctrl.messages.any((m) => m.id == 'o1'), true);

      await ctrl.clearMyView();

      expect(ctrl.messages.any((m) => m.id == 'o1'), false);
      ctrl.dispose();
      repo.close();
    });
  });

  group('ChatController — two-sided deletion', () {
    test('messages deleted-for-me (my role in deletedFor) are hidden', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo); // mySenderId == 'A'
      await ctrl.init();

      repo.emitMessages([
        makeMessage(id: 'visible', sender: 'B'),
        makeMessage(id: 'goneForA', sender: 'B', deletedFor: ['A']),
        makeMessage(id: 'goneForBonly', sender: 'B', deletedFor: ['B']),
      ]);
      await Future.delayed(Duration.zero);

      final ids = ctrl.messages.map((m) => m.id).toList();
      expect(ids, contains('visible'));
      expect(ids, contains('goneForBonly')); // only B deleted → I still see it
      expect(ids, isNot(contains('goneForA')));
      ctrl.dispose();
      repo.close();
    });

    test('deleteForMe delegates to the repo with id and current deletedFor',
        () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      await ctrl.deleteForMe(
          makeMessage(id: 'm1', sender: 'B', deletedFor: ['B']));

      expect(repo.deleteForMeLog.single.id, 'm1');
      expect(repo.deleteForMeLog.single.deletedFor, ['B']);
      ctrl.dispose();
      repo.close();
    });

    test('clearChat delegates to repo.clearChatForMe', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      await ctrl.clearChat();

      expect(repo.clearChatForMeCount, 1);
      ctrl.dispose();
      repo.close();
    });
  });

  group('ChatController — leave', () {
    test('leave() is idempotent — leaveChat called only once', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      await ctrl.leave();
      await ctrl.leave();
      await ctrl.leave();

      expect(repo.leaveCount, 1);
      ctrl.dispose();
      repo.close();
    });

    test('enter() resets leave guard so next leave works', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      await ctrl.leave();
      expect(repo.leaveCount, 1);

      await ctrl.enter();
      await ctrl.leave();
      expect(repo.leaveCount, 2);
      ctrl.dispose();
      repo.close();
    });
  });

  group('ChatController — canModify', () {
    test('own message sent within 1 hour can be modified', () {
      final msg = Message(
        id: 'm1', sender: 'A', text: 'hi', type: MessageType.text,
        timestamp: DateTime.now().subtract(const Duration(minutes: 30)),
      );
      expect(ChatController.canModify(msg), true);
    });

    test('own message older than 1 hour cannot be modified', () {
      final msg = Message(
        id: 'm1', sender: 'A', text: 'hi', type: MessageType.text,
        timestamp: DateTime.now().subtract(const Duration(hours: 2)),
      );
      expect(ChatController.canModify(msg), false);
    });

    test('other person message cannot be modified even if recent', () {
      final msg = Message(
        id: 'm1', sender: 'B', text: 'hi', type: MessageType.text,
        timestamp: DateTime.now(),
      );
      expect(ChatController.canModify(msg), false);
    });

    test('message sent exactly 60 minutes ago cannot be modified', () {
      final msg = Message(
        id: 'm1', sender: 'A', text: 'hi', type: MessageType.text,
        timestamp: DateTime.now().subtract(const Duration(minutes: 60)),
      );
      expect(ChatController.canModify(msg), false);
    });
  });

  group('ChatController — hideMessage', () {
    test('hidden message is removed from the visible list', () async {
      final repo = FakeChatRepository()..autoConfirm = true;
      final ctrl = ChatController(repo);
      await ctrl.init();

      repo.emitMessages([
        makeMessage(id: 'm1', text: 'visible'),
        makeMessage(id: 'm2', text: 'hidden'),
      ]);
      await Future.delayed(Duration.zero);
      expect(ctrl.messages.length, 2);

      await ctrl.hideMessage('m2');
      expect(ctrl.messages.any((m) => m.id == 'm2'), false);
      expect(ctrl.messages.any((m) => m.id == 'm1'), true);
      ctrl.dispose();
      repo.close();
    });

    test('hiding a message does not affect other messages', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      repo.emitMessages([
        makeMessage(id: 'a'), makeMessage(id: 'b'), makeMessage(id: 'c'),
      ]);
      await Future.delayed(Duration.zero);

      await ctrl.hideMessage('b');

      final ids = ctrl.messages.map((m) => m.id).toSet();
      expect(ids, containsAll(['a', 'c']));
      expect(ids, isNot(contains('b')));
      ctrl.dispose();
      repo.close();
    });
  });

  group('ChatController — editMessage', () {
    test('editMessage delegates to the repository', () async {
      final repo = FakeChatRepository()..autoConfirm = true;
      final ctrl = ChatController(repo);
      await ctrl.init();

      await ctrl.sendText('original');
      await Future.delayed(Duration.zero);
      final msgId = ctrl.messages.first.id;

      await ctrl.editMessage(msgId, 'edited text');

      expect(repo.editLog.any((e) => e.id == msgId && e.text == 'edited text'), true);
      ctrl.dispose();
      repo.close();
    });

    test('empty string is ignored by editMessage', () async {
      final repo = FakeChatRepository()..autoConfirm = true;
      final ctrl = ChatController(repo);
      await ctrl.init();

      await ctrl.sendText('keep me');
      await Future.delayed(Duration.zero);
      final msgId = ctrl.messages.first.id;

      await ctrl.editMessage(msgId, '   ');

      expect(repo.editLog, isEmpty);
      ctrl.dispose();
      repo.close();
    });
  });

  group('ChatController — deleteMessage', () {
    test('deleteMessage delegates to the repository', () async {
      final repo = FakeChatRepository()..autoConfirm = true;
      final ctrl = ChatController(repo);
      await ctrl.init();

      await ctrl.sendText('delete me');
      await Future.delayed(Duration.zero);
      final msgId = ctrl.messages.first.id;

      await ctrl.deleteMessage(msgId);

      expect(repo.deleteLog, contains(msgId));
      ctrl.dispose();
      repo.close();
    });
  });

  group('ChatController — presence', () {
    test('otherOnline reflects the presence stream', () async {
      final repo = FakeChatRepository();
      final presenceCtrl = StreamController<bool>.broadcast();
      repo.overridePresenceStream = presenceCtrl.stream;
      final ctrl = ChatController(repo);
      await ctrl.init();

      expect(ctrl.otherOnline, false);
      presenceCtrl.add(true);
      await Future.delayed(Duration.zero);
      expect(ctrl.otherOnline, true);

      presenceCtrl.add(false);
      await Future.delayed(Duration.zero);
      expect(ctrl.otherOnline, false);

      ctrl.dispose();
      presenceCtrl.close();
      repo.close();
    });

    test('online flips to offline when the heartbeat goes stale', () async {
      final repo = FakeChatRepository();
      final presenceCtrl = StreamController<bool>.broadcast();
      repo.overridePresenceStream = presenceCtrl.stream;
      final ctrl = ChatController(
        repo,
        presenceRefreshInterval: const Duration(milliseconds: 40),
        presenceStaleAfter: const Duration(milliseconds: 100),
      );
      await ctrl.init();

      // Other side comes online WITH a heartbeat.
      presenceCtrl.add(true);
      repo.emitPresenceAt(DateTime(2030, 1, 1, 12, 0, 0));
      await Future.delayed(Duration.zero);
      expect(ctrl.otherOnline, true);

      // No further heartbeats arrive (simulated force-kill: presence bool
      // stays true in Firestore, but presenceAt stops changing). After the
      // stale window the periodic re-check must flip online to false.
      await Future.delayed(const Duration(milliseconds: 250));
      expect(ctrl.otherOnline, false,
          reason: 'stale heartbeat must not keep showing online');

      // A fresh heartbeat (new value) restores online.
      repo.emitPresenceAt(DateTime(2030, 1, 1, 12, 0, 20));
      await Future.delayed(Duration.zero);
      expect(ctrl.otherOnline, true);

      ctrl.dispose();
      presenceCtrl.close();
      repo.close();
    });

    test('a long-dead peer shows offline immediately on chat open', () async {
      // The bug: staleness was measured from when we LOCALLY received the
      // peer's last heartbeat, so opening the chat granted a fresh window even
      // though the peer died long ago. Fix: compare the peer's heartbeat to our
      // OWN (both server timestamps). Our heartbeat is recent; theirs is 30 min
      // behind → stale at once, no false "online" grace.
      final repo = FakeChatRepository();
      final presenceCtrl = StreamController<bool>.broadcast();
      repo.overridePresenceStream = presenceCtrl.stream;
      final ctrl = ChatController(
        repo,
        presenceStaleAfter: const Duration(seconds: 45),
      );
      await ctrl.init();

      presenceCtrl.add(true); // presence bool still stuck true (force-killed)
      repo.emitMyPresenceAt(DateTime(2030, 1, 1, 12, 30, 0)); // my heartbeat: now
      repo.emitPresenceAt(DateTime(2030, 1, 1, 12, 0, 0)); // theirs: 30 min ago
      await Future.delayed(Duration.zero);

      expect(ctrl.otherOnline, false,
          reason: 'a 30-min-old heartbeat must never read as online on open');

      // Both heartbeating recently → online.
      repo.emitPresenceAt(DateTime(2030, 1, 1, 12, 29, 50));
      await Future.delayed(Duration.zero);
      expect(ctrl.otherOnline, true);

      ctrl.dispose();
      presenceCtrl.close();
      repo.close();
    });

    test('legacy peer with no heartbeat is trusted on the raw boolean', () async {
      final repo = FakeChatRepository();
      final presenceCtrl = StreamController<bool>.broadcast();
      repo.overridePresenceStream = presenceCtrl.stream;
      final ctrl = ChatController(
        repo,
        presenceRefreshInterval: const Duration(milliseconds: 40),
        presenceStaleAfter: const Duration(milliseconds: 100),
      );
      await ctrl.init();

      // Old app version never writes presenceAt — bool must be trusted
      // indefinitely (pre-heartbeat behavior preserved).
      presenceCtrl.add(true);
      await Future.delayed(Duration.zero);
      expect(ctrl.otherOnline, true);
      await Future.delayed(const Duration(milliseconds: 250));
      expect(ctrl.otherOnline, true,
          reason: 'no heartbeat data → no staleness check');

      ctrl.dispose();
      presenceCtrl.close();
      repo.close();
    });

    test('own heartbeat is re-affirmed periodically while entered', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(
        repo,
        presenceRefreshInterval: const Duration(milliseconds: 40),
        presenceStaleAfter: const Duration(milliseconds: 100),
      );
      await ctrl.init();

      await Future.delayed(const Duration(milliseconds: 150));
      expect(repo.refreshPresenceCount, greaterThan(0),
          reason: 'heartbeat writes while chat open');

      // After leave() the heartbeat must stop.
      await ctrl.leave();
      final countAtLeave = repo.refreshPresenceCount;
      await Future.delayed(const Duration(milliseconds: 150));
      expect(repo.refreshPresenceCount, countAtLeave,
          reason: 'no heartbeat after leaving');

      ctrl.dispose();
      repo.close();
    });

    test('dispose() without leave() still clears presence (defense-in-depth)',
        () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      expect(repo.leaveCount, 0);
      ctrl.dispose(); // no explicit leave() — e.g. an unexpected dispose path
      await Future.delayed(Duration.zero);
      expect(repo.leaveCount, 1,
          reason: 'dispose must clear presence if leave() was skipped');

      repo.close();
    });
  });

  group('ChatController — reply', () {
    test('setReplyingTo stores the message and clears attach menu', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      ctrl.setShowAttachMenu(true);
      expect(ctrl.showAttachMenu, true);

      final msg = makeMessage(id: 'r1');
      ctrl.setReplyingTo(msg);

      expect(ctrl.replyingTo, msg);
      expect(ctrl.showAttachMenu, false);
      ctrl.dispose();
      repo.close();
    });

    test('setReplyingTo(null) clears the reply', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(repo);
      await ctrl.init();

      ctrl.setReplyingTo(makeMessage(id: 'r1'));
      ctrl.setReplyingTo(null);

      expect(ctrl.replyingTo, isNull);
      ctrl.dispose();
      repo.close();
    });
  });

  // ── Silent push → stream recovery ──────────────────────────────────────────
  // A `messages` watch target can die without raising an error, which is why
  // the resubscribe-on-error path (#80) never fires for it. The FCM data push
  // is a delivery channel independent of Firestore, so it is the only thing
  // that can notice. It must not, however, re-subscribe on every message of a
  // healthy conversation.

  group('ChatController — silent push recovery', () {
    setUp(() => chatRefreshNotifier.value = 0);

    test('re-subscribes when a push arrives but no snapshot follows', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(
        repo,
        pushGraceWindow: const Duration(milliseconds: 50),
      );
      await ctrl.init();
      final subscriptionsBefore = repo.messagesSubscribeCount;

      // The stream is dead: the push fires, nothing is delivered.
      chatRefreshNotifier.value++;
      await Future.delayed(const Duration(milliseconds: 150));

      expect(repo.messagesSubscribeCount, greaterThan(subscriptionsBefore),
          reason: 'a silently dead message stream must be re-subscribed');
      ctrl.dispose();
      repo.close();
    });

    test('does not re-subscribe when the stream delivers the message',
        () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(
        repo,
        pushGraceWindow: const Duration(milliseconds: 100),
      );
      await ctrl.init();
      final subscriptionsBefore = repo.messagesSubscribeCount;

      // Healthy: the push and the snapshot race, and the snapshot lands first.
      chatRefreshNotifier.value++;
      repo.emitMessages([makeMessage(id: 'm1', text: 'delivered')]);
      await Future.delayed(const Duration(milliseconds: 200));

      expect(repo.messagesSubscribeCount, subscriptionsBefore,
          reason: 'a live conversation must not re-subscribe per message');
      ctrl.dispose();
      repo.close();
    });

    test('stops listening for pushes once disposed', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(
        repo,
        pushGraceWindow: const Duration(milliseconds: 20),
      );
      await ctrl.init();
      ctrl.dispose();
      final subscriptionsAfterDispose = repo.messagesSubscribeCount;

      chatRefreshNotifier.value++;
      await Future.delayed(const Duration(milliseconds: 80));

      expect(repo.messagesSubscribeCount, subscriptionsAfterDispose);
      repo.close();
    });
  });

  // ── Stuck-write watchdog ───────────────────────────────────────────────────
  // A wedged Firestore connection goes SILENT — no error, so the listener
  // self-heal added in #80 never fires. Writes queue locally forever: this
  // phone keeps showing its own messages from cache while the other phone gets
  // nothing, not even the presence heartbeat. Only a relaunch used to fix it.

  group('ChatController — stuck-write watchdog', () {
    test('resets the connection when writes stop being acknowledged', () async {
      final repo = FakeChatRepository();
      // The margins here are deliberately wide: these are wall-clock timers, so
      // a starved tick must not be mistakable for a wedged connection.
      final ctrl = ChatController(
        repo,
        presenceRefreshInterval: const Duration(milliseconds: 20),
        stuckWriteAfter: const Duration(milliseconds: 200),
        connectionResetCooldown: const Duration(milliseconds: 500),
      );
      await ctrl.init();

      // Healthy: heartbeats are acknowledged, so nothing is reset.
      await Future.delayed(const Duration(milliseconds: 100));
      expect(repo.resetConnectionCount, 0,
          reason: 'a live connection must never be reset');

      // The connection wedges: writes are accepted but never acknowledged.
      repo.wedged = true;
      await Future.delayed(const Duration(milliseconds: 600));

      expect(repo.resetConnectionCount, greaterThanOrEqualTo(1),
          reason: 'a silently dead connection must be rebuilt');
      ctrl.dispose();
      repo.close();
    });

    test('holds off re-resetting while the cooldown is running', () async {
      // A phone that is simply offline would otherwise thrash the connection.
      final repo = FakeChatRepository();
      final ctrl = ChatController(
        repo,
        presenceRefreshInterval: const Duration(milliseconds: 20),
        stuckWriteAfter: const Duration(milliseconds: 100),
        connectionResetCooldown: const Duration(seconds: 30),
      );
      await ctrl.init();

      repo.wedged = true;
      // Keep it wedged: the fake clears the flag on reset, so re-arm it.
      for (var i = 0; i < 20; i++) {
        await Future.delayed(const Duration(milliseconds: 20));
        repo.wedged = true;
      }

      expect(repo.resetConnectionCount, 1,
          reason: 'the cooldown allows exactly one reset in this window');
      ctrl.dispose();
      repo.close();
    });

    test('a successful send counts as proof the connection is alive', () async {
      final repo = FakeChatRepository();
      final ctrl = ChatController(
        repo,
        presenceRefreshInterval: const Duration(milliseconds: 20),
        stuckWriteAfter: const Duration(seconds: 2),
        connectionResetCooldown: const Duration(milliseconds: 500),
      );
      await ctrl.init();

      for (var i = 0; i < 6; i++) {
        await ctrl.sendText('still here $i');
        await Future.delayed(const Duration(milliseconds: 20));
      }

      expect(repo.resetConnectionCount, 0);
      ctrl.dispose();
      repo.close();
    });
  });
}
