part of '../message_bubble.dart';

// ── Audio tile ───────────────────────────────────────────────────────────────

class _AudioMessageTile extends StatefulWidget {
  final Message message;
  const _AudioMessageTile({required this.message});

  @override
  State<_AudioMessageTile> createState() => _AudioMessageTileState();
}

class _AudioMessageTileState extends State<_AudioMessageTile> {
  bool _downloading = false;

  Future<void> _download() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    try {
      final name = widget.message.fileName ?? 'audio.m4a';
      final path = await _savePath(name);
      await Dio().download(widget.message.mediaUrl!, path);
      await OpenFile.open(path);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          const Icon(Icons.audio_file, color: Colors.white70),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.message.fileName ?? 'Audio file',
              style: const TextStyle(fontSize: 13, color: Colors.white),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _download,
            child: _downloading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white70),
                  )
                : const Icon(Icons.download, color: Colors.white60, size: 20),
          ),
        ],
      ),
    );
  }
}
