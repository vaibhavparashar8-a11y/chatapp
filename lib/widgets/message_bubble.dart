import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:video_player/video_player.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';
import 'package:dio/dio.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import '../constants.dart';
import '../models/message.dart';
import '../screens/media_viewer_screen.dart';

part 'bubbles/shared.dart';
part 'bubbles/encrypted_image.dart';
part 'bubbles/download_button.dart';
part 'bubbles/video_player.dart';
part 'bubbles/file_tile.dart';
part 'bubbles/audio_tile.dart';

class MessageBubble extends StatefulWidget {
  final Message message;
  final DateTime? otherReadAt;
  final void Function(Message)? onReply;
  final bool isPending;
  final bool isFailed;
  final VoidCallback? onRetry;
  final bool showReadTime;
  final VoidCallback? onLongPress;

  const MessageBubble({
    super.key,
    required this.message,
    this.otherReadAt,
    this.onReply,
    this.isPending = false,
    this.isFailed = false,
    this.onRetry,
    this.showReadTime = false,
    this.onLongPress,
  });

  // Dark theme palette
  static const _myColor    = Color(0xFF6D28D9);
  static const _theirColor = Color(0xFF1E1D30);

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble>
    with SingleTickerProviderStateMixin {

  static const _triggerThreshold = 64.0;
  static const _maxSlide = 72.0;

  late final AnimationController _snapCtrl;
  Animation<double>? _snapAnim;
  double _slideOffset = 0;
  bool _triggerFired = false;

  @override
  void initState() {
    super.initState();
    _snapCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..addListener(_onSnapTick);
  }

  void _onSnapTick() {
    if (_snapAnim != null && mounted) {
      setState(() => _slideOffset = _snapAnim!.value);
    }
  }

  @override
  void dispose() {
    _snapCtrl.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_snapCtrl.isAnimating) _snapCtrl.stop();
    final next = (_slideOffset + d.delta.dx).clamp(0.0, _maxSlide);
    if (next == _slideOffset) return;
    setState(() => _slideOffset = next);
    if (_slideOffset >= _triggerThreshold && !_triggerFired) {
      _triggerFired = true;
      HapticFeedback.mediumImpact();
    }
  }

  void _onDragEnd(DragEndDetails _) {
    if (_triggerFired) widget.onReply?.call(widget.message);
    _triggerFired = false;
    _snapAnim = Tween<double>(begin: _slideOffset, end: 0).animate(
      CurvedAnimation(parent: _snapCtrl, curve: Curves.easeOut),
    );
    _snapCtrl.forward(from: 0);
  }

  bool get isMe => widget.message.sender == mySenderId;

  bool get _isRead {
    if (!isMe || widget.otherReadAt == null) return false;
    return !widget.message.timestamp.isAfter(widget.otherReadAt!);
  }

