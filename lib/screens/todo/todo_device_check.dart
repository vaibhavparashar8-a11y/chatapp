part of '../todo_screen.dart';

// ── Device check ─────────────────────────────────────────────────────────────
// Long-press the AppBar title to open it. Two halves: what the room doc
// already knows (passive, instant, but survives an uninstall), and a live
// round-trip ping that only a phone still running the app can answer.
// See PingService for why the passive half alone is not trustworthy.

extension _TodoDeviceCheck on _TodoScreenState {
  Future<void> _showDeviceCheckDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _DeviceCheckDialog(),
    );
  }
}

class _DeviceCheckDialog extends StatefulWidget {
  const _DeviceCheckDialog();

  @override
  State<_DeviceCheckDialog> createState() => _DeviceCheckDialogState();
}

class _DeviceCheckDialogState extends State<_DeviceCheckDialog> {
  DeviceCheck? _check;
  bool _loading = true;
  bool _pinging = false;
  PingResult? _result;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final check = await PingService.readRoom();
    if (!mounted) return;
    setState(() {
      _check = check;
      _loading = false;
    });
  }

  Future<void> _sendPing() async {
    setState(() {
      _pinging = true;
      _result = null;
    });
    final result = await PingService.ping();
    if (!mounted) return;
    setState(() {
      _pinging = false;
      _result = result;
    });
  }

  String get _otherRole => mySenderId == 'A' ? 'B' : 'A';

  String _resultText(PingResult result) {
    switch (result.outcome) {
      case PingOutcome.replied:
        final ms = result.roundTrip?.inMilliseconds ?? 0;
        final where = switch (result.via) {
          PingReplyVia.foreground => 'app was open',
          PingReplyVia.background => 'woken by the push',
          PingReplyVia.unknown => 'answered',
        };
        return 'Phone ${result.repliedBy} replied in ${ms}ms — $where.';
      case PingOutcome.timedOut:
        return 'No reply in ${PingService.replyTimeout.inSeconds}s. '
            'Phone $_otherRole is uninstalled, offline, or not receiving '
            'pushes.';
      case PingOutcome.failed:
        return 'Could not send the ping — check this phone\'s connection.';
    }
  }

  Color _resultColor(PingOutcome outcome) => switch (outcome) {
        PingOutcome.replied => _kTodoEmerald,
        PingOutcome.timedOut => Colors.orange,
        PingOutcome.failed => Colors.red,
      };

  @override
  Widget build(BuildContext context) {
    final check = _check;
    final result = _result;
    return AlertDialog(
      backgroundColor: _kTodoCard,
      titleTextStyle: _kTodoDialogTitle,
      contentTextStyle: _kTodoDialogContent,
      title: const Text('Device check'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Reading room…'),
              )
            else if (check == null)
              const Text('Room unreadable — you can still send a ping.')
            else ...[
              _DeviceRow(
                label: 'This phone ($mySenderId)',
                record: check.me,
              ),
              const SizedBox(height: 10),
              _DeviceRow(
                label: 'Other phone ($_otherRole)',
                record: check.them,
              ),
            ],
            const SizedBox(height: 14),
            const Divider(color: _kTodoDivider, height: 1),
            const SizedBox(height: 12),
            if (_pinging)
              const Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: _kTodoAccentLight),
                  ),
                  SizedBox(width: 10),
                  Text('Waiting for a reply…'),
                ],
              )
            else if (result != null)
              Text(
                _resultText(result),
                style: TextStyle(
                  color: _resultColor(result.outcome),
                  fontSize: 13,
                ),
              )
            else
              const Text(
                'A ping wakes the other phone silently. Only an app that is '
                'still installed and reachable can answer it.',
                style: TextStyle(color: _kTodoTextFaint, fontSize: 12),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(foregroundColor: _kTodoTextDim),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: _pinging ? null : _sendPing,
          style: FilledButton.styleFrom(backgroundColor: _kTodoAccentDeep),
          child: Text(_result == null ? 'Send ping' : 'Ping again'),
        ),
      ],
    );
  }
}

/// One phone's passive record: claimed role, push token, last time it opened.
class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.label, required this.record});

  final String label;
  final DeviceRecord record;

  @override
  Widget build(BuildContext context) {
    final lastSeen = record.lastSeen;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                color: _kTodoText, fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        _CheckLine(ok: record.claimed, text: 'Installed (role claimed)'),
        _CheckLine(ok: record.hasFcmToken, text: 'Push token on file'),
        Text(
          lastSeen == null
              ? 'Never opened the app'
              : 'Last opened ${formatLastSeen(lastSeen)}',
          style: const TextStyle(color: _kTodoTextFaint, fontSize: 12),
        ),
      ],
    );
  }
}

class _CheckLine extends StatelessWidget {
  const _CheckLine({required this.ok, required this.text});

  final bool ok;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(ok ? Icons.check_circle_outline : Icons.remove_circle_outline,
            size: 14, color: ok ? _kTodoEmerald : _kTodoTextFaint),
        const SizedBox(width: 6),
        Text(text,
            style: const TextStyle(color: _kTodoTextDim, fontSize: 12)),
      ],
    );
  }
}
