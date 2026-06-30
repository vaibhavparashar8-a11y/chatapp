part of '../message_bubble.dart';

// ── File tile ────────────────────────────────────────────────────────────────

class _FileMessageTile extends StatefulWidget {
  final Message message;
  const _FileMessageTile({required this.message});

  @override
  State<_FileMessageTile> createState() => _FileMessageTileState();
}

class _FileMessageTileState extends State<_FileMessageTile> {
  double? _progress;
  bool _downloading = false;

  String _formatSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _download() async {
    if (_downloading) return;
    setState(() { _downloading = true; _progress = 0; });
    try {
      final name = widget.message.fileName ?? 'file';
      final path = await _savePath(name);
      await Dio().download(
        widget.message.mediaUrl!, path,
        onReceiveProgress: (r, t) {
          if (t > 0 && mounted) setState(() => _progress = r / t);
        },
      );
      await OpenFile.open(path);
    } catch (_) {
    } finally {
      if (mounted) setState(() { _downloading = false; _progress = null; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _download,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.insert_drive_file,
                color: Colors.white70, size: 32),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.message.fileName ?? 'File',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Colors.white),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _formatSize(widget.message.fileSize),
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                  if (_downloading && _progress != null)
                    const SizedBox(height: 4),
                  if (_downloading && _progress != null)
                    LinearProgressIndicator(
                      value: _progress,
                      color: Colors.white70,
                      backgroundColor: Colors.white24,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (!_downloading)
              const Icon(Icons.download, color: Colors.white60, size: 20),
          ],
        ),
      ),
    );
  }
}
