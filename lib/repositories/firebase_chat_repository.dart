import 'dart:io';
import '../models/message.dart';
import '../services/chat_service.dart';
import 'i_chat_repository.dart';

/// Adapts the static ChatService API to the IChatRepository interface.
/// This is the only file that knows about the concrete Firebase implementation.
/// Follows the Adapter pattern — ChatController stays clean of Firebase details.
class FirebaseChatRepository implements IChatRepository {
  const FirebaseChatRepository();

  @override
  Stream<List<Message>> messagesStream({int limit = 50}) =>
      ChatService.messagesStream(limit: limit);

  @override
  Future<void> sendText(
    String text, {
    String? replyToId,
    String? replyToText,
    String? replyToSender,
    String? clientId,
  }) =>
      ChatService.sendText(
        text,
        replyToId: replyToId,
        replyToText: replyToText,
        replyToSender: replyToSender,
        clientId: clientId,
      );

  @override
  Future<void> sendMedia(
    File file,
    MessageType type, {
    String? fileName,
    void Function(double)? onProgress,
  }) =>
      ChatService.sendMedia(file, type, fileName: fileName, onProgress: onProgress);

  @override
  Future<void> enterChat() => ChatService.enterChat();

  @override
  Future<void> leaveChat() => ChatService.leaveChat();

  @override
  Future<void> markRead() => ChatService.markRead();

  @override
  Future<String?> getLastReadMsgId() => ChatService.getLastReadMsgId();

  @override
  Future<void> setLastReadMsgId(String messageId) =>
      ChatService.setLastReadMsgId(messageId);

  @override
  Future<void> setTyping(bool isTyping) => ChatService.setTyping(isTyping);

  @override
  Stream<bool> otherTypingStream() => ChatService.otherTypingStream();

  @override
  Future<void> refreshPresence() => ChatService.refreshPresence();

  @override
  Stream<bool> otherPresenceStream() => ChatService.otherPresenceStream();

  @override
  Stream<DateTime?> otherPresenceAtStream() =>
      ChatService.otherPresenceAtStream();

  @override
  Stream<DateTime?> myPresenceAtStream() => ChatService.myPresenceAtStream();

  @override
  Stream<DateTime?> otherLastSeenStream() => ChatService.otherLastSeenStream();

  @override
  Stream<DateTime?> otherReadAtStream() => ChatService.otherReadAtStream();

  @override
  Future<void> clearMyView() => ChatService.clearMyView();

  @override
  Future<DateTime?> getClearedAt() => ChatService.getClearedAt();

  @override
  Future<List<Message>> fetchOlderMessages(DateTime before, {int limit = 30}) =>
      ChatService.fetchOlderMessages(before, limit: limit);

  @override
  Future<void> editMessage(String messageId, String newText) =>
      ChatService.editMessage(messageId, newText);

  @override
  Future<void> deleteMessage(String messageId) =>
      ChatService.deleteMessage(messageId);

  @override
  Future<void> hideMessage(String messageId) =>
      ChatService.hideMessage(messageId);

  @override
  Future<Set<String>> getHiddenIds() => ChatService.getHiddenIds();

  @override
  Future<void> deleteForMe(String messageId, List<String> deletedFor) =>
      ChatService.deleteForMe(messageId, deletedFor);

  @override
  Future<void> clearChatForMe() => ChatService.clearChatForMe();
}
