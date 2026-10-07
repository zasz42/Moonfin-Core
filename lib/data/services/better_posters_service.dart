import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:server_core/server_core.dart';

import '../models/aggregated_item.dart';

/// Client-side integration with the Better Posters (btttr.cc) external poster
/// service. When enabled via [externalPostersEnabled], primary image URLs for
/// known items are replaced with btttr.cc live-render URLs that composite
/// overlay badges onto the poster at request time.
///
/// Scope: home rows, upcoming releases, and library/folder browsing only.
/// Series/episode detail pages always use the server poster and are never
/// touched by this service.
///
/// Enabled overlay set (matching the Better Posters plugin configuration):
/// Trend Tags, Quality Tags, Genre, Ratings (source: Average), Age Rating.
///
/// URL scheme (from the BetterPosters-for-Jellyfin plugin's
/// BtttrPosterUrlBuilder):
///   path: poster-<overlays> where genre+rating collapse to nothing (genre
///         absorbs rating), then q=quality tags, a=age rating. With
///         trend+quality+genre+rating(average)+age all on this resolves to
///         `poster-qa`.
///   id source: `imdb` only. The `tmdb` path 404s on btttr.cc even for valid
///   TMDB ids (TMDB fallback lives in the Jellyfin plugin server-side, not
///   in raw URLs), so items without an IMDb id keep the server poster.
///   query: `tag=none` only when trend tags are off (ours are on, so omitted);
///          `rs=` omitted because the rating source is Average; `lang=`
///          omitted for English.
/// Result: https://btttr.cc/poster-qa/imdb/poster-default/<tt-id>.jpg
class BetterPostersService {
  BetterPostersService._();

  static const String _baseUrl = 'https://btttr.cc';

  /// The overlay path for the fixed enabled set (trend+quality+genre+rating
  /// (average)+age rating), matching BtttrPosterUrlBuilder.GetPosterPath.
  static const String _posterPath = 'poster-qa';

  /// Disk image cache for btttr.cc bytes. btttr.cc answers `max-age=21600`
  /// (6h), so the shared 14-day artwork manager still revalidates every
  /// poster on roughly every launch; pinning these immutable-per-overlay
  /// URLs to a 30-day manager keeps the replacement painted from disk
  /// between launches instead of refetching it.
  static const String _imageCacheKey = 'betterPostersImageCache';
  static const Duration _imageStalePeriod = Duration(days: 30);
  static const int _imageMaxObjects = 2000;

  static BaseCacheManager? _posterCacheManager;
  static bool _posterManagerLoading = false;

  /// Ready poster image manager, or null until [_ensurePosterManager]
  /// finishes. [cacheManagerForUrl] falls back to the default manager while
  /// null, so cards still paint (with standard freshness) instead of
  /// failing.
  static BaseCacheManager? get posterImageCacheManager => _posterCacheManager;

  /// Builds the poster manager once, off the critical path. The metadata
  /// repo is an explicit JSON file in the temp dir — the same ground the
  /// artwork disk cache stands on. The library default (sqflite on
  /// mobile/macOS, app-support JSON elsewhere) is unusable on tvOS, where
  /// every poster fetch through it fails and no btttr art ever paints.
  static Future<void> _ensurePosterManager() async {
    if (_posterCacheManager != null || _posterManagerLoading) return;
    _posterManagerLoading = true;
    try {
      final repo = await _posterCacheRepo();
      if (repo != null) {
        _posterCacheManager = CacheManager(
          Config(
            _imageCacheKey,
            stalePeriod: _imageStalePeriod,
            maxNrOfCacheObjects: _imageMaxObjects,
            repo: repo,
          ),
        );
      }
    } catch (_) {
    } finally {
      _posterManagerLoading = false;
    }
  }

