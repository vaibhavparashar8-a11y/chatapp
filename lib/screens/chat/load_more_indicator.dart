part of '../chat_screen.dart';

// ── Load-more indicator (shown at the top when older pages exist) ─────────────

class _LoadMoreIndicator extends StatelessWidget {
  final bool loading;
  const _LoadMoreIndicator({required this.loading});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Center(
        child: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Color(0xFFA78BFA)),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}
