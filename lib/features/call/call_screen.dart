// lib/features/call/call_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'agora_token_builder.dart';
import 'call_service.dart';
import '../../services/chat_service.dart';
import '../../services/log_service.dart';
import '../../constants.dart';
import '../../utils/call_signal_interpreter.dart';

const _proximityChannel = MethodChannel('com.example.chatapp/proximity');
const _callChannel      = MethodChannel('com.example.chatapp/call');

class CallScreen extends StatefulWidget {
  final bool isVideo;
  final bool isCaller;
  final String callToken;
  // true when user returns to a minimized call — skips joinChannel
  final bool isReconnecting;
  /// Injectable for testing; defaults to [ChatService.callSignalStream] in production.
  final Stream<Map<String, dynamic>?> Function()? callSignalProvider;

  const CallScreen({
    super.key,
    required this.isVideo,
    required this.isCaller,
    this.callToken = '',
    this.isReconnecting = false,
    this.callSignalProvider,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  int? _remoteUid;
  bool _muted = false;
  bool _speakerOn = false;
  bool _cameraOff = false;
  bool _callConnected = false;
  bool _engineReady = false;
  bool _ending = false;
  bool _minimizing = false;
  // Caller-only: driven by the callee's callSignal updates.
  bool _remoteDelivered = false;
  bool _remoteAccepted = false;
  StreamSubscription<Map<String, dynamic>?>? _callSignalSub;
  // Video layout state
  bool _localIsMain = false; // when true, local video fills screen, remote is small
  double? _selfVideoX;       // null = unset, initialized on first build
  double _selfVideoY = 60;
  final _stopwatch = Stopwatch();
  Duration _durationOffset = Duration.zero;
  String _duration = '00:00';

  @override
  void initState() {
    super.initState();
    // Turn off screen when held to ear during audio calls (proximity sensor)
    if (!widget.isVideo) {
      _proximityChannel.invokeMethod('acquire').catchError((_) {});
    }
    if (widget.isReconnecting) {
      _reconnect();
    } else {
      _startCall();
    }
    // Only the caller needs to track the callee's ringing/accept/decline —
    // the callee only ever opens this screen after already accepting.
    if (widget.isCaller && !widget.isReconnecting) {
      _listenForCallSignal();
    }
  }

  void _listenForCallSignal() {
    final stream = widget.callSignalProvider != null
        ? widget.callSignalProvider!()
        : ChatService.callSignalStream();
    _callSignalSub = stream.listen((signal) {
      if (!mounted) return;
      switch (interpretCallSignal(signal, mySenderId: mySenderId)) {
        case CallSignalEvent.delivered:
          setState(() => _remoteDelivered = true);
          break;
        case CallSignalEvent.accepted:
          setState(() => _remoteAccepted = true);
          break;
        case CallSignalEvent.declined:
          unawaited(_endCall(errorMsg: 'Call rejected'));
          break;
        case CallSignalEvent.none:
          break;
      }
    });
  }

  // Re-attach UI callbacks to the existing Agora engine session.
  void _reconnect() {
    CallService.updateCallbacks(
      onUserJoined: (uid) {
        if (!mounted) return;
        setState(() { _remoteUid = uid; _callConnected = true; });
        _stopwatch.start();
        _updateDuration();
      },
      onUserLeft: (uid) {
        if (!mounted) return;
        setState(() { _remoteUid = null; _callConnected = false; });
        _stopwatch.stop();
        _endCall();
      },
      onError: () {
        if (!mounted) return;
        _endCall();
      },
    );
    CallService.onCallEnded = () {
      callActiveNotifier.value = false;
      if (mounted) _endCall();
    };
    // Restore connected state if the remote peer is still in the channel
    final remoteUid = CallService.currentRemoteUid;
    if (CallService.callStartTime != null) {
      _durationOffset = DateTime.now().difference(CallService.callStartTime!);
    }
    setState(() {
      _engineReady = true;
      _muted = CallService.isMuted;
      _speakerOn = CallService.isSpeakerOn;
      _cameraOff = CallService.isCameraOff;
      if (remoteUid != null) {
        _remoteUid = remoteUid;
        _callConnected = true;
      }
    });
    if (remoteUid != null) {
      _stopwatch.start();
      _updateDuration();
    }
    LogService.i('CallScreen', 'Reconnected — remoteUid=$remoteUid');
  }

  Future<void> _startCall() async {
    LogService.i('CallScreen', 'Starting — isCaller=${widget.isCaller} isVideo=${widget.isVideo}');
    try {
      final String token;
      if (agoraToken.isNotEmpty) {
        token = agoraToken;
      } else if (widget.isCaller && agoraAppCertificate.isNotEmpty) {
        token = AgoraTokenBuilder.buildRtcToken(
          appId: agoraAppId,
          appCertificate: agoraAppCertificate,
          channelName: agoraChannel,
          uid: 0,
          expireSecs: 3600,
        );
      } else {
        token = widget.callToken;
      }

      CallService.onCallEnded = () {
        callActiveNotifier.value = false;
        if (mounted) _endCall();
      };

      // Ring the other side before joining our own engine — joining (camera
      // capture, SDP offer, Firestore round-trip for WebRTC) can take several
      // seconds, and gating the ring on that finishing first meant a slow
      // join could eat the whole 20s call-setup window with the other side
      // never even notified. See docs §6.4 for the intended signal-first flow.
      // prepareOutgoingCall() (clears stale WebRTC signaling state) MUST run
      // before the ring goes out — otherwise the callee can start listening
      // and pick up the previous call's leftover offer.
      if (widget.isCaller) {
        await CallService.prepareOutgoingCall();
        ChatService.signalCall(widget.isVideo ? 'video' : 'audio', token: token);
      }

      await CallService.joinCall(
        videoEnabled: widget.isVideo,
        isCaller: widget.isCaller,
        token: token,
        onUserJoined: (uid) {
          LogService.i('CallScreen', 'onUserJoined uid=$uid');
          if (!mounted) return;
          setState(() { _remoteUid = uid; _callConnected = true; });
          _stopwatch.start();
          _updateDuration();
          if (widget.isCaller) {
            ChatService.sendCallEvent(
              widget.isVideo ? 'Video call started' : 'Audio call started',
            );
          }
        },
        onUserLeft: (uid) {
          LogService.i('CallScreen', 'onUserLeft uid=$uid');
          if (!mounted) return;
          setState(() { _remoteUid = null; _callConnected = false; });
          _stopwatch.stop();
          _endCall();
        },
        onError: () {
          LogService.e('CallScreen', 'Agora error callback — ending call');
          _endCall(errorMsg: 'Call failed. The Agora token may be expired — update it in Remote Config.');
        },
      );
      if (!mounted) return;
      setState(() => _engineReady = true);
      // Start foreground service so Android keeps the process alive in background
      _callChannel.invokeMethod('startForeground').catchError((_) {});
      LogService.i('CallScreen', 'Engine ready — isCaller=${widget.isCaller}');

      Future.delayed(const Duration(seconds: 20), () {
        if (mounted && !_callConnected) {
          LogService.w('CallScreen', 'Timeout — no remote user joined after 20s');
          if (widget.isCaller) {
            _endCall();
          } else {
            final msg = CallService.activeBackend == 'webrtc'
                ? 'Call timed out. The peer-to-peer connection never completed — check the TURN relay in Remote Config.'
                : 'Call timed out. Check that the Agora token is valid.';
            _endCall(errorMsg: msg);
          }
        }
      });
    } catch (e) {
      LogService.e('CallScreen', 'joinCall threw: $e');
      _endCall();
    }
  }

  void _updateDuration() {
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted || !_stopwatch.isRunning) return;
      final s = _stopwatch.elapsed.inSeconds + _durationOffset.inSeconds;
      setState(() {
        _duration =
            '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
      });
      _updateDuration();
    });
  }

  Future<void> _endCall({String? errorMsg}) async {
    if (_ending) return;
    _ending = true;
    callActiveNotifier.value = false;
    _callChannel.invokeMethod('stopForeground').catchError((_) {});
    _stopwatch.stop();
    if (widget.isCaller) {
      final label = widget.isVideo ? 'Video call' : 'Audio call';
      // !_callConnected covers both: A manually cuts before B answers, and 20s timeout
      if (!_callConnected) {
        await ChatService.sendCallEvent('Missed $label');
      } else {
        await ChatService.sendCallEvent('$label ended • $_duration');
      }
    }
    await ChatService.updateCallStatus('ended');
    // Timeout so a stuck Agora engine can't block navigation forever.
    await CallService.leaveCall().timeout(
      const Duration(seconds: 5),
      onTimeout: () {},
    );
    if (mounted) {
      if (errorMsg != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(errorMsg),
          backgroundColor: Colors.red[700],
          duration: const Duration(seconds: 4),
        ));
      }
      Navigator.pop(context);
    }
  }

  // Minimize call: keep engine alive, show mini bar in ChatScreen.
  Future<void> _minimize() async {
    _minimizing = true;
    callActiveNotifier.value = true;
    isCallVideo = widget.isVideo;
    isCallCaller = widget.isCaller;
    activeCallToken = widget.callToken;
    // If remote hangs up while minimized, clean up silently
    CallService.onCallEnded = () async {
      callActiveNotifier.value = false;
      _callChannel.invokeMethod('stopForeground').catchError((_) {});
      await CallService.leaveCall();
    };
    // Clear UI callbacks — this screen is going away
    CallService.updateCallbacks(
      onUserJoined: (_) {},
      onUserLeft: (_) {},
      onError: () {},
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _callSignalSub?.cancel();
    // Release proximity wake lock regardless of how the screen exits
    if (!widget.isVideo) {
      _proximityChannel.invokeMethod('release').catchError((_) {});
    }
    // Only release engine if truly ending, not minimizing
    if (!_minimizing && !_ending) {
      CallService.dispose();
    }
    super.dispose();
  }

  // Waiting-to-connect label — overridden by the live duration once connected.
  String get _statusLabel {
    if (!widget.isCaller) return 'Connecting...';
    return callerStatusLabel(
      remoteAccepted: _remoteAccepted,
      remoteDelivered: _remoteDelivered,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _minimize();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // ── Full-screen video ───────────────────────────────────────────
            if (widget.isVideo && _engineReady && _localIsMain && !_cameraOff)
              // Local video fills the screen
              SizedBox.expand(child: CallService.localVideoView())
            else if (widget.isVideo && _engineReady && !_localIsMain && _remoteUid != null)
              // Remote video fills the screen (default)
              SizedBox.expand(child: CallService.remoteVideoView(_remoteUid!))
            else
              // Waiting / audio call background
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF0D1117), Color(0xFF1A2332)],
                  ),
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const CircleAvatar(
                        radius: 60,
                        backgroundColor: Color(0xFF128C7E),
                        child: Icon(Icons.person, color: Colors.white, size: 60),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        otherDisplayName,
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _callConnected ? _duration : _statusLabel,
                        style: const TextStyle(color: Colors.white70, fontSize: 16),
                      ),
                    ],
                  ),
                ),
              ),

            // ── Small draggable video (tap to swap) ─────────────────────────
            if (widget.isVideo && _engineReady)
              Builder(builder: (context) {
                final size = MediaQuery.of(context).size;
                // Initialise position to top-right on first build
                _selfVideoX ??= size.width - 116;

                // What to show in the small pip — opposite of full-screen
                final Widget pipContent;
                if (_localIsMain) {
                  // Small = remote
                  pipContent = _remoteUid != null
                      ? CallService.remoteVideoView(_remoteUid!)
                      : const ColoredBox(
                          color: Color(0xFF1A2332),
                          child: Center(
                            child: Icon(Icons.person, color: Colors.white38, size: 40),
                          ),
                        );
                } else {
                  // Small = local (hide pip when camera is off)
                  if (_cameraOff) return const SizedBox.shrink();
                  pipContent = CallService.localVideoView();
                }

                return Positioned(
                  left: _selfVideoX,
                  top: _selfVideoY,
                  child: GestureDetector(
                    onTap: () => setState(() => _localIsMain = !_localIsMain),
                    onPanUpdate: (d) {
                      setState(() {
                        _selfVideoX = (_selfVideoX! + d.delta.dx)
                            .clamp(0, size.width - 100);
                        _selfVideoY = (_selfVideoY + d.delta.dy)
                            .clamp(0, size.height - 160);
                      });
                    },
                    child: Container(
                      width: 100,
                      height: 140,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white, width: 1.5),
                        boxShadow: const [
                          BoxShadow(color: Colors.black45, blurRadius: 6),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: pipContent,
                      ),
                    ),
                  ),
                );
              }),

            // Top bar with duration and back-to-chat button
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: _minimize,
                        child: const Icon(Icons.keyboard_arrow_down,
                            color: Colors.white70, size: 28),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _callConnected ? _duration : _statusLabel,
                        style: const TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Bottom controls
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _CallButton(
                        icon: _muted ? Icons.mic_off : Icons.mic,
                        label: _muted ? 'Unmute' : 'Mute',
                        onTap: () async {
                          setState(() => _muted = !_muted);
                          await CallService.toggleMute(_muted);
                        },
                      ),
                      // Flip camera always in bottom row — never obscured
                      if (widget.isVideo)
                        _CallButton(
                          icon: Icons.flip_camera_ios,
                          label: 'Flip',
                          onTap: CallService.switchCamera,
                        ),
                      _CallButton(
                        icon: Icons.call_end,
                        label: 'End',
                        color: Colors.red,
                        size: 60,
                        onTap: _endCall,
                      ),
                      if (widget.isVideo)
                        _CallButton(
                          icon: _cameraOff ? Icons.videocam_off : Icons.videocam,
                          label: _cameraOff ? 'Cam off' : 'Camera',
                          onTap: () async {
                            setState(() => _cameraOff = !_cameraOff);
                            await CallService.toggleCamera(_cameraOff);
                          },
                        )
                      else
                        _CallButton(
                          icon: _speakerOn
                              ? Icons.volume_up
                              : Icons.volume_down_rounded,
                          label: _speakerOn ? 'Speaker' : 'Earpiece',
                          active: _speakerOn,
                          onTap: () async {
                            final next = !_speakerOn;
                            setState(() => _speakerOn = next);
                            await CallService.toggleSpeaker(next);
                            // Release proximity lock on speaker (no need to dim
                            // screen when phone isn't held to ear); re-acquire
                            // when switching back to earpiece.
                            if (next) {
                              _proximityChannel
                                  .invokeMethod('release')
                                  .catchError((_) {});
                            } else {
                              _proximityChannel
                                  .invokeMethod('acquire')
                                  .catchError((_) {});
                            }
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final double size;
  final bool active;

  const _CallButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.size = 52,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color ?? (active ? Colors.white54 : Colors.white24),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: size * 0.45),
          ),
          const SizedBox(height: 6),
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 11)),
        ],
      ),
    );
  }
}
