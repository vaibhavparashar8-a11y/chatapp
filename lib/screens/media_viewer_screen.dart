// lib/screens/media_viewer_screen.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:chewie/chewie.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';



class MediaViewerScreen extends StatefulWidget {
  final String url;
  final bool isVideo;

  const MediaViewerScreen({
    super.key,
    required this.url,
    required this.isVideo,
  });

  @override
  State<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends State<MediaViewerScreen> {
  // Video
  VideoPlayerController? _videoCtrl;
  ChewieController? _chewieCtrl;

  // Image
  Uint8List? _imageBytes;

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.isVideo ? _initVideo() : _initImage();
  }

  Future<void> _initImage() async {
    try {
      final bytes = await _fetchBytes();
      if (mounted) setState(() { _imageBytes = bytes; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _initVideo() async {
    try {
      final tmp  = await getTemporaryDirectory();
      final path = '${tmp.path}/viewer_${widget.url.hashCode}.mp4';
      await Dio().download(widget.url, path);
      final localFile = File(path);
      _videoCtrl = VideoPlayerController.file(localFile);
      await _videoCtrl!.initialize();
      _chewieCtrl = ChewieController(
        videoPlayerController: _videoCtrl!,
        autoPlay: true,
        looping: false,
        aspectRatio: _videoCtrl!.value.aspectRatio,
      );
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<Uint8List> _fetchBytes() async {
    final resp = await Dio().get<List<int>>(
      widget.url,
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(resp.data!);
  }

  @override
  void dispose() {
    _chewieCtrl?.dispose();
    _videoCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: _loading
            ? const CircularProgressIndicator(color: Colors.white)
            : _error != null
                ? Text('Failed to load', style: const TextStyle(color: Colors.white54))
                : widget.isVideo
                    ? (_chewieCtrl != null
                        ? Chewie(controller: _chewieCtrl!)
                        : const SizedBox.shrink())
                    : InteractiveViewer(
                        child: Image.memory(_imageBytes!, fit: BoxFit.contain),
                      ),
      ),
    );
  }
}
