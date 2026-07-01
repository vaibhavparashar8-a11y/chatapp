// lib/screens/chat_screen.dart

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import '../constants.dart';
import '../controllers/chat_controller.dart';
import '../models/message.dart';
import '../repositories/firebase_chat_repository.dart';
import '../repositories/i_chat_repository.dart';
import '../features/call/call_service.dart';
import '../services/chat_service.dart';
import '../widgets/message_bubble.dart';
import '../features/call/incoming_call_dialog.dart';
import '../features/call/call_screen.dart';
import '../utils/time_utils.dart';

part 'chat/load_more_indicator.dart';
part 'chat/attach_option.dart';
part 'chat/typing_indicator.dart';
part 'chat/floating_video_overlay.dart';

class ChatScreen extends StatefulWidget {
  /// Injectable for testing; defaults to [FirebaseChatRepository] in production.
  final IChatRepository? repository;
  /// Injectable for testing; defaults to [ChatService.callSignalStream] in production.
  final Stream<Map<String, dynamic>?> Function()? callSignalProvider;

  const ChatScreen({super.key, this.repository, this.callSignalProvider});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

/// Thin UI layer. All business logic lives in [ChatController].
/// This class only handles:
///   - Widget building (delegated to private _build* methods)
///   - Navigation (requires BuildContext)
///   - App lifecycle → navigation
///   - Call signal dialog (requires BuildContext)
///   - Device input (image picker, file picker)
class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  // Flutter-specific controllers that need a widget lifecycle
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _picker = ImagePicker();

  // Call signal subscription stays here — needs context for showDialog
  StreamSubscription<Map<String, dynamic>?>? _callSub;

  // Debounce timer for presence: prevents brief pauses (system dialogs, etc.)
  // from immediately marking the user offline (fix for issue #11).
  Timer? _leaveTimer;

  // Business logic lives entirely in the controller
  late final ChatController _ctrl;

