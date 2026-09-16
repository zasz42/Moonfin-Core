import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:server_core/server_core.dart';

import '../../preference/user_preferences.dart';
import '../models/media_bar_slide_item.dart';
import '../models/media_bar_state.dart';
import '../services/media_server_client_factory.dart';
import 'multi_server_repository.dart';

class MediaBarRepository {
  static const _precacheBackdropCount = 1;
  static const _precacheLogoCount = 1;

  final MediaServerClient _client;
  final UserPreferences _prefs;
  final _random = math.Random();

  static const _fields =
      'Type,Genres,OfficialRating,CommunityRating,CriticRating,'
      'RunTimeTicks,ProductionYear,ImageTags,BackdropImageTags,'
      'Overview,ProviderIds';

  MediaBarRepository(this._client, this._prefs);

  Future<MediaBarState> loadItems() async {
    if (!GetIt.instance.isRegistered<MediaBarRepository>() ||
        GetIt.instance<MediaBarRepository>() != this) {
      return const MediaBarDisabled();
    }

    final mediaBarMode = _prefs.get(UserPreferences.mediaBarMode);
    if (!UserPreferences.isMediaBarModeEnabled(mediaBarMode)) {
      return const MediaBarDisabled();
    }

    await _loadSessionClients();

    final contentType = _prefs.get(UserPreferences.mediaBarContentType);
    final pluginSyncEnabled = _prefs.get(UserPreferences.pluginSyncEnabled);

    final maxItems = pluginSyncEnabled
        ? (int.tryParse(_prefs.get(UserPreferences.mediaBarItemCount)) ?? 10)
        : 5;
    // The pickers in settings are open to everyone and the filtering below is
    // plain item queries, so a plugin is not needed to honour the choice.
    final libraryIds = _splitCsv(UserPreferences.mediaBarLibraryIds);
    final collectionIds = _splitCsv(UserPreferences.mediaBarCollectionIds);
    final excludedGenres = _splitCsv(
      UserPreferences.mediaBarExcludedGenres,
    ).toSet();

    final fetchLimit = maxItems + 2;

    final includeTypes = switch (contentType) {
      'movies' => const ['Movie'],
      'tvshows' => const ['Series'],
      _ => const ['Movie', 'Series'],
    };

    final preferredCollectionTypes = switch (contentType) {
      'movies' => const ['movies'],
      'tvshows' => const ['tvshows'],
      _ => const ['tvshows', 'movies'],
    };

    // A source is a `serverId|libraryId` pair; a bare libraryId belongs to the
    // active server (the pre-multi-server stored form). Collections stay tied
    // to the active server, like the source library picker writes them.
    final allSources = <_MediaBarSource>[];
    final allSourceItemTypes = <String, List<String>>{};

    try {
      final viewsResponse = await _client.userViewsApi.getUserViews().timeout(
        const Duration(seconds: 4),
      );
      final views = (viewsResponse['Items'] as List? ?? [])
          .cast<Map<String, dynamic>>();

      final validLibraryIds = <String>{};
      for (final view in views) {
        final viewId = view['Id']?.toString();
        if (viewId == null ||
            !supportsMediaBarLibrary(view, preferredCollectionTypes)) {
          continue;
        }

        validLibraryIds.add(viewId);

        // A mixed library is left off this map so it keeps the full type list
        final type = _normalizeCollectionType(view['CollectionType']);
        if (type == 'movies' || type == 'tvshows') {
          allSourceItemTypes[viewId] = type == 'movies'
              ? const ['Movie']
              : const ['Series'];
        }
      }

      // Filter libraryIds to only include valid movies/tvshows library IDs,
      // resolving each stored token to the server that owns it.
      final resolved = libraryIds.map(_parseSourceToken).toList();
      final validBySource = <_MediaBarSource>[]; // sources whose lib is valid
      for (final source in resolved) {
        if (source.isActiveServer) {
          if (validLibraryIds.contains(source.libraryId)) {
            validBySource.add(source);
          }
        } else {
          // A non-active server's library is listed by that server's views.
          final client = _clientForSource(source);
          try {
            final remoteViews = await client.userViewsApi.getUserViews().timeout(
              const Duration(seconds: 4),
            );
            final remoteItems = (remoteViews['Items'] as List? ?? [])
                .cast<Map<String, dynamic>>();
            final remoteValid = remoteItems
                .where(
                  (view) =>
                      view['Id']?.toString() == source.libraryId &&
                      supportsMediaBarLibrary(
                        view,
                        preferredCollectionTypes,
                      ),
                )
                .toList();
            if (remoteValid.isNotEmpty) {
              validBySource.add(source);
              _mapSourceType(source, remoteValid.first, allSourceItemTypes);
            }
          } catch (_) {
            // A server that fails to list its views contributes nothing for a
            // directly chosen library, but the selection is still kept below.
            validBySource.add(source);
          }
        }
      }

      allSources.addAll(validBySource);
      allSources.addAll(
        collectionIds.map(
          (id) => _MediaBarSource(serverId: '', libraryId: id),
        ),
      );

      if (allSources.isEmpty) {
        allSources.addAll(
          validLibraryIds.map(
            (id) => _MediaBarSource(serverId: '', libraryId: id),
          ),
        );
      }
    } catch (_) {
      // Fallback: If UserViews lookup fails, trust user's selection directly.
      allSources.addAll(libraryIds.map(_parseSourceToken));
      allSources.addAll(
        collectionIds.map(
          (id) => _MediaBarSource(serverId: '', libraryId: id),
        ),
      );
    }

    try {
      final allItems = <Map<String, dynamic>>[];

      if (allSources.isEmpty) {
        return const MediaBarDisabled();
      } else {
        for (final source in allSources) {
          if (!GetIt.instance.isRegistered<MediaBarRepository>() ||
              GetIt.instance<MediaBarRepository>() != this) {
            return const MediaBarDisabled();
          }
          try {
            final targetTypes =
                allSourceItemTypes[source.sourceKey] ?? includeTypes;
            final client = _clientForSource(source);
            final batch = await _fetchItems(
              targetTypes,
              fetchLimit,
              parentId: source.libraryId,
              client: client,
            );
            for (final item in batch) {
              if (source.serverId.isNotEmpty) {
                item['_moonfinServerId'] = source.serverId;
              }
            }
            allItems.addAll(batch);
          } catch (_) {
            // Keep fetching remaining libraries if one fails
          }
        }
      }

      var selected = _selectItemsWithBackdrops(
        allItems,
        maxItems,
        excludedGenres,
      );

      if (selected.isEmpty && allSources.isNotEmpty) {
        final first = allSources.first;
        final fallbackItems = <Map<String, dynamic>>[];
        final targetTypes =
            allSourceItemTypes[first.sourceKey] ?? includeTypes;
        final client = _clientForSource(first);
        fallbackItems.addAll(
          await _fetchItems(
            targetTypes,
            fetchLimit,
            parentId: first.libraryId,
            client: client,
          ),
        );

        selected = _selectItemsWithBackdrops(
          fallbackItems,
          maxItems,
          excludedGenres,
        );
      }

      if (selected.isEmpty) {
        final firstLibraryItems =
            await _fetchItemsFromFirstSeriesOrMoviesLibrary(
              includeTypes,
              fetchLimit,
              contentType: contentType,
            );
        selected = _selectItemsWithBackdrops(
          firstLibraryItems,
          maxItems,
          excludedGenres,
        );
      }

      if (selected.isEmpty) {
        return const MediaBarError('No items with backdrop images found');
      }

      final items = selected.map(_toSlideItem).toList();
      return MediaBarReady(items);
    } catch (e) {
      final firstLibraryItems = await _fetchItemsFromFirstSeriesOrMoviesLibrary(
        includeTypes,
        fetchLimit,
        contentType: contentType,
      );
      final selected = _selectItemsWithBackdrops(
        firstLibraryItems,
        maxItems,
        excludedGenres,
      );
      if (selected.isNotEmpty) {
        final items = selected.map(_toSlideItem).toList();
        return MediaBarReady(items);
      }
      return MediaBarError('Failed to load: $e');
    }
  }

