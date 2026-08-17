part of '../chat_screen.dart';

// ── Emoji / GIF panel ────────────────────────────────────────────────────────

/// The panel under the composer: an emoji grid and a GIF picker behind two
/// tabs. Emoji are inserted into the message field (never sent on their own);
/// picking a GIF sends it straight away, like WhatsApp.
class _EmojiGifPanel extends StatefulWidget {
  final void Function(String emoji) onEmoji;
  final void Function(GiphyGif gif) onGif;
  final VoidCallback onBackspace;

  const _EmojiGifPanel({
    required this.onEmoji,
    required this.onGif,
    required this.onBackspace,
  });

  @override
  State<_EmojiGifPanel> createState() => _EmojiGifPanelState();
}

class _EmojiGifPanelState extends State<_EmojiGifPanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  int _category = 0;

  static const _height = 260.0;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _height,
      color: const Color(0xFF14112A),
      child: Column(
        children: [
          SizedBox(
            height: 38,
            child: TabBar(
              controller: _tabs,
              indicatorColor: const Color(0xFFA78BFA),
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white38,
              labelStyle:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              tabs: const [Tab(text: 'EMOJI'), Tab(text: 'GIF')],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _buildEmojiTab(),
                _GifPicker(onGif: widget.onGif),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmojiTab() {
    final category = emojiCategories[_category];
    return Column(
      children: [
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 44,
            ),
            itemCount: category.emoji.length,
            itemBuilder: (_, i) {
              final emoji = category.emoji[i];
              return InkWell(
                onTap: () => widget.onEmoji(emoji),
                borderRadius: BorderRadius.circular(8),
                child: Center(
                  child: Text(emoji, style: const TextStyle(fontSize: 24)),
                ),
              );
            },
          ),
        ),
        _buildCategoryBar(),
      ],
    );
  }

  Widget _buildCategoryBar() {
    return Container(
      height: 42,
      decoration: const BoxDecoration(
        color: Color(0xFF1A1636),
        border: Border(top: BorderSide(color: Color(0x22FFFFFF))),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: emojiCategories.length,
              itemBuilder: (_, i) {
                final selected = i == _category;
                return InkWell(
                  onTap: () => setState(() => _category = i),
                  child: Container(
                    width: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: selected
                              ? const Color(0xFFA78BFA)
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                    child: Opacity(
                      opacity: selected ? 1 : 0.45,
                      child: Text(emojiCategories[i].icon,
                          style: const TextStyle(fontSize: 18)),
                    ),
                  ),
                );
              },
            ),
          ),
          // Backspace: the on-screen keyboard is usually hidden while this
          // panel is open, so without it a mistyped emoji cannot be removed.
          IconButton(
            onPressed: widget.onBackspace,
            icon: const Icon(Icons.backspace_outlined,
                size: 18, color: Colors.white54),
          ),
        ],
      ),
    );
  }
}

/// GIF tab — trending by default, with a search box. Shows a plain "not
/// configured" note when no Giphy key is set rather than an error state.
class _GifPicker extends StatefulWidget {
  final void Function(GiphyGif gif) onGif;
  const _GifPicker({required this.onGif});

  @override
  State<_GifPicker> createState() => _GifPickerState();
}

class _GifPickerState extends State<_GifPicker> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  List<GiphyGif> _gifs = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (GiphyService.isConfigured) _load('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load(String query) async {
    setState(() => _loading = true);
    final results = await GiphyService.search(query);
    if (!mounted) return;
    setState(() {
      _gifs = results;
      _loading = false;
    });
  }

  /// Debounced so typing a word is one request, not one per letter — each
  /// keystroke would otherwise send a search term to Giphy.
  void _onQueryChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () => _load(query));
  }

  @override
  Widget build(BuildContext context) {
    if (!GiphyService.isConfigured) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'GIF search is not set up.\nAdd a Giphy API key as "giphy_api_key" '
            'in Firebase Remote Config.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
          child: TextField(
            controller: _searchCtrl,
            onChanged: _onQueryChanged,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search GIFs',
              hintStyle: const TextStyle(color: Colors.white30, fontSize: 13),
              prefixIcon:
                  const Icon(Icons.search, size: 18, color: Colors.white38),
              filled: true,
              fillColor: const Color(0xFF1E1A40),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(child: _buildResults()),
      ],
    );
  }

  Widget _buildResults() {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white30),
        ),
      );
    }
    if (_gifs.isEmpty) {
      return const Center(
        child: Text('No GIFs found',
            style: TextStyle(color: Colors.white38, fontSize: 12)),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
      ),
      itemCount: _gifs.length,
      itemBuilder: (_, i) {
        final gif = _gifs[i];
        return GestureDetector(
          onTap: () => widget.onGif(gif),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CachedNetworkImage(
              imageUrl: gif.previewUrl,
              fit: BoxFit.cover,
              placeholder: (_, __) => const ColoredBox(color: Color(0xFF1E1A40)),
              errorWidget: (_, __, ___) => const ColoredBox(
                color: Color(0xFF1E1A40),
                child: Icon(Icons.broken_image, color: Colors.white24, size: 18),
              ),
            ),
          ),
        );
      },
    );
  }
}
