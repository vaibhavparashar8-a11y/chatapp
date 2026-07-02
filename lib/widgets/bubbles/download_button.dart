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
  bool _done = false;
  bool _error = false;

  Future<void> _save(BuildContext ctx) async {
    if (_saving || _done) return;
    setState(() { _saving = true; _error = false; });
    try {
      await Gal.requestAccess();
      final path = await _savePath(widget.fileName);
      await Dio().download(widget.url, path);

      if (widget.messageType == MessageType.video) {
        await Gal.putVideo(path);
      } else if (widget.messageType == MessageType.image ||
                 widget.messageType == MessageType.gif) {
        await Gal.putImage(path);
      }
      if (mounted) setState(() { _saving = false; _done = true; });
    } catch (e) {
      debugPrint('DownloadButton: save failed — $e');
      if (mounted) {
        setState(() { _saving = false; _error = true; });
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('Download failed'), duration: Duration(seconds: 2)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _save(context),
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
            : _done
                ? const Icon(Icons.check, color: Colors.greenAccent, size: 18)
                : _error
                    ? const Icon(Icons.error_outline, color: Colors.redAccent, size: 18)
                    : const Icon(Icons.download, color: Colors.white, size: 18),
      ),
    );
  }
}
