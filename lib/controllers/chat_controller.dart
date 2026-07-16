import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:video_compress/video_compress.dart';
import '../constants.dart';
import '../models/message.dart';
import '../repositories/i_chat_repository.dart';
import '../services/log_service.dart';

/// Owns all chat business logic. Knows nothing about Flutter widgets or Firebase.
///
/// Features implemented here (not in UI):
///   • Optimistic UI      — text messages appear instantly; confirmed via clientId
///   • Pagination         — stream limited to last 50; [loadMoreMessages] fetches older
///   • Debounced markRead — batches read-receipt writes into 500 ms windows
///   • Retry              — failed sends preserved in [_pendingEntries] for re-attempt
class ChatController extends ChangeNotifier {
  final IChatRepository _repo;
  final void Function(String message)? onUploadError;

  /// How often this device re-affirms its own presence heartbeat while the
  /// chat is open, and how old the OTHER side's heartbeat may get before
  /// their "online" is treated as stale. Injectable for tests.
  final Duration presenceRefreshInterval;
  final Duration presenceStaleAfter;

  ChatController(
    this._repo, {
    this.onUploadError,
    this.presenceRefreshInterval = const Duration(seconds: 20),
    this.presenceStaleAfter = const Duration(seconds: 45),
  });

  // ── Private state ────────────────────────────────────────────────────────

  List<Message> _streamMessages = [];     // real-time latest N
  List<Message> _olderMessages = [];      // paginated history
  final List<_PendingEntry> _pendingEntries = []; // optimistic + failed

  DateTime? _clearedAt;
  Set<String> _hiddenIds = {};
  DateTime? _otherReadAt;
  bool _otherTyping = false;
  bool _otherOnline = false;
  DateTime? _otherLastSeen;
  double? _uploadProgress;

  // Presence staleness state. Firestore has no onDisconnect, so a force-killed
  // app leaves `presence=true` behind forever. The writer re-stamps
  // `presenceAt` every [presenceRefreshInterval]; the reader only shows
  // "online" while those heartbeats keep ARRIVING. Freshness is measured by
  // the local receive time of a CHANGED presenceAt value — never by comparing
  // server timestamps to the device clock, so clock skew can't break it.
  bool _otherPresenceRaw = false;
  DateTime? _otherPresenceAtValue;   // last heartbeat value seen (server time)
  DateTime? _otherBeatReceivedAt;    // local time that value last CHANGED
  Timer? _presenceTimer;

  bool _hasMoreMessages = true;
  bool _loadingMore = false;

  bool _didLeave = false;
  int _leaveVersion = 0;  // incremented by enter() to abort a concurrent leave()
  bool _isTyping = false;
  bool _markReadPaused = false;
  Timer? _typingTimer;
  Timer? _markReadTimer;

  StreamSubscription<List<Message>>? _messagesSub;
  StreamSubscription<DateTime?>? _readAtSub;
  StreamSubscription<bool>? _typingSub;
  StreamSubscription<bool>? _presenceSub;
  StreamSubscription<DateTime?>? _presenceAtSub;
  StreamSubscription<DateTime?>? _lastSeenSub;

  // UI-only state that belongs here because it drives notifyListeners()
  Message? _replyingTo;
  bool _showAttachMenu = false;

  // Read-receipt guard: ID of the latest message from the other person that we
  // have already scheduled a markRead for. Only updated when !_markReadPaused
  // so that pauseMarkRead/resumeMarkRead correctly detects deferred reads.
  String? _lastSeenOtherMsgId;

  // ── Public getters ───────────────────────────────────────────────────────

  /// Combined, filtered message list: paginated older + stream recent + pending.
  List<Message> get messages {
    bool visible(Message m) =>
        !_hiddenIds.contains(m.id) &&
        (_clearedAt == null || m.timestamp.isAfter(_clearedAt!));
    return [
      ..._olderMessages.where(visible),
      ..._streamMessages.where(visible),
      ..._pendingEntries.map((e) => e.message),
    ];
  }

