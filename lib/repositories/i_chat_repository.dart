import 'dart:io';
import '../models/message.dart';

/// Contract for all chat data operations.
/// ChatController depends on this abstraction — never on a concrete service.
/// Swap the implementation (Firebase → local DB, mock, etc.) without touching
/// any business logic or UI.
abstract class IChatRepository {
  /// Real-time stream of the most recent [limit] messages, oldest first.
  Stream<List<Message>> messagesStream({int limit = 50});

  Future<void> sendText(
    String text, {
    String? replyToId,
    String? replyToText,
    String? replyToSender,
    // Client-generated ID stored in Firestore to confirm optimistic messages.
    String? clientId,
  });

  Future<void> sendMedia(
    File file,
    MessageType type, {
    String? fileName,
    void Function(double progress)? onProgress,
  });

  Future<void> enterChat();
  Future<void> leaveChat();
  Future<void> markRead();

  /// ID of the newest message from the other person already marked read on this
  /// device. Persisted so a chat re-open after an app restart does not re-stamp
  /// `readAt` (which would change the read time of already-read messages).
  Future<String?> getLastReadMsgId();
  Future<void> setLastReadMsgId(String messageId);

  Future<void> setTyping(bool isTyping);
  Stream<bool> otherTypingStream();
  Stream<bool> otherPresenceStream();
  Stream<DateTime?> otherLastSeenStream();
  Stream<DateTime?> otherReadAtStream();
  Future<void> clearMyView();
  Future<DateTime?> getClearedAt();

  /// Fetch up to [limit] messages sent strictly before [before], oldest first.
  /// Returns an empty list when there are no more older messages.
  Future<List<Message>> fetchOlderMessages(DateTime before, {int limit = 30});

  /// Update the text of a sent message (marks it as edited in Firestore).
  Future<void> editMessage(String messageId, String newText);

  /// Permanently delete a message and its media file (if any).
  Future<void> deleteMessage(String messageId);

  /// Hide a message from this user's view only (stored locally, other user unaffected).
  Future<void> hideMessage(String messageId);

  /// Return the set of message IDs hidden by this user.
  Future<Set<String>> getHiddenIds();
}
