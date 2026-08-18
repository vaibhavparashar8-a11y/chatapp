// lib/screens/chat_screen.dart

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import '../constants.dart';
import '../controllers/chat_controller.dart';
import '../models/message.dart';
import '../repositories/firebase_chat_repository.dart';
import '../repositories/i_chat_repository.dart';
import '../features/call/call_service.dart';
import '../features/call/end_minimized_call.dart';
import '../services/chat_service.dart';
import '../widgets/message_bubble.dart';
import '../features/call/incoming_call_dialog.dart';
import '../features/call/call_screen.dart';
import '../services/device_service.dart';
import '../services/giphy_service.dart';
import '../services/log_service.dart';
import '../theme/chat_theme.dart';
import '../utils/emoji_data.dart';
import '../utils/message_grouping.dart';
import '../utils/time_utils.dart';
import 'calls_screen.dart';

part 'chat/aurora_background.dart';
part 'chat/load_more_indicator.dart';
part 'chat/attach_option.dart';
part 'chat/typing_indicator.dart';
part 'chat/emoji_panel.dart';
part 'chat/composer_input.dart';
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
class _ChatScreenState extends State<ChatScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  // Flutter-specific controllers that need a widget lifecycle
  final _textController = TextEditingController();
  // Held so the emoji button can hand focus back to the field (and the system
  // keyboard with it) when the panel closes.
  final _inputFocus = FocusNode();
  final _scrollController = ScrollController();
  final _picker = ImagePicker();
  late TabController _tabCtrl;

  // Call signal subscription stays here — needs context for showDialog
  StreamSubscription<Map<String, dynamic>?>? _callSub;
  // Prevent duplicate incoming-call dialogs when the rooms document re-emits
  // before updateCallStatus('accepted') has committed to Firestore.
  bool _incomingDialogShowing = false;

  // Debounce timer for presence: prevents brief pauses (system dialogs, etc.)
  // from immediately marking the user offline (fix for issue #11).
  Timer? _leaveTimer;

  // Business logic lives entirely in the controller
  late final ChatController _ctrl;

  // Incremented each time we return from the call screen so _FloatingVideoOverlay
  // is force-reconstructed and picks up a fresh platform surface.
  int _floatingVideoEpoch = 0;

  // Last time the other device opened the app (null = never / unknown).
  DateTime? _otherLastOpened;
  StreamSubscription<DateTime?>? _otherLastOpenedSub;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _ctrl = ChatController(
      widget.repository ?? const FirebaseChatRepository(),
      // Lets the controller skip codec-heavy work (video transcoding) while a
      // call is live — competing for MediaCodec can take the process down.
      isCallActive: () => CallService.inCall,
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
    DeviceService.writeHeartbeat();
    final otherId = mySenderId == 'A' ? 'B' : 'A';
    _otherLastOpenedSub = DeviceService.otherLastOpenedStream(otherId).listen(
      (ts) { if (mounted) setState(() => _otherLastOpened = ts); },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _leaveTimer?.cancel();
      _ctrl.enter();
    } else if (state == AppLifecycleState.inactive) {
      // Some Android devices only fire `inactive` for incoming call overlays
      // and never follow up with `paused`/`hidden`. Start the leave timer only
      // if one isn't already running (??= guards against restarting it on the
      // normal resumed→inactive→paused sequence where `hidden`/`paused` also fire).
      _leaveTimer ??= Timer(const Duration(seconds: 8), () {
        _leaveTimer = null;
        _ctrl.leave();
        // CallService.inCall covers full-screen calls; callActiveNotifier
        // only covers minimized ones. Popping during a full-screen call
        // disposes CallScreen and kills the Agora engine.
        if (mounted && !callActiveNotifier.value && !CallService.inCall) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      });
    } else if (state == AppLifecycleState.hidden ||
               state == AppLifecycleState.paused) {
      // `hidden` fires on newer Android when going to recent apps and may
      // never proceed to `paused` — handle both so the timer always starts.
      // Timer restarts on each event, so the 5s delay is from the last one.
      _leaveTimer?.cancel();
      _leaveTimer = Timer(const Duration(seconds: 5), () {
        _ctrl.leave();
        // Skip navigation while any call is live: minimized (notifier) or
        // full-screen (CallService.inCall) — popping would dispose CallScreen
        // and release the Agora engine mid-call.
        if (mounted && !callActiveNotifier.value && !CallService.inCall) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      });
    } else if (state == AppLifecycleState.detached) {
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
    _otherLastOpenedSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_onScroll);
    _callSub?.cancel();
    _textController.dispose();
    _inputFocus.dispose();
    _scrollController.dispose();
    _tabCtrl.dispose();
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

      final status = signal['status'] as String?;

      // Caller cancelled/ended before B answered — auto-dismiss the popup
      if (_incomingDialogShowing && status != 'ringing') {
        _incomingDialogShowing = false;
        if (mounted) Navigator.of(context).pop();
        return;
      }

      if (status != 'ringing') return;
      // Guard 1: already in an active call (e.g. minimized call bar is showing)
      if (callActiveNotifier.value) return;
      // Guard 2: dialog already on screen — rooms doc re-emitted before
      // updateCallStatus('accepted') committed, which would show a second dialog
      if (_incomingDialogShowing) return;

      _incomingDialogShowing = true;
      // Tell the caller its call actually reached this device — flips the
      // caller's "Calling..." label to "Ringing...".
      unawaited(ChatService.markCallDelivered());
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => IncomingCallDialog(
          callType: signal['type'] ?? 'audio',
          onAccept: () async {
            _incomingDialogShowing = false;
            Navigator.pop(context);
            await ChatService.updateCallStatus('accepted');
            if (mounted) {
              _ctrl.pauseMarkRead();
              await Navigator.push(context, MaterialPageRoute(
                builder: (_) => CallScreen(
                  isVideo: signal['type'] == 'video',
                  isCaller: false,
                  callToken: signal['token'] as String? ?? '',
                ),
              ));
              if (mounted) _ctrl.resumeMarkRead();
            }
          },
          onDecline: () async {
            _incomingDialogShowing = false;
            Navigator.pop(context);
            await ChatService.updateCallStatus('declined');
          },
        ),
      ).whenComplete(() => _incomingDialogShowing = false);
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
    if (source == ImageSource.camera) {
      // Camera always single shot
      final picked = await _picker.pickImage(source: source, imageQuality: 70);
      if (picked == null) return;
      await _ctrl.sendMedia(File(picked.path), MessageType.image);
    } else {
      // Gallery — allow multi-select
      final picked = await _picker.pickMultiImage(imageQuality: 70);
      if (picked.isEmpty) return;
      for (final xf in picked) {
        await _ctrl.sendMedia(File(xf.path), MessageType.image);
      }
    }
  }

  Future<void> _recordVideo() async {
    _ctrl.setShowAttachMenu(false);
    final picked = await _picker.pickVideo(source: ImageSource.camera);
    if (picked == null) return;
    await _ctrl.sendMedia(File(picked.path), MessageType.video);
  }

  Future<void> _sendVideo() async {
    _ctrl.setShowAttachMenu(false);
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.video,
    );
    if (result == null || result.files.isEmpty) return;
    for (final f in result.files) {
      if (f.path == null) continue;
      await _ctrl.sendMedia(File(f.path!), MessageType.video, fileName: f.name);
    }
  }

  Future<void> _sendAudio() async {
    _ctrl.setShowAttachMenu(false);
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.audio,
    );
    if (result == null || result.files.isEmpty) return;
    for (final f in result.files) {
      if (f.path == null) continue;
      await _ctrl.sendMedia(File(f.path!), MessageType.audio, fileName: f.name);
    }
  }

  Future<void> _sendFile() async {
    _ctrl.setShowAttachMenu(false);
    final result = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.any);
    if (result == null || result.files.isEmpty) return;
    for (final f in result.files) {
      if (f.path == null) continue;
      final ext = f.extension?.toLowerCase() ?? '';
      var type = MessageType.file;
      if (['jpg', 'jpeg', 'png', 'webp'].contains(ext)) type = MessageType.image;
      if (['mp4', 'mkv', 'mov', 'avi'].contains(ext)) type = MessageType.video;
      if (ext == 'gif') type = MessageType.gif;
      if (['mp3', 'wav', 'aac', 'm4a', 'ogg'].contains(ext)) type = MessageType.audio;
      await _ctrl.sendMedia(File(f.path!), type, fileName: f.name);
    }
  }

  void _startCall(bool isVideo) {
    _ctrl.pauseMarkRead();
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CallScreen(isVideo: isVideo, isCaller: true)),
    ).then((_) { if (mounted) _ctrl.resumeMarkRead(); });
  }

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
              Expanded(
                child: TabBarView(
                  controller: _tabCtrl,
                  // Disable swipe: messages use horizontal drag for swipe-to-reply
                  // and the gestures conflict.  Tabs are still switchable by tapping.
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    // ── Chat tab ────────────────────────────────────────────
                    Column(children: [
                      Expanded(
                        child: _AuroraBackground(child: _buildMessageList()),
                      ),
                      if (_ctrl.replyingTo != null) _buildReplyBar(),
                      if (_ctrl.showAttachMenu) _buildAttachMenu(),
                      _buildInputBar(),
                      if (_ctrl.showEmojiPanel) _buildEmojiPanel(),
                    ]),
                    // ── Calls tab ───────────────────────────────────────────
                    CallsScreen(onStartCall: _startCall),
                  ],
                ),
              ),
            ]),
            _buildFloatingVideo(),
          ]),
        ),
      ),
    );
  }

  // ── Private build methods (one per UI section) ─────────────────────────────

  String _formatOtherInstallStatus() {
    final ts = _otherLastOpened;
    if (ts == null) return 'app not yet opened on other device';
    final diff = DateTime.now().difference(ts);
    if (diff.inDays >= 30) return 'other device not seen in ${diff.inDays} days — may be uninstalled';
    if (diff.inDays >= 1) return 'other device: opened ${diff.inDays}d ago';
    if (diff.inHours >= 1) return 'other device: opened ${diff.inHours}h ago';
    return 'other device: opened recently';
  }

  AppBar _buildAppBar() {
    return AppBar(
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
      elevation: 0,
      flexibleSpace: Container(
        decoration: const BoxDecoration(
          gradient: ChatTheme.appBar,
          boxShadow: [
            BoxShadow(color: Color(0x59000000), blurRadius: 14, offset: Offset(0, 3)),
          ],
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
        // Avatar with a live presence ring — green while they are online, so
        // status is readable at a glance and not only as small text.
        Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: _ctrl.otherOnline ? ChatTheme.success : Colors.white24,
              width: 1.5,
            ),
            boxShadow: _ctrl.otherOnline
                ? ChatTheme.glow(ChatTheme.success, blur: 8, opacity: 0.35)
                : null,
          ),
          child: Container(
            width: 34,
            height: 34,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: ChatTheme.sendButton,
            ),
            alignment: Alignment.center,
            child: Text(
              otherDisplayName.isNotEmpty
                  ? otherDisplayName[0].toUpperCase()
                  : '?',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(otherDisplayName,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2)),
          Text(
            _ctrl.otherTyping
                ? 'typing...'
                : _ctrl.otherOnline
                    ? 'online'
                    : _ctrl.otherLastSeen != null
                        ? 'last seen ${formatLastSeen(_ctrl.otherLastSeen!)}'
                        : _formatOtherInstallStatus(),
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
          tooltip: 'Clear chat',
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Clear chat?'),
                content: const Text(
                    'Messages are removed from your view now. Each one is '
                    'permanently deleted once the other person clears it too.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Clear')),
                ],
              ),
            );
            if (ok != true) return;
            await _ctrl.clearChat();
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Chat cleared for you'),
                    duration: Duration(seconds: 1)),
              );
            }
          },
        ),
      ],
      bottom: TabBar(
        controller: _tabCtrl,
        indicatorColor: Colors.white,
        indicatorWeight: 2,
        labelColor: Colors.white,
        unselectedLabelColor: Colors.white54,
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5),
        tabs: const [
          Tab(text: 'CHAT'),
          Tab(text: 'CALLS'),
        ],
      ),
    );
  }

  Widget _buildMiniCallBar() {
    return ValueListenableBuilder<bool>(
      valueListenable: callActiveNotifier,
      builder: (_, active, __) {
        // Cross-check CallService.inCall: the notifier is a process-wide global
        // that can be left stale-true by an atypical teardown; inCall is tied
        // to the actual engine lifetime, so require both (phantom-bar guard).
        if (!active || !CallService.inCall || isCallVideo) {
          return const SizedBox.shrink();
        }
        return GestureDetector(
          onTap: _returnToCall,
          child: Container(
            color: ChatTheme.surface2,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(children: [
              const Icon(Icons.call, color: Colors.white, size: 18),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Tap to return to call',
                    style: TextStyle(color: Colors.white, fontSize: 13)),
              ),
              GestureDetector(
                onTap: endMinimizedCall,
                child: const Icon(Icons.call_end, color: Colors.redAccent, size: 22),
              ),
            ]),
          ),
        );
      },
    );
  }

  Widget _buildMessageList() {
    final messages = _ctrl.messages;
    if (messages.isEmpty && !_ctrl.otherTyping) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          // Haloed lock — the empty state is the first thing a new install
          // shows, so it carries the same lit-from-within look as the bubbles.
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [
                ChatTheme.violet.withValues(alpha: 0.35),
                ChatTheme.violet.withValues(alpha: 0.02),
              ]),
            ),
            child: const Icon(Icons.lock_rounded,
                size: 38, color: ChatTheme.accent),
          ),
          const SizedBox(height: 18),
          const Text('Private & anonymous',
              style: TextStyle(
                  color: ChatTheme.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2)),
          const SizedBox(height: 6),
          const Text('Messages are deleted when you leave',
              style: TextStyle(color: ChatTheme.textFaint, fontSize: 13)),
        ]),
      );
    }

    // Most recent message I sent that the other person has already read.
    // Only that one bubble shows the "Read HH:mm" label beneath it.
    String? lastReadMsgId;
    if (_ctrl.otherReadAt != null) {
      final pendingIds = _ctrl.pendingIds;
      for (int i = messages.length - 1; i >= 0; i--) {
        final m = messages[i];
        if (m.sender == mySenderId &&
            !pendingIds.contains(m.id) &&
            !m.timestamp.isAfter(_ctrl.otherReadAt!)) {
          lastReadMsgId = m.id;
          break;
        }
      }
    }

    // Date chips and bubble runs, decided in one pure pass (see
    // utils/message_grouping.dart) so the rules stay testable.
    final layouts = layoutMessages(messages);

    // With reverse: true, index 0 = visual bottom (newest).
    // The load-more indicator sits at the very top (last index = oldest end).
    final typingOffset = _ctrl.otherTyping ? 1 : 0;
    final loadMoreOffset = _ctrl.hasMoreMessages ? 1 : 0;

    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      itemCount: messages.length + typingOffset + loadMoreOffset,
      itemBuilder: (_, i) {
        // Typing indicator at visual bottom (index 0)
        if (_ctrl.otherTyping && i == 0) return const _TypingIndicator();

        // Load-more indicator at visual top (last index)
        if (_ctrl.hasMoreMessages && i == messages.length + typingOffset) {
          return _LoadMoreIndicator(loading: _ctrl.loadingMore);
        }

        final index = messages.length - 1 - (i - typingOffset);
        final msg = messages[index];
        final layout = layouts[index];
        final isPending = _ctrl.pendingIds.contains(msg.id);
        final isFailed = _ctrl.failedIds.contains(msg.id);

        final bubble = MessageBubble(
          message: msg,
          otherReadAt: _ctrl.otherReadAt,
          isPending: isPending,
          isFailed: isFailed,
          uploadProgress: _ctrl.uploadProgressFor(msg.id),
          isFirstInGroup: layout.isFirstInGroup,
          isLastInGroup: layout.isLastInGroup,
          onRetry: isFailed ? () => _ctrl.retryMessage(msg.id) : null,
          onReply: msg.type == MessageType.callEvent ? null : _ctrl.setReplyingTo,
          showReadTime: !isPending && !isFailed && msg.id == lastReadMsgId,
          onLongPress: isPending || isFailed || msg.type == MessageType.callEvent
              ? null
              : () => _showMessageActions(msg),
        );

        if (!layout.showDateChip) return bubble;
        // The chip belongs above its message; the list is reversed, so it is
        // the second child of the column, not the first.
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [_DateSeparator(date: msg.timestamp), bubble],
        );
      },
    );
  }

  Widget _buildReplyBar() {
    final reply = _ctrl.replyingTo!;
    return Container(
      color: ChatTheme.surface1,
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
    return _AttachSheet(
      options: [
        _AttachOption(
            icon: Icons.photo_camera_rounded,
            label: 'Camera',
            color: const Color(0xFF8B5CF6),
            onTap: () => _sendImage(ImageSource.camera)),
        _AttachOption(
            icon: Icons.photo_library_rounded,
            label: 'Gallery',
            color: const Color(0xFFEC4899),
            onTap: () => _sendImage(ImageSource.gallery)),
        _AttachOption(
            icon: Icons.videocam_rounded,
            label: 'Record',
            color: const Color(0xFFEF4444),
            onTap: _recordVideo),
        _AttachOption(
            icon: Icons.video_library_rounded,
            label: 'Video',
            color: const Color(0xFFF59E0B),
            onTap: _sendVideo),
        _AttachOption(
            icon: Icons.headphones_rounded,
            label: 'Audio',
            color: const Color(0xFF10B981),
            onTap: _sendAudio),
        _AttachOption(
            icon: Icons.description_rounded,
            label: 'Document',
            color: const Color(0xFF3B82F6),
            onTap: _sendFile),
        _AttachOption(
            icon: Icons.gif_box_rounded,
            label: 'GIF',
            color: const Color(0xFF06B6D4),
            onTap: () => _toggleEmojiPanel(onGifTab: true)),
      ],
    );
  }

  Widget _buildEmojiPanel() {
    final onGif = _ctrl.emojiPanelOnGifTab;
    return _EmojiGifPanel(
      // Keyed on the tab so re-opening on the other side rebuilds the panel:
      // TabController.initialIndex only applies when the controller is created.
      key: ValueKey(onGif),
      initialTab: onGif ? 1 : 0,
      onEmoji: _insertEmoji,
      onGif: _sendGif,
      onBackspace: _backspace,
    );
  }

  /// Emoji button in the composer. Hides the system keyboard when opening so
  /// the panel isn't stacked on top of it; closing hands focus back, which is
  /// what the keyboard icon then means.
  void _toggleEmojiPanel({bool onGifTab = false}) {
    final opening = !_ctrl.showEmojiPanel || (onGifTab && !_ctrl.emojiPanelOnGifTab);
    if (opening) {
      FocusScope.of(context).unfocus();
    } else {
      _inputFocus.requestFocus();
    }
    _ctrl.setShowEmojiPanel(opening, onGifTab: onGifTab);
  }
  Widget _buildInputBar() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ChatTheme.surface1,
        border: const Border(top: BorderSide(color: ChatTheme.hairline)),
        boxShadow: ChatTheme.panelShadow,
      ),
      child: SafeArea(
        top: false,
        // With the emoji/GIF panel open BELOW this bar, its own bottom inset
        // (nav bar / gesture pill) would sit in the middle of the composer as
        // dead space — which is what pushed the GIF grid down to a row and a
        // half. The panel takes the inset instead.
        bottom: !_ctrl.showEmojiPanel,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
          child: Row(children: [
            // Compact by hand: a default IconButton reserves a 48x48 tap target
            // plus its own padding, and two of those side by side ate most of
            // the composer width. The emoji button moved inside the text pill
            // (below) so only this one sits outside it.
            IconButton(
              icon: Icon(
                _ctrl.showAttachMenu ? Icons.close : Icons.add_circle_outline,
                color: ChatTheme.accent,
                size: 26,
              ),
              tooltip: 'Attach',
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 40, height: 40),
              onPressed: () => _ctrl.setShowAttachMenu(!_ctrl.showAttachMenu),
            ),
            Expanded(
              child: TextField(
                controller: _textController,
                focusNode: _inputFocus,
                // Gboard's GIF/sticker key and Play Store sticker packs deliver
                // their images through Android's commitContent API; without
                // this the keyboard shows them greyed out as "not supported".
                contentInsertionConfiguration: ContentInsertionConfiguration(
                  allowedMimeTypes: const [
                    'image/gif',
                    'image/png',
                    'image/jpeg',
                    'image/webp',
                  ],
                  onContentInserted: _onKeyboardContent,
                ),
                onTap: () {
                  _ctrl.setShowAttachMenu(false);
                  _ctrl.setShowEmojiPanel(false);
                },
                onChanged: _ctrl.onTypingChanged,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(color: Colors.white),
                maxLines: 4,
                minLines: 1,
                decoration: InputDecoration(
                  hintText: 'Message',
                  hintStyle: const TextStyle(color: ChatTheme.textFaint),
                  // Inside the pill, like WhatsApp: it reads as part of the
                  // field rather than a third competing button.
                  prefixIcon: IconButton(
                    icon: Icon(
                      _ctrl.showEmojiPanel
                          ? Icons.keyboard_alt_outlined
                          : Icons.emoji_emotions_outlined,
                      color: ChatTheme.accent,
                      size: 22,
                    ),
                    tooltip: 'Emoji & GIFs',
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    constraints:
                        const BoxConstraints.tightFor(width: 38, height: 38),
                    onPressed: () => _toggleEmojiPanel(),
                  ),
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 42, minHeight: 38),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(ChatTheme.pillRadius),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(ChatTheme.pillRadius),
                    borderSide: const BorderSide(color: ChatTheme.hairline),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(ChatTheme.pillRadius),
                    borderSide: BorderSide(
                        color: ChatTheme.accent.withValues(alpha: 0.55)),
                  ),
                  filled: true,
                  fillColor: ChatTheme.surface2,
                  contentPadding:
                      const EdgeInsets.only(left: 4, right: 14, top: 11, bottom: 11),
                ),
                onSubmitted: (_) => _sendText(),
              ),
            ),
            const SizedBox(width: 6),
            // Never gated on an upload: media goes up behind its own bubble,
            // so text can still be sent while a photo or video is uploading.
            _SendButton(onTap: _sendText),
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
      backgroundColor: ChatTheme.surface1,
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
            // My recent msg → delete for everyone immediately; otherwise a
            // two-sided "delete for me" (gone for both once they delete it too).
            _actionTile(Icons.delete_outline, 'Delete', () {
              Navigator.pop(context);
              if (isMe && canModify) {
                _ctrl.deleteMessage(msg.id);
              } else {
                _ctrl.deleteForMe(msg);
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
        backgroundColor: ChatTheme.surface1,
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
            fillColor: ChatTheme.surface2,
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
        // Same phantom guard as the mini bar: only show over a live engine.
        if (!active || !CallService.inCall || !isCallVideo) {
          return const SizedBox.shrink();
        }
        return _FloatingVideoOverlay(
          key: ValueKey(_floatingVideoEpoch),
          onTap: _returnToCall,
          onEnd: () => unawaited(endMinimizedCall()),
        );
      },
    );
  }
}

