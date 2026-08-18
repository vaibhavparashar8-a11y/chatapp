import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chatapp/constants.dart';
import 'package:chatapp/screens/chat_screen.dart';
import 'package:chatapp/services/device_service.dart';
import 'package:chatapp/services/giphy_service.dart';
import 'package:chatapp/services/log_service.dart';
import '../helpers/fake_chat_repository.dart';

/// Composer surface: the redesigned attach sheet and the emoji/GIF panel.
void main() {
  late FakeChatRepository repo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DeviceService.testMode = true;
    LogService.testMode = true;
    mySenderId = 'A';
    giphyApiKey = '';
    repo = FakeChatRepository();
  });

  tearDown(() {
    DeviceService.testMode = false;
    LogService.testMode = false;
    giphyApiKey = '';
    GiphyService.testMode = false;
    GiphyService.searchResults = [];
    repo.close();
  });

  Future<void> pumpChat(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        repository: repo,
        callSignalProvider: () => const Stream.empty(),
      ),
    ));
    await tester.pump();
  }

  Future<void> openAttach(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pump();
  }

  Future<void> openEmoji(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
    await tester.pump();
  }

  group('attach sheet', () {
    testWidgets('is closed until the attach button is tapped', (tester) async {
      await pumpChat(tester);
      expect(find.text('Camera'), findsNothing);

      await openAttach(tester);
      expect(find.text('Camera'), findsOneWidget);
    });

    // The old horizontal scroller hid options off the right edge; the grid
    // shows every one at once, including the two new entries.
    testWidgets('shows all seven options together', (tester) async {
      await pumpChat(tester);
      await openAttach(tester);

      for (final label in [
        'Camera', 'Gallery', 'Record', 'Video', 'Audio', 'Document', 'GIF',
      ]) {
        expect(find.text(label), findsOneWidget, reason: '$label is missing');
      }
    });

    testWidgets('the attach button turns into a close button when open',
        (tester) async {
      await pumpChat(tester);
      await openAttach(tester);
      expect(find.byIcon(Icons.close), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(find.text('Camera'), findsNothing);
    });
  });

  group('emoji panel', () {
    testWidgets('opens on the emoji button and shows both tabs',
        (tester) async {
      await pumpChat(tester);
      expect(find.text('EMOJI'), findsNothing);

      await openEmoji(tester);
      expect(find.text('EMOJI'), findsOneWidget);
      expect(find.text('GIF'), findsOneWidget);
    });

    testWidgets('tapping an emoji puts it in the message field, unsent',
        (tester) async {
      await pumpChat(tester);
      await openEmoji(tester);

      await tester.tap(find.text('😀').first);
      await tester.pump();

      expect(find.widgetWithText(TextField, '😀'), findsOneWidget);
      expect(repo.sentTexts, isEmpty, reason: 'emoji must not send on tap');
    });

    testWidgets('emoji append at the caret rather than replacing',
        (tester) async {
      await pumpChat(tester);
      await tester.enterText(find.byType(TextField).first, 'hi ');
      await openEmoji(tester);

      await tester.tap(find.text('😀').first);
      await tester.pump();

      expect(find.widgetWithText(TextField, 'hi 😀'), findsOneWidget);
    });

    // Without this the panel replaces the keyboard and a mistyped emoji is
    // stuck in the field.
    testWidgets('backspace removes a whole emoji, not half a surrogate pair',
        (tester) async {
      await pumpChat(tester);
      await openEmoji(tester);
      await tester.tap(find.text('😀').first);
      await tester.pump();

      await tester.tap(find.byIcon(Icons.backspace_outlined));
      await tester.pump();

      expect(find.widgetWithText(TextField, ''), findsOneWidget);
    });

    testWidgets('opening the attach sheet closes the emoji panel',
        (tester) async {
      await pumpChat(tester);
      await openEmoji(tester);
      expect(find.text('EMOJI'), findsOneWidget);

      await openAttach(tester);

      expect(find.text('EMOJI'), findsNothing,
          reason: 'both panels occupy the same space');
      expect(find.text('Camera'), findsOneWidget);
    });

    testWidgets('the GIF attach tile opens the panel already on the GIF tab',
        (tester) async {
      giphyApiKey = 'test-key';
      GiphyService.testMode = true;
      GiphyService.searchResults = const [];

      await pumpChat(tester);
      await openAttach(tester);
      await tester.tap(find.text('GIF'));
      await tester.pumpAndSettle();

      expect(find.text('EMOJI'), findsOneWidget); // panel is open
      expect(find.text('Camera'), findsNothing);  // attach sheet closed
      // Landing on the emoji side would mean a second tap for a choice the
      // user already made: the GIF search box must be on screen right away.
      expect(find.text('Search GIFs'), findsOneWidget);
    });

    testWidgets('the composer emoji button still opens on the emoji tab',
        (tester) async {
      giphyApiKey = 'test-key';
      GiphyService.testMode = true;

      await pumpChat(tester);
      await openEmoji(tester);
      await tester.pumpAndSettle();

      expect(find.text('Search GIFs'), findsNothing);
      expect(find.text('😀'), findsWidgets);
    });
  });

  group('GIF tab', () {
    testWidgets('explains how to enable search when no key is configured',
        (tester) async {
      await pumpChat(tester);
      await openEmoji(tester);
      await tester.tap(find.text('GIF'));
      await tester.pumpAndSettle();

      expect(find.textContaining('giphy_api_key'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget,
          reason: 'no search box without a key — only the composer field');
    });

    testWidgets('shows a search box and results once configured',
        (tester) async {
      giphyApiKey = 'test-key';
      GiphyService.testMode = true;
      GiphyService.searchResults = const [
        GiphyGif(id: 'g1', previewUrl: 'https://g/1.gif', url: 'https://g/1.gif'),
        GiphyGif(id: 'g2', previewUrl: 'https://g/2.gif', url: 'https://g/2.gif'),
      ];

      await pumpChat(tester);
      await openEmoji(tester);
      await tester.tap(find.text('GIF'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, ''), findsWidgets);
      expect(find.text('Search GIFs'), findsOneWidget);
      expect(find.textContaining('giphy_api_key'), findsNothing);
    });
  });
}
