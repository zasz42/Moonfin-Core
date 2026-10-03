import '../../l10n/app_localizations.dart';
import '../../preference/preference_constants.dart';
import '../models/aggregated_item.dart';

/// A server names a TV library 'tvshows' or 'shows', so both count.
bool _isTvCollectionType(String? collectionType) {
  final normalized = collectionType?.toLowerCase();
  return normalized == 'tvshows' || normalized == 'shows';
}

int latestMediaFetchLimitForCollection(
  String? collectionType, {
  required int defaultLimit,
  required int maxLimit,
}) {
  if (_isTvCollectionType(collectionType)) {
    final expandedLimit = defaultLimit * 4;
    if (expandedLimit > maxLimit) {
      return maxLimit;
    }
    return expandedLimit;
  }

  return defaultLimit;
}

/// The item types a Recently Released row asks a library for.
///
/// Asking by type is what lets the query recurse and reach a title the server
/// left sitting inside a folder of its own. A library that reports no type, or
/// one nothing here covers, gets null, and the caller then leaves recursion off
/// so the row keeps to the titles sitting directly in the library.
///
/// [seriesType] is only called for a TV library, so nothing else has to have
/// the setting to hand.
List<String>? recentlyReleasedItemTypesFor(
  String? collectionType, {
  required RecentlyReleasedSeriesType Function() seriesType,
}) => switch (collectionType?.toLowerCase()) {
  'tvshows' || 'shows' => switch (seriesType()) {
    RecentlyReleasedSeriesType.series => const ['Series'],
    RecentlyReleasedSeriesType.season => const ['Season'],
    RecentlyReleasedSeriesType.episode => const ['Episode'],
  },
  'movies' => const ['Movie'],
  'music' => const ['MusicAlbum'],
  // A books library holds both kinds.
  'books' => const ['Book', 'AudioBook'],
  'audiobooks' => const ['AudioBook', 'Audio'],
  _ => null,
};

/// Marks a row stitched together from several libraries of one kind. Such a row
/// has no single parent library, so nothing can ask the server for more of it.
const mergedTypeRowIdPrefix = 'mergedtype_';

bool isMergedTypeRowId(String rowId) => rowId.startsWith(mergedTypeRowIdPrefix);

/// Names the kind of media a merged row holds, standing in for the library
/// names it replaced.
String genericDescriptorForCollectionType(
  AppLocalizations l10n,
  String? collectionType,
) {
  return switch (collectionType?.toLowerCase()) {
    'movies' => l10n.movies,
    'tvshows' || 'shows' => l10n.tvShows,
    'music' => l10n.music,
    'books' => l10n.books,
    'audiobooks' => l10n.audiobooks,
    'musicvideos' => l10n.musicVideos,
    'homevideos' || 'photos' => l10n.homeVideos,
    _ => l10n.library,
  };
}

List<AggregatedItem> normalizeLatestMediaItems(
  List<AggregatedItem> items, {
  String? collectionType,
  required int limit,
}) {
  // Paging asks without a collection type, so a row that opened with series
  // cards would start handing back seasons part way along.
  final shouldCollapse =
      _isTvCollectionType(collectionType) ||
      (collectionType == null &&
          items.any((i) => i.type == 'Episode' || i.type == 'Season'));

  final normalized = shouldCollapse ? _collapseLatestTvItems(items) : items;

  if (normalized.length <= limit) {
    return normalized;
  }

  return normalized.take(limit).toList();
}

List<AggregatedItem> _collapseLatestTvItems(List<AggregatedItem> items) {
  return dedupMergedRows(
    [for (final item in items) _seriesCardForLatestTvItem(item) ?? item],
  );
}

/// Whether a server with display [name] is the Remux/Debrid source whose
/// copies should represent a title found on several servers.
bool isRemuxServerName(String? name) =>
    (name ?? '').toLowerCase().contains('remux');

/// All identity keys for [item]: provider ids plus a normalized title+year
/// key. Episodes and seasons key by their series, since rows collapse them
/// to series cards.
List<String> _mergedRowIdentityKeys(AggregatedItem item) {
  final keys = <String>[];
  final imdb = item.imdbId;
  if (imdb != null && imdb.isNotEmpty) keys.add('imdb:$imdb');
  final tmdb = item.tmdbId;
  if (tmdb != null && tmdb.isNotEmpty) keys.add('tmdb:$tmdb');
  final type = item.type?.toLowerCase() ?? '';
  if (type == 'episode' || type == 'season') {
    final seriesName = (item.seriesName ?? '').toLowerCase().trim().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    if (seriesName.isNotEmpty) {
      final numbers =
          's${item.parentIndexNumber ?? 0}e${item.indexNumber ?? 0}';
      keys.add('episode:$seriesName|${item.productionYear ?? 0}|$numbers');
    }
  } else {
    final name = item.name.toLowerCase().trim().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    if (name.isNotEmpty) {
      keys.add('title:$name|${item.productionYear ?? 0}');
    }
  }
  if (keys.isEmpty) keys.add('${item.serverId}|${item.id}');
  return keys;
}

