import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/models/aggregated_item.dart';
import 'package:moonfin/data/services/better_posters_service.dart';
import 'package:server_core/server_core.dart';

class _FakeItemsApi implements ItemsApi {
  Map<String, Map<String, dynamic>> itemsById = {};
  int getItemCalls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #getItem) {
      getItemCalls++;
      final id = invocation.positionalArguments[0] as String;
      final item = itemsById[id];
      if (item == null) throw Exception('not found: $id');
      return Future<Map<String, dynamic>>.value(item);
    }
    return super.noSuchMethod(invocation);
  }
}

class _FakeClient implements MediaServerClient {
  final _FakeItemsApi items = _FakeItemsApi();

  @override
  ItemsApi get itemsApi => items;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

AggregatedItem seriesCard(String id, {Map<String, String>? providerIds}) {
  final raw = <String, dynamic>{'Id': id, 'Type': 'Series', 'Name': 'Show'};
  if (providerIds != null) raw['ProviderIds'] = providerIds;
  return AggregatedItem(id: id, serverId: 'srv', rawData: raw);
}

AggregatedItem episode(String id, String seriesId) {
  return AggregatedItem(
    id: id,
    serverId: 'srv',
    rawData: {
      'Id': id,
      'Type': 'Episode',
      'Name': 'Episode',
      'SeriesId': seriesId,
      'SeriesName': 'Show',
    },
  );
}

void main() {
  late bool wasEnabled;

  setUp(() {
    wasEnabled = BetterPostersService.enabled;
  });

  tearDown(() {
    BetterPostersService.enabled = wasEnabled;
  });

  test('backfills missing series ids so the poster resolves on first paint',
      () async {
    BetterPostersService.enabled = true;
    final client = _FakeClient();
    client.items.itemsById['s1'] = {
      'Id': 's1',
      'ProviderIds': {'Imdb': 'tt1234567'},
    };
    final card = seriesCard('s1');

    expect(
      BetterPostersService.buildUrl(card),
      isNull,
      reason: 'collapsed series cards carry no provider ids',
    );

    final result = await BetterPostersService.withSeriesProviderIds(
      (_) => client,
      [card],
    );

    expect(result.single.providerIds['Imdb'], 'tt1234567');
    expect(client.items.getItemCalls, 1);
    final url = BetterPostersService.posterUrlFor(result.single);
    expect(url, startsWith('https://btttr.cc/poster-qa/imdb/'));
    expect(url, contains('tt1234567'));
  });

  test('disabled performs no fetch and returns the same list', () async {
    BetterPostersService.enabled = false;
    final client = _FakeClient();
    final items = [seriesCard('s1')];

    final result = await BetterPostersService.withSeriesProviderIds(
      (_) => client,
      items,
    );

    expect(identical(result, items), isTrue);
    expect(client.items.getItemCalls, 0);
  });

  test('keeps the server card when the fetch fails or has no ids', () async {
    BetterPostersService.enabled = true;
    final client = _FakeClient();
    final missing = seriesCard('gone');
    final empty = seriesCard('empty');
    client.items.itemsById['empty'] = {'Id': 'empty'};

    final result = await BetterPostersService.withSeriesProviderIds(
      (_) => client,
      [missing, empty],
    );

    expect(result[0].providerIds, isEmpty);
    expect(result[1].providerIds, isEmpty);
    expect(BetterPostersService.buildUrl(result[0]), isNull);
  });

  test('skips cards that already carry provider ids', () async {
    BetterPostersService.enabled = true;
    final client = _FakeClient();
    final items = [
      seriesCard('s1', providerIds: {'Imdb': 'tt9999999'}),
    ];

    final result = await BetterPostersService.withSeriesProviderIds(
      (_) => client,
      items,
    );

    expect(identical(result, items), isTrue);
    expect(client.items.getItemCalls, 0);
    expect(
      BetterPostersService.posterUrlFor(result.single),
      contains('tt9999999'),
    );
  });

  test('episodes register their parent series poster', () async {
    BetterPostersService.enabled = true;
    final client = _FakeClient();
    client.items.itemsById['s9'] = {
      'Id': 's9',
      'ProviderIds': {'Imdb': 'tt1111111'},
    };
    final ep = episode('e1', 's9');

    expect(BetterPostersService.posterUrlFor(ep), isNull);

    final result = await BetterPostersService.withSeriesProviderIds(
      (_) => client,
      [ep],
    );

    expect(client.items.getItemCalls, 1);
    // The episode card itself is untouched; the series resolves instead.
    expect(identical(result.single, ep), isTrue);
    final url = BetterPostersService.posterUrlFor(ep);
    expect(url, startsWith('https://btttr.cc/poster-qa/imdb/'));
    expect(url, contains('tt1111111'));
  });

  test('episodes skip the fetch when their series is registered', () async {
    BetterPostersService.enabled = true;
    final client = _FakeClient();
    client.items.itemsById['s9'] = {
      'Id': 's9',
      'ProviderIds': {'Imdb': 'tt1111111'},
    };

    await BetterPostersService.withSeriesProviderIds(
      (_) => client,
      [episode('e1', 's9')],
    );
    expect(client.items.getItemCalls, 1);

    final result = await BetterPostersService.withSeriesProviderIds(
      (_) => client,
      [episode('e2', 's9')],
    );

    expect(client.items.getItemCalls, 1);
    expect(result.single.type, 'Episode');
    expect(
      BetterPostersService.posterUrlFor(result.single),
      contains('tt1111111'),
    );
  });
}