  static Future<CacheInfoRepository?> _posterCacheRepo() async {
    try {
      final temp = await getTemporaryDirectory().timeout(
        const Duration(seconds: 2),
      );
      final dir = Directory('${temp.path}/$_imageCacheKey');
      await dir.create(recursive: true);
      return JsonCacheInfoRepository.withFile(
        File('${dir.path}/$_imageCacheKey.json'),
      );
    } catch (_) {
      return null;
    }
  }

  /// Whether [url] is a btttr.cc poster (rather than server art).
  static bool isPosterUrl(String? url) {
    if (url == null || url.isEmpty) return false;
    try {
      return Uri.parse(url).host == 'btttr.cc';
    } catch (_) {
      return false;
    }
  }

  /// The image cache manager for [url]: the poster manager for btttr.cc
  /// URLs while the feature is enabled, null (default manager) otherwise.
  /// Kicks off the async manager build on first use; cards painted before
  /// it finishes still resolve through the default manager.
  static BaseCacheManager? cacheManagerForUrl(String? url) {
    if (!enabled || !isPosterUrl(url)) return null;
    final manager = _posterCacheManager;
    if (manager == null) {
      unawaited(_ensurePosterManager().catchError((_) {}));
    }
    return manager;
  }

  /// Name of the on-disk resolution index. Versioned together with the
  /// overlay path: a config change that alters built URLs must invalidate
  /// every stored one.
  static const String _indexFileName = 'better_posters_index.json';
  static const int _indexVersion = 1;

  /// Entries unseen this long are dropped by [pruneStale] (media that left
  /// the libraries stops refreshing `lastSeen` on register).
  static const Duration _staleAfter = Duration(days: 30);

  /// Minimum gap between prune runs; bounds the index for very large
  /// libraries.
  static const int _maxEntries = 10000;

  /// Minimum gap between prune runs.
  static const Duration _pruneInterval = Duration(hours: 24);

  /// Cooldown for persisting the index after registrations burst in.
  static const Duration _saveDelay = Duration(seconds: 10);

  /// item id -> last-seen epoch millis. Registration refreshes it, so the
  /// prune can tell media still in the libraries from media that left.
  static final Map<String, int> _lastSeenByItemId = <String, int>{};

  static int? _lastPruneMs;
  static bool _indexLoading = false;
  static Timer? _saveTimer;

  /// item id -> fully-built btttr.cc poster URL for items that carry an
  /// IMDb id. Populated as items flow through the app.
  static final Map<String, String> _urlByItemId = <String, String>{};

  static bool _installed = false;

  /// Whether the feature is currently enabled. Driven by the
  /// [UserPreferences.externalPostersEnabled] preference.
  static bool enabled = false;

  /// Installs the [ImageApi.primaryImageOverride] hook so image-URL builders
  /// that consult it resolve registered items to btttr.cc. Idempotent.
  /// In-scope screens additionally resolve via [posterUrlFor] directly, so
  /// series/episode detail pages — which never consult either path — always
  /// keep the server poster.
  static void install() {
    if (_installed) return;
    _installed = true;
    ImageApi.primaryImageOverride = _resolve;
  }

  /// Enables or disables the feature and (un)installs the hook. When disabled
  /// the hook is left in place but returns null for every item, so the server
  /// poster is used.
  static void setEnabled(bool value) {
    enabled = value;
    if (!value) return;
    install();
    // The persisted index makes every previously seen poster resolve without
    // waiting for its row to load; the image manager build and the prune
    // then drop media that left the libraries. All run off the critical
    // path; cards painted before the manager is ready use the default one.
    if (!_indexLoading) {
      _indexLoading = true;
      unawaited(
        Future(() async {
          try {
            await loadPersisted();
            await _ensurePosterManager();
            await pruneStale();
          } catch (_) {}
        }).whenComplete(() => _indexLoading = false),
      );
    }
  }

