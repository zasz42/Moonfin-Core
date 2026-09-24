import 'dart:async';

import 'package:get_it/get_it.dart';
import 'package:logger/logger.dart';
import 'package:server_core/server_core.dart';

import '../../auth/models/server.dart';
import '../../auth/repositories/session_repository.dart';
import '../../auth/store/authentication_store.dart';
import '../../auth/store/credential_store.dart';
import '../../preference/preference_constants.dart';
import '../../preference/user_preferences.dart';
import '../../util/server_url.dart';
import '../models/aggregated_item.dart';
import '../models/aggregated_library.dart';
import '../models/home_row.dart';
import '../services/better_posters_service.dart';
import '../services/media_server_client_factory.dart';
import '../utils/blocked_ratings.dart';
import '../utils/bounded_concurrency.dart';
import '../utils/genre_browse_utils.dart';
import '../utils/latest_media_row_normalizer.dart';
import '../utils/next_up_cutoff.dart';
import '../utils/next_up_enrichment.dart';
import '../utils/playlist_utils.dart';
import 'user_views_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/current_app_localizations.dart';

class ServerUserSession {
  final Server server;
  final String userId;
  final MediaServerClient client;

  const ServerUserSession({
    required this.server,
    required this.userId,
    required this.client,
  });
}

/// A playback target translated to the server that should serve it, plus the
/// media source that should be requested on that server.
class ResolvedPlaybackItem {
  final AggregatedItem item;
  final String? mediaSourceId;

  const ResolvedPlaybackItem({required this.item, this.mediaSourceId});
}

class MultiServerRepository {
  final AuthenticationStore _authStore;
  final CredentialStore _credentialStore;
  final MediaServerClientFactory _clientFactory;
  final SessionRepository _sessionRepo;
  final _logger = Logger();

  static const _sessionCacheDuration = Duration(seconds: 5);
  static const _serverTimeout = Duration(seconds: 8);
  static const _fields =
      'DateCreated,Type,UserData,Overview,Genres,CommunityRating,CriticRating,'
      'OfficialRating,RunTimeTicks,ProductionYear,SeriesName,'
      'ParentIndexNumber,IndexNumber,Status,ImageTags,BackdropImageTags,'
      'ParentBackdropItemId,ParentBackdropImageTags,ParentThumbItemId,'
      'ParentThumbImageTag,SeriesId,SeriesPrimaryImageTag,'
      'ParentLogoItemId,ParentLogoImageTag,PrimaryImageTag,PrimaryImageAspectRatio,'
      'ProviderIds';
  // Cap image tags to one per type (server returns all by default)
  static const _imageTypes = 'Primary,Backdrop,Thumb,Banner';
  static const _imageTypeLimit = 1;
  static const _defaultLimit = 15;
  static const _maxItems = 100;
  static const _defaultSortBy = 'SortName';
  static const _defaultSortOrder = 'Ascending';
  static const _studioPageSize = 200;
  static const _genreArtworkConcurrency = 6;

  List<ServerUserSession>? _cachedSessions;
  DateTime _cacheExpiry = DateTime(0);
  final Map<String, int> _rowOffsets = {};
  final Map<String, int> _rowTotals = {};

  void clearOffsets() {
    _rowOffsets.clear();
    _rowTotals.clear();
  }

  MultiServerRepository(
    this._authStore,
    this._credentialStore,
    this._clientFactory,
    this._sessionRepo,
  );

  AppLocalizations get _l10n => currentAppLocalizations();

  ImageApi getImageApiForServer(String serverId) {
    final client = _clientFactory.getClientIfExists(serverId);
    return client?.imageApi ?? _clientFactory.getActiveClient().imageApi;
  }

  Future<List<ServerUserSession>> getLoggedInServers() async {
    if (_cachedSessions != null && DateTime.now().isBefore(_cacheExpiry)) {
      return _cachedSessions!;
    }

    final servers = _authStore.getServers();
    final activeServerId = _sessionRepo.activeServerId;

    final sessions = <ServerUserSession>[];

    for (final server in servers) {
      try {
        final users = _authStore.getUsers(server.id);
        if (users.isEmpty) continue;

        String? userId;
        String? accessToken;

        if (server.id == activeServerId && _sessionRepo.activeUserId != null) {
          final activeUser = users
              .where((u) => u.id == _sessionRepo.activeUserId)
              .firstOrNull;
          if (activeUser != null && activeUser.accessToken.isNotEmpty) {
            userId = activeUser.id;
            accessToken = activeUser.accessToken;
          }
        }

        if (userId == null) {
          final token = await _credentialStore.getToken(server.id);
          for (final user in users) {
            final userToken = token ?? user.accessToken;
            if (userToken.isNotEmpty) {
              userId = user.id;
              accessToken = userToken;
              break;
            }
          }
        }

        if (userId == null || accessToken == null || accessToken.isEmpty) {
          continue;
        }

        final client = _clientFactory.getClient(
          serverId: server.id,
          serverType: server.serverType,
          baseUrl: server.address,
        );
        client.accessToken = accessToken;
        client.userId = userId;

        sessions.add(
          ServerUserSession(server: server, userId: userId, client: client),
        );
      } catch (e) {
        _logger.w('MultiServer: Error checking server ${server.name}: $e');
      }
    }

    _cachedSessions = sessions;
    _cacheExpiry = DateTime.now().add(_sessionCacheDuration);
    return sessions;
  }

  // Concurrent callers share one in-flight aggregation instead of each
  // fanning out to every server.
  Future<List<AggregatedLibrary>>? _inFlightLibraries;

  Future<List<AggregatedLibrary>> getAggregatedLibraries() =>
      _inFlightLibraries ??= _getAggregatedLibrariesNow().whenComplete(
        () => _inFlightLibraries = null,
      );

  Future<List<AggregatedLibrary>> _getAggregatedLibrariesNow() async {
    final sessions = await getLoggedInServers();
    final hasMultiple = sessions.length > 1;

    final results = await Future.wait(
      sessions.map(
        (session) => _withTimeout(() async {
          final response = await loadVisibleUserViews(session.client);
          final items = response['Items'] as List? ?? [];

          return items.map((item) {
            final data = item as Map<String, dynamic>;
            final name = data['Name'] as String? ?? '';
            return AggregatedLibrary(
              id: data['Id']?.toString() ?? '',
              name: hasMultiple
                  ? _l10n.libraryNameWithServer(name, session.server.name)
                  : name,
              collectionType: data['CollectionType'] as String? ?? '',
              serverId: session.server.id,
              primaryImageAspectRatio: (data['PrimaryImageAspectRatio'] as num?)
                  ?.toDouble(),
              imageTags: data['ImageTags'] != null
                  ? Map<String, dynamic>.from(data['ImageTags'] as Map)
                  : null,
              backdropImageTags: (data['BackdropImageTags'] as List?)
                  ?.map((e) => e.toString())
                  .toList(),
            );
          }).toList();
        }, label: 'libraries from ${session.server.name}'),
      ),
    );

    return results.expand((e) => e).toList();
  }

  Future<HomeRow> getAggregatedResume({int limit = _defaultLimit}) async {
    final sessions = await getLoggedInServers();
    final perServer = (limit * 3).clamp(1, 100);

    final results = await _gatherPerServer(
      sessions,
      (session) async {
        final response = await session.client.itemsApi.getResumeItems(
          mediaTypes: 'Video',
          limit: perServer,
          fields: _fields,
          enableImageTypes: _imageTypes,
          imageTypeLimit: _imageTypeLimit,
        );
        return _parseItems(response, session.server.id);
      },
      label: 'resume',
    );

    // One card per title across servers; Remux copies win so the row plays
    // the local/Debrid versions.
    final remuxServerIds = <String>{
      for (final session in sessions)
        if (isRemuxServerName(session.server.name)) session.server.id,
    };
    final all =
        dedupMergedRows(
              results.expand((e) => e),
              remuxServerIds: remuxServerIds,
            )
            ..sort(_compareByLastPlayed);

    return HomeRow(
      id: 'resume',
      title: _l10n.continueWatching,
      items: all.take(limit).toList(),
      rowType: HomeRowType.resume,
    );
  }

  Future<HomeRow> getAggregatedResumeAudio({int limit = _defaultLimit}) async {
    final sessions = await getLoggedInServers();
    final perServer = (limit * 3).clamp(1, 100);

    final results = await Future.wait(
      sessions.map(
        (session) => _withTimeout(() async {
          final response = await session.client.itemsApi.getResumeItems(
            mediaTypes: 'Audio',
            limit: perServer,
            fields: _fields,
            enableImageTypes: _imageTypes,
            imageTypeLimit: _imageTypeLimit,
          );
          return _parseItems(response, session.server.id);
        }, label: 'resume audio from ${session.server.name}'),
      ),
    );

    final remuxServerIds = <String>{
      for (final session in sessions)
        if (isRemuxServerName(session.server.name)) session.server.id,
    };
    final all =
        dedupMergedRows(
              results.expand((e) => e),
              remuxServerIds: remuxServerIds,
            )
            ..sort(_compareByLastPlayed);

    return HomeRow(
      id: 'resumeAudio',
      title: _l10n.continueListening,
      items: all.take(limit).toList(),
      rowType: HomeRowType.resumeAudio,
    );
  }

