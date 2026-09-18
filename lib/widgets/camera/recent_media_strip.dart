import 'package:flutter/material.dart';

import '../../models/gallery_item.dart';
import '../../theme/chat_theme.dart';
import '../../utils/time_utils.dart';

/// The row of recent gallery items above the shutter, so the last photo can be
/// sent without leaving the camera. Renders nothing when [items] is empty —
/// gallery access may be denied, and an empty grey band would look broken.
class RecentMediaStrip extends StatelessWidget {
  final List<GalleryItem> items;
  final ValueChanged<GalleryItem> onTap;

  /// Height of the strip, tile included.
  static const double height = 84;

  const RecentMediaStrip({
    super.key,
    required this.items,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) => _StripTile(item: items[i], onTap: onTap),
      ),
    );
  }
}

class _StripTile extends StatelessWidget {
  final GalleryItem item;
  final ValueChanged<GalleryItem> onTap;

  const _StripTile({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final thumb = item.thumbnail;
    return GestureDetector(
      onTap: () => onTap(item),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 76,
          height: RecentMediaStrip.height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (thumb == null)
                const ColoredBox(color: ChatTheme.surface2)
              else
                Image.memory(thumb, fit: BoxFit.cover, gaplessPlayback: true),
              if (item.isVideo)
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.videocam_rounded,
                            size: 13, color: Colors.white),
                        const SizedBox(width: 3),
                        Text(
                          formatClipDuration(item.duration),
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            shadows: [Shadow(blurRadius: 3)],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
