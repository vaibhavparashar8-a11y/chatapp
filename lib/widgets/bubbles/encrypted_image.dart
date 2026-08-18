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
///
/// While the full file downloads it shows [thumbUrl] — a 32 px copy uploaded
/// beside the photo — blurred up to fill the bubble. A few KB arrives almost
/// instantly, so the bubble holds a recognisable version of the actual picture
/// instead of an empty grey tile.
class _EncryptedImage extends StatelessWidget {
  final String url;
  final String? thumbUrl;
  final double width;
  final double height;

  const _EncryptedImage({
    required this.url,
    this.thumbUrl,
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
      fadeInDuration: ChatTheme.base,
      placeholder: (_, __) => _MediaLoadingTile(
          width: width, height: height, thumbUrl: thumbUrl),
      errorWidget: (_, __, ___) => _MediaPlaceholder(
        width: width,
        height: height,
        icon: Icons.broken_image_rounded,
        spinner: false,
      ),
    );
  }
}

/// What fills a media bubble before its full-size file has arrived: the blurred
/// thumbnail when there is one, otherwise a neutral tile.
class _MediaLoadingTile extends StatelessWidget {
  final double width;
  final double height;
  final String? thumbUrl;

  const _MediaLoadingTile({
    required this.width,
    required this.height,
    required this.thumbUrl,
  });

  @override
  Widget build(BuildContext context) {
    final thumb = thumbUrl;
    if (thumb == null) {
      return _MediaPlaceholder(width: width, height: height);
    }
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The thumbnail is ~32 px wide, so it is blurred rather than shown
          // sharp — upscaled detail that small looks like a mistake.
          ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: CachedNetworkImage(
              imageUrl: thumb,
              fit: BoxFit.cover,
              fadeInDuration: ChatTheme.fast,
              placeholder: (_, __) =>
                  const ColoredBox(color: Color(0xFF241C46)),
              errorWidget: (_, __, ___) =>
                  const ColoredBox(color: Color(0xFF241C46)),
            ),
          ),
          const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}

/// Neutral tile shown when there is no thumbnail, or the media cannot be shown.
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