  Future<HomeRow> getAggregatedNextUp({int limit = _defaultLimit}) async {
    final sessions = await getLoggedInServers();
    final perServer = (limit * 3).clamp(1, 100);

    final results = await _gatherPerServer(
      sessions,
      (session) async {
        final response = await session.client.itemsApi.getNextUp(
          limit: perServer,
          fields: _fields,
          enableImageTypes: _imageTypes,
          imageTypeLimit: _imageTypeLimit,
          enableResumable: false,
          nextUpDateCutoff: nextUpDateCutoff,
        );
        final parsed = _parseItems(response, session.server.id);
        return await _enrichNextUpItemsWithSeriesLastPlayed(
          parsed,
          session.client,
        );
      },
      label: 'next up',
    );

    // One card per title across servers; Remux copies win so the row plays
    // the local/Debrid versions.
    final remuxServerIds = <String>{
      for (final session in sessions)
        if (isRemuxServerName(session.server.name)) session.server.id,
    };
    final all =
        dedupMergedRows(
              results.expand((e) => e),
              remuxServerIds: remuxServerIds,
            )
            ..sort(_compareByLastPlayed);

    return HomeRow(
      id: 'nextUp',
      title: _l10n.nextUp,
      items: all.take(limit).toList(),
      rowType: HomeRowType.nextUp,
    );
  }

  Future<HomeRow> getAggregatedPlaylists({
    int limit = _defaultLimit,
    String sortBy = _defaultSortBy,
    String sortOrder = _defaultSortOrder,
    String? mediaType,
  }) async {
    final sessions = await getLoggedInServers();
    final isAudio = mediaType == 'Audio';
    final cacheKeyPrefix = isAudio ? 'audioPlaylists' : 'playlists';

    final results = await Future.wait(
      sessions.map(
        (session) => _withTimeout(() async {
          final response = await session.client.itemsApi.getItems(
            includeItemTypes: const ['Playlist'],
            sortBy: sortBy,
            sortOrder: sortOrder,
            recursive: true,
            limit: limit,
            fields: '$_fields,ChildCount,RecursiveItemCount',
            enableImageTypes: _imageTypes,
            imageTypeLimit: _imageTypeLimit,
          );
          final playlistsOnly = _parseItems(response, session.server.id)
              .where((item) => item.type == 'Playlist')
              .toList();
          final items = await filterBrowsablePlaylists(
            session.client,
            playlistsOnly,
            mediaType: mediaType,
          );
          _rowTotals['${cacheKeyPrefix}_${session.server.id}'] =
              response['TotalRecordCount'] as int? ?? items.length;
          return items;
        }, label: '$cacheKeyPrefix from ${session.server.name}'),
      ),
    );

    final all = results.expand((e) => e).toList();
    if (sortBy == 'SortName') {
      if (sortOrder == 'Ascending') {
        all.sort((a, b) => a.name.compareTo(b.name));
      } else {
        all.sort((a, b) => b.name.compareTo(a.name));
      }
    } else {
      _sortAggregatedItems(all, sortBy: sortBy, sortOrder: sortOrder);
    }

    final takenItems = all.take(limit).toList();
    final totalCount = sessions.fold<int>(0, (sum, session) {
      return sum + (_rowTotals['${cacheKeyPrefix}_${session.server.id}'] ?? 0);
    });

    return HomeRow(
      id: cacheKeyPrefix,
      title: isAudio ? _l10n.audioPlaylists : _l10n.playlists,
      items: takenItems,
      rowType: isAudio ? HomeRowType.audioPlaylists : HomeRowType.playlists,
      totalCount: totalCount,
      isAudio: isAudio,
    );
  }

  Future<HomeRow> getAggregatedAudioArtists({
    int limit = _defaultLimit,
    String sortBy = _defaultSortBy,
    String sortOrder = _defaultSortOrder,
  }) async {
    final row = await _getAggregatedSortedItemsRow(
      id: 'audioArtists',
      title: _l10n.artists,
      rowType: HomeRowType.audioArtists,
      includeItemTypes: const ['MusicArtist'],
      limit: limit,
      logPrefix: 'audioArtists',
      sortBy: sortBy,
      sortOrder: sortOrder,
    );
    return row.copyWith(isAudio: true);
  }

  Future<HomeRow> getAggregatedAudioAlbums({
    int limit = _defaultLimit,
    String sortBy = _defaultSortBy,
    String sortOrder = _defaultSortOrder,
  }) async {
    final row = await _getAggregatedSortedItemsRow(
      id: 'audioAlbums',
      title: _l10n.albums,
      rowType: HomeRowType.audioAlbums,
      includeItemTypes: const ['MusicAlbum'],
      limit: limit,
      logPrefix: 'audioAlbums',
      sortBy: sortBy,
      sortOrder: sortOrder,
    );
    return row.copyWith(isAudio: true);
  }

  Future<HomeRow> getAggregatedAudioPlaylists({
    int limit = _defaultLimit,
    String sortBy = _defaultSortBy,
    String sortOrder = _defaultSortOrder,
  }) async {
    return getAggregatedPlaylists(
      limit: limit,
      sortBy: sortBy,
      sortOrder: sortOrder,
      mediaType: 'Audio',
    );
  }


  Future<HomeRow> getAggregatedFavorites({
    required String rowId,
    required String title,
    List<String>? includeItemTypes,
    int limit = _defaultLimit,
    String sortBy = _defaultSortBy,
    String sortOrder = _defaultSortOrder,
  }) async {
    return _getAggregatedSortedItemsRow(
      id: rowId,
      title: title,
      rowType: HomeRowType.favorites,
      includeItemTypes: includeItemTypes,
      isFavorite: true,
      limit: limit,
      logPrefix: 'favorites',
      sortBy: sortBy,
      sortOrder: sortOrder,
    );
  }

  Future<HomeRow> getAggregatedCollections({
    int limit = _defaultLimit,
    String sortBy = _defaultSortBy,
    String sortOrder = _defaultSortOrder,
  }) async {
    return _getAggregatedSortedItemsRow(
      id: 'collections',
      title: _l10n.collections,
      rowType: HomeRowType.collections,
      includeItemTypes: const ['BoxSet'],
      limit: limit,
      logPrefix: 'collections',
      sortBy: sortBy,
      sortOrder: sortOrder,
    );
  }

  Future<HomeRow> getAggregatedGenres({
    int limit = _defaultLimit,
    String sortBy = _defaultSortBy,
    String sortOrder = _defaultSortOrder,
    List<String>? includeItemTypes,
  }) async {
    const cacheKeyPrefix = 'genres';
    const rowType = HomeRowType.genres;

    final browseItemTypes = normalizeBrowsableGenreItemTypes(includeItemTypes);
    final sessions = await getLoggedInServers();
    final perServer = (limit * 3).clamp(1, 100);

    final results = await Future.wait(
      sessions.map(
        (session) => _withTimeout(() async {
          final response = await session.client.itemsApi.getGenres(
            sortBy: sortBy,
            sortOrder: sortOrder,
            recursive: true,
            limit: perServer,
            fields: 'ItemCounts,PrimaryImageAspectRatio',
            includeItemTypes: browseItemTypes,
          );
          final items = await _buildBrowsableGenresForSession(
            session,
            response,
            includeItemTypes: browseItemTypes,
          );
          _rowTotals['${cacheKeyPrefix}_${session.server.id}'] =
              response['TotalRecordCount'] as int? ?? items.length;
          return items;
        }, label: '$cacheKeyPrefix from ${session.server.name}'),
      ),
    );

    final all = _sortAggregatedItems(
      results.expand((e) => e).toList(growable: false),
      sortBy: sortBy,
      sortOrder: sortOrder,
    );

    final takenItems = all.take(limit).toList();
    final totalCount = sessions.fold<int>(0, (sum, session) {
      return sum + (_rowTotals['${cacheKeyPrefix}_${session.server.id}'] ?? 0);
    });

    return HomeRow(
      id: cacheKeyPrefix,
      title: _l10n.genres,
      items: takenItems,
      rowType: rowType,
      totalCount: totalCount,
    );
  }

  Future<HomeRow> getAggregatedStudios({
    int limit = _defaultLimit,
    String sortBy = _defaultSortBy,
    String sortOrder = _defaultSortOrder,
    String selectedIds = '',
    String? title,
  }) async {
    const cacheKeyPrefix = 'studios';
    const rowType = HomeRowType.studios;

    final sessions = await getLoggedInServers();
    final perServer = (limit * 3).clamp(1, 100);

    final selectedSet = selectedIds
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();

    final results = await Future.wait(
      sessions.map(
        (session) => _withTimeout(() async {
          Future<Map<String, dynamic>> fetchPage(int startIndex, int limit) =>
              session.client.itemsApi.getStudios(
                userId: session.client.userId,
                sortBy: sortBy,
                sortOrder: sortOrder,
                recursive: true,
                startIndex: startIndex,
                limit: limit,
                fields: 'ItemCounts,PrimaryImageAspectRatio',
              );

          if (selectedSet.isEmpty) {
            final response = await fetchPage(0, perServer);
            return _parseItems(response, session.server.id);
          }
          return _collectStudios(selectedSet, session.server.id, fetchPage);
        }, label: '$cacheKeyPrefix from ${session.server.name}'),
      ),
    );

    final all = _sortAggregatedItems(
      results.expand((e) => e).toList(growable: false),
      sortBy: sortBy,
      sortOrder: sortOrder,
    );

    // The row arrives complete either way, so the count has to match what it
    // holds or it will claim a next page that no one can serve.
    final items = selectedSet.isEmpty ? all.take(limit).toList() : all;

    return HomeRow(
      id: cacheKeyPrefix,
      title: title ?? _l10n.studios,
      items: items,
      rowType: rowType,
      totalCount: items.length,
    );
  }

