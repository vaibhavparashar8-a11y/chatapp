import 'package:chatapp/theme/app_palette.dart';
import 'package:chatapp/theme/chat_theme.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two halves of the app must share one palette.
///
/// They did not: the todo card was #1A1040 while the chat panel was #141024,
/// so moving between the todo list and the chat shifted the background a
/// shade. These assertions are what stop a future edit re-introducing a second
/// set of hex literals.
void main() {
  group('app palette is derived from ChatTheme', () {
    test('surfaces match the chat surfaces', () {
      expect(kAppBg, ChatTheme.surface0);
      expect(kAppCard, ChatTheme.surface1);
      expect(kAppHeaderBar, ChatTheme.surface1);
      expect(kAppField, ChatTheme.surface2);
    });

    test('accents and text match', () {
      expect(kAppAccent, ChatTheme.violet);
      expect(kAppAccentDeep, ChatTheme.violetDeep);
      expect(kAppAccentLight, ChatTheme.accent);
      expect(kAppEmerald, ChatTheme.success);
      expect(kAppText, ChatTheme.textPrimary);
      expect(kAppTextDim, ChatTheme.textSecondary);
      expect(kAppTextFaint, ChatTheme.textFaint);
      expect(kAppDivider, ChatTheme.hairline);
    });

    test('the card gradient ends darker than it starts', () {
      final colors = kAppCardGradient.colors;
      expect(colors, hasLength(2));
      expect(colors.first.computeLuminance(),
          greaterThan(colors.last.computeLuminance()),
          reason: 'cards are lit from the top-left, like the chat bubbles');
    });
  });
}
