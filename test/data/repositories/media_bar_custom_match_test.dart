import 'package:flutter_test/flutter_test.dart';

/// Local copy of the match verification in `media_bar_repository.dart`.
/// The behaviour is the point: a server that ignores `anyProviderIdEquals`
/// answers with an unfiltered page, and trusting its first row is what made
/// every custom-row slide show the same title's ratings.
bool carriesProviderId(Map<String, dynamic> item, String key, String value) {
  final ids = item['ProviderIds'] as Map?;
  if (ids == null) return false;
  for (final entry in ids.entries) {
    if (entry.key.toString().toLowerCase() == key.toLowerCase() &&
        entry.value.toString() == value) {
      return true;
    }
  }
  return false;
}

Map<String, dynamic>? pickMatch(
  List<Object?> items,
  String key,
  String value,
  String wantType,
) {
  for (final raw in items) {
    if (raw is! Map<String, dynamic>) continue;
    if (raw['Type'] != wantType) continue;
    if (!carriesProviderId(raw, key, value)) continue;
    return raw;
  }
  return null;
}

Map<String, dynamic> item(
  String type,
  String key,
  String value, {
  double? community,
}) => {
  'Id': 'x$value',
  'Type': type,
  'ProviderIds': {key: value},
  if (community != null) 'CommunityRating': community,
};

void main() {
  group('carriesProviderId', () {
    test('matches the queried provider id', () {
      expect(carriesProviderId(item('Movie', 'Tmdb', '603'), 'Tmdb', '603'), isTrue);
    });

    test('tolerates key casing differences', () {
      final i = {'ProviderIds': {'tmdb': '603'}};
      expect(carriesProviderId(i, 'Tmdb', '603'), isTrue);
    });

    test('rejects a different value', () {
      expect(carriesProviderId(item('Movie', 'Tmdb', '604'), 'Tmdb', '603'), isFalse);
    });

    test('rejects a missing or empty ProviderIds block', () {
      expect(carriesProviderId({'Id': 'a'}, 'Tmdb', '603'), isFalse);
      expect(carriesProviderId({'ProviderIds': <String, dynamic>{}}, 'Tmdb', '603'), isFalse);
    });

    test('does not match a different key with the same value', () {
      expect(carriesProviderId(item('Movie', 'Imdb', 'tt1'), 'Tmdb', 'tt1'), isFalse);
    });
  });

  group('pickMatch', () {
    test('returns the title that really carries the id', () {
      final items = [
        item('Movie', 'Tmdb', '603', community: 7.4),
        item('Movie', 'Tmdb', '604', community: 9.1),
      ];
      final match = pickMatch(items, 'Tmdb', '604', 'Movie');
      expect(match?['CommunityRating'], 9.1);
    });

    test('rejects an unfiltered page, which is the bug being guarded', () {
      // A server that ignores the filter replies with whatever it likes; none
      // of these is the title that was asked for, so nothing may be used.
      final unfiltered = [
        item('Movie', 'Tmdb', '11', community: 5.7),
        item('Movie', 'Tmdb', '12', community: 6.2),
      ];
      expect(pickMatch(unfiltered, 'Tmdb', '603', 'Movie'), isNull);
    });

    test('skips an episode that shares the series provider id', () {
      // A series and its episodes can carry the same TMDB id; asking for the
      // series must not be answered by an episode (or the other way round).
      final items = [
        item('Episode', 'Tmdb', '1399', community: 8.8),
        item('Series', 'Tmdb', '1399', community: 8.9),
      ];
      expect(pickMatch(items, 'Tmdb', '1399', 'Series')?['CommunityRating'], 8.9);
      expect(pickMatch(items, 'Tmdb', '1399', 'Movie'), isNull);
    });

    test('gives each title its own numbers rather than the first row', () {
      // The regression in one shape: three different custom titles must not
      // all come back with the first library item's 5.7 / 35%.
      final page = [
        item('Movie', 'Tmdb', '603', community: 5.7),
        item('Movie', 'Tmdb', '604', community: 7.2),
        item('Movie', 'Tmdb', '605', community: 8.4),
      ];
      final got = {
        for (final id in ['603', '604', '605'])
          id: pickMatch(page, 'Tmdb', id, 'Movie')?['CommunityRating'],
      };
      expect(got, {'603': 5.7, '604': 7.2, '605': 8.4});
    });

    test('ignores non-map entries', () {
      expect(pickMatch(['nope', 42], 'Tmdb', '603', 'Movie'), isNull);
    });

    test('an empty page yields nothing', () {
      expect(pickMatch(const [], 'Tmdb', '603', 'Movie'), isNull);
    });
  });
}