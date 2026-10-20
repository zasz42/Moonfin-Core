import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/repositories/media_bar_repository.dart';

void main() {
  group('hasMediaBarSourceSelection', () {
    test('nothing selected means nothing to draw', () {
      expect(
        hasMediaBarSourceSelection(
          libraryIds: const [],
          collectionIds: const [],
          customTokens: const [],
        ),
        isFalse,
      );
    });

    test('a library alone counts as a selection', () {
      expect(
        hasMediaBarSourceSelection(
          libraryIds: const ['lib1'],
          collectionIds: const [],
          customTokens: const [],
        ),
        isTrue,
      );
    });

    test('a collection alone counts as a selection', () {
      expect(
        hasMediaBarSourceSelection(
          libraryIds: const [],
          collectionIds: const ['box1'],
          customTokens: const [],
        ),
        isTrue,
      );
    });

    test('a custom row list alone counts as a selection', () {
      expect(
        hasMediaBarSourceSelection(
          libraryIds: const [],
          collectionIds: const [],
          customTokens: const ['custom:custom_row_1'],
        ),
        isTrue,
      );
    });
  });

  group('mediaBarCustomImageUrl', () {
    test('a bare TMDB path becomes an absolute image url', () {
      expect(
        mediaBarCustomImageUrl('/abc123.jpg', 'w1280'),
        'https://image.tmdb.org/t/p/w1280/abc123.jpg',
      );
    });

    test('an absolute url passes through untouched', () {
      expect(
        mediaBarCustomImageUrl('https://image.tmdb.org/t/p/w500/x.jpg', 'w1280'),
        'https://image.tmdb.org/t/p/w500/x.jpg',
      );
    });

    test('null, empty and non-path values are dropped', () {
      expect(mediaBarCustomImageUrl(null, 'w1280'), isNull);
      expect(mediaBarCustomImageUrl('', 'w1280'), isNull);
      expect(mediaBarCustomImageUrl('abc123.jpg', 'w1280'), isNull);
    });
  });

  group('custom row source tokens', () {
    test('a token round-trips through the section it names', () {
      final token = customRowSourceToken('custom_row_42');
      expect(token, 'custom:custom_row_42');
      expect(isCustomRowSourceToken(token), isTrue);
      expect(customRowSectionForToken(token), 'custom_row_42');
    });

    test('a bare library id is not a custom row token', () {
      expect(isCustomRowSourceToken('abc123'), isFalse);
      expect(customRowSectionForToken('abc123'), isNull);
    });

    test('a server-prefixed library token is not a custom row token', () {
      expect(isCustomRowSourceToken('server1|abc123'), isFalse);
      expect(customRowSectionForToken('server1|abc123'), isNull);
    });
  });
}