  List<Map<String, dynamic>> _selectItemsWithBackdrops(
    List<Map<String, dynamic>> source,
    int maxItems,
    Set<String> excludedGenres,
  ) {
    final withBackdrops =
        source
            .where(
              (item) =>
                  _hasBackdrop(item) &&
                  !_isBoxSet(item) &&
                  !_hasExcludedGenre(item, excludedGenres),
            )
            .toList()
          ..shuffle();
    return withBackdrops.take(maxItems).toList();
  }

  List<String> _splitCsv(Preference<String> pref) =>
      _prefs.get(pref).split(',').where((s) => s.isNotEmpty).toList();

  _MediaBarSource _parseSourceToken(String token) {
    final sep = token.indexOf('|');
    if (sep < 0) {
      return _MediaBarSource(serverId: '', libraryId: token);
    }
    return _MediaBarSource(
      serverId: token.substring(0, sep),
      libraryId: token.substring(sep + 1),
    );
  }

  /// The clients of every connected server, refreshed on each load so a source
  /// library on another server resolves to a client even when no home row
  /// triggered the session load yet.
  Map<String, MediaServerClient> _sessionClients = const {};

  Future<void> _loadSessionClients() async {
    if (!_prefs.get(UserPreferences.enableMultiServerLibraries)) return;
    try {
      final sessions = await GetIt.instance<
          MultiServerRepository
        >().getLoggedInServers();
      _sessionClients = {
        for (final session in sessions) session.server.id: session.client,
      };
    } catch (_) {
      _sessionClients = const {};
    }
  }