  /// Walks one server's studio list a page at a time until every id in
  /// [wanted] has turned up.
  ///
  /// The endpoint has no way to ask for particular studios and a library can
  /// report well over a thousand of them, so reading the lot to keep a handful
  /// is a heavy call to make on every home load, once per server. Stopping once
  /// the selection is accounted for usually means one page.
  Future<List<AggregatedItem>> _collectStudios(
    Set<String> wanted,
    String serverId,
    Future<Map<String, dynamic>> Function(int startIndex, int limit) fetchPage,
  ) async {
    final outstanding = wanted.toSet();
    final found = <AggregatedItem>[];
    var startIndex = 0;

    while (outstanding.isNotEmpty) {
      final response = await fetchPage(startIndex, _studioPageSize);
      // Paging walks the server's own count. A page that comes back short
      // because items were filtered out of it is still a full page as far as
      // the next offset is concerned.
      final rawCount = (response['Items'] as List?)?.length ?? 0;
      if (rawCount == 0) break;
      for (final studio in _parseItems(response, serverId)) {
        if (outstanding.remove(studio.id)) found.add(studio);
      }
      if (rawCount < _studioPageSize) break;
      startIndex += _studioPageSize;
    }

    return found;
  }

  Future<(List<AggregatedItem>, int)> loadMore({required HomeRow row}) async {
    if (!row.hasMore || row.items.length >= _maxItems) {
      return (row.items, row.totalCount);
    }

    final prefs = GetIt.instance.isRegistered<UserPreferences>()
        ? GetIt.instance<UserPreferences>()
        : null;
    final sessions = await getLoggedInServers();

    // Group existing items by serverId to know how many items we already have for each server
    final Map<String, List<AggregatedItem>> itemsByServer = {};
    for (final item in row.items) {
      itemsByServer.putIfAbsent(item.serverId, () => []).add(item);
    }

    final results = await Future.wait(
      sessions.map(
        (session) => _withTimeout(() async {
          final serverId = session.server.id;
          final cacheKey = '${row.id}_$serverId';
          final existingCount = itemsByServer[serverId]?.length ?? 0;

          int startIndex = existingCount;
          final trackedOffset = _rowOffsets[cacheKey];
          if (trackedOffset != null && trackedOffset > existingCount) {
            startIndex = trackedOffset;
          }

          switch (row.rowType) {
            case HomeRowType.playlists:
              final pageCount = (startIndex / _defaultLimit).ceil();
              final targetStartIndex = pageCount * _defaultLimit;
              _rowOffsets[cacheKey] = targetStartIndex + _defaultLimit;
              final sortBy =
                  prefs?.get(UserPreferences.playlistsRowSortBy).apiValue ??
                  _defaultSortBy;
              final sortOrder =
                  prefs?.get(UserPreferences.playlistsRowSortOrder).apiValue ??
                  _defaultSortOrder;

              final response = await session.client.itemsApi.getItems(
                includeItemTypes: const ['Playlist'],
                sortBy: sortBy,
                sortOrder: sortOrder,
                recursive: true,
                startIndex: targetStartIndex,
                limit: _defaultLimit,
                fields: _fields,
                enableImageTypes: _imageTypes,
                imageTypeLimit: _imageTypeLimit,
              );
              final items = await filterBrowsablePlaylists(
                session.client,
                _parseItems(response, serverId),
              );
              _rowTotals[cacheKey] =
                  response['TotalRecordCount'] as int? ?? items.length;
              return items;
            case HomeRowType.audioPlaylists:
              final pageCount = (startIndex / _defaultLimit).ceil();
              final targetStartIndex = pageCount * _defaultLimit;
              _rowOffsets[cacheKey] = targetStartIndex + _defaultLimit;
              final sortBy =
                  prefs?.get(UserPreferences.audioRowsSortBy).apiValue ??
                  _defaultSortBy;
              final sortOrder =
                  prefs?.get(UserPreferences.audioRowsSortOrder).apiValue ??
                  _defaultSortOrder;

              final response = await session.client.itemsApi.getItems(
                includeItemTypes: const ['Playlist'],
                sortBy: sortBy,
                sortOrder: sortOrder,
                recursive: true,
                startIndex: targetStartIndex,
                limit: _defaultLimit,
                fields: _fields,
                enableImageTypes: _imageTypes,
                imageTypeLimit: _imageTypeLimit,
              );
              final items = await filterBrowsablePlaylists(
                session.client,
                _parseItems(response, serverId),
                mediaType: 'Audio',
              );
              _rowTotals[cacheKey] =
                  response['TotalRecordCount'] as int? ?? items.length;
              return items;
            case HomeRowType.audioArtists:
              _rowOffsets[cacheKey] = startIndex + _defaultLimit;
              final sortBy =
                  prefs?.get(UserPreferences.audioRowsSortBy).apiValue ??
                  _defaultSortBy;
              final sortOrder =
                  prefs?.get(UserPreferences.audioRowsSortOrder).apiValue ??
                  _defaultSortOrder;

              final response = await session.client.itemsApi.getItems(
                includeItemTypes: const ['MusicArtist'],
                sortBy: sortBy,
                sortOrder: sortOrder,
                recursive: true,
                startIndex: startIndex,
                limit: _defaultLimit,
                fields: _fields,
                enableImageTypes: _imageTypes,
                imageTypeLimit: _imageTypeLimit,
              );
              final items = _parseItems(response, serverId);
              _rowTotals[cacheKey] =
                  response['TotalRecordCount'] as int? ?? items.length;
              return items;
            case HomeRowType.audioAlbums:
              _rowOffsets[cacheKey] = startIndex + _defaultLimit;
              final sortBy =
                  prefs?.get(UserPreferences.audioRowsSortBy).apiValue ??
                  _defaultSortBy;
              final sortOrder =
                  prefs?.get(UserPreferences.audioRowsSortOrder).apiValue ??
                  _defaultSortOrder;

              final response = await session.client.itemsApi.getItems(
                includeItemTypes: const ['MusicAlbum'],
                sortBy: sortBy,
                sortOrder: sortOrder,
                recursive: true,
                startIndex: startIndex,
                limit: _defaultLimit,
                fields: _fields,
                enableImageTypes: _imageTypes,
                imageTypeLimit: _imageTypeLimit,
              );
              final items = _parseItems(response, serverId);
              _rowTotals[cacheKey] =
                  response['TotalRecordCount'] as int? ?? items.length;
              return items;
            case HomeRowType.favorites:
              final favoriteFilter = FavoriteTypeFilter.fromRowId(row.id);
              final sortBy =
                  prefs?.get(UserPreferences.favoritesRowSortBy).apiValue ??
                  _defaultSortBy;
              final sortOrder =
                  prefs?.get(UserPreferences.favoritesRowSortOrder).apiValue ??
                  _defaultSortOrder;
              _rowOffsets[cacheKey] = startIndex + _defaultLimit;

              final response = await session.client.itemsApi.getItems(
                includeItemTypes: favoriteFilter.itemTypes,
                sortBy: sortBy,
                sortOrder: sortOrder,
                recursive: true,
                startIndex: startIndex,
                limit: _defaultLimit,
                isFavorite: true,
                fields: _fields,
                enableImageTypes: _imageTypes,
                imageTypeLimit: _imageTypeLimit,
              );
              final items = _parseItems(response, serverId);
              _rowTotals[cacheKey] =
                  response['TotalRecordCount'] as int? ?? items.length;
              return items;
            case HomeRowType.collections:
              final sortBy =
                  prefs?.get(UserPreferences.collectionsRowSortBy).apiValue ??
                  _defaultSortBy;
              final sortOrder =
                  prefs?.get(UserPreferences.collectionsRowSortOrder).apiValue ??
                  _defaultSortOrder;
              _rowOffsets[cacheKey] = startIndex + _defaultLimit;

              final response = await session.client.itemsApi.getItems(
                includeItemTypes: const ['BoxSet'],
                sortBy: sortBy,
                sortOrder: sortOrder,
                recursive: true,
                startIndex: startIndex,
                limit: _defaultLimit,
                fields: _fields,
                enableImageTypes: _imageTypes,
                imageTypeLimit: _imageTypeLimit,
              );
              final items = _parseItems(response, serverId);
              _rowTotals[cacheKey] =
                  response['TotalRecordCount'] as int? ?? items.length;
              return items;
            case HomeRowType.genres:
              final sortBy =
                  prefs?.get(UserPreferences.genresRowSortBy).apiValue ??
                  _defaultSortBy;
              final sortOrder =
                  prefs?.get(UserPreferences.genresRowSortOrder).apiValue ??
                  _defaultSortOrder;
              final includeItemTypes = prefs
                  ?.get(UserPreferences.genresRowItemFilter)
                  .includeItemTypes;
              final browseItemTypes = normalizeBrowsableGenreItemTypes(
                includeItemTypes,
              );
              if (row.id == 'genres') {
                final pageCount = (startIndex / _defaultLimit).ceil();
                final targetStartIndex = pageCount * _defaultLimit;
                _rowOffsets[cacheKey] = targetStartIndex + _defaultLimit;

                final response = await session.client.itemsApi.getGenres(
                  sortBy: sortBy,
                  sortOrder: sortOrder,
                  recursive: true,
                  startIndex: targetStartIndex,
                  limit: _defaultLimit,
                  fields: 'ItemCounts',
                  includeItemTypes: browseItemTypes,
                );
                final items = await _buildBrowsableGenresForSession(
                  session,
                  response,
                  includeItemTypes: browseItemTypes,
                );
                _rowTotals[cacheKey] =
                    response['TotalRecordCount'] as int? ?? items.length;
                return items;
              } else {
                _rowOffsets[cacheKey] = startIndex + _defaultLimit;

                final response = await session.client.itemsApi.getItems(
                  genreIds: [row.id],
                  sortBy: sortBy,
                  sortOrder: sortOrder,
                  recursive: true,
                  startIndex: startIndex,
                  limit: _defaultLimit,
                  includeItemTypes: includeItemTypes,
                  excludeItemTypes: const ['Episode'],
                  fields: _fields,
                  enableImageTypes: _imageTypes,
                  imageTypeLimit: _imageTypeLimit,
                );
                final items = _parseItems(response, serverId);
                _rowTotals[cacheKey] =
                    response['TotalRecordCount'] as int? ?? items.length;
                return items;
              }
            case HomeRowType.latestMedia:
              if (row.id.startsWith('latest_')) {
                final parts = row.id.split('_');
                if (parts.length >= 3) {
                  final rowServerId = parts[1];
                  final parentId = parts[2];
                  if (serverId != rowServerId) return const <AggregatedItem>[];

                  _rowOffsets[cacheKey] = startIndex + _defaultLimit;
                  final targetLimit = startIndex + _defaultLimit;

                  final response = await session.client.itemsApi.getLatestItems(
                    parentId: parentId,
                    limit: targetLimit,
                    fields: _fields,
                    enableImageTypes: _imageTypes,
                    imageTypeLimit: _imageTypeLimit,
                  );
                  final items = normalizeLatestMediaItems(
                    _parseItems(response, serverId),
                    limit: targetLimit,
                  );
                  if (items.length <= existingCount) {
                    _rowTotals[cacheKey] = items.length;
                  } else {
                    _rowTotals[cacheKey] =
                        response['TotalRecordCount'] as int? ?? _maxItems;
                  }
                  return items;
                }
              }
              return const <AggregatedItem>[];
            default:
              return const <AggregatedItem>[];
          }
        }, label: 'loadMore ${row.rowType} from ${session.server.name}'),
      ),
    );

    final newItems = results.expand((e) => e).toList();
    if (newItems.isEmpty) return (row.items, row.totalCount);

    // Merge and sort
    final combined = [...row.items, ...newItems];

    // Deduplicate unique items
    final seen = <String>{};
    final uniqueCombined = combined
        .where((item) => seen.add('${item.serverId}_${item.id}'))
        .toList();

    final List<AggregatedItem> sortedCombined;
    if (row.rowType == HomeRowType.playlists ||
        row.rowType == HomeRowType.audioPlaylists ||
        row.rowType == HomeRowType.latestMedia) {
      if (row.rowType == HomeRowType.playlists ||
          row.rowType == HomeRowType.audioPlaylists) {
        final sortBy = row.rowType == HomeRowType.audioPlaylists
            ? (prefs?.get(UserPreferences.audioRowsSortBy).apiValue ?? _defaultSortBy)
            : (prefs?.get(UserPreferences.playlistsRowSortBy).apiValue ?? _defaultSortBy);
        final sortOrder = row.rowType == HomeRowType.audioPlaylists
            ? (prefs?.get(UserPreferences.audioRowsSortOrder).apiValue ??
                  _defaultSortOrder)
            : (prefs?.get(UserPreferences.playlistsRowSortOrder).apiValue ??
                  _defaultSortOrder);
        if (sortBy == 'SortName') {
          final ascending = sortOrder == SortDirection.ascending.apiValue;
          uniqueCombined.sort(
            (a, b) => ascending
                ? a.name.compareTo(b.name)
                : b.name.compareTo(a.name),
          );
        } else {
          _sortAggregatedItems(
            uniqueCombined,
            sortBy: sortBy,
            sortOrder: sortOrder,
          );
        }
      }
      sortedCombined = uniqueCombined;
    } else {
      final collectionsSort = prefs?.get(UserPreferences.collectionsRowSortBy);
      // For a specific pinned collection row using Playlist Order, preserve the
      // server-returned insertion order — don't re-sort on the client side.
      // The generic 'collections' all-BoxSets row (row.id == 'collections') has
      // no parentId, so playlistOrder is never active for it.
      final collectionsUsePlaylistOrder =
          row.rowType == HomeRowType.collections &&
          (collectionsSort?.usesDedicatedEndpoint ?? false) &&
          row.id != 'collections';
      if (collectionsUsePlaylistOrder) {
        sortedCombined = uniqueCombined;
      } else {
        final sortBy = switch (row.rowType) {
          HomeRowType.favorites =>
            prefs?.get(UserPreferences.favoritesRowSortBy).apiValue ??
                _defaultSortBy,
          HomeRowType.collections =>
            collectionsSort?.apiValue ?? _defaultSortBy,
          HomeRowType.genres =>
            prefs?.get(UserPreferences.genresRowSortBy).apiValue ??
                _defaultSortBy,
          HomeRowType.audioArtists ||
          HomeRowType.audioAlbums =>
            prefs?.get(UserPreferences.audioRowsSortBy).apiValue ??
                _defaultSortBy,
          _ => _defaultSortBy,
        };
        final sortOrder = switch (row.rowType) {
          HomeRowType.favorites =>
            prefs?.get(UserPreferences.favoritesRowSortOrder).apiValue ??
                _defaultSortOrder,
          HomeRowType.collections =>
            prefs?.get(UserPreferences.collectionsRowSortOrder).apiValue ??
                _defaultSortOrder,
          HomeRowType.genres =>
            prefs?.get(UserPreferences.genresRowSortOrder).apiValue ??
                _defaultSortOrder,
          HomeRowType.audioArtists ||
          HomeRowType.audioAlbums =>
            prefs?.get(UserPreferences.audioRowsSortOrder).apiValue ??
                _defaultSortOrder,
          _ => _defaultSortOrder,
        };

        sortedCombined = _sortAggregatedItems(
          uniqueCombined,
          sortBy: sortBy,
          sortOrder: sortOrder,
        );
      }
    }

    final totalCount = sessions.fold<int>(0, (sum, session) {
      return sum + (_rowTotals['${row.id}_${session.server.id}'] ?? 0);
    });

    return (sortedCombined, totalCount);
  }

