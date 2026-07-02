import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../constants.dart';
import '../models/message.dart';
import '../services/chat_service.dart';

class CallsScreen extends StatelessWidget {
  final void Function(bool isVideo) onStartCall;
  /// Overrides the Firestore stream in tests.
  final Stream<List<Message>>? callsStream;

  const CallsScreen({super.key, required this.onStartCall, this.callsStream});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF0F0F1E),
      child: StreamBuilder<List<Message>>(
        stream: callsStream ?? ChatService.callEventsStream(),
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: Color(0xFF7C3AED)));
          }
          final calls = snap.data ?? [];
          if (calls.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.call_outlined, size: 64, color: Color(0x44FFFFFF)),
                  SizedBox(height: 16),
                  Text('No calls yet',
                      style: TextStyle(color: Color(0x88FFFFFF), fontSize: 16)),
                  SizedBox(height: 6),
                  Text('Audio and video calls will appear here',
                      style: TextStyle(color: Color(0x44FFFFFF), fontSize: 13)),
                ],
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.only(top: 8, bottom: 24),
            itemCount: calls.length,
            separatorBuilder: (_, __) =>
                const Divider(color: Color(0x1AFFFFFF), height: 1, indent: 72),
            itemBuilder: (ctx, i) =>
                _CallTile(message: calls[i], onCallBack: onStartCall),
          );
        },
      ),
    );
  }
}

class _CallTile extends StatelessWidget {
  final Message message;
  final void Function(bool isVideo) onCallBack;

  const _CallTile({required this.message, required this.onCallBack});

  @override
  Widget build(BuildContext context) {
    final lower = message.text.toLowerCase();
    final isVideo = lower.contains('video');
    final isMissed = lower.contains('missed');

    // callerId is null on events written before the field was added.
    final callerId = message.callerId;
    final hasDirection = callerId != null;
    final isOutgoing = callerId == mySenderId;

    // "Audio call ended • 1m 34s" → duration = "1m 34s"
    final String? duration = message.text.contains('•')
        ? message.text.split('•').last.trim()
        : null;

    final Color accentColor =
        isMissed ? const Color(0xFFFF6B6B) : const Color(0xFF34D399);

    IconData dirIcon;
    String dirLabel;
    if (!hasDirection) {
      dirIcon = Icons.call_rounded;
      dirLabel = '';
    } else if (isMissed && !isOutgoing) {
      dirIcon = Icons.call_missed_rounded;
      dirLabel = 'Missed';
    } else if (isOutgoing) {
      dirIcon = Icons.call_made_rounded;
      dirLabel = 'Outgoing';
    } else {
      dirIcon = Icons.call_received_rounded;
      dirLabel = 'Incoming';
    }

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: isMissed
            ? const Color(0x22FF6B6B)
            : const Color(0x2234D399),
        child: Icon(
          isVideo ? Icons.videocam_rounded : Icons.call_rounded,
          color: accentColor,
          size: 22,
        ),
      ),
      title: Text(
        isVideo ? 'Video call' : 'Audio call',
        style: TextStyle(
          color: isMissed ? const Color(0xFFFF6B6B) : Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Row(
          children: [
            if (hasDirection) ...[
              Icon(dirIcon, size: 13,
                  color: isMissed
                      ? const Color(0xFFFF6B6B)
                      : const Color(0x88FFFFFF)),
              const SizedBox(width: 4),
              Text(
                dirLabel,
                style: TextStyle(
                  color: isMissed
                      ? const Color(0xFFFF6B6B)
                      : const Color(0x88FFFFFF),
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 5),
              const Text('·',
                  style: TextStyle(color: Color(0x55FFFFFF), fontSize: 12)),
              const SizedBox(width: 5),
            ],
            Text(
              _formatCallTime(message.timestamp),
              style: const TextStyle(color: Color(0x66FFFFFF), fontSize: 12),
            ),
            if (duration != null) ...[
              const SizedBox(width: 5),
              const Text('·',
                  style: TextStyle(color: Color(0x55FFFFFF), fontSize: 12)),
              const SizedBox(width: 5),
              Text(duration,
                  style:
                      const TextStyle(color: Color(0x66FFFFFF), fontSize: 12)),
            ],
          ],
        ),
      ),
      trailing: IconButton(
        icon: Icon(
          isVideo ? Icons.videocam_outlined : Icons.call_outlined,
          color: const Color(0xFF7C3AED),
          size: 22,
        ),
        tooltip: isVideo ? 'Video call' : 'Audio call',
        onPressed: () => onCallBack(isVideo),
      ),
    );
  }

  String _formatCallTime(DateTime ts) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final msgDay = DateTime(ts.year, ts.month, ts.day);
    final time = DateFormat('HH:mm').format(ts);
    if (msgDay == today) return 'Today, $time';
    if (msgDay == yesterday) return 'Yesterday, $time';
    if (now.difference(ts).inDays < 7) {
      return '${DateFormat('EEEE').format(ts)}, $time';
    }
    return '${DateFormat('d MMM').format(ts)}, $time';
  }
}
