part of '../message_bubble.dart';

// ── Download button overlay ──────────────────────────────────────────────────

class _DownloadButton extends StatefulWidget {
  final String url;
  final String fileName;
  final MessageType messageType;
  final String? mediaIv; // kept for API compat, no longer used

  const _DownloadButton({
    required this.url,
    required this.fileName,
    required this.messageType,
    this.mediaIv,
  });

  @override
  State<_DownloadButton> createState() => _DownloadButtonState();
}

class _DownloadButtonState extends State<_DownloadButton> {
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final isImageOrVideo = widget.messageType == MessageType.image ||
          widget.messageType == MessageType.video ||
          widget.messageType == MessageType.gif;
      final path = await _savePath(widget.fileName);
      await Dio().download(widget.url, path);
      if (isImageOrVideo) {
        await Gal.putImage(path);
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _save,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.black45,
          borderRadius: BorderRadius.circular(16),
        ),
        child: _saving
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.download, color: Colors.white, size: 18),
      ),
    );
  }
}