  Future<HomeRow> _getAggregatedSortedItemsRow({
    required String id,
    required String title,
    required HomeRowType rowType,
    required String logPrefix,
    List<String>? includeItemTypes,
    bool? isFavorite,
    int limit = _defaultLimit,
    String sortBy = _defaultSortBy,
    String sortOrder = _defaultSortOrder,
  }) async {
    final sessions = await getLoggedInServers();
    final perServer = (limit * 3).clamp(1, 100);

    final results = await Future.wait(
      sessions.map(
        (session) => _withTimeout(() async {
          final response = await session.client.itemsApi.getItems(
            includeItemTypes: includeItemTypes,
            sortBy: sortBy,
            sortOrder: sortOrder,
            recursive: true,
            limit: perServer,
            isFavorite: isFavorite,
            fields: _fields,
            enableImageTypes: _imageTypes,
            imageTypeLimit: _imageTypeLimit,
          );
          final items = _parseItems(response, session.server.id);
          _rowTotals['${id}_${session.server.id}'] =
              response['TotalRecordCount'] as int? ?? items.length;
          return items;
        }, label: '$logPrefix from ${session.server.name}'),
      ),
    );

    final all = _sortAggregatedItems(
      results.expand((e) => e).toList(growable: false),
      sortBy: sortBy,
      sortOrder: sortOrder,
    );

    final takenItems = all.take(limit).toList();
    final totalCount = sessions.fold<int>(0, (sum, session) {
      return sum + (_rowTotals['${id}_${session.server.id}'] ?? 0);
    });

    return HomeRow(
      id: id,
      title: title,
      items: takenItems,
      rowType: rowType,
      totalCount: totalCount,
    );
  }

  Future<HomeRow> getAggregatedLibraryTiles({
    HomeRowType rowType = HomeRowType.libraryTiles,
  }) async {
    final libraries = await getAggregatedLibraries();
    final items = libraries
        .map(
          (lib) => AggregatedItem(
            id: lib.id,
            serverId: lib.serverId,
            rawData: {
              'Id': lib.id,
              'Name': lib.name,
              'CollectionType': lib.collectionType,
              'Type': 'CollectionFolder',
              if (lib.primaryImageAspectRatio != null)
                'PrimaryImageAspectRatio': lib.primaryImageAspectRatio,
              if (lib.imageTags != null) 'ImageTags': lib.imageTags,
              if (lib.backdropImageTags != null)
                'BackdropImageTags': lib.backdropImageTags,
            },
          ),
        )
        .toList();

    return HomeRow(
      id: rowType == HomeRowType.libraryTilesSmall
          ? 'libraryTilesSmall'
          : 'libraryTiles',
      title: _l10n.myMedia,
      items: items,
      rowType: rowType,
    );
  }

