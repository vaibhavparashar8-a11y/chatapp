part of '../message_bubble.dart';

// ── Media album (stacked photos/videos) ──────────────────────────────────────

/// A batch of photos/videos sent together, drawn as one stacked grid instead of
/// a column of identical bubbles — the WhatsApp album layout.
///
/// Up to four tiles are shown; anything beyond that is folded into a `+N`
/// overlay on the last one. Tapping any tile opens the full-screen viewer on
/// that item with the whole album loaded, so the rest are a swipe away.
class _MediaAlbum extends StatelessWidget {
  /// Oldest first, at least two entries.
  final List<Message> messages;

  /// Long-press on a tile acts on *that* message (delete, reply), not on the
  /// album as a whole.
  final void Function(Message)? onTileLongPress;

  const _MediaAlbum({required this.messages, this.onTileLongPress});

  static const double _width = 220;
  static const double _gap = 2;
  static const double _half = (_width - _gap) / 2;

  /// Tiles actually drawn — the rest live behind the `+N` badge.
  static const int _maxTiles = 4;

  void _open(BuildContext context, int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MediaViewerScreen(
          items: [
            for (final m in messages)
              MediaViewerItem(
                url: m.mediaUrl!,
                isVideo: m.type == MessageType.video,
              ),
          ],
          initialIndex: index,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = messages.length > _maxTiles
        ? messages.sublist(0, _maxTiles)
        : messages;
    final overflow = messages.length - shown.length;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      child: SizedBox(
        width: _width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _rows(context, shown, overflow),
        ),
      ),
    );
  }

  /// Row layout by count: two side by side, one wide over two for three, and a
  /// 2x2 grid for four or more.
  List<Widget> _rows(BuildContext context, List<Message> shown, int overflow) {
    Widget tile(int index, double w, double h) => _AlbumTile(
          message: shown[index],
          width: w,
          height: h,
          // The badge belongs on the last visible tile only.
          overflowCount: (index == shown.length - 1) ? overflow : 0,
          onTap: () => _open(context, index),
          onLongPress: onTileLongPress == null
              ? null
              : () => onTileLongPress!(shown[index]),
        );

    Widget pair(int a, int b, double h) => Row(children: [
          tile(a, _half, h),
          const SizedBox(width: _gap),
          tile(b, _half, h),
        ]);

    switch (shown.length) {
      case 2:
        return [pair(0, 1, 150)];
      case 3:
        return [
          tile(0, _width, 110),
          const SizedBox(height: _gap),
          pair(1, 2, 110),
        ];
      default:
        return [
          pair(0, 1, 110),
          const SizedBox(height: _gap),
          pair(2, 3, 110),
        ];
    }
  }
}

/// One square of an album: the poster frame, a play badge for video, and the
/// `+N` veil when it stands in for the items that did not fit.
class _AlbumTile extends StatelessWidget {
  final Message message;
  final double width;
  final double height;
  final int overflowCount;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _AlbumTile({
    required this.message,
    required this.width,
    required this.height,
    required this.overflowCount,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final isVideo = message.type == MessageType.video;
    // Prefer the small poster frame: an album tile is ~109 px wide, so pulling
    // the full photo for each one would undo the point of the grid. The full
    // file is fetched when the tile is opened.
    final url = message.thumbUrl ?? message.mediaUrl!;
    final dpr = MediaQuery.of(context).devicePixelRatio;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              memCacheWidth: (width * dpr).round(),
              fadeInDuration: ChatTheme.fast,
              placeholder: (_, __) =>
                  _MediaPlaceholder(width: width, height: height),
              errorWidget: (_, __, ___) => _MediaPlaceholder(
                width: width,
                height: height,
                icon: isVideo
                    ? Icons.videocam_rounded
                    : Icons.broken_image_rounded,
                spinner: false,
              ),
            ),
            if (isVideo && overflowCount == 0)
              const Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(Icons.play_arrow, color: Colors.white, size: 24),
                  ),
                ),
              ),
            if (overflowCount > 0)
              ColoredBox(
                color: Colors.black.withValues(alpha: 0.55),
                child: Center(
                  child: Text(
                    '+$overflowCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
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
