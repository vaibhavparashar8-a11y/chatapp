import 'dart:io' show File;
import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import '../constants.dart';
import '../models/message.dart';
import '../screens/media_viewer_screen.dart';
import '../services/log_service.dart';
import '../services/media_store_service.dart';
import '../theme/chat_theme.dart';
import '../utils/link_utils.dart';

part 'bubbles/shared.dart';
part 'bubbles/encrypted_image.dart';
part 'bubbles/download_button.dart';
part 'bubbles/video_player.dart';
part 'bubbles/file_tile.dart';
part 'bubbles/audio_tile.dart';
part 'bubbles/upload_preview.dart';

class MessageBubble extends StatefulWidget {
  final Message message;
  final DateTime? otherReadAt;
  final void Function(Message)? onReply;
  final bool isPending;
  final bool isFailed;

  /// 0–1 while this message's media is uploading; null otherwise. Drives the
  /// ring drawn over the local preview.
  final double? uploadProgress;

  /// Position within a run of consecutive messages from the same sender.
  /// Only the last of a run draws a tail and the time/status row, so a burst
  /// reads as one block rather than repeating the clock on every line.
  final bool isFirstInGroup;
  final bool isLastInGroup;

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
    this.uploadProgress,
    this.isFirstInGroup = true,
    this.isLastInGroup = true,
    this.onRetry,
    this.showReadTime = false,
    this.onLongPress,
  });

  // Dark theme palette
  // Tail colours: the flat end of each bubble gradient, so the painted
  // triangle joins its bubble seamlessly.
  static const _myColor    = ChatTheme.violetDeep;
  static const _theirColor = Color(0xFF1A1530);

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble>
    with TickerProviderStateMixin {

  static const _triggerThreshold = 64.0;
  static const _maxSlide = 72.0;

  late final AnimationController _snapCtrl;

  /// Fade + rise as the bubble appears. Runs whenever the item is built into
  /// the viewport, so it covers both a new message and one scrolled back to —
  /// kept short and small so it reads as materialising, not as a slideshow.
  late final AnimationController _entryCtrl;

  Animation<double>? _snapAnim;
  double _slideOffset = 0;
  bool _triggerFired = false;

  // Tap recognizers for link spans — recreated per build, disposed with the state.
  final List<TapGestureRecognizer> _linkRecognizers = [];

  @override
  void initState() {
    super.initState();
    _snapCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..addListener(_onSnapTick);
    _entryCtrl = AnimationController(
      vsync: this,
      duration: ChatTheme.fast,
    )..forward();
  }

  void _onSnapTick() {
    if (_snapAnim != null && mounted) {
      setState(() => _slideOffset = _snapAnim!.value);
    }
  }

  @override
  void dispose() {
    _snapCtrl.dispose();
    _entryCtrl.dispose();
    _disposeLinkRecognizers();
    super.dispose();
  }

  void _disposeLinkRecognizers() {
    for (final r in _linkRecognizers) {
      r.dispose();
    }
    _linkRecognizers.clear();
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
    if (!isMe || widget.otherReadAt == null || widget.isPending) return false;
    return !widget.message.timestamp.isAfter(widget.otherReadAt!);
  }

  Widget _buildCallEventRow() {
    final text = widget.message.text;
    final lower = text.toLowerCase();
    final isVideo = lower.contains('video');
    final isMissed = lower.contains('missed');
    final time = DateFormat('HH:mm').format(widget.message.timestamp);

    final IconData icon;
    final Color iconColor;
    if (isMissed) {
      icon = isVideo ? Icons.videocam_off_rounded : Icons.phone_missed_rounded;
      iconColor = const Color(0xAAFF6B6B);
    } else {
      icon = isVideo ? Icons.videocam_rounded : Icons.call_rounded;
      iconColor = const Color(0x66FFFFFF);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: Row(
        children: [
          const Expanded(child: Divider(color: Color(0x33FFFFFF), thickness: 0.5)),
          const SizedBox(width: 10),
          Icon(icon, size: 13, color: iconColor),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: isMissed ? const Color(0xAAFF6B6B) : const Color(0x66FFFFFF),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            time,
            style: const TextStyle(fontSize: 11, color: Color(0x44FFFFFF)),
          ),
          const SizedBox(width: 10),
          const Expanded(child: Divider(color: Color(0x33FFFFFF), thickness: 0.5)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.message.type == MessageType.callEvent) {
      return _buildCallEventRow();
    }

    final message      = widget.message;
    final isPending    = widget.isPending;
    final isFailed     = widget.isFailed;
    final otherReadAt  = widget.otherReadAt;
    final showReadTime = widget.showReadTime;

    final textColor   = isMe ? Colors.white : ChatTheme.textPrimary;
    final metaColor   = isMe
        ? Colors.white.withValues(alpha: 0.70)
        : Colors.white.withValues(alpha: 0.45);

    // Square off the corner facing the previous bubble in a run, so a group
    // reads as one stacked column; the tail corner only opens on the last.
    const r = Radius.circular(ChatTheme.bubbleRadius);
    const tail = Radius.circular(ChatTheme.bubbleTailRadius);
    final borderRadius = BorderRadius.only(
      topLeft: isMe || widget.isFirstInGroup ? r : tail,
      topRight: !isMe || widget.isFirstInGroup ? r : tail,
      bottomLeft: isMe || !widget.isLastInGroup ? r : tail,
      bottomRight: !isMe || !widget.isLastInGroup ? r : tail,
    );

    final bubbleContent = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.74,
      ),
      decoration: BoxDecoration(
        gradient: isMe ? ChatTheme.myBubble : ChatTheme.theirBubble,
        borderRadius: borderRadius,
        // A violet-tinted shadow under my bubbles (rather than plain black) is
        // most of what makes them read as lit instead of pasted on.
        boxShadow: isMe
            ? ChatTheme.bubbleGlow
            : const [
                BoxShadow(
                    color: Color(0x40000000),
                    blurRadius: 8,
                    offset: Offset(0, 3)),
              ],
        border: isFailed
            ? Border.all(color: ChatTheme.danger.withValues(alpha: 0.8), width: 1)
            : Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      foregroundDecoration: isPending
          // Dim in place: fading the gradient itself would wash the colour out.
          ? BoxDecoration(
              color: ChatTheme.surface0.withValues(alpha: 0.35),
              borderRadius: borderRadius,
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (message.replyToText != null) _buildReplyPreview(textColor),
          _buildContent(context, textColor),
          // Only the last bubble of a run carries the clock and ticks.
          if (!widget.isLastInGroup)
            const SizedBox(height: 6)
          else
          Padding(
            padding: const EdgeInsets.only(right: 10, bottom: 6, left: 10),
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

    return FadeTransition(
      opacity: CurvedAnimation(parent: _entryCtrl, curve: Curves.easeOut),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(
            CurvedAnimation(parent: _entryCtrl, curve: ChatTheme.enter)),
        child: _buildGestureLayer(context, bubbleContent, otherReadAt, showReadTime),
      ),
    );
  }

  Widget _buildGestureLayer(BuildContext context, Widget bubbleContent,
      DateTime? otherReadAt, bool showReadTime) {
    final isMe = this.isMe;
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
                      // The tail is drawn once per run, on its last bubble;
                      // the others reserve the same width so the column of
                      // bubbles stays aligned.
                      if (!isMe)
                        SizedBox(
                          width: 8,
                          height: 12,
                          child: widget.isLastInGroup
                              ? CustomPaint(
                                  painter: _TailPainter(
                                      color: MessageBubble._theirColor,
                                      isMe: false),
                                )
                              : null,
                        ),
                      Flexible(child: bubbleContent),
                      if (isMe)
                        SizedBox(
                          width: 8,
                          height: 12,
                          child: widget.isLastInGroup
                              ? CustomPaint(
                                  painter: _TailPainter(
                                      color: MessageBubble._myColor, isMe: true),
                                )
                              : null,
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

  /// Text with http(s)/www URLs rendered as tappable, underlined spans that
  /// open in the external browser. Long-press still bubbles up to the message
  /// actions sheet — recognizers only claim taps.
  Widget _buildLinkifiedText(String text, Color textColor) {
    final chunks = splitLinks(text);
    final baseStyle = TextStyle(fontSize: 15, color: textColor);
    if (chunks.length == 1 && !chunks.first.isLink) {
      return Text(text, style: baseStyle);
    }
    _disposeLinkRecognizers();
    return Text.rich(
      TextSpan(
        children: chunks.map((c) {
          if (!c.isLink) return TextSpan(text: c.text, style: baseStyle);
          final recognizer = TapGestureRecognizer()
            ..onTap = () => _openLink(c.url);
          _linkRecognizers.add(recognizer);
          return TextSpan(
            text: c.text,
            recognizer: recognizer,
            style: baseStyle.copyWith(
              color: const Color(0xFF8AB4F8),
              decoration: TextDecoration.underline,
              decorationColor: const Color(0xFF8AB4F8),
            ),
          );
        }).toList(),
      ),
    );
  }

  Future<void> _openLink(String url) async {
    try {
      final ok = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
      if (!ok) LogService.w('Link', 'launchUrl returned false: $url');
    } catch (e) {
      LogService.w('Link', 'Could not open $url: $e');
    }
  }

  Widget _buildContent(BuildContext context, Color textColor) {
    final msg = widget.message;
    // Still uploading (or failed): there is no download URL yet, so show the
    // local preview with its progress ring instead of the remote media.
    if (msg.mediaUrl == null &&
        (msg.type == MessageType.image ||
            msg.type == MessageType.gif ||
            msg.type == MessageType.video)) {
      return _UploadPreview(
        previewPath: msg.previewPath,
        type: msg.type,
        progress: widget.uploadProgress,
      );
    }
    switch (msg.type) {
      case MessageType.text:
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
          child: _buildLinkifiedText(msg.text, textColor),
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
                  ),
                ),
              ),
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(12)),
                child: _EncryptedImage(
                  url: msg.mediaUrl!,
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
              ),
            ),
          ],
        );

      case MessageType.video:
        return _InlineVideoPlayer(
          url: msg.mediaUrl!,
          fileName: msg.fileName ?? '${msg.id}.mp4',
          messageId: msg.id,
          thumbUrl: msg.thumbUrl,
        );

      case MessageType.file:
        return _FileMessageTile(message: msg);

      case MessageType.audio:
        return _AudioMessageTile(message: msg);

      case MessageType.callEvent:
        // Handled by _buildCallEventRow() before reaching here — fallback only.
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
          child: Text(widget.message.text,
              style: const TextStyle(fontSize: 12, color: Colors.white38)),
        );
    }
  }
}
