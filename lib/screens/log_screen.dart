import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/log_service.dart';

class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  String _filter = 'ALL';

  Color _levelColor(String level) {
    switch (level) {
      case 'ERROR':
        return Colors.red[300]!;
      case 'WARN':
        return Colors.orange[300]!;
      default:
        return Colors.green[300]!;
    }
  }

  List<LogEntry> get _filtered {
    if (_filter == 'ALL') return LogService.logs;
    return LogService.logs.where((e) => e.level == _filter).toList();
  }

  void _copyAll() {
    final text = _filtered.map((e) => e.toString()).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Logs copied to clipboard'), duration: Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF2D2D2D),
        foregroundColor: Colors.white,
        title: const Text('App Logs', style: TextStyle(fontFamily: 'monospace', fontSize: 15)),
        actions: [
          DropdownButton<String>(
            value: _filter,
            dropdownColor: const Color(0xFF2D2D2D),
            style: const TextStyle(color: Colors.white, fontSize: 12),
            underline: const SizedBox(),
            items: ['ALL', 'INFO', 'WARN', 'ERROR']
                .map((f) => DropdownMenuItem(value: f, child: Text(f)))
                .toList(),
            onChanged: (v) => setState(() => _filter = v!),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 20),
            tooltip: 'Copy all',
            onPressed: _copyAll,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: 'Clear',
            onPressed: () {
              LogService.clear();
              setState(() {});
            },
          ),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: LogService.notifier,
        builder: (_, __, ___) {
          final entries = _filtered;
          if (entries.isEmpty) {
            return const Center(
              child: Text('No logs yet', style: TextStyle(color: Colors.grey)),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: entries.length,
            itemBuilder: (_, i) {
              final e = entries[i];
              final time = e.time.toIso8601String().substring(11, 23);
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: RichText(
                  text: TextSpan(
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                    children: [
                      TextSpan(text: '$time ', style: const TextStyle(color: Colors.grey)),
                      TextSpan(
                        text: '${e.level} ',
                        style: TextStyle(color: _levelColor(e.level), fontWeight: FontWeight.bold),
                      ),
                      TextSpan(text: '${e.tag}: ', style: const TextStyle(color: Colors.cyan)),
                      TextSpan(text: e.message, style: const TextStyle(color: Colors.white70)),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
