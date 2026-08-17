import 'package:chatapp/utils/emoji_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('emojiCategories', () {
    test('every category has a label, a tab icon and entries', () {
      expect(emojiCategories, isNotEmpty);
      for (final category in emojiCategories) {
        expect(category.label, isNotEmpty);
        expect(category.icon, isNotEmpty);
        expect(category.emoji, isNotEmpty, reason: '${category.label} is empty');
      }
    });

    test('the tab icon is one of the category\'s own emoji', () {
      for (final category in emojiCategories) {
        expect(category.emoji, contains(category.icon),
            reason: '${category.label} tab shows an emoji it does not list');
      }
    });

    // A duplicate is dead space in a grid the user scans by eye.
    test('no duplicates within a category', () {
      for (final category in emojiCategories) {
        expect(category.emoji.toSet().length, category.emoji.length,
            reason: '${category.label} repeats an emoji');
      }
    });

    test('no blank entries', () {
      for (final category in emojiCategories) {
        expect(category.emoji.where((e) => e.trim().isEmpty), isEmpty,
            reason: '${category.label} has a blank entry');
      }
    });
  });
}
