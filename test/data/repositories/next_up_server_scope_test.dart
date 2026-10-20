import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/models/aggregated_item.dart';
import 'package:moonfin/data/repositories/multi_server_repository.dart';
import 'package:moonfin/data/utils/latest_media_row_normalizer.dart';

AggregatedItem _movie({
  required String id,
  required String serverId,
  String? imdb,
}) {
  return AggregatedItem(
    id: id,
    serverId: serverId,
    rawData: {
      'Id': id,
      'Name': 'Shared Movie',
      'Type': 'Movie',
      'ProductionYear': 2020,
      if (imdb != null)
        'ProviderIds': {'Imdb': imdb},
    },
  );
}

void main() {
  group('Default Server for Next Up scoping', () {
    test('Auto keeps every server', () {
      final items = [
        _movie(id: 'a', serverId: 'jelly', imdb: 'tt1'),
        _movie(id: 'b', serverId: 'remux', imdb: 'tt2'),
      ];

      expect(
        MultiServerRepository.scopeToNextUpServer(items, ''),
        hasLength(2),
      );
      expect(
        MultiServerRepository.scopeToNextUpServer(items, null),
        hasLength(2),
      );
    });

    test('a selected server keeps only its own titles', () {
      final items = [
        _movie(id: 'a', serverId: 'jelly', imdb: 'tt1'),
        _movie(id: 'b', serverId: 'remux', imdb: 'tt2'),
      ];

      final scoped = MultiServerRepository.scopeToNextUpServer(
        items,
        'jelly',
      ).toList();

      expect(scoped, hasLength(1));
      expect(scoped.single.serverId, 'jelly');
    });

    test('scoping before the Remux-preferring merge keeps the selected copy',
        () {
      final items = [
        _movie(id: 'j1', serverId: 'jelly', imdb: 'tt1'),
        _movie(id: 'r1', serverId: 'remux', imdb: 'tt1'),
      ];

      // Merge-first (the bug): the Remux copy wins the dedupe, so a later
      // filter to jellyfin drops the title entirely.
      final mergedFirst = dedupMergedRows(items, remuxServerIds: {'remux'});
      expect(mergedFirst, hasLength(1));
      expect(mergedFirst.single.serverId, 'remux');
      expect(
        mergedFirst.where((item) => item.serverId == 'jelly'),
        isEmpty,
      );

      // Scope-first (the fix): the jellyfin copy survives the merge.
      final scoped = MultiServerRepository.scopeToNextUpServer(items, 'jelly');
      final merged = dedupMergedRows(scoped, remuxServerIds: {'remux'});
      expect(merged, hasLength(1));
      expect(merged.single.serverId, 'jelly');
      expect(merged.single.id, 'j1');
    });
  });
}
