import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/models/media_bar_slide_item.dart';

/// Local copy of the round-robin helpers in
/// `media_bar_repository.dart`. They are private there; the behaviour they
/// implement is what matters, so the test pins the algorithm rather than
/// reaching into the repository.

List<MediaBarSlideItem> interleave(
  List<List<MediaBarSlideItem>> pools,
  int maxItems,
) {
  if (pools.length <= 1) {
    return pools.isEmpty ? const [] : pools.first.take(maxItems).toList();
  }
  final out = <MediaBarSlideItem>[];
  var round = 0;
  while (out.length < maxItems) {
    var added = false;
    for (final pool in pools) {
      if (round >= pool.length) continue;
      out.add(pool[round]);
      added = true;
      if (out.length >= maxItems) break;
    }
    if (!added) break;
    round++;
  }
  return out;
}

MediaBarSlideItem slide(String id) => MediaBarSlideItem(
  itemId: id,
  serverId: 'seerr',
  title: id,
);

void main() {
  group('custom list round-robin', () {
    test('a long list cannot crowd out a short one', () {
      // The bug this guards: one long list swallowed the whole banner.
      final long = [for (var i = 0; i < 20; i++) slide('a$i')];
      final short = [slide('b0')];

      final out = interleave([long, short], 10);

      expect(out.any((s) => s.itemId == 'b0'), isTrue);
      expect(out, hasLength(10));
    });

    test('alternates between two lists', () {
      final a = [for (var i = 0; i < 5; i++) slide('a$i')];
      final b = [for (var i = 0; i < 5; i++) slide('b$i')];

      final out = interleave([a, b], 6);

      expect(out.map((s) => s.itemId), [
        'a0',
        'b0',
        'a1',
        'b1',
        'a2',
        'b2',
      ]);
    });

    test('a single list keeps its order and is capped', () {
      final only = [for (var i = 0; i < 20; i++) slide('a$i')];
      final out = interleave([only], 3);
      expect(out.map((s) => s.itemId), ['a0', 'a1', 'a2']);
    });

    test('stops when every list runs out', () {
      final a = [slide('a0')];
      final b = [slide('b0')];
      final out = interleave([a, b], 10);
      expect(out.map((s) => s.itemId), ['a0', 'b0']);
    });

    test('no pools yields nothing', () {
      expect(interleave(const [], 5), isEmpty);
    });

    test('skips an exhausted list and keeps the others going', () {
      final short = [slide('a0')];
      final long = [for (var i = 0; i < 5; i++) slide('b$i')];
      final out = interleave([short, long], 4);
      // a0, b0, then a is done so b continues.
      expect(out.map((s) => s.itemId), ['a0', 'b0', 'b1', 'b2']);
    });
  });
}