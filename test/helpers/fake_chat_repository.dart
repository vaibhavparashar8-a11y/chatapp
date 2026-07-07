import 'dart:async';
import 'dart:io';
import 'package:chatapp/constants.dart';
import 'package:chatapp/models/message.dart';
import 'package:chatapp/repositories/i_chat_repository.dart';

/// In-memory implementation of IChatRepository for unit and widget tests.
/// No Firebase or network calls — everything is simulated via StreamControllers.
class FakeChatRepository implements IChatRepository {
  final _msgsCtrl = StreamController<List<Message>>.broadcast();
  final _typingCtrl = StreamController<bool>.broadcast();
  final _readAtCtrl = StreamController<DateTime?>.broadcast();

  // Confirmed messages (simulate what Firestore holds)
  final List<Message> _confirmed = [];

  // Pre-configured older messages returned by fetchOlderMessages
  List<Message> olderMessages = [];

  // Control flags
  bool throwOnSend = false;
  bool autoConfirm = true; // emit confirmed message on stream after sendText

  // Cleared-at timestamp (simulates SharedPreferences)
  DateTime? clearedAt;

  // Observation counters / logs for assertions
  int markReadCount = 0;
  int enterCount = 0;
  int leaveCount = 0;
  final List<bool> typingLog = [];
  final List<String> sentTexts = [];

  // ── Helpers for test control ──────────────────────────────────────────────

  void emitMessages(List<Message> msgs) => _msgsCtrl.add(msgs);
  void emitTyping(bool typing) => _typingCtrl.add(typing);
  void emitReadAt(DateTime? ts) => _readAtCtrl.add(ts);

  void close() {
    _msgsCtrl.close();
    _typingCtrl.close();
    _readAtCtrl.close();
  }

  // ── IChatRepository ───────────────────────────────────────────────────────

  @override
  Stream<List<Message>> messagesStream({int limit = 50}) => _msgsCtrl.stream;

  @override
  Future<void> sendText(
    String text, {
    String? replyToId,
    String? replyToText,
    String? replyToSender,
    String? clientId,
  }) async {
    sentTexts.add(text);
    if (throwOnSend) throw Exception('Network error');
    if (autoConfirm) {
      final msg = Message(
        id: 'srv_${_confirmed.length}',
        sender: mySenderId,
        text: text,
        type: MessageType.text,
        timestamp: DateTime.now(),
        replyToId: replyToId,
        replyToText: replyToText,
        replyToSender: replyToSender,
        clientId: clientId,
      );
      _confirmed.add(msg);
      _msgsCtrl.add(List.from(_confirmed));
    }
  }

  @override
  Future<void> sendMedia(
    File file,
    MessageType type, {
    String? fileName,
    void Function(double)? onProgress,
  }) async {
    onProgress?.call(0.5);
    onProgress?.call(1.0);
  }

  @override
  Future<void> enterChat() async => enterCount++;

  @override
  Future<void> leaveChat() async => leaveCount++;

  @override
  Future<void> markRead() async => markReadCount++;

  // Simulates the per-room SharedPreferences value. Preset it before init()
  // to emulate a chat re-opened after an app restart.
  String? lastReadMsgId;

  @override
  Future<String?> getLastReadMsgId() async => lastReadMsgId;

  @override
  Future<void> setLastReadMsgId(String messageId) async =>
      lastReadMsgId = messageId;

  @override
  Future<void> setTyping(bool isTyping) async => typingLog.add(isTyping);

  @override
  Stream<bool> otherTypingStream() => _typingCtrl.stream;

  Stream<bool>? overridePresenceStream;

  @override
  Stream<bool> otherPresenceStream() => overridePresenceStream ?? const Stream.empty();

  @override
  Stream<DateTime?> otherLastSeenStream() => const Stream.empty();

  @override
  Stream<DateTime?> otherReadAtStream() => _readAtCtrl.stream;

  @override
  Future<void> clearMyView() async =>
      clearedAt = DateTime.now();

  @override
  Future<DateTime?> getClearedAt() async => clearedAt;

  @override
  Future<List<Message>> fetchOlderMessages(DateTime before, {int limit = 30}) async =>
      olderMessages.where((m) => m.timestamp.isBefore(before)).toList();

  // Observation logs for assertions
  final List<({String id, String text})> editLog = [];
  final List<String> deleteLog = [];

  final Set<String> _hiddenIds = {};
  List<String> get hiddenLog => _hiddenIds.toList();

  @override
  Future<void> hideMessage(String messageId) async {
    // Production stores hidden IDs locally only (SharedPreferences) — no stream
    // event is emitted. The controller re-fetches _hiddenIds and uses them as a
    // filter in messages getter.
    _hiddenIds.add(messageId);
  }

  @override
  Future<Set<String>> getHiddenIds() async => Set.from(_hiddenIds);

  @override
  Future<void> editMessage(String messageId, String newText) async {
    editLog.add((id: messageId, text: newText));
    final i = _confirmed.indexWhere((m) => m.id == messageId);
    if (i != -1) {
      final old = _confirmed[i];
      _confirmed[i] = Message(
        id: old.id, sender: old.sender, text: newText,
        type: old.type, timestamp: old.timestamp,
        clientId: old.clientId, edited: true,
      );
      _msgsCtrl.add(List.from(_confirmed));
    }
  }

  @override
  Future<void> deleteMessage(String messageId) async {
    deleteLog.add(messageId);
    _confirmed.removeWhere((m) => m.id == messageId);
    _msgsCtrl.add(List.from(_confirmed));
  }
}

// ── Factory helpers ──────────────────────────────────────────────────────────

Message makeMessage({
  required String id,
  String? sender,
  String text = 'hello',
  DateTime? timestamp,
  String? clientId,
}) {
  return Message(
    id: id,
    sender: sender ?? mySenderId,
    text: text,
    type: MessageType.text,
    timestamp: timestamp ?? DateTime(2024, 1, 1, 12, 0),
    clientId: clientId,
  );
}
