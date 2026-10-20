import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/preference/home_section_config.dart';

HomeSectionConfig _customRow({
  bool enabled = true,
  bool hiddenFromHome = false,
  String section = 'custom_row_1',
}) => HomeSectionConfig.pluginDynamic(
  serverId: 'custom',
  pluginSection: section,
  pluginDisplayText: 'My List',
  pluginAdditionalData: jsonEncode({
    'source': 'tmdb',
    'type': 'user_list',
    'params': {'id': '42'},
  }),
  pluginSource: HomeSectionPluginSource.custom,
  enabled: enabled,
  hiddenFromHome: hiddenFromHome,
);

void main() {
  group('custom row hiddenFromHome', () {
    test('defaults to visible', () {
      expect(_customRow().hiddenFromHome, isFalse);
      expect(_customRow().enabled, isTrue);
    });

    test('hiding keeps the row enabled', () {
      // The whole point: hidden from the home rows, still on so the media bar
      // keeps getting the list.
      final hidden = _customRow(hiddenFromHome: true);
      expect(hidden.hiddenFromHome, isTrue);
      expect(hidden.enabled, isTrue);
    });

    test('survives a JSON round trip', () {
      final hidden = _customRow(hiddenFromHome: true);
      final restored = HomeSectionConfig.fromJson(hidden.toJson());

      expect(restored.hiddenFromHome, isTrue);
      expect(restored.enabled, isTrue);
      expect(restored.pluginSection, 'custom_row_1');
      expect(restored.pluginSource, HomeSectionPluginSource.custom);
    });

    test('a layout saved before the flag existed reads as visible', () {
      // No `hiddenFromHome` key at all, as every pre-existing saved layout is.
      final legacy = HomeSectionConfig.fromJson({
        'type': 'none',
        'enabled': true,
        'order': 3,
        'kind': 'pluginDynamic',
        'pluginSource': 'custom',
        'pluginSection': 'custom_row_9',
      });

      expect(legacy.hiddenFromHome, isFalse);
    });

    test('an unhidden row writes no hiddenFromHome key', () {
      // Keeps saved layouts byte-identical to what they were before the flag,
      // so nothing re-syncs for nothing.
      final json = _customRow().toJson();
      expect(json.containsKey('hiddenFromHome'), isFalse);
    });

    test('copyWith flips it without touching enabled', () {
      final shown = _customRow().copyWith(hiddenFromHome: true);
      expect(shown.hiddenFromHome, isTrue);
      expect(shown.enabled, isTrue);

      final hiddenAgain = shown.copyWith(hiddenFromHome: false);
      expect(hiddenAgain.hiddenFromHome, isFalse);
      expect(hiddenAgain.enabled, isTrue);
    });

    test('toggling hidden does not change the row identity', () {
      final visible = _customRow();
      final hidden = visible.copyWith(hiddenFromHome: true);
      expect(hidden.stableId, visible.stableId);
    });
  });
}