  DateTime? get otherReadAt => _otherReadAt;
  bool get otherTyping => _otherTyping;
  bool get otherOnline => _otherOnline;
  DateTime? get otherLastSeen => _otherLastSeen;
  double? get uploadProgress => _uploadProgress;
  bool get sending => _uploadProgress != null;
  bool get hasMoreMessages => _hasMoreMessages;
  bool get loadingMore => _loadingMore;
  Message? get replyingTo => _replyingTo;
  bool get showAttachMenu => _showAttachMenu;

  Set<String> get pendingIds =>
      _pendingEntries.where((e) => !e.failed).map((e) => e.message.id).toSet();

  Set<String> get failedIds =>
      _pendingEntries.where((e) => e.failed).map((e) => e.message.id).toSet();

  // ── Lifecycle ────────────────────────────────────────────────────────────

  Future<void> init() async {
    _clearedAt = await _repo.getClearedAt();
    _hiddenIds = await _repo.getHiddenIds();
    // Restore the last message we marked read in a previous session so that
    // re-opening this chat after an app restart (with no new messages) does not
    // re-fire markRead and move the read time of already-read messages.
    _lastSeenOtherMsgId = await _repo.getLastReadMsgId();

    _subscribeMessages();

    _readAtSub = _repo.otherReadAtStream().listen((ts) {
      if (ts != _otherReadAt) {
        _otherReadAt = ts;
        notifyListeners();
      }
    });

    _typingSub = _repo.otherTypingStream().listen((typing) {
      if (typing != _otherTyping) {
        _otherTyping = typing;
        notifyListeners();
      }
    });

    _presenceSub = _repo.otherPresenceStream().listen((online) {
      _otherPresenceRaw = online;
      _recomputeOnline();
    });

    _presenceAtSub = _repo.otherPresenceAtStream().listen((ts) {
      if (ts != _otherPresenceAtValue) {
        _otherPresenceAtValue = ts;
        _otherBeatReceivedAt = DateTime.now();
      }
      _recomputeOnline();
    });

    _startPresenceTimer();

    _lastSeenSub = _repo.otherLastSeenStream().listen((ts) {
      if (ts != _otherLastSeen) {
        _otherLastSeen = ts;
        notifyListeners();
      }
    });

    await _repo.enterChat();
    // Initial mark-read is handled by the first stream emission in _subscribeMessages().
  }

  void _subscribeMessages() {
    _messagesSub?.cancel();
    _messagesSub = _repo.messagesStream().listen((msgs) {
      _streamMessages = msgs;

      final confirmedClientIds = msgs
          .where((m) => m.clientId != null)
          .map((m) => m.clientId!)
          .toSet();
      _pendingEntries.removeWhere((e) => confirmedClientIds.contains(e.clientId));

      // Only mark read when a genuinely new message from the other person arrives.
      // Comparing the latest message ID prevents re-writing readAt on every
      // Firestore stream re-emission (e.g. on chat re-open with no new messages).
      // `!_didLeave` gates it on actually being in the chat: the message stream
      // stays live while the app is backgrounded, and without this an incoming
      // message would mark itself read (advancing the sender's "Read HH:mm")
      // even though this user has left and never saw it. enter() marks read on
      // return.
      final otherId = mySenderId == 'A' ? 'B' : 'A';
      final otherMsgs = msgs.where((m) => m.sender == otherId).toList();
      if (otherMsgs.isNotEmpty) {
        final latestId = otherMsgs.last.id;
        if (latestId != _lastSeenOtherMsgId && !_markReadPaused && !_didLeave) {
          _advanceReadTo(latestId);
        }
      }
      notifyListeners();
    });
  }

  Future<void> enter() async {
    _didLeave = false;
    _leaveVersion++;          // abort any leave() suspended at an await point
    _startPresenceTimer();
    // Back in the foreground chat: mark read any message that arrived while we
    // were away (the stream stayed live but _subscribeMessages skipped it).
    _markReadLatestIfNew();
    await _repo.enterChat();
    // Stream re-emits on reconnect; _subscribeMessages will handle mark-read
    // only if there is a genuinely new message (latestId != _lastSeenOtherMsgId).
  }

  Future<void> leave() async {
    if (_didLeave) return;
    _didLeave = true;
    _typingTimer?.cancel();
    _markReadTimer?.cancel();
    _presenceTimer?.cancel();
    _presenceTimer = null;
    final version = _leaveVersion;
    await _repo.setTyping(false);
    if (_leaveVersion != version) return;  // enter() was called while we awaited
    await _repo.leaveChat();
  }

  // ── Presence heartbeat / staleness ───────────────────────────────────────

  /// While the chat is open: re-affirm our own heartbeat AND re-check whether
  /// the other side's heartbeat has gone stale (staleness flips without a new
  /// Firestore snapshot, so a stream listener alone can never observe it).
  void _startPresenceTimer() {
    _presenceTimer?.cancel();
    _presenceTimer = Timer.periodic(presenceRefreshInterval, (_) {
      if (!_didLeave) {
        _repo.refreshPresence();
      }
      _recomputeOnline();
    });
  }

  void _recomputeOnline() {
    // Legacy compatibility: the other phone's app predates the heartbeat
    // (never wrote presenceAt) → trust the raw boolean, exactly as before.
    bool fresh = true;
    if (_otherPresenceAtValue != null) {
      final beat = _otherBeatReceivedAt;
      fresh = beat != null &&
          DateTime.now().difference(beat) <= presenceStaleAfter;
    }
    final online = _otherPresenceRaw && fresh;
    if (online != _otherOnline) {
      _otherOnline = online;
      notifyListeners();
    }
  }

  // ── Pagination ───────────────────────────────────────────────────────────

  Future<void> loadMoreMessages() async {
    if (_loadingMore || !_hasMoreMessages) return;

    final allCurrent = [..._olderMessages, ..._streamMessages];
    if (allCurrent.isEmpty) return;

    _loadingMore = true;
    notifyListeners();

    try {
      final older = await _repo.fetchOlderMessages(allCurrent.first.timestamp);
      if (older.isEmpty) {
        _hasMoreMessages = false;
      } else {
        if (older.length < 30) _hasMoreMessages = false;
        final existingIds = {
          ..._olderMessages.map((m) => m.id),
          ..._streamMessages.map((m) => m.id),
        };
        final newOnes = older.where((m) => !existingIds.contains(m.id)).toList();
        _olderMessages = [...newOnes, ..._olderMessages];
      }
    } catch (e) {
      LogService.w('ChatController', 'loadMoreMessages failed: $e');
    } finally {
      _loadingMore = false;
      notifyListeners();
    }
  }

  // ── Typing ───────────────────────────────────────────────────────────────

  void onTypingChanged(String value) {
    _typingTimer?.cancel();
    final nowTyping = value.isNotEmpty;
    if (nowTyping != _isTyping) {
      _isTyping = nowTyping;
      _repo.setTyping(nowTyping);
    }
    if (nowTyping) {
      _typingTimer = Timer(const Duration(seconds: 2), () {
        _isTyping = false;
        _repo.setTyping(false);
      });
    }
  }

  // ── Send (optimistic) ────────────────────────────────────────────────────

  Future<void> sendText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    _typingTimer?.cancel();
    _isTyping = false;
    _repo.setTyping(false);

    final reply = _replyingTo;
    final previewText = reply == null ? null : _previewFor(reply);
    setReplyingTo(null);