  /// Registers [item] so its poster can resolve to a btttr.cc URL.
  /// No-op when the item has no IMDb id or is not a poster-backed type.
  ///
  /// For items that carry a provider id this keys the registry by [AggregatedItem.id],
  /// so in-scope screens (home rows, library/folder grids) can resolve it via
  /// [posterUrlFor]/[urlForId]. External (Seerr / calendar) rows resolve
  /// their poster at render time via [buildUrl] instead of mutating
  /// `PosterPath`, so toggling the feature never leaves stale URLs behind.
  static void registerItem(AggregatedItem item) {
    final url = buildUrl(item);
    if (url == null || !enabled) return;
    _urlByItemId[item.id] = url;
    _lastSeenByItemId[item.id] = DateTime.now().millisecondsSinceEpoch;
    _scheduleSave();
  }

  /// Registers every item in [items] that has a usable provider id.
  static void registerAll(Iterable<AggregatedItem> items) {
    for (final item in items) {
      registerItem(item);
    }
  }

  /// Builds the btttr.cc poster URL for [item], or null when the item has no
  /// usable IMDb id or is not a Movie/Series/Season.
  ///
  /// Only the `imdb` id source resolves on btttr.cc (verified: the `tmdb`
  /// path returns 404 even for valid TMDB ids; TMDB fallback lives in the
  /// Jellyfin plugin server-side, not in raw URLs). Callers must fall back
  /// to the server poster when this returns null — never render a TMDB-path
  /// URL, it blanks the card.
  static String? buildUrl(AggregatedItem item) {
    final type = item.type?.toLowerCase() ?? '';
    if (type != 'movie' && type != 'series' && type != 'season') {
      return null;
    }
    // Seerr/calendar rows carry their TMDB id as the item id, but may also
    // carry resolved ProviderIds (IMDb captured from Seerr details).
    if (item.serverId == 'seerr') {
      final imdb = item.imdbId;
      if (imdb != null && imdb.isNotEmpty) {
        return _build('imdb', imdb, item);
      }
      if (_looksLikeImdbId(item.id)) {
        return _build('imdb', item.id, item);
      }
      return null;
    }
    final imdb = item.imdbId;
    if (imdb != null && imdb.isNotEmpty) {
      return _build('imdb', imdb, item);
    }
    return null;
  }

  /// Whether [id] is an IMDb identifier (`tt...`) rather than a numeric
  /// TMDB id. Seerr rows key some items by IMDb id directly.
  static bool _looksLikeImdbId(String id) {
    if (id.length < 3 || id.length > 12) return false;
    if (!id.startsWith('tt')) return false;
    return int.tryParse(id.substring(2)) != null;
  }

  static String _build(String idSource, String id, AggregatedItem item) {
    var identifier = Uri.encodeComponent(id);
    // Per-season posters use the parent series' IMDb id plus a season index,
    // appended verbatim as btttr.cc expects `<imdb>:season:<n>.jpg`.
    if ((item.type?.toLowerCase() ?? '') == 'season') {
      final seasonNumber = item.indexNumber;
      if (idSource == 'imdb' && seasonNumber != null && seasonNumber > 0) {
        identifier = '$identifier:season:$seasonNumber';
      }
    }
    return '$_baseUrl/$_posterPath/$idSource/poster-default/$identifier.jpg';
  }

  /// Hook consulted by ImageApi implementations. Returns the btttr.cc URL for
  /// [itemId] when the feature is enabled and the item is registered.
  static String? _resolve(String itemId) {
    if (!enabled) return null;
    return _urlByItemId[itemId];
  }

  /// Returns the registered btttr.cc URL for [itemId], if any. Used by
  /// episode/season fallbacks that render the parent series poster.
  static String? urlForId(String itemId) {
    if (!enabled) return null;
    return _urlByItemId[itemId];
  }

  /// Resolves the btttr.cc poster for [item] when the feature is enabled, or
  /// null when the server poster should be used. Episodes and seasons without
  /// their own provider ids fall back to the registered parent series poster.
  static String? posterUrlFor(AggregatedItem item) {
    if (!enabled) return null;
    final direct = buildUrl(item);
    if (direct != null) return direct;
    final type = item.type?.toLowerCase() ?? '';
    if (type == 'episode' || type == 'season') {
      final seriesId = item.seriesId;
      if (seriesId != null && seriesId.isNotEmpty) {
        return _urlByItemId[seriesId];
      }
    }
    return null;
  }

