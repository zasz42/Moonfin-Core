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
    if (value) install();
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
}