  /// The client that owns [source]: its own server's when that server is
  /// loaded, the active client otherwise.
  MediaServerClient _clientForSource(_MediaBarSource source) {
    if (source.isActiveServer) return _client;
    return _sessionClients[source.serverId] ??
        GetIt.instance<MediaServerClientFactory>().getClientIfExists(
          source.serverId,
        ) ??
        _client;
  }

  void _mapSourceType(
    _MediaBarSource source,
    Map<String, dynamic> view,
    Map<String, List<String>> types,
  ) {
    final type = _normalizeCollectionType(view['CollectionType']);
    if (type == 'movies') {
      types[source.sourceKey] = const ['Movie'];
    } else if (type == 'tvshows') {
      types[source.sourceKey] = const ['Series'];
    }
  }

  Future<List<Map<String, dynamic>>> _fetchItemsFromFirstSeriesOrMoviesLibrary(
    List<String>? itemTypes,
    int limit, {
    required String contentType,
  }) async {
    try {
      final viewsResponse = await _client.userViewsApi.getUserViews().timeout(
        const Duration(seconds: 4),
      );
      final views = (viewsResponse['Items'] as List? ?? [])
          .cast<Map<String, dynamic>>();
      if (views.isEmpty) {
        return const <Map<String, dynamic>>[];
      }

      final preferredCollectionTypes = switch (contentType) {
        'movies' => const ['movies'],
        'tvshows' => const ['tvshows'],
        _ => const ['tvshows', 'movies'],
      };

      String? libraryId;

      for (final preferredType in preferredCollectionTypes) {
        for (final view in views) {
          final collectionType = _normalizeCollectionType(
            view['CollectionType'],
          );
          if (collectionType != preferredType) {
            continue;
          }
          final id = view['Id']?.toString();
          if (id != null && id.isNotEmpty) {
            libraryId = id;
            break;
          }
        }
        if (libraryId != null) {
          break;
        }
      }

      if (libraryId == null) {
        for (final view in views) {
          if (!supportsMediaBarLibrary(view, const ['movies', 'tvshows'])) {
            continue;
          }
          final id = view['Id']?.toString();
          if (id != null && id.isNotEmpty) {
            libraryId = id;
            break;
          }
        }
      }

      if (libraryId == null) {
        return const <Map<String, dynamic>>[];
      }

      return _fetchItems(itemTypes, limit, parentId: libraryId);
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  String _normalizeCollectionType(Object? value) {
    return value?.toString().trim().toLowerCase() ?? '';
  }

  void precacheImages(BuildContext context, List<MediaBarSlideItem> items) {
    for (final item in items.take(_precacheBackdropCount)) {
      if (item.backdropUrl != null) {
        precacheImage(CachedNetworkImageProvider(item.backdropUrl!), context);
      }
    }
    for (final item in items.take(_precacheLogoCount)) {
      if (item.logoUrl != null) {
        precacheImage(CachedNetworkImageProvider(item.logoUrl!), context);
      }
    }
  }

  /// How many titles each source hands the selector. The random source reads
  /// this many from a random place in the library, and the dated ones read
  /// this many of the newest.
  static const _poolSize = 40;

  Future<List<Map<String, dynamic>>> _fetchItems(
    List<String>? itemTypes,
    int limit, {
    String? parentId,
    MediaServerClient? client,
  }) async {
    final effectiveClient = client ?? _client;
    if (!GetIt.instance.isRegistered<MediaBarRepository>() ||
        GetIt.instance<MediaBarRepository>() != this) {
      return const <Map<String, dynamic>>[];
    }
    final sourceType = _prefs.get(UserPreferences.mediaBarSourceType);
    if (sourceType == UserPreferences.mediaBarSourceRecentlyAdded ||
        sourceType == UserPreferences.mediaBarSourceRecentlyReleased) {
      return _fetchDatedItems(
        sourceType,
        itemTypes,
        limit,
        parentId: parentId,
        client: effectiveClient,
      );
    }
    try {
      // Get the total count for this parent so we can pick a random window.
      // Asking for a single item keeps it cheap.
      final countResponse = await effectiveClient.itemsApi
          .getItems(
            includeItemTypes: itemTypes,
            sortBy: 'SortName',
            sortOrder: 'Ascending',
            // A library the user has grouped with others holds those libraries
            // rather than the titles, so only a recursive walk reaches anything.
            // The type filter keeps the walk to movies and series either way.
            recursive: true,
            parentId: parentId,
            limit: 1,
            enableTotalRecordCount: true,
          )
          .timeout(const Duration(seconds: 15));

      final total = countResponse['TotalRecordCount'] as int? ?? 0;

      if (total <= 0) {
        return const <Map<String, dynamic>>[];
      }

      // Fetch a random window with the fields and backdrop tags the selector
      // needs. A small library takes its whole set starting from the first item.
      final windowSize = math.min(total, _poolSize);
      final maxStartIndex = total - windowSize;
      final startIndex = maxStartIndex > 0
          ? _random.nextInt(maxStartIndex + 1)
          : 0;

      final windowResponse = await effectiveClient.itemsApi
          .getItems(
            includeItemTypes: itemTypes,
            sortBy: 'SortName',
            sortOrder: 'Ascending',
            recursive: true,
            parentId: parentId,
            startIndex: startIndex,
            limit: windowSize,
            fields: _fields,
            enableTotalRecordCount: false,
            enableImageTypes: 'Backdrop,Logo',
          )
          .timeout(const Duration(seconds: 15));

      final windowItems = windowResponse['Items'] as List? ?? [];
      final rawItems = windowItems.cast<Map<String, dynamic>>().toList();

      // Shuffle locally to provide a fresh random feel on every launch
      rawItems.shuffle(_random);
      return rawItems;
    } on TimeoutException {
      return _fetchItemsFromFallbackSource(
        itemTypes,
        limit,
        parentId: parentId,
        client: effectiveClient,
      );
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode ?? 0;
      if (statusCode == 401 || statusCode == 403) {
        return const <Map<String, dynamic>>[];
      }
      if (statusCode != 400 && statusCode < 500) {
        rethrow;
      }

      return _fetchItemsFromFallbackSource(
        itemTypes,
        limit,
        parentId: parentId,
        client: effectiveClient,
      );
    }
  }

  /// The newest titles a dated source offers, ordered and cut off the same way
  /// the matching home row does, so the two surfaces agree on what recent
  /// means.
  Future<List<Map<String, dynamic>>> _fetchDatedItems(
    String sourceType,
    List<String>? itemTypes,
    int limit, {
    String? parentId,
    MediaServerClient? client,
  }) async {
    final effectiveClient = client ?? _client;
    try {
      final response =
          sourceType == UserPreferences.mediaBarSourceRecentlyReleased
          ? await effectiveClient.itemsApi
                .getRecentlyReleasedItems(
                  includeItemTypes: itemTypes,
                  parentId: parentId,
                  recursive: true,
                  limit: _poolSize,
                  fields: _fields,
                  enableImageTypes: 'Backdrop,Logo',
                )
                .timeout(const Duration(seconds: 15))
          : await effectiveClient.itemsApi
                .getLatestItems(
                  includeItemTypes: itemTypes,
                  parentId: parentId,
                  limit: _poolSize,
                  fields: _fields,
                  enableImageTypes: 'Backdrop,Logo',
                )
                .timeout(const Duration(seconds: 15));

      final rawItems = response['Items'] as List? ?? [];
      return rawItems.cast<Map<String, dynamic>>();
    } catch (error) {
      final statusCode = error is DioException
          ? (error.response?.statusCode ?? 0)
          : 0;
      if (statusCode == 401 || statusCode == 403) {
        return const <Map<String, dynamic>>[];
      }
      return _fetchItemsFromFallbackSource(
        itemTypes,
        limit,
        parentId: parentId,
        client: effectiveClient,
      );
    }
  }

  Future<List<Map<String, dynamic>>> _fetchItemsFromFallbackSource(
    List<String>? itemTypes,
    int limit, {
    String? parentId,
    MediaServerClient? client,
  }) async {
    final effectiveClient = client ?? _client;
    final reducedLimit = limit > 24 ? 24 : limit;

    try {
      final latestResponse = await effectiveClient.itemsApi
          .getLatestItems(
            includeItemTypes: itemTypes,
            parentId: parentId,
            limit: reducedLimit,
            fields: _fields,
          )
          .timeout(const Duration(seconds: 15));
      final rawItems = latestResponse['Items'] as List? ?? [];
      return rawItems.cast<Map<String, dynamic>>();
    } catch (_) {}

    try {
      final fallbackResponse = await effectiveClient.itemsApi
          .getItems(
            includeItemTypes: itemTypes,
            sortBy: 'SortName',
            sortOrder: 'Ascending',
            recursive: true,
            parentId: parentId,
            limit: reducedLimit,
            fields: _fields,
            enableTotalRecordCount: false,
            enableImageTypes: 'Backdrop,Logo',
          )
          .timeout(const Duration(seconds: 15));
      final rawItems = fallbackResponse['Items'] as List? ?? [];
      return rawItems.cast<Map<String, dynamic>>();
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  bool _hasBackdrop(Map<String, dynamic> item) {
    final tags = item['BackdropImageTags'] as List?;
    return tags != null && tags.isNotEmpty;
  }

  bool _isBoxSet(Map<String, dynamic> item) {
    return item['Type'] == 'BoxSet';
  }

  bool _hasExcludedGenre(Map<String, dynamic> item, Set<String> excluded) {
    if (excluded.isEmpty) return false;
    final genres = (item['Genres'] as List?)?.cast<String>() ?? [];
    return genres.any((g) => excluded.contains(g));
  }

  /// Items for the setup wizard previews, free of the bar's own rules.
  ///
  /// The bar refuses to run without a movies or series library, and again
  /// without backdrop artwork, and both refusals hold for the whole session
  /// no matter how often it is asked. The previews only need something real
  /// to draw, so this takes the newest items across everything the user can
  /// see and keeps whatever comes back, posters and all.
  Future<List<MediaBarSlideItem>> fetchPreviewItems({int limit = 10}) async {
    try {
      final response = await _client.itemsApi
          .getItems(
            includeItemTypes: const ['Movie', 'Series'],
            sortBy: 'DateCreated',
            sortOrder: 'Descending',
            recursive: true,
            limit: limit,
            fields: _fields,
          )
          .timeout(const Duration(seconds: 15));
      final items = (response['Items'] as List? ?? [])
          .cast<Map<String, dynamic>>();
      return items.map(_toSlideItem).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  MediaBarSlideItem _toSlideItem(Map<String, dynamic> data) {
    final itemId = data['Id']?.toString() ?? '';
    // Items fetched from another connected server carry the app-level server id
    // that the factory keys clients by (the server's own ServerId field is not
    // stable across reconnects). Active-server items keep the raw value.
    final rawServerId = data['ServerId']?.toString() ?? '';
    final serverId = data['_moonfinServerId']?.toString() ?? rawServerId;
    final client = _clientForSource(
      _MediaBarSource(serverId: serverId, libraryId: ''),
    );
    final providerIds = data['ProviderIds'] as Map<String, dynamic>?;

    final backdropTags = data['BackdropImageTags'] as List?;
    final backdropUrl = (backdropTags != null && backdropTags.isNotEmpty)
        ? client.imageApi.getBackdropImageUrl(
            itemId,
            tag: backdropTags[0] as String,
            maxWidth: 1280,
          )
        : null;

    final logoTag = (data['ImageTags'] as Map?)?['Logo'] as String?;
    final logoUrl = logoTag != null
        ? client.imageApi.getLogoImageUrl(itemId, tag: logoTag, maxWidth: 600)
        : null;

    final primaryTag = (data['ImageTags'] as Map?)?['Primary'] as String?;
    final posterUrl = client.imageApi.getPrimaryImageUrl(
      itemId,
      tag: primaryTag,
      maxWidth: 600,
    );

    final runTimeTicks = data['RunTimeTicks'] as int?;

    return MediaBarSlideItem(
      itemId: itemId,
      serverId: serverId,
      title: data['Name'] as String? ?? '',
      overview: data['Overview'] as String?,
      backdropUrl: backdropUrl,
      logoUrl: logoUrl,
      posterUrl: posterUrl,
      officialRating: data['OfficialRating'] as String?,
      year: data['ProductionYear'] as int?,
      genres:
          (data['Genres'] as List?)?.cast<String>().take(3).toList() ??
          const [],
      runtime: runTimeTicks != null
          ? Duration(microseconds: runTimeTicks ~/ 10)
          : null,
      communityRating: (data['CommunityRating'] as num?)?.toDouble(),
      criticRating: (data['CriticRating'] as num?)?.toInt(),
      tmdbId: (providerIds?['Tmdb'] ?? providerIds?['tmdb'])?.toString(),
      imdbId: (providerIds?['Imdb'] ?? providerIds?['imdb'])?.toString(),
      itemType: data['Type'] as String? ?? 'Movie',
      remoteTrailers:
          (data['RemoteTrailers'] as List?)?.cast<Map<String, dynamic>>() ??
          const [],
    );
  }
}

// A library source: the app-level server id (empty = the active server) plus
// the library id on that server.
class _MediaBarSource {
  final String serverId;
  final String libraryId;

  const _MediaBarSource({required this.serverId, required this.libraryId});

  bool get isActiveServer => serverId.isEmpty;

  String get sourceKey =>
      serverId.isEmpty ? libraryId : '$serverId|$libraryId';
}

// A mixed library names no collection type, so the bar takes it for either
// kind. Folders and recordings name none either, but a query on one of those
// reaches every library, so they go out by name.
bool supportsMediaBarLibrary(
  Map<String, dynamic> view,
  List<String> preferredTypes,
) {
  final name = (view['Name']?.toString() ?? '').trim().toLowerCase();
  if (name == 'folders' || name == 'recordings') return false;

  final type = (view['CollectionType']?.toString() ?? '').trim().toLowerCase();
  if (type.isEmpty || type == 'mixed' || type == 'unknown') return true;

  return preferredTypes.contains(type);
}