  /// Loads the persisted resolution index into [_urlByItemId], so posters
  /// resolve from the first frame without waiting for their rows to load and
  /// register. Entries built for a different overlay path are dropped: they
  /// address artwork that no longer exists.
  @visibleForTesting
  static Future<void> loadPersisted() async {
    final file = await _indexFile();
    if (file == null) return;
    Map<String, dynamic> decoded;
    try {
      final text = await file.readAsString();
      decoded = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (decoded['v'] != _indexVersion || decoded['overlay'] != _posterPath) {
      return;
    }
    final entries = decoded['entries'];
    if (entries is! Map) return;
    _lastPruneMs = (decoded['prunedAtMs'] as num?)?.toInt();
    entries.forEach((key, value) {
      if (_urlByItemId.length >= _maxEntries) return;
      if (value is! Map) return;
      final url = value['u']?.toString() ?? '';
      final seen = (value['seenMs'] as num?)?.toInt() ?? 0;
      if (key is! String || url.isEmpty || !isPosterUrl(url)) return;
      _urlByItemId.putIfAbsent(key, () => url);
      _lastSeenByItemId.putIfAbsent(key, () => seen);
    });
  }

  /// Drops index entries unseen for [_staleAfter] (media that left the
  /// libraries) along with their cached image bytes. Runs at most every
  /// [_pruneInterval]; pass `force: true` to run regardless (tests).
  @visibleForTesting
  static Future<void> pruneStale({bool force = false, DateTime? now}) async {
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    if (!force &&
        _lastPruneMs != null &&
        at - _lastPruneMs! < _pruneInterval.inMilliseconds) {
      return;
    }
    _lastPruneMs = at;
    final cutoff = at - _staleAfter.inMilliseconds;
    final stale = <String>[];
    _lastSeenByItemId.forEach((id, seen) {
      if (seen < cutoff) stale.add(id);
    });
    if (stale.isNotEmpty) {
      // Null until the async manager build finishes; the index entries are
      // still dropped, and orphaned bytes age out by stalePeriod/cap anyway.
      final manager = _posterCacheManager;
      for (final id in stale) {
        final url = _urlByItemId.remove(id);
        _lastSeenByItemId.remove(id);
        if (url != null && manager != null) {
          try {
            await manager.removeFile(url);
          } catch (_) {}
        }
      }
    }
    await _saveNow();
  }

  static Future<File?> _indexFile() async {
    try {
      final docs = await getApplicationDocumentsDirectory().timeout(
        const Duration(seconds: 2),
      );
      return File('${docs.path}/$_indexFileName');
    } catch (_) {
      return null;
    }
  }

  static void _scheduleSave() {
    if (_saveTimer?.isActive ?? false) return;
    _saveTimer = Timer(_saveDelay, () {
      unawaited(_saveNow().catchError((_) {}));
    });
  }

  /// Writes the index, oldest-lastSeen first so the [_maxEntries] cap drops
  /// the stalest entries when libraries outgrow it.
  static Future<void> _saveNow() async {
    final file = await _indexFile();
    if (file == null) return;
    final ordered = _lastSeenByItemId.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final entries = <String, Map<String, dynamic>>{};
    for (final entry in ordered) {
      if (entries.length >= _maxEntries) break;
      final url = _urlByItemId[entry.key];
      if (url == null || url.isEmpty) continue;
      entries[entry.key] = {'u': url, 'seenMs': entry.value};
    }
    try {
      await file.writeAsString(
        jsonEncode({
          'v': _indexVersion,
          'overlay': _posterPath,
          'prunedAtMs': _lastPruneMs,
          'entries': entries,
        }),
        flush: true,
      );
    } catch (_) {}
  }
}
