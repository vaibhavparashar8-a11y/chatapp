// lib/screens/media_viewer_screen.dart

import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:video_player/video_player.dart';

import '../services/log_service.dart';

/// One photo or video in the viewer. An album opens with all of its members so
/// the user can swipe between them without going back to the chat.
class MediaViewerItem {
  final String url;
  final bool isVideo;

  const MediaViewerItem({required this.url, this.isVideo = false});
}

/// Full-screen photo/video viewer.
///
/// Both media types are served from [DefaultCacheManager] — the *same* cache
/// [CachedNetworkImage] fills for the bubbles in the chat. Opening a photo that
/// is already on screen is therefore instant: it used to re-download the whole
/// file through Dio, which is why tapping an image showed a black screen and a
/// second spinner for something the phone already had.
class MediaViewerScreen extends StatefulWidget {
  final List<MediaViewerItem> items;
  final int initialIndex;

  const MediaViewerScreen({
    super.key,
    required this.items,
    this.initialIndex = 0,
  });

  /// Convenience for the common single-media case.
  MediaViewerScreen.single({
    super.key,
    required String url,
    required bool isVideo,
  })  : items = [MediaViewerItem(url: url, isVideo: isVideo)],
        initialIndex = 0;

  @override
  State<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends State<MediaViewerScreen> {
  late final PageController _pageController;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.items.length - 1);
    _pageController = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final multiple = widget.items.length > 1;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: multiple
            ? Text('${_index + 1} / ${widget.items.length}',
                style: const TextStyle(color: Colors.white70, fontSize: 15))
            : null,
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.items.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (_, i) {
          final item = widget.items[i];
          return item.isVideo
              // Keyed per URL so paging away disposes the player it belongs to
              // instead of handing the controller to the next video.
              ? _VideoPage(key: ValueKey(item.url), url: item.url)
              : _ImagePage(url: item.url);
        },
      ),
    );
  }
}

/// Zoomable photo, straight from the shared cache.
class _ImagePage extends StatelessWidget {
  final String url;

  const _ImagePage({required this.url});

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      maxScale: 5,
      child: Center(
        child: CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.contain,
          // No fade: a cache hit is immediate and a fade only makes it look
          // like the image is still arriving.
          fadeInDuration: Duration.zero,
          placeholder: (_, __) =>
              const CircularProgressIndicator(color: Colors.white),
          errorWidget: (_, __, ___) => const Text('Failed to load',
              style: TextStyle(color: Colors.white54)),
        ),
      ),
    );
  }
}

/// Video page. Downloads once into the shared cache, then plays from the local
/// file — a re-open (or a second play of the same clip in the chat) is instant.
class _VideoPage extends StatefulWidget {
  final String url;

  const _VideoPage({super.key, required this.url});

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  VideoPlayerController? _videoCtrl;
  ChewieController? _chewieCtrl;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final File file = await cachedMediaFile(widget.url);
      final ctrl = VideoPlayerController.file(file);
      await ctrl.initialize();
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      _videoCtrl = ctrl;
      _chewieCtrl = ChewieController(
        videoPlayerController: ctrl,
        autoPlay: true,
        looping: false,
        aspectRatio: ctrl.value.aspectRatio,
      );
      setState(() => _loading = false);
    } catch (e, st) {
      LogService.e('MediaViewer', 'video load failed — ${widget.url}: $e\n$st');
      if (mounted) setState(() { _loading = false; _failed = true; });
    }
  }

  @override
  void dispose() {
    _chewieCtrl?.dispose();
    _videoCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    if (_failed || _chewieCtrl == null) {
      return const Center(
        child: Text('Failed to load', style: TextStyle(color: Colors.white54)),
      );
    }
    return Center(child: Chewie(controller: _chewieCtrl!));
  }
}

/// Downloads [url] into the shared media cache (or returns the copy already
/// there) as a local file. Used by both this viewer and the inline video bubble
/// so a clip is fetched once and replayed from disk.
Future<File> cachedMediaFile(String url) =>
    DefaultCacheManager().getSingleFile(url);