    final clientId = 'pending_${DateTime.now().microsecondsSinceEpoch}';
    final entry = _PendingEntry(
      clientId: clientId,
      message: Message(
        id: clientId,
        sender: mySenderId,
        text: trimmed,
        type: MessageType.text,
        timestamp: DateTime.now(),
        replyToId: reply?.id,
        replyToText: previewText,
        replyToSender: reply?.sender,
        clientId: clientId,
      ),
      replyToId: reply?.id,
      replyToText: previewText,
      replyToSender: reply?.sender,
    );
    _pendingEntries.add(entry);
    notifyListeners(); // message appears before Firestore write begins

    try {
      await _repo.sendText(
        trimmed,
        replyToId: reply?.id,
        replyToText: previewText,
        replyToSender: reply?.sender,
        clientId: clientId,
      );
      // Stream listener removes the entry once clientId is confirmed
    } catch (e) {
      LogService.e('ChatController', 'sendText failed: $e');
      entry.failed = true;
      notifyListeners();
      onUploadError?.call(e.toString().split(']').last.trim());
    }
  }

  Future<void> sendMedia(File file, MessageType type, {String? fileName}) async {
    _uploadProgress = 0;
    notifyListeners();
    try {
      File uploadFile = file;
      if (type == MessageType.video) {
        // Transcode to H.264 Main/Baseline at 720p so low-end devices can
        // decode the video (avoids NO_EXCEEDS_CAPABILITIES on MediaCodec).
        LogService.i('ChatController', 'Compressing video before upload');
        final info = await VideoCompress.compressVideo(
          file.path,
          quality: VideoQuality.MediumQuality,
          deleteOrigin: false,
          includeAudio: true,
        );
        if (info?.file != null) {
          uploadFile = info!.file!;
          LogService.i('ChatController',
              'Compressed: ${file.lengthSync()} → ${uploadFile.lengthSync()} bytes');
        } else {
          LogService.w('ChatController', 'Compression returned null — uploading original');
        }
      }
      await _repo.sendMedia(
        uploadFile,
        type,
        fileName: fileName,
        onProgress: (p) {
          _uploadProgress = p;
          notifyListeners();
        },
      );
    } catch (e) {
      LogService.e('ChatController', 'sendMedia failed: $e');
      onUploadError?.call(e.toString().split(']').last.trim());
    } finally {
      _uploadProgress = null;
      notifyListeners();
    }
  }

  /// Re-send a failed text message identified by its [clientId].
  Future<void> retryMessage(String clientId) async {
    final entry = _pendingEntries
        .where((e) => e.message.id == clientId)
        .firstOrNull;
    if (entry == null || !entry.failed) return;
    entry.failed = false;
    notifyListeners();

    try {
      await _repo.sendText(
        entry.message.text,
        replyToId: entry.replyToId,
        replyToText: entry.replyToText,
        replyToSender: entry.replyToSender,
        clientId: entry.clientId,
      );
    } catch (e) {
      LogService.e('ChatController', 'retryMessage failed: $e');
      entry.failed = true;
      notifyListeners();
      onUploadError?.call(e.toString().split(']').last.trim());
    }
  }

  // ── View mutations ───────────────────────────────────────────────────────

  Future<void> editMessage(String messageId, String newText) async {
    final trimmed = newText.trim();
    if (trimmed.isEmpty) return;
    await _repo.editMessage(messageId, trimmed);
  }

  Future<void> deleteMessage(String messageId) async {
    await _repo.deleteMessage(messageId);
  }

  /// Hide a received message locally (never deletes from Firestore).
  Future<void> hideMessage(String messageId) async {
    await _repo.hideMessage(messageId);
    _hiddenIds = await _repo.getHiddenIds();
    notifyListeners();
  }

  /// True when [msg] was sent by me and is within the 1-hour edit/delete window.
  static bool canModify(Message msg) =>
      msg.sender == mySenderId &&
      DateTime.now().difference(msg.timestamp).inMinutes < 60;

  Future<void> clearMyView() async {
    await _repo.clearMyView();
    _clearedAt = await _repo.getClearedAt();
    _olderMessages = [];
    _hasMoreMessages = true;
    notifyListeners();
  }

  void setReplyingTo(Message? msg) {
    _replyingTo = msg;
    if (msg != null) _showAttachMenu = false;
    notifyListeners();
  }

  void setShowAttachMenu(bool show) {
    _showAttachMenu = show;
    notifyListeners();
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Prevent read receipts from firing while the user is on a call screen.
  /// The background message stream stays active, so without this B's messages
  /// would be marked read even though B is in CallScreen and hasn't seen them.
  void pauseMarkRead() {
    _markReadPaused = true;
    _markReadTimer?.cancel();
  }

  /// Resume read receipts after returning from the call screen. Schedules a
  /// mark-read only if new messages arrived from the other person while paused
  /// (i.e. the stream advanced beyond _lastSeenOtherMsgId during the call).
  void resumeMarkRead() {
    _markReadPaused = false;
    _markReadLatestIfNew();
  }

  /// Mark read the newest message from the other person, if it's one we haven't
  /// marked yet. No-op while receipts are paused (call/media overlay) or while
  /// we've left the chat. Used by both [resumeMarkRead] and [enter].
  void _markReadLatestIfNew() {
    if (_markReadPaused || _didLeave) return;
    final otherId = mySenderId == 'A' ? 'B' : 'A';
    final otherMsgs = _streamMessages.where((m) => m.sender == otherId).toList();
    if (otherMsgs.isNotEmpty && otherMsgs.last.id != _lastSeenOtherMsgId) {
      _advanceReadTo(otherMsgs.last.id);
    }
  }

  /// Record [latestId] as the newest read message — in memory and persisted —
  /// then schedule the debounced markRead. Persisting is what keeps the read
  /// time stable across app restarts (a re-open with no new messages finds the
  /// same id and never re-stamps readAt).
  void _advanceReadTo(String latestId) {
    _lastSeenOtherMsgId = latestId;
    _repo.setLastReadMsgId(latestId);
    _scheduleMarkRead();
  }

  /// Batch read-receipt writes into 500 ms windows to avoid per-message Firestore calls.
  void _scheduleMarkRead() {
    if (_markReadPaused) return;
    _markReadTimer?.cancel();
    _markReadTimer = Timer(const Duration(milliseconds: 500), _repo.markRead);
  }

  String _previewFor(Message msg) {
    switch (msg.type) {
      case MessageType.text:  return msg.text;
      case MessageType.image: return '[Image]';
      case MessageType.video: return '[Video]';
      case MessageType.audio: return '[Audio]';
      case MessageType.file:      return '[File: ${msg.fileName ?? 'file'}]';
      case MessageType.gif:       return '[GIF]';
      case MessageType.callEvent: return msg.text;
    }
  }

  @override
  void dispose() {
    // Defense-in-depth: any dispose path that skipped the normal back-button/
    // PopScope handlers would otherwise leave presence=true in Firestore.
    // Guarded by _didLeave, so the normal path is a no-op. Fire-and-forget —
    // dispose() is synchronous.
    if (!_didLeave) leave();
    _typingTimer?.cancel();
    _markReadTimer?.cancel();
    _presenceTimer?.cancel();
    _messagesSub?.cancel();
    _readAtSub?.cancel();
    _typingSub?.cancel();
    _presenceSub?.cancel();
    _presenceAtSub?.cancel();
    _lastSeenSub?.cancel();
    super.dispose();
  }
}

// Holds an outgoing text message in the optimistic (pending) or failed state.
class _PendingEntry {
  final String clientId;
  final Message message;
  final String? replyToId;
  final String? replyToText;
  final String? replyToSender;
  bool failed = false;

  _PendingEntry({
    required this.clientId,
    required this.message,
    this.replyToId,
    this.replyToText,
    this.replyToSender,
  });
}
