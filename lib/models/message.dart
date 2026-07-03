// lib/models/message.dart

enum MessageType { text, image, video, file, gif, audio, callEvent }

class Message {
  final String id;
  final String sender;
  final String text;
  final MessageType type;
  final String? mediaUrl;
  final String? fileName;
  final int? fileSize;
  final DateTime timestamp;
  final String? replyToId;
  final String? replyToText;
  final String? replyToSender;
  final String? clientId;
  final bool edited;
  // Who placed the call — present on callEvent messages written after this field
  // was added. Null on older events (direction cannot be determined).
  final String? callerId;

  Message({
    required this.id,
    required this.sender,
    required this.text,
    required this.type,
    this.mediaUrl,
    this.fileName,
    this.fileSize,
    required this.timestamp,
    this.replyToId,
    this.replyToText,
    this.replyToSender,
    this.clientId,
    this.edited = false,
    this.callerId,
  });

  factory Message.fromMap(Map<String, dynamic> map, String id) {
    return Message(
      id: id,
      sender: map['sender'] ?? '',
      text: map['text'] ?? '',
      type: MessageType.values.firstWhere(
        (e) => e.name == (map['type'] ?? 'text'),
        orElse: () => MessageType.text,
      ),
      mediaUrl: map['mediaUrl'],
      fileName: map['fileName'],
      fileSize: map['fileSize'],
      timestamp: map['timestamp'] != null
          ? (map['timestamp'] as dynamic).toDate()
          : DateTime.now(),
      replyToId: map['replyToId'],
      replyToText: map['replyToText'],
      replyToSender: map['replyToSender'],
      clientId: map['clientId'],
      edited: (map['edited'] as bool?) ?? false,
      callerId: map['callerId'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'sender': sender,
      'text': text,
      'type': type.name,
      if (mediaUrl != null) 'mediaUrl': mediaUrl,
      if (fileName != null) 'fileName': fileName,
      if (fileSize != null) 'fileSize': fileSize,
      'timestamp': timestamp,
      if (replyToId != null) 'replyToId': replyToId,
      if (replyToText != null) 'replyToText': replyToText,
      if (replyToSender != null) 'replyToSender': replyToSender,
      if (clientId != null) 'clientId': clientId,
      if (edited) 'edited': true,
      if (callerId != null) 'callerId': callerId,
    };
  }
}
