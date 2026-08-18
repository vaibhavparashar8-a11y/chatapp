part of '../message_bubble.dart';

// ── Image bubble ─────────────────────────────────────────────────────────────

/// Remote image in a bubble.
///
/// Uses [CachedNetworkImage], not `Image.network`, for two reasons that were
/// both making received photos crawl:
///   * `Image.network` has **no disk cache**, so every scroll back re-fetched
///     the full file from Firebase Storage.
///   * It decodes at full resolution — a 12 MP phone photo decoded into memory
///     to be drawn 220 px wide.
/// [memCacheWidth]/[maxWidthDiskCache] cap the decode at roughly what is
/// actually on screen, which is where most of the delay went.
class _EncryptedImage extends StatelessWidget {
  final String url;
  final double width;
  final double height;

  const _EncryptedImage({
    required this.url,
    this.width = 220,
    this.height = 200,
  });

  @override
  Widget build(BuildContext context) {
    // Decode for the real pixel size of the bubble, not the source file.
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final targetWidth = (width * dpr).round();

    return CachedNetworkImage(
      imageUrl: url,
      width: width,
      height: height,
      fit: BoxFit.cover,
      memCacheWidth: targetWidth,
      maxWidthDiskCache: targetWidth,
      fadeInDuration: ChatTheme.fast,
      // Same tile the upload preview shows, so an arriving photo occupies its
      // final shape immediately instead of collapsing the bubble.
      placeholder: (_, __) => _MediaPlaceholder(width: width, height: height),
      errorWidget: (_, __, ___) => _MediaPlaceholder(
        width: width,
        height: height,
        icon: Icons.broken_image_rounded,
        spinner: false,
      ),
    );
  }
}

/// Neutral tile shown while media loads or when it cannot be shown.
class _MediaPlaceholder extends StatelessWidget {
  final double width;
  final double height;
  final IconData icon;
  final bool spinner;

  const _MediaPlaceholder({
    required this.width,
    required this.height,
    this.icon = Icons.image_rounded,
    this.spinner = true,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: ColoredBox(
        color: const Color(0xFF241C46),
        child: Center(
          child: spinner
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white30),
                )
              : Icon(icon, color: Colors.white24, size: 38),
        ),
      ),
    );
  }
}