  // Incremented each time we return from the call screen so _FloatingVideoOverlay
  // is force-reconstructed and picks up a fresh platform surface.
  int _floatingVideoEpoch = 0;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _ctrl = ChatController(
      widget.repository ?? const FirebaseChatRepository(),
      onUploadError: (msg) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Upload failed: $msg'),
          backgroundColor: Colors.red[700],
          duration: const Duration(seconds: 3),
        ));
      },
    );
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    _ctrl.init();
    _listenForCalls();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Cancel any pending offline write — user came back before the grace period.
      _leaveTimer?.cancel();
      _ctrl.enter();
    } else if (state == AppLifecycleState.paused) {
      // Debounce: only write offline after 5 s of being in background.
      // System dialogs (notification permission, in-call UI, etc.) trigger
      // `paused` briefly — without debouncing they would reset lastSeen to
      // "just now" and make the user appear offline to the other person.
      _leaveTimer?.cancel();
      _leaveTimer = Timer(const Duration(seconds: 5), () {
        _ctrl.leave();
        if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      });
    } else if (state == AppLifecycleState.detached) {
      // App is being killed — write offline immediately, no grace period.
      _leaveTimer?.cancel();
      _ctrl.leave();
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    // reverse: true means maxScrollExtent is at the visual top (oldest messages)
    if (pos.pixels >= pos.maxScrollExtent - 300) {
      _ctrl.loadMoreMessages();
    }
  }

  @override
  void dispose() {
    _leaveTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_onScroll);
    _callSub?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  // ── Call signaling (context-dependent, stays in widget layer) ─────────────

  void _listenForCalls() {
    final stream = widget.callSignalProvider != null
        ? widget.callSignalProvider!()
        : ChatService.callSignalStream();
    _callSub = stream.listen((signal) {
      if (signal == null) return;
      if (signal['from'] == mySenderId) return;
      if (signal['status'] != 'ringing') return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => IncomingCallDialog(
          callType: signal['type'] ?? 'audio',
          onAccept: () async {
            Navigator.pop(context);
            await ChatService.updateCallStatus('accepted');
            if (mounted) {
              Navigator.push(context, MaterialPageRoute(
                builder: (_) => CallScreen(
                  isVideo: signal['type'] == 'video',
                  isCaller: false,
                  callToken: signal['token'] as String? ?? '',
                ),
              ));
            }
          },
          onDecline: () async {
            Navigator.pop(context);
            await ChatService.updateCallStatus('declined');
          },
        ),
      );
    });
  }

  // ── Device input (file system / camera access, stays in widget layer) ─────

  Future<void> _sendText() async {
    final text = _textController.text;
    // Clear immediately so a second tap while the Firestore write is in flight
    // hits an empty field and is rejected by the controller's isEmpty guard.
    _textController.clear();
    await _ctrl.sendText(text);
  }

  Future<void> _sendImage(ImageSource source) async {
    _ctrl.setShowAttachMenu(false);
    final picked = await _picker.pickImage(source: source, imageQuality: 70);
    if (picked == null) return;
    await _ctrl.sendMedia(File(picked.path), MessageType.image);
  }

  Future<void> _sendVideo() async {
    _ctrl.setShowAttachMenu(false);
    final picked = await _picker.pickVideo(source: ImageSource.gallery);
    if (picked == null) return;
    await _ctrl.sendMedia(File(picked.path), MessageType.video);
  }

  Future<void> _sendFile() async {
    _ctrl.setShowAttachMenu(false);
    final result = await FilePicker.platform.pickFiles(allowMultiple: false, type: FileType.any);
    if (result == null || result.files.isEmpty) return;
    final f = result.files.first;
    if (f.path == null) return;
    final ext = f.extension?.toLowerCase() ?? '';
    var type = MessageType.file;
    if (['jpg', 'jpeg', 'png', 'webp'].contains(ext)) type = MessageType.image;
    if (['mp4', 'mkv', 'mov', 'avi'].contains(ext)) type = MessageType.video;
    if (ext == 'gif') type = MessageType.gif;
    if (['mp3', 'wav', 'aac', 'm4a', 'ogg'].contains(ext)) type = MessageType.audio;
    await _ctrl.sendMedia(File(f.path!), type, fileName: f.name);
  }

  void _startCall(bool isVideo) => Navigator.push(context,
      MaterialPageRoute(builder: (_) => CallScreen(isVideo: isVideo, isCaller: true)));

  Future<void> _returnToCall() async {
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => CallScreen(
        isVideo: isCallVideo,
        isCaller: isCallCaller,
        callToken: activeCallToken,
        isReconnecting: true,
      ),
    ));
    // Force _FloatingVideoOverlay to fully reconstruct so AgoraVideoView gets
    // a fresh platform surface — the old one goes stale when CallScreen disposes.
    if (mounted) setState(() => _floatingVideoEpoch++);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _ctrl,
      builder: (context, _) => PopScope(
        onPopInvokedWithResult: (_, __) => _ctrl.leave(),
        child: Scaffold(
          appBar: _buildAppBar(),
          body: Stack(children: [
            Column(children: [
              _buildMiniCallBar(),
              if (_ctrl.uploadProgress != null) _buildUploadBanner(),
              Expanded(
                child: ColoredBox(
                  color: const Color(0xFF0F0F1E),
                  child: _buildMessageList(),
                ),
              ),
              if (_ctrl.replyingTo != null) _buildReplyBar(),
              if (_ctrl.showAttachMenu) _buildAttachMenu(),
              _buildInputBar(),
            ]),
            _buildFloatingVideo(),
          ]),
        ),
      ),
    );
  }

  // ── Private build methods (one per UI section) ─────────────────────────────

  AppBar _buildAppBar() {
    return AppBar(
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
      elevation: 0,
      flexibleSpace: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1C0544), Color(0xFF3D1A78)],
          ),
        ),
      ),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () async {
          await _ctrl.leave();
          if (context.mounted) Navigator.pop(context);
        },
      ),
      title: Row(children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: Colors.white24,
          child: Text(
            otherDisplayName.isNotEmpty ? otherDisplayName[0].toUpperCase() : '?',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ),
        const SizedBox(width: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(otherDisplayName,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          Text(
            _ctrl.otherTyping
                ? 'typing...'
                : _ctrl.otherOnline
                    ? 'online'
                    : _ctrl.otherLastSeen != null
                        ? 'last seen ${formatLastSeen(_ctrl.otherLastSeen!)}'
                        : 'end-to-end encrypted',
            style: TextStyle(
              fontSize: 11,
              color: _ctrl.otherTyping
                  ? const Color(0xFFD8B4FE)
                  : _ctrl.otherOnline
                      ? const Color(0xFF34D399)
                      : Colors.white70,
              fontStyle: _ctrl.otherTyping ? FontStyle.italic : FontStyle.normal,
            ),
          ),
        ]),
      ]),
      actions: [
        IconButton(icon: const Icon(Icons.call), onPressed: () => _startCall(false), tooltip: 'Audio call'),
        IconButton(icon: const Icon(Icons.videocam), onPressed: () => _startCall(true), tooltip: 'Video call'),
        IconButton(
          icon: const Icon(Icons.delete_sweep),
          tooltip: 'Clear my chat',
          onPressed: () async {
            await _ctrl.clearMyView();
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Chat cleared for you'), duration: Duration(seconds: 1)),
              );
            }
          },
        ),
      ],
    );
  }

  Widget _buildMiniCallBar() {
    return ValueListenableBuilder<bool>(
      valueListenable: callActiveNotifier,
      builder: (_, active, __) {
        if (!active || isCallVideo) return const SizedBox.shrink();
        return GestureDetector(
          onTap: _returnToCall,
          child: Container(
            color: const Color(0xFF1C1040),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(children: [
              const Icon(Icons.call, color: Colors.white, size: 18),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Tap to return to call',
                    style: TextStyle(color: Colors.white, fontSize: 13)),
              ),
              GestureDetector(
                onTap: () async {
                  callActiveNotifier.value = false;
                  await CallService.leaveCall();
                },
                child: const Icon(Icons.call_end, color: Colors.redAccent, size: 22),
              ),
            ]),
          ),
        );
      },
    );
  }

  Widget _buildUploadBanner() {
    return Column(children: [
      LinearProgressIndicator(
        value: _ctrl.uploadProgress,
        minHeight: 4,
        backgroundColor: Colors.white12,
        color: const Color(0xFF7C3AED),
      ),
      Container(
        color: const Color(0xFF1A1040),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          'Uploading… ${((_ctrl.uploadProgress ?? 0) * 100).toStringAsFixed(0)}%',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, color: Color(0xFFA78BFA)),
        ),
      ),
    ]);
  }

  Widget _buildMessageList() {
    final messages = _ctrl.messages;
    if (messages.isEmpty && !_ctrl.otherTyping) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.lock, size: 48, color: Colors.white.withValues(alpha: 0.25)),
          const SizedBox(height: 12),
          Text('Private & anonymous',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 16, fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          Text('Messages are deleted when you leave',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.38), fontSize: 13)),
        ]),
      );
    }

    // Most recent message I sent that the other person has already read.
    // Only that one bubble shows the "Read HH:mm" label beneath it.
    String? lastReadMsgId;
    if (_ctrl.otherReadAt != null) {
      for (int i = messages.length - 1; i >= 0; i--) {
        final m = messages[i];
        if (m.sender == mySenderId &&
            !m.timestamp.isAfter(_ctrl.otherReadAt!)) {
          lastReadMsgId = m.id;
          break;
        }
      }
    }

    // With reverse: true, index 0 = visual bottom (newest).
    // The load-more indicator sits at the very top (last index = oldest end).
    final typingOffset = _ctrl.otherTyping ? 1 : 0;
    final loadMoreOffset = _ctrl.hasMoreMessages ? 1 : 0;

    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      itemCount: messages.length + typingOffset + loadMoreOffset,
      itemBuilder: (_, i) {
        // Typing indicator at visual bottom (index 0)
        if (_ctrl.otherTyping && i == 0) return const _TypingIndicator();

        // Load-more indicator at visual top (last index)
        if (_ctrl.hasMoreMessages && i == messages.length + typingOffset) {
          return _LoadMoreIndicator(loading: _ctrl.loadingMore);
        }

        final msg = messages[messages.length - 1 - (i - typingOffset)];
        final isPending = _ctrl.pendingIds.contains(msg.id);
        final isFailed = _ctrl.failedIds.contains(msg.id);

        return MessageBubble(
          message: msg,
          otherReadAt: _ctrl.otherReadAt,
          isPending: isPending,
          isFailed: isFailed,
          onRetry: isFailed ? () => _ctrl.retryMessage(msg.id) : null,
          onReply: _ctrl.setReplyingTo,
          showReadTime: !isPending && !isFailed && msg.id == lastReadMsgId,
          onLongPress: isPending || isFailed ? null : () => _showMessageActions(msg),
        );
      },
    );
  }

  Widget _buildReplyBar() {
    final reply = _ctrl.replyingTo!;
    return Container(
      color: const Color(0xFF1A1040),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(children: [
        Container(width: 3, height: 36, color: const Color(0xFFA78BFA)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                reply.sender == mySenderId ? myDisplayName : otherDisplayName,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFFA78BFA)),
              ),
              Text(
                reply.type == MessageType.text ? reply.text : '[${reply.type.name}]',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.55)),
              ),
            ],
          ),
        ),
        IconButton(
          icon: Icon(Icons.close, size: 18, color: Colors.white.withValues(alpha: 0.6)),
          onPressed: () => _ctrl.setReplyingTo(null),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
      ]),
    );
  }

  Widget _buildAttachMenu() {
    return Container(
      color: const Color(0xFF14112A),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _AttachOption(icon: Icons.photo_camera, label: 'Camera', color: Colors.purple,
              onTap: () => _sendImage(ImageSource.camera)),
          _AttachOption(icon: Icons.photo, label: 'Gallery', color: Colors.pink,
              onTap: () => _sendImage(ImageSource.gallery)),
          _AttachOption(icon: Icons.videocam, label: 'Video', color: Colors.orange,
              onTap: _sendVideo),
          _AttachOption(icon: Icons.insert_drive_file, label: 'File', color: Colors.blue,
              onTap: _sendFile),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return Material(
      elevation: 6,
      color: const Color(0xFF13102A),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(children: [
            IconButton(
              icon: Icon(
                _ctrl.showAttachMenu ? Icons.close : Icons.attach_file,
                color: const Color(0xFFA78BFA),
              ),
              onPressed: () => _ctrl.setShowAttachMenu(!_ctrl.showAttachMenu),
            ),
            Expanded(
              child: TextField(
                controller: _textController,
                onTap: () => _ctrl.setShowAttachMenu(false),
                onChanged: _ctrl.onTypingChanged,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(color: Colors.white),
                maxLines: 4,
                minLines: 1,
                decoration: InputDecoration(
                  hintText: 'Message',
                  hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.35)),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: const Color(0xFF1E1A40),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                onSubmitted: (_) => _sendText(),
              ),
            ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: _ctrl.sending ? null : _sendText,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _ctrl.sending ? Colors.white24 : const Color(0xFF6D28D9),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.send, color: Colors.white, size: 20),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // ── Message action sheet ───────────────────────────────────────────────────

  void _showMessageActions(Message msg) {
    final isMe = msg.sender == mySenderId;
    final canModify = ChatController.canModify(msg);
    final canEdit   = isMe && canModify && msg.type == MessageType.text;
    final canCopy   = msg.type == MessageType.text && msg.text.isNotEmpty;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1040),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (canEdit)
              _actionTile(Icons.edit_outlined, 'Edit', () {
                Navigator.pop(context);
                _showEditDialog(msg);
              }),
            _actionTile(Icons.reply_outlined, 'Reply', () {
              Navigator.pop(context);
              _ctrl.setReplyingTo(msg);
            }),
            if (canCopy)
              _actionTile(Icons.copy_outlined, 'Copy', () {
                Navigator.pop(context);
                Clipboard.setData(ClipboardData(text: msg.text));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Copied to clipboard'),
                    duration: Duration(seconds: 1),
                  ),
                );
              }),
            // Delete for me (my msg within 1 h → Firestore delete; otherwise hide locally)
            _actionTile(Icons.delete_outline, 'Delete', () {
              Navigator.pop(context);
              if (isMe && canModify) {
                _ctrl.deleteMessage(msg.id);
              } else {
                _ctrl.hideMessage(msg.id);
              }
            }, destructive: true),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _actionTile(IconData icon, String label, VoidCallback onTap,
      {bool destructive = false}) {
    final color = destructive ? Colors.redAccent : Colors.white;
    return ListTile(
      leading: Icon(icon, color: color, size: 22),
      title: Text(label, style: TextStyle(color: color, fontSize: 15)),
      onTap: onTap,
    );
  }

  void _showEditDialog(Message msg) {
    final editCtrl = TextEditingController(text: msg.text);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1040),
        title: const Text('Edit message',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: editCtrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          maxLines: null,
          decoration: InputDecoration(
            hintText: 'Edit your message…',
            hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.35)),
            enabledBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: Colors.white24),
            ),
            focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: Color(0xFFA78BFA)),
            ),
            filled: true,
            fillColor: const Color(0xFF1E1A40),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              final newText = editCtrl.text.trim();
              if (newText.isNotEmpty && newText != msg.text) {
                _ctrl.editMessage(msg.id, newText);
              }
              Navigator.pop(context);
            },
            child: const Text('Save',
                style: TextStyle(color: Color(0xFFA78BFA))),
          ),
        ],
      ),
    );
  }

  Widget _buildFloatingVideo() {
    return ValueListenableBuilder<bool>(
      valueListenable: callActiveNotifier,
      builder: (_, active, __) {
        if (!active || !isCallVideo) return const SizedBox.shrink();
        return _FloatingVideoOverlay(
          key: ValueKey(_floatingVideoEpoch),
          onTap: _returnToCall,
          onEnd: () async {
            callActiveNotifier.value = false;
            await CallService.leaveCall();
          },
        );
      },
    );
  }
}

