// lib/features/call/incoming_call_dialog.dart

import 'package:flutter/material.dart';

class IncomingCallDialog extends StatelessWidget {
  final String callType;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const IncomingCallDialog({
    super.key,
    required this.callType,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 36,
              backgroundColor: const Color(0xFF128C7E),
              child: const Icon(Icons.person, color: Colors.white, size: 36),
            ),
            const SizedBox(height: 16),
            const Text('Incoming call',
                style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'Incoming ${callType == 'video' ? 'video' : 'audio'} call...',
              style: TextStyle(color: Colors.grey[600]),
            ),
            const SizedBox(height: 28),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Decline
                Column(
                  children: [
                    GestureDetector(
                      onTap: onDecline,
                      child: Container(
                        width: 60,
                        height: 60,
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.call_end,
                            color: Colors.white, size: 28),
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text('Decline',
                        style: TextStyle(fontSize: 12, color: Colors.red)),
                  ],
                ),
                // Accept
                Column(
                  children: [
                    GestureDetector(
                      onTap: onAccept,
                      child: Container(
                        width: 60,
                        height: 60,
                        decoration: const BoxDecoration(
                          color: Color(0xFF128C7E),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          callType == 'video'
                              ? Icons.videocam
                              : Icons.call,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text('Accept',
                        style: TextStyle(
                            fontSize: 12, color: Color(0xFF128C7E))),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
