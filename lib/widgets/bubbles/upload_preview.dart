part of '../message_bubble.dart';

/// Photo/video bubble while it is still uploading: the local file (a video
/// shows its generated thumbnail) dimmed behind a progress ring, so the sender
/// sees what they sent immediately instead of an empty composer lock.
///
/// [progress] is null when the upload has failed — the ring is dropped and the
/// bubble's own failed styling (red border + retry icon) carries the state.
class _UploadPreview extends StatelessWidget {
  final String? previewPath;
  final MessageType type;
  final double? progress;

  const _UploadPreview({
    required this.previewPath,
    required this.type,
    required this.progress,
  });

  static const _width = 220.0;
  static const _height = 200.0;

  @override
  Widget build(BuildContext context) {
    final path = previewPath;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      child: SizedBox(
        width: _width,
        height: _height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (path != null)
              Image.file(
                File(path),
                fit: BoxFit.cover,
                // A picked file can disappear (cache cleanup, cancelled pick)
                // between selection and paint — fall back, never throw.
                errorBuilder: (_, __, ___) => const _UploadPlaceholder(),
              )
            else
              _UploadPlaceholder(
                  icon: type == MessageType.video
                      ? Icons.videocam_rounded
                      : Icons.image_rounded),
            const ColoredBox(color: Color(0x66000000)),
            if (progress != null)
              Center(
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CircularProgressIndicator(
                        // 0 means "queued / compressing", where a determinate
                        // ring would look frozen at empty.
                        value: progress == 0 ? null : progress,
                        strokeWidth: 3,
                        backgroundColor: Colors.white24,
                        valueColor:
                            const AlwaysStoppedAnimation(Color(0xFFA78BFA)),
                      ),
                      Center(
                        child: Text(
                          '${((progress ?? 0) * 100).round()}%',
                          style: const TextStyle(
                              fontSize: 10, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _UploadPlaceholder extends StatelessWidget {
  final IconData icon;
  const _UploadPlaceholder({this.icon = Icons.image_rounded});

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: const Color(0xFF241C46),
        child: Center(child: Icon(icon, size: 40, color: Colors.white24)),
      );
}