/// Returns [base] with any provider ids it lacks filled in from [extra].
/// Only global ids travel across servers; artwork tags never do (a tag is
/// only valid for the item id it was issued with).
AggregatedItem _withBackfilledProviderIds(
  AggregatedItem base,
  AggregatedItem extra,
) {
  final baseLower = <String>{
    for (final k in base.providerIds.keys) k.toLowerCase(),
  };
  final merged = Map<String, String>.from(base.providerIds);
  var changed = false;
  extra.providerIds.forEach((k, v) {
    if (v.isNotEmpty && !baseLower.contains(k.toLowerCase())) {
      merged[k] = v;
      changed = true;
    }
  });
  if (!changed) return base;
  final raw = Map<String, dynamic>.from(base.rawData)
    ..['ProviderIds'] = merged;
  return AggregatedItem(
    id: base.id,
    serverId: base.serverId,
    rawData: raw,
  );
}

/// Merges [items] to one card per title for combined rows. An item is
/// dropped when ANY of its identity keys was already kept, so copies that
/// share only a TMDB id, only a title, or only an IMDb id still collapse
/// together. Of the copies, a Remux one wins (it exposes both the local
/// and the Debrid versions); otherwise the first one seen wins. The
/// survivor backfills provider ids it lacks from the dropped copies.
List<AggregatedItem> dedupMergedRows(
  Iterable<AggregatedItem> items, {
  Set<String> remuxServerIds = const {},
}) {
  final keyToIndex = <String, int>{};
  final result = <AggregatedItem>[];
  bool isRemux(AggregatedItem item) => remuxServerIds.contains(item.serverId);

  for (final item in items) {
    final keys = _mergedRowIdentityKeys(item);
    int? match;
    for (final key in keys) {
      final index = keyToIndex[key];
      if (index != null) {
        match = index;
        break;
      }
    }
    if (match == null) {
      final index = result.length;
      result.add(item);
      for (final key in keys) {
        keyToIndex[key] = index;
      }
      continue;
    }
    final survivor = result[match];
    if (isRemux(item) && !isRemux(survivor)) {
      result[match] = _withBackfilledProviderIds(item, survivor);
      for (final key in _mergedRowIdentityKeys(survivor)) {
        keyToIndex[key] = match;
      }
    } else {
      result[match] = _withBackfilledProviderIds(survivor, item);
    }
    for (final key in keys) {
      keyToIndex[key] = match;
    }
  }
  return result;
}

AggregatedItem? _seriesCardForLatestTvItem(AggregatedItem item) {
  if (item.type == 'Series') {
    return item;
  }

  if (item.type != 'Episode' && item.type != 'Season') {
    return null;
  }

  final seriesId = item.seriesId;
  final seriesName = item.seriesName?.trim();
  if (seriesId == null || seriesName == null || seriesName.isEmpty) {
    return null;
  }

  final rawData = Map<String, dynamic>.from(item.rawData);
  rawData['Id'] = seriesId;
  rawData['Type'] = 'Series';
  rawData['Name'] = seriesName;
  rawData.remove('IndexNumber');
  rawData.remove('ParentIndexNumber');
  // An episode's provider ids identify the episode, never the show: left in
  // place the card would build (and dedup by) a poster id that cannot
  // resolve to series art. Seasons keep theirs (usable for per-season
  // posters via the parent series id).
  if (item.type == 'Episode') {
    rawData.remove('ProviderIds');
  }

  // A season's parent is the series so its tag fits the id set below, but an
  // episode's parent is the season and that tag would not match the series.
  final seriesPrimaryImageTag =
      item.seriesPrimaryImageTag ??
      (item.type == 'Season' ? item.parentPrimaryImageTag : null);
  // The parent tag only fits the id below when the parent really is the
  // series. An episode whose season has a thumb of its own would otherwise
  // stamp the season's tag onto the series card, the mismatch the primary
  // tag above already guards against.
  final seriesThumbImageTag = item.parentThumbItemId == seriesId
      ? item.parentThumbImageTag
      : null;

  // A tag the episode or season brought along points at one scene, so the card
  // drops it rather than letting it stand in for the show.
  if (item.parentBackdropItemId == seriesId &&
      item.parentBackdropImageTags.isNotEmpty) {
    rawData['BackdropImageTags'] = List<String>.from(
      item.parentBackdropImageTags,
    );
  } else {
    rawData.remove('BackdropImageTags');
  }

  final imageTags = Map<String, dynamic>.from(
    rawData['ImageTags'] as Map? ?? const {},
  );
  if (seriesPrimaryImageTag != null && seriesPrimaryImageTag.isNotEmpty) {
    imageTags['Primary'] = seriesPrimaryImageTag;
    rawData['PrimaryImageTag'] = seriesPrimaryImageTag;
  } else {
    imageTags.remove('Primary');
    rawData.remove('PrimaryImageTag');
  }
  rawData['PrimaryImageItemId'] = seriesId;

  if (seriesThumbImageTag != null && seriesThumbImageTag.isNotEmpty) {
    imageTags['Thumb'] = seriesThumbImageTag;
  } else {
    imageTags.remove('Thumb');
  }

  rawData['ImageTags'] = imageTags;

  return AggregatedItem(
    id: seriesId,
    serverId: item.serverId,
    rawData: rawData,
  );
}