  @override
  Widget build(BuildContext context) {
    final message      = widget.message;
    final isPending    = widget.isPending;
    final isFailed     = widget.isFailed;
    final otherReadAt  = widget.otherReadAt;
    final showReadTime = widget.showReadTime;

    final bubbleColor = isMe ? MessageBubble._myColor : MessageBubble._theirColor;
    final textColor   = isMe ? Colors.white : const Color(0xFFE8E8FF);
    final metaColor   = isMe
        ? Colors.white.withValues(alpha: 0.60)
        : Colors.white.withValues(alpha: 0.40);

    final bubbleContent = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.72,
      ),
      decoration: BoxDecoration(
        color: bubbleColor.withValues(alpha: isPending ? 0.55 : 1.0),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(14),
          topRight: const Radius.circular(14),
          bottomLeft: Radius.circular(isMe ? 14 : 2),
          bottomRight: Radius.circular(isMe ? 2 : 14),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
        border: isFailed
            ? Border.all(color: Colors.redAccent.withValues(alpha: 0.7), width: 1)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (message.replyToText != null) _buildReplyPreview(textColor),
          _buildContent(context, textColor),
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 5, left: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (message.edited)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(
                      'edited',
                      style: TextStyle(
                          fontSize: 9,
                          color: metaColor,
                          fontStyle: FontStyle.italic),
                    ),
                  ),
                Text(
                  DateFormat('HH:mm').format(message.timestamp),
                  style: TextStyle(fontSize: 10, color: metaColor),
                ),
                if (isMe) ...[
                  const SizedBox(width: 3),
                  if (isPending)
                    Icon(Icons.schedule, size: 13, color: metaColor)
                  else if (isFailed)
                    GestureDetector(
                      onTap: widget.onRetry,
                      child: const Icon(Icons.error_outline,
                          size: 13, color: Colors.redAccent),
                    )
                  else
                    Icon(
                      _isRead ? Icons.done_all : Icons.done,
                      size: 14,
                      color: _isRead ? const Color(0xFF34D399) : metaColor,
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    final replyHintOpacity = (_slideOffset / _triggerThreshold).clamp(0.0, 1.0);
    final showHint = widget.onReply != null && _slideOffset > 6;

    return GestureDetector(
      onLongPress: widget.onLongPress,
      onHorizontalDragUpdate: widget.onReply != null ? _onDragUpdate : null,
      onHorizontalDragEnd: widget.onReply != null ? _onDragEnd : null,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Transform.translate(
            offset: Offset(_slideOffset, 0),
            child: Padding(
              padding: EdgeInsets.only(
                left: isMe ? 52 : 4,
                right: isMe ? 4 : 52,
                bottom: 4,
              ),
              child: Column(
                crossAxisAlignment:
                    isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment:
                        isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (!isMe)
                        SizedBox(
                          width: 8,
                          height: 12,
                          child: CustomPaint(
                            painter: _TailPainter(
                                color: MessageBubble._theirColor, isMe: false),
                          ),
                        ),
                      Flexible(child: bubbleContent),
                      if (isMe)
                        SizedBox(
                          width: 8,
                          height: 12,
                          child: CustomPaint(
                            painter: _TailPainter(
                                color: MessageBubble._myColor, isMe: true),
                          ),
                        ),
                    ],
                  ),
                  if (showReadTime && otherReadAt != null)
                    Padding(
                      padding: EdgeInsets.only(
                        top: 2,
                        right: isMe ? 12 : 0,
                        left: isMe ? 0 : 12,
                        bottom: 2,
                      ),
                      child: Text(
                        'Read ${DateFormat('HH:mm').format(otherReadAt)}',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF34D399),
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (showHint)
            Positioned(
              left: 8,
              top: 0,
              bottom: 0,
              child: Align(
                alignment: Alignment.center,
                child: Opacity(
                  opacity: replyHintOpacity,
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.10),
                    ),
                    child: const Icon(
                      Icons.reply_rounded,
                      size: 16,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildReplyPreview(Color textColor) {
    final msg = widget.message;
    final replyFromMe = msg.replyToSender == mySenderId;
    final accentColor =
        replyFromMe ? const Color(0xFFA78BFA) : const Color(0xFF60A5FA);
    return Container(
      margin: const EdgeInsets.fromLTRB(6, 6, 6, 0),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: accentColor, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            replyFromMe ? myDisplayName : otherDisplayName,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.bold, color: accentColor),
          ),
          Text(
            msg.replyToText ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                TextStyle(fontSize: 12, color: textColor.withValues(alpha: 0.70)),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context, Color textColor) {
    final msg = widget.message;
    switch (msg.type) {
      case MessageType.text:
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
          child: Text(msg.text, style: TextStyle(fontSize: 15, color: textColor)),
        );

      case MessageType.image:
      case MessageType.gif:
        final ext = msg.type == MessageType.gif ? 'gif' : 'jpg';
        return Stack(
          children: [
            GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => MediaViewerScreen(
                    url: msg.mediaUrl!,
                    isVideo: false,
                    mediaIv: msg.mediaIv,
                    cacheKey: msg.id,
                  ),
                ),
              ),
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(12)),
                child: _EncryptedImage(
                  url: msg.mediaUrl!,
                  mediaIv: msg.mediaIv,
                  cacheKey: msg.id,
                  width: 220,
                  height: 200,
                ),
              ),
            ),
            Positioned(
              top: 6,
              right: 6,
              child: _DownloadButton(
                url: msg.mediaUrl!,
                fileName: msg.fileName ?? '${msg.id}.$ext',
                messageType: msg.type,
                mediaIv: msg.mediaIv,
              ),
            ),
          ],
        );

      case MessageType.video:
        return _InlineVideoPlayer(
          url: msg.mediaUrl!,
          fileName: msg.fileName ?? '${msg.id}.mp4',
          mediaIv: msg.mediaIv,
          messageId: msg.id,
        );

      case MessageType.file:
        return _FileMessageTile(message: msg);

      case MessageType.audio:
        return _AudioMessageTile(message: msg);
    }
  }
}