  Future<List<HomeRow>> getAggregatedLatestMediaRows() async {
    final sessions = await getLoggedInServers();
    final hasMultiple = sessions.length > 1;
    final rows = <HomeRow>[];

    final mergeByType = GetIt.instance<UserPreferences>().get(
      UserPreferences.mergeRecentRowsByType,
    );
    final groupedItems = <String, List<AggregatedItem>>{};

    for (final session in sessions) {
      try {
        final views = await _withTimeout(
          () => loadUserViews(session.client, includeHidden: true),
          label: 'views from ${session.server.name}',
        );

        Set<String> latestExcludes = const {};
        try {
          final config = await session.client.usersApi.getUserConfiguration();
          latestExcludes = config.latestItemsExcludes.toSet();
        } catch (_) {}

        for (final view in views) {
          final id = view.id;
          final collectionType = view.collectionType.toLowerCase();
          if (collectionType == 'playlists' ||
              collectionType == 'boxsets' ||
              collectionType == 'livetv') {
            continue;
          }
          if (latestExcludes.contains(id)) continue;

          final name = view.name;
          final fetchLimit = latestMediaFetchLimitForCollection(
            collectionType,
            defaultLimit: _defaultLimit,
            maxLimit: _maxItems,
          );

          try {
            final latestResponse = await _withTimeout(
              () => session.client.itemsApi.getLatestItems(
                parentId: id,
                limit: fetchLimit,
                fields: _fields,
                enableImageTypes: _imageTypes,
                imageTypeLimit: _imageTypeLimit,
              ),
              label: 'latest $name from ${session.server.name}',
            );

            final parsed = _parseItems(latestResponse, session.server.id);
            if (parsed.isEmpty) continue;

            // Merged rows are built once every server has answered, so the
            // items are only collected here.
            if (mergeByType) {
              groupedItems.putIfAbsent(collectionType, () => []).addAll(parsed);
              continue;
            }

            final items = normalizeLatestMediaItems(
              parsed,
              collectionType: collectionType,
              limit: _defaultLimit,
            );
            if (items.isEmpty) continue;

            final displayName = hasMultiple
                ? '$name (${session.server.name})'
                : name;
            final totalCount = items.length < _defaultLimit
                ? items.length
                : _maxItems;
            _rowTotals['latest_${session.server.id}_${id}_${session.server.id}'] =
                totalCount;
            rows.add(
              HomeRow(
                id: 'latest_${session.server.id}_$id',
                title: _l10n.latestLibraryName(displayName),
                items: items,
                rowType: HomeRowType.latestMedia,
                totalCount: totalCount,
                isAudio: collectionType == 'music',
              ),
            );
          } catch (e) {
            _logger.w('MultiServer: Failed to load latest for $name: $e');
          }
        }
      } catch (e) {
        _logger.w(
          'MultiServer: Failed to load views from ${session.server.name}: $e',
        );
      }
    }

    if (!mergeByType) return rows;

    // Server ids whose display name marks them as the Remux/Debrid source.
    // Their copies win when a title exists on several servers.
    final remuxServerIds = <String>{
      for (final session in sessions)
        if (isRemuxServerName(session.server.name)) session.server.id,
    };
 
    for (final entry in groupedItems.entries) {
      final collectionType = entry.key;

      // A title in two libraries, or on two servers, is kept once.
      // Jellyfin ids differ per server/library, and one side may only carry
      // a TMDB id (or none) where the other has IMDb, so any shared identity
      // key wins.
      final allItems = dedupMergedRows(
        entry.value,
        remuxServerIds: remuxServerIds,
      );
      if (allItems.isEmpty) continue;

      allItems.sort((a, b) {
        final da = _parseDateCreated(a.rawData['DateCreated']);
        final db = _parseDateCreated(b.rawData['DateCreated']);
        if (da != null && db != null) return db.compareTo(da);
        if (da != null) return -1;
        if (db != null) return 1;
        return 0;
      });

      final items = normalizeLatestMediaItems(
        allItems,
        collectionType: collectionType,
        limit: _defaultLimit,
      );
      if (items.isEmpty) continue;

      final rowId = '${mergedTypeRowIdPrefix}latest_$collectionType';
      _rowTotals[rowId] = items.length;
      rows.add(
        HomeRow(
          id: rowId,
          title: _l10n.latestLibraryName(
            genericDescriptorForCollectionType(_l10n, collectionType),
          ),
          items: items,
          rowType: HomeRowType.latestMedia,
          // Everything the row will ever hold is already here.
          totalCount: items.length,
          isAudio: collectionType == 'music',
        ),
      );
    }

    return rows;
  }

  Future<T> _withTimeout<T>(
    Future<T> Function() fn, {
    required String label,
  }) async {
    try {
      return await fn().timeout(_serverTimeout);
    } on TimeoutException {
      _logger.w('MultiServer: Timeout $label');
      rethrow;
    }
  }

  /// Runs [task] for every session and tolerates individual server failures,
  /// substituting an empty list for any server that timed out or errored. Throws
  /// only when every session fails, so callers can tell a real all-servers
  /// outage apart from a legitimately empty result and keep the previous row.
  Future<List<List<AggregatedItem>>> _gatherPerServer(
    List<ServerUserSession> sessions,
    Future<List<AggregatedItem>> Function(ServerUserSession session) task, {
    required String label,
  }) async {
    var failures = 0;
    final results = await Future.wait(
      sessions.map(
        (session) => _withTimeout(
          () => task(session),
          label: '$label from ${session.server.name}',
        ).catchError((_) {
          failures++;
          return <AggregatedItem>[];
        }),
      ),
    );
    if (sessions.isNotEmpty && failures == sessions.length) {
      throw StateError('MultiServer: all servers failed to load $label');
    }
    return results;
  }

  Future<List<AggregatedItem>> _buildBrowsableGenresForSession(
    ServerUserSession session,
    Map<String, dynamic> response, {
    required List<String> includeItemTypes,
  }) async {
    final rawItems = response['Items'] as List? ?? const [];
    final genres = rawItems
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .where(
          (genre) =>
              browsableGenreCount(
                genre,
                normalizedItemTypes: includeItemTypes,
              ) >
              0,
        )
        .toList(growable: false);

    if (genres.isEmpty) {
      return const [];
    }

    final resolved = await mapBounded(
      genres,
      _genreArtworkConcurrency,
      (genre) => _enrichSingleGenreForBrowse(
        session,
        genre,
        includeItemTypes: includeItemTypes,
      ),
    );

    return resolved.whereType<AggregatedItem>().toList();
  }

  Future<AggregatedItem?> _enrichSingleGenreForBrowse(
    ServerUserSession session,
    Map<String, dynamic> genreData, {
    required List<String> includeItemTypes,
  }) async {
    final genreId = genreData['Id']?.toString();
    if (genreId == null || genreId.isEmpty) {
      return null;
    }

    try {
      final response = await session.client.itemsApi.getItems(
        genreIds: [genreId],
        includeItemTypes: includeItemTypes,
        excludeItemTypes: const ['Episode'],
        sortBy: 'Random',
        sortOrder: 'Ascending',
        recursive: true,
        limit: 10,
        fields: _fields,
        enableImageTypes: _imageTypes,
        imageTypeLimit: _imageTypeLimit,
      );

      final items = (response['Items'] as List?) ?? const [];
      final maps = List<Map<String, dynamic>>.from(
        items.whereType<Map>().map((item) => item.cast<String, dynamic>()),
      );
      if (maps.isEmpty) {
        return null;
      }

      maps.shuffle();
      final representative = maps[0];
      final backdropRepresentative = maps.length > 1 ? maps[1] : null;

      final rawTotalCount = response['TotalRecordCount'];
      final totalCount = rawTotalCount is num
          ? rawTotalCount.toInt()
          : browsableGenreCount(
              genreData,
              normalizedItemTypes: includeItemTypes,
            );
      if (totalCount <= 0) {
        return null;
      }

      final merged = mergeGenreWithRepresentativeItem(
        genreData: genreData,
        representativeItem: representative,
        itemCount: totalCount,
        backdropRepresentativeItem: backdropRepresentative,
      );
      return AggregatedItem(
        id: merged['Id']?.toString() ?? '',
        serverId: session.server.id,
        rawData: merged,
      );
    } catch (_) {
      return null;
    }
  }

  List<AggregatedItem> _parseItems(
    Map<String, dynamic> response,
    String serverId,
  ) {
    final rawItems = response['Items'] as List? ?? [];
    final parsed = rawItems.map((item) {
      final data = item as Map<String, dynamic>;
      return AggregatedItem(
        id: data['Id']?.toString() ?? '',
        serverId: serverId,
        rawData: data,
      );
    }).toList();
    BetterPostersService.registerAll(parsed);
    return withoutBlockedItems(parsed);
  }

  List<AggregatedItem> _sortAggregatedItems(
    List<AggregatedItem> items, {
    required String sortBy,
    required String sortOrder,
  }) {
    final sorted = List<AggregatedItem>.of(items);
    if (sortBy == 'Random') {
      sorted.shuffle();
      return sorted;
    }

    int compare(AggregatedItem a, AggregatedItem b) {
      switch (sortBy) {
        case 'DateCreated':
          return _compareNullableDate(
            _parseDateCreated(a.rawData['DateCreated']),
            _parseDateCreated(b.rawData['DateCreated']),
          );
        case 'PremiereDate':
          return _compareNullableDate(a.premiereDate, b.premiereDate);
        case 'CommunityRating':
          return _compareNullableNum(a.communityRating, b.communityRating);
        case 'CriticRating':
          return _compareNullableNum(
            a.criticRating?.toDouble(),
            b.criticRating?.toDouble(),
          );
        case 'Runtime':
        case 'RunTimeTicks':
          return _compareNullableNum(
            a.runTimeTicks?.toDouble(),
            b.runTimeTicks?.toDouble(),
          );
        case 'ProductionYear':
          return _compareNullableNum(
            a.productionYear?.toDouble(),
            b.productionYear?.toDouble(),
          );
        default:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
    }

    sorted.sort(compare);
    if (sortOrder.toLowerCase() == 'descending') {
      return sorted.reversed.toList(growable: false);
    }
    return sorted;
  }

  static DateTime? _parseDateCreated(dynamic value) {
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  static int _compareNullableDate(DateTime? a, DateTime? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  static int _compareNullableNum(double? a, double? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  static int _compareByLastPlayed(AggregatedItem a, AggregatedItem b) {
    final aDate = a.rawData['UserData']?['LastPlayedDate'] as String? ?? '';
    final bDate = b.rawData['UserData']?['LastPlayedDate'] as String? ?? '';
    return bDate.compareTo(aDate);
  }

  Future<List<AggregatedItem>> _enrichNextUpItemsWithSeriesLastPlayed(
    List<AggregatedItem> items,
    MediaServerClient client,
  ) => enrichNextUpItemsWithSeriesLastPlayed(items, client);

  String? get _localServerId => _sessionRepo.activeServerId;

  /// The server the user picked to be the backend for playing local media, or
  /// the active server when unset (Automatic).
  String get _primaryServerId {
    final chosen = GetIt.instance<UserPreferences>().get(
      UserPreferences.primaryServerForLocalMedia,
    );
    if (chosen != null && chosen.isNotEmpty) return chosen;
    return _localServerId ?? '';
  }

  static String _normalizeMediaPath(String path) {
    return path.replaceAll('\\', '/').trim().toLowerCase();
  }

  static String _sourceFileName(Map<String, dynamic> source) {
    final path = (source['Path'] as String?) ?? '';
    if (path.isEmpty) return '';
    final normalized = _normalizeMediaPath(path);
    return normalized.split('/').lastWhere(
      (part) => part.isNotEmpty,
      orElse: () => '',
    );
  }

  static Set<String> _localFileNames(AggregatedItem item) {
    final names = <String>{};
    for (final source in item.mediaSources) {
      if (!_isLocalFileSourceStatic(item, source)) continue;
      final fileName = _sourceFileName(source);
      if (fileName.isNotEmpty) names.add(fileName);
    }
    return names;
  }

  static bool _hasLocalFileSource(AggregatedItem item) {
    for (final source in item.mediaSources) {
      if (_isLocalFileSourceStatic(item, source)) return true;
    }
    return false;
  }

  static bool _isLocalFileSourceStatic(
    AggregatedItem item,
    Map<String, dynamic> source,
  ) {
    final protocol = (source['Protocol'] as String?)?.toLowerCase();
    if (protocol == 'file') return true;
    if (protocol == 'http') return false;
    final id = source['Id']?.toString() ?? '';
    if (id.isNotEmpty) return id == item.id;
    return false;
  }

  /// Returns the first candidate exposing one of [item]'s local files. File
  /// names are a fallback when provider metadata is missing or inconsistent;
  /// season/episode positions still win when both items carry them.
  static AggregatedItem? _matchSameLocalFile(
    AggregatedItem item,
    List<AggregatedItem> candidates, {
    bool seriesResolved = false,
  }) {
    final names = _localFileNames(item);
    if (names.isEmpty) return null;
    for (final candidate in candidates) {
      if ((candidate.type ?? '').toLowerCase() !=
          (item.type ?? '').toLowerCase()) {
        continue;
      }
      final candidateNames = _localFileNames(candidate);
      if (candidateNames.isEmpty) continue;
      var sharesFile = false;
      for (final name in names) {
        if (candidateNames.contains(name)) {
          sharesFile = true;
          break;
        }
      }
      if (!sharesFile) continue;
      if ((item.type ?? '').toLowerCase() == 'episode' &&
          item.parentIndexNumber != null &&
          item.indexNumber != null &&
          candidate.parentIndexNumber != null &&
          candidate.indexNumber != null) {
        if (item.parentIndexNumber == candidate.parentIndexNumber &&
            item.indexNumber == candidate.indexNumber) {
          return candidate;
        }
        if (!seriesResolved && !_sameEpisodePos(item, candidate)) {
          continue;
        }
        if (seriesResolved) continue;
      }
      return candidate;
    }
    return null;
  }

  /// Fetches the versions of [item] as they exist on every connected server and
  /// returns the combined, origin-tagged [MediaSource] maps, the primary (local
  /// media) server's copies first. Returns null when the caller should stick
  /// with the item's own sources (single server, or the item has nothing to
  /// join)
  Future<List<Map<String, dynamic>>?> mergedMediaSourcesForItem(
    AggregatedItem item,
  ) async {
    final localServerId = _localServerId;

    final sessions = await getLoggedInServers();
    if (sessions.length < 2) return null;

    final localSources = item.mediaSources;
    if (localSources.isEmpty) return null;

    final sourceItems = <AggregatedItem>[];
    for (final session in sessions) {
      if (_sameServer(session, item.serverId)) {
        continue;
      }
      final match = await _findItemOnServerByIdentity(
        item,
        session,
      );
      if (match != null) {
        sourceItems.add(match);
      }
    }
    if (sourceItems.isEmpty) return null;

    final mergedItems = _mergeSourcesAcrossServers(
      [item, ...sourceItems],
      localServerId: localServerId ?? item.serverId,
      primaryServerId: _primaryServerId,
    );
    if (mergedItems.isEmpty) return null;

    final mergedRaw = mergedItems.first.rawData['MediaSources'];
    if (mergedRaw is! List) return null;
    return mergedRaw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
  }

  /// Copies the origin series name onto an episode when the detail response
  /// did not include it. Series-scoped matching needs that name even when the
  /// episode's own provider ids do not resolve on the other server.
  Future<AggregatedItem> _withOriginSeriesName(
    AggregatedItem item,
    List<ServerUserSession> sessions,
  ) async {
    if ((item.type ?? '').toLowerCase() != 'episode') return item;
    if (item.seriesName != null && item.seriesName!.isNotEmpty) return item;
    final seriesId = item.rawData['SeriesId']?.toString() ?? '';
    if (seriesId.isEmpty) return item;
    ServerUserSession? origin;
    for (final session in sessions) {
      if (_sameServer(session, item.serverId)) {
        origin = session;
        break;
      }
    }
    if (origin == null) return item;
    try {
      final seriesData = await origin.client.itemsApi.getItem(seriesId);
      final seriesName = seriesData['Name']?.toString() ?? '';
      if (seriesName.isEmpty) return item;
      final rawData = Map<String, dynamic>.from(item.rawData)
        ..['SeriesName'] = seriesName;
      return AggregatedItem(
        id: item.id,
        serverId: item.serverId,
        rawData: rawData,
      );
    } catch (_) {
      return item;
    }
  }

  /// Returns the item and media source that should be used when [item] is
  /// played while an explicit Default Server for Local Media is selected.
  ///
  /// Local-file playback is routed to the selected server whenever that server
  /// has the same file. An explicitly selected merged version keeps the server
  /// that owns it. Returns null when playback should continue with [item].
  Future<ResolvedPlaybackItem?> resolvePlaybackItem(
    AggregatedItem item, {
    String? mediaSourceId,
  }) async {
    if (item.id.isEmpty) return null;
    final sessions = await getLoggedInServers();
    if (sessions.length < 2) return null;
    final primaryServerId = _primaryServerId;
    if (primaryServerId.isEmpty) return null;
    ServerUserSession? primarySession;
    for (final session in sessions) {
      if (_sameServer(session, primaryServerId)) {
        primarySession = session;
        break;
      }
    }
    if (primarySession == null) return null;

    Map<String, dynamic>? selectedSource;
    if (mediaSourceId != null && mediaSourceId.isNotEmpty) {
      for (final source in item.mediaSources) {
        if (source['Id']?.toString() == mediaSourceId) {
          selectedSource = source;
          break;
        }
      }
      // A source id the current item does not list is stale; leave playback
      // alone rather than guessing a different version.
      if (selectedSource == null) return null;
      final selectedOrigin = selectedSource['_moonfinServerId']?.toString();
      if (selectedOrigin != null && selectedOrigin.isNotEmpty) {
        return _resolveExplicitSourceOwner(
          sessions,
          selectedSource,
          fallbackItem: item,
        );
      }
      if (!_isLocalFileSource(item, selectedSource)) return null;
    } else if (item.type?.toLowerCase() != 'series' &&
        item.type?.toLowerCase() != 'season' &&
        !_hasLocalFileSource(item)) {
      return null;
    }

    item = await _withOriginSeriesName(item, sessions);
    if (_sameServer(primarySession, item.serverId)) return null;
    AggregatedItem? match;
    try {
      match = await _findItemOnServerByIdentity(item, primarySession);
    } catch (_) {
      return null;
    }
    if (match == null || match.id.isEmpty) return null;
    final primaryItem = await _hydrateSessionItem(primarySession, match);
    final primarySource = _preferredLocalSource(primaryItem, selectedSource);
    final type = (item.type ?? '').toLowerCase();
    if (primarySource == null && type != 'series' && type != 'season') {
      return null;
    }
    return ResolvedPlaybackItem(
      item: primaryItem,
      mediaSourceId: primarySource?['Id']?.toString(),
    );
  }

  /// Honors a version explicitly selected from merged sources by returning the
  /// owning server's item and source.
  Future<ResolvedPlaybackItem?> _resolveExplicitSourceOwner(
    List<ServerUserSession> sessions,
    Map<String, dynamic> selectedSource, {
    required AggregatedItem fallbackItem,
  }) async {
    final origin = selectedSource['_moonfinServerId']?.toString() ?? '';
    final ownerItemId =
        selectedSource['_moonfinItemId']?.toString() ?? fallbackItem.id;
    ServerUserSession? owner;
    for (final session in sessions) {
      if (_sameServer(session, origin)) {
        owner = session;
        break;
      }
    }
    if (owner == null || ownerItemId.isEmpty) return null;
    try {
      final full = await owner.client.itemsApi.getItem(ownerItemId);
      final ownerItem = AggregatedItem(
        id: ownerItemId,
        serverId: owner.server.id,
        rawData: Map<String, dynamic>.from(full),
      );
      return ResolvedPlaybackItem(
        item: ownerItem,
        mediaSourceId: selectedSource['Id']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<AggregatedItem> _hydrateSessionItem(
    ServerUserSession session,
    AggregatedItem match,
  ) async {
    try {
      final full = await session.client.itemsApi.getItem(match.id);
      return AggregatedItem(
        id: match.id,
        serverId: session.server.id,
        rawData: Map<String, dynamic>.from(full),
      );
    } catch (_) {
      return match;
    }
  }

  Map<String, dynamic>? _preferredLocalSource(
    AggregatedItem item,
    Map<String, dynamic>? preferredSource,
  ) {
    if (preferredSource != null) {
      final preferredName = _sourceFileName(preferredSource);
      if (preferredName.isNotEmpty) {
        for (final source in item.mediaSources) {
          if (_isLocalFileSource(item, source) &&
              _sourceFileName(source) == preferredName) {
            return source;
          }
        }
      }
    }
    return _defaultLocalSource(item);
  }

  Map<String, dynamic>? _defaultLocalSource(AggregatedItem item) {
    for (final source in item.mediaSources) {
      if (_isLocalFileSource(item, source)) return source;
    }
    if (item.mediaSources.isNotEmpty) return item.mediaSources.first;
    return null;
  }

  static bool _sameServer(ServerUserSession session, String serverId) {
    if (serverId.isEmpty) return false;
    if (session.server.id == serverId) return true;
    if (session.client.baseUrl == serverId) return true;
    final normalized = normalizeServerBaseUrl(serverId);
    return normalizeServerBaseUrl(session.client.baseUrl) == normalized;
  }

  /// Finds the same title as [item] on [session]'s server by provider id, or
  /// by series+season+episode identity for episodes, and returns it parsed onto
  /// that server (with its own MediaSources populated).
  Future<AggregatedItem?> _findItemOnServerByIdentity(
    AggregatedItem item,
    ServerUserSession session,
  ) async {
    final type = item.type?.toLowerCase() ?? '';
    try {
      if (item.providerIds.isNotEmpty) {
        for (final key in ['Tmdb', 'Imdb', 'Tvdb']) {
          final providerId = item.providerIds[key];
          if (providerId == null || providerId.isEmpty) continue;
          final response = await session.client.itemsApi.getItems(
            anyProviderIdEquals: providerId,
            includeItemTypes: const ['Movie', 'Episode'],
            recursive: true,
            limit: 10,
            fields:
                'ProviderIds,MediaSources,SeriesName,ParentIndexNumber,IndexNumber',
          );
          final parsed = _parseItems(response, session.server.id);
          if (parsed.isEmpty) continue;
          final fileMatch = _matchSameLocalFile(item, parsed);
          if (fileMatch != null) return fileMatch;

          // Prefer a same-type match carrying the same provider id.
          final sameType = parsed
              .where((p) => (p.type ?? '').toLowerCase() == type)
              .firstOrNull;

          // Episodes must also agree on season/episode numbers; a provider id
          // can be shared by an episode and its series or another server's
          // different-sourced edition.
          if (sameType != null &&
              (type != 'episode' || _sameEpisodePos(item, sameType))) {
            return sameType;
          }
          final fallback = parsed.firstOrNull;
          if (fallback != null &&
              type == 'episode' &&
              _sameEpisodePos(item, fallback)) {
            return fallback;
          }
          break;
        }
      }

      // No provider ids to key on: fall back to a series/name match, scoping
      // the episode lookup to the resolved series so the whole library is not
      // scanned (that misses anything ranked past the first page).
      if (type == 'episode' &&
          item.seriesName != null &&
          item.seriesName!.isNotEmpty) {
        final series = await _findSeriesOnServer(item, session);
        if (series == null) return null;
        const episodeFields =
            'ProviderIds,MediaSources,SeriesName,ParentIndexNumber,IndexNumber';
        final season = await _findSeasonOnServer(item, session, series.id);
        if (season != null) {
          final seasonResponse = await session.client.itemsApi.getEpisodes(
            series.id,
            seasonId: season.id,
            fields: episodeFields,
          );
          final seasonParsed = _parseItems(
            Map<String, dynamic>.from({
              'Items': seasonResponse['Items'],
            }),
            session.server.id,
          );
          for (final p in seasonParsed) {
            if (_sameEpisodePos(item, p)) return p;
          }
          final seasonFileMatch = _matchSameLocalFile(
            item,
            seasonParsed,
            seriesResolved: true,
          );
          if (seasonFileMatch != null) return seasonFileMatch;
        }
        final response = await session.client.itemsApi.getItems(
          parentId: series.id,
          includeItemTypes: const ['Episode'],
          recursive: true,
          limit: 100,
          fields: episodeFields,
        );
        final parsed = _parseItems(response, session.server.id);
        for (final p in parsed) {
          if (_sameEpisodePos(item, p)) return p;
        }
        return _matchSameLocalFile(item, parsed, seriesResolved: true);
      }

      // Seasons sit under a series: match the series first, then compare by
      // season number so a folder mark on one server lands on the same season
      // (not another server's differently-numbered or same-named one).
      if (type == 'season' || type == 'series') {
        final series = await _findSeriesOnServer(item, session);
        if (series == null) return null;
        if (type == 'series') return series;
        final seasonNumber = item.indexNumber;
        if (seasonNumber == null) return null;
        final seasonsData = await session.client.itemsApi.getSeasons(
          series.id,
          fields: 'IndexNumber',
        );
        final seasons = (seasonsData['Items'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (raw) => AggregatedItem(
                id: raw['Id']?.toString() ?? '',
                serverId: session.server.id,
                rawData: raw.cast<String, dynamic>(),
              ),
            );
        for (final season in seasons) {
          if (season.indexNumber == seasonNumber) return season;
        }
        return null;
      }

      final response = await session.client.itemsApi.getItems(
        searchTerm: item.name,
        includeItemTypes: [item.type ?? 'Movie'],
        recursive: true,
        limit: 10,
        fields: 'ProviderIds,MediaSources,SeriesName,ProductionYear',
      );
      final parsed = _parseItems(response, session.server.id);
      for (final p in parsed) {
        if (_sameNameAndYear(item, p)) return p;
      }
      return _matchSameLocalFile(item, parsed);
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Finds the season with the same season number under [seriesId] on
  /// [session]'s server. A season-scoped episode lookup avoids missing an
  /// episode ranked past the first page of a whole-series response.
  Future<AggregatedItem?> _findSeasonOnServer(
    AggregatedItem item,
    ServerUserSession session,
    String seriesId,
  ) async {
    final seasonNumber = item.parentIndexNumber;
    if (seasonNumber == null) return null;
    try {
      final seasonsData = await session.client.itemsApi.getSeasons(
        seriesId,
        fields: 'IndexNumber',
      );
      final seasons = (seasonsData['Items'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (raw) => AggregatedItem(
              id: raw['Id']?.toString() ?? '',
              serverId: session.server.id,
              rawData: raw.cast<String, dynamic>(),
            ),
          );
      for (final season in seasons) {
        if (season.indexNumber == seasonNumber) return season;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Finds the series counterpart of [item] on [session]'s server. [item] may
  /// itself be the series, in which case it is matched directly; for a season
  /// the parent series is located through its name/year (and provider ids when
  /// present) so the season can then be resolved under it.
  Future<AggregatedItem?> _findSeriesOnServer(
    AggregatedItem item,
    ServerUserSession session,
  ) async {
    // Seasons carry the series provider ids on themselves; use those first.
    // Episode provider ids identify the episode, not its series, so episodes
    // resolve their series by name below.
    if ((item.type ?? '').toLowerCase() != 'episode' &&
        item.providerIds.isNotEmpty) {
      for (final key in ['Tmdb', 'Imdb', 'Tvdb']) {
        final providerId = item.providerIds[key];
        if (providerId == null || providerId.isEmpty) continue;
        final response = await session.client.itemsApi.getItems(
          anyProviderIdEquals: providerId,
          includeItemTypes: const ['Series'],
          recursive: true,
          limit: 10,
          fields: 'ProviderIds,SeriesName,ProductionYear',
        );
        final parsed = _parseItems(response, session.server.id);
        for (final p in parsed) {
          if (p.type?.toLowerCase() == 'series') return p;
        }
      }
    }
    if (item.seriesName != null && item.seriesName!.isNotEmpty) {
      final seriesName = item.seriesName ??
          (item.type?.toLowerCase() == 'series' ? item.name : null);
      if (seriesName != null && seriesName.isNotEmpty) {
        final response = await session.client.itemsApi.getItems(
          searchTerm: seriesName,
          includeItemTypes: const ['Series'],
          recursive: true,
          limit: 10,
          fields: 'ProviderIds,SeriesName,ProductionYear',
        );
        final parsed = _parseItems(response, session.server.id);
        for (final p in parsed) {
          if (_similarName(seriesName, p.name)) return p;
        }
      }
    }
    return null;
  }

  static bool _similarName(String lhs, String? rhs) {
    if (rhs == null) return false;
    final a = lhs.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final b = rhs.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return a == b || a.contains(b) || b.contains(a);
  }

  static bool _sameEpisodePos(AggregatedItem a, AggregatedItem b) {
    if (a.parentIndexNumber != b.parentIndexNumber) return false;
    if (a.indexNumber != b.indexNumber) return false;
    final aSeries = a.seriesName ?? '';
    final bSeries = b.seriesName ?? '';
    return aSeries.toLowerCase() == bSeries.toLowerCase();
  }

  static bool _sameNameAndYear(AggregatedItem a, AggregatedItem b) {
    if ((a.name ?? '').toLowerCase() != (b.name ?? '').toLowerCase()) {
      return false;
    }
    if (a.productionYear != null && b.productionYear != null) {
      return a.productionYear == b.productionYear;
    }
    return true;
  }

  /// Combines the versions of matching items from different servers into one
  /// row. The primary (local media) server's item survives as the row anchor
  /// and its copies lead the merged source list; every other copy keeps its
  /// origin server tagged on so playback routes to the server that owns it.
  List<AggregatedItem> _mergeSourcesAcrossServers(
    List<AggregatedItem> items, {
    required String localServerId,
    String? primaryServerId,
  }) {
    final knownServerIds = <String>{
      for (final item in items) item.serverId,
    }.toSet();
    if (knownServerIds.length < 2) {
      return items;
    }

    // The server whose copies lead a merged row. When a primary server is
    // configured its item is the one that survives (so posters, details and
    // episodes come from it); otherwise the active server keeps that role.
    final primary =
        (primaryServerId != null && primaryServerId.isNotEmpty)
        ? primaryServerId
        : localServerId;

    // Primary-server items first so a single-server copy keeps its place at the
    // front of the row and its sources lead the merged version list.
    final ordered = <AggregatedItem>[
      ...items.where((i) => i.serverId == primary),
      ...items.where((i) => i.serverId != primary),
    ];

    final merged = <AggregatedItem>[];
    final byKey = <String, AggregatedItem>{};
    final knownSourcesByItem = <AggregatedItem, Set<String>>{};

    for (final item in ordered) {
      final key = _crossServerMatchKey(item);
      final existing = byKey[key];
      if (existing == null || existing.serverId == item.serverId) {
        // A merged row's server id is the row's own server, but the picker can
        // show another server's copies on top (the selected local server's file
        // next to a Debrid/remux encode). Every source must carry its origin
        // server so playback, direct-play checks and artwork route to the
        // server that actually owns it instead of always asking the active one.
        final tagged = _tagOwnSources(item);
        byKey[key] = tagged;
        merged.add(tagged);
        continue;
      }

      final sources = knownSourcesByItem.putIfAbsent(
        existing,
        () => {
          for (final s in existing.mediaSources) _sourceKey(existing, s),
        },
      );

      // Two servers can expose the SAME physical local file (they share a
      // library mount, or one mirrors the other). Only the primary local media
      // server's copy is meaningful as a playback source — the Primary Server
      // for Local Media is the designated direct-play/transcode backend — so a
      // non-primary server's duplicate local copy is dropped instead of listed
      // beside the primary's as a second, indistinguishable Version. Debrid and
      // other remote (Http) sources are distinct encodes and always kept; they
      // continue to play from whichever server owns them.
      final anchorHasLocalCopy =
          existing.mediaSources.any((s) => _isLocalFileSource(existing, s));
      final additions = <Map<String, dynamic>>[];
      for (final source in item.mediaSources) {
        if (!_isLocalFileSource(item, source) || !anchorHasLocalCopy) {
          if (sources.add(_sourceKey(existing, source))) {
            additions.add(_mapWithOrigin(source, item.serverId, item.id));
          }
        }
      }
      if (additions.isEmpty) {
        continue;
      }

      final raw = Map<String, dynamic>.from(existing.rawData);
      raw['MediaSources'] = [
        ...?((raw['MediaSources'] as List?)?.whereType<Map>() ?? const []),
        ...additions,
      ];
      final index = merged.indexOf(existing);
      final replacement = AggregatedItem(
        id: existing.id,
        serverId: existing.serverId,
        rawData: raw,
      );
      if (index >= 0) {
        merged[index] = replacement;
      }
      byKey[key] = replacement;
      knownSourcesByItem
        ..remove(existing)
        ..[replacement] = sources;
    }

    // Primary copies already lead: _tagOwnSources stamped them at creation, and
    // the merge appends other servers' sources onto a primary-anchored row.
    return merged;
  }

  Map<String, dynamic> _mapOf(Map<String, dynamic> source) =>
      Map<String, dynamic>.from(source);

  Map<String, dynamic> _mapWithOrigin(
    Map<String, dynamic> source,
    String serverId,
    String itemId,
  ) {
    final copy = _mapOf(source);
    copy['_moonfinServerId'] = serverId;
    copy['_moonfinItemId'] = itemId;
    return copy;
  }

  /// Marks [item]'s own sources with the server on which they live, so a merged
  /// row can route each version back to where it is stored. The row keeps only
  /// one server id (its own), so an unmatched "own" source would otherwise be
  /// played by whatever server is active when the row resolves — a local file
  /// at the top of a Versions list ending up directly played or transcoded by
  /// the Debrid/remux server instead of the selected local one.
  AggregatedItem _tagOwnSources(AggregatedItem item) {
    final sources = item.mediaSources;
    if (sources.isEmpty) return item;
    final tagged = <Map<String, dynamic>>[];
    var changed = false;
    for (final source in sources) {
      if (source['_moonfinServerId'] == null) {
        tagged.add(_mapWithOrigin(source, item.serverId, item.id));
        changed = true;
      } else {
        tagged.add(source);
      }
    }
    if (!changed) return item;
    final raw = Map<String, dynamic>.from(item.rawData)
      ..['MediaSources'] = tagged;
    return AggregatedItem(
      id: item.id,
      serverId: item.serverId,
      rawData: raw,
    );
  }

  /// Stable match key across servers for an item.
  String _crossServerMatchKey(AggregatedItem item) {
    final type = item.type?.toLowerCase() ?? '';
    // Episodes: the series is the identity, not the provider ids of the
    // episode itself (a server may key them differently).
    if (type == 'episode' ||
        (type == 'video' && item.parentIndexNumber != null)) {
      return 'ep|${item.seriesName ?? ''}|${item.parentIndexNumber ?? ''}|${item.indexNumber ?? ''}';
    }

    final provider = item.providerIds;
    final tmdb = provider['Tmdb'] ?? provider['tmdb'] ?? provider['TMDB'];
    final imdb = provider['Imdb'] ?? provider['imdb'] ?? provider['IMDB'];
    final tvdb = provider['Tvdb'] ?? provider['tvdb'] ?? provider['TVDB'];
    final providerKey = <String>[
      if (tmdb != null) 'tmdb:$tmdb',
      if (imdb != null) 'imdb:$imdb',
      if (tvdb != null) 'tvdb:$tvdb',
    ].join('|');
    if (providerKey.isNotEmpty) {
      return '$type|$providerKey';
    }
    return '$type|${item.name ?? ''}|${item.productionYear ?? ''}';
  }

  /// The identity of a single media source within an item, scoped so a remux
  /// server's copies never shadow each other during the merge.
  String _sourceKey(AggregatedItem item, Map<String, dynamic> source) {
    final id = source['Id']?.toString() ?? '';
    if (id.isNotEmpty) return '${item.serverId}|$id';
    final path = source['Path']?.toString() ?? '';
    if (path.isNotEmpty) return '${item.serverId}|$path';
    return '${item.serverId}|${source['Name']?.toString() ?? ''}';
  }

  /// Whether [source] is a plain local file on [item]'s server rather than a
  /// remote/debrid encode. A Jellyfin/Emby server reports local files as
  /// `Protocol: File` with a filesystem `Path`; the mediaSourceId equals the
  /// item id for the server's own single-file item. Remote `.strm`/debrid links
  /// come back as `Protocol: Http` (URL `Path`) and are never local.
  bool _isLocalFileSource(AggregatedItem item, Map<String, dynamic> source) {
    return _isLocalFileSourceStatic(item, source);
  }
}
