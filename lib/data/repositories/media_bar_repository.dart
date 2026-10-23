import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:server_core/server_core.dart';

import '../../preference/home_section_config.dart';
import '../../preference/user_preferences.dart';
import '../models/media_bar_slide_item.dart';
import '../models/media_bar_state.dart';
import '../services/custom_external_lists_service.dart';
import '../services/library_scope_service.dart';
import '../services/media_server_client_factory.dart';
import 'seerr_repository.dart';
import '../utils/blocked_ratings.dart';
import 'multi_server_repository.dart';
import '../utils/bounded_concurrency.dart';

class MediaBarRepository {

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

    final contentType = _prefs.get(UserPreferences.mediaBarContentType);

    final maxItems =
        int.tryParse(_prefs.get(UserPreferences.mediaBarItemCount)) ?? 10;
    // The pickers in settings are open to everyone and the filtering below is
    // plain item queries, so a plugin is not needed to honour the choice.
    final storedSources = _splitCsv(UserPreferences.mediaBarLibraryIds);
    // A custom row list the user added (TMDB / Letterboxd / MDBList) rides in
    // the same preference under a `custom:` token: it is a source library for
    // the banner too, whether or not the row is on and shown among the home
    // rows. Custom lists are read from the list itself, never a server view.
    final customTokens =
        storedSources.where(isCustomRowSourceToken).toList();
    final libraryIds =
        storedSources.where((t) => !isCustomRowSourceToken(t)).toList();
    final collectionIds = _splitCsv(UserPreferences.mediaBarCollectionIds);
    final excludedGenres = _splitCsv(
      UserPreferences.mediaBarExcludedGenres,
    ).toSet();

    // The bar draws from what the user picked and nothing else. With no source
    // library, collection or custom list selected there is nothing to draw, so
    // the bar stays off rather than quietly widening to every library (which
    // is what the fallbacks below would otherwise do).
    if (!hasMediaBarSourceSelection(
      libraryIds: libraryIds,
      collectionIds: collectionIds,
      customTokens: customTokens,
    )) {
      return const MediaBarDisabled();
    }

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

    final allSources = <_MediaBarSource>[];
    final allSourceItemTypes = <String, List<String>>{};

    await _loadSessionClients();

    // A list switched off entirely is not a source, so its token is skipped even
      // before the picker gets the chance to forget it.
      final customSlides = await _loadCustomRowSlides(customTokens, maxItems);

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

      // No widening to every library here. The bar draws from the selected
      // sources only, so a selection that no longer resolves (revoked access,
      // a custom list that came back empty) leaves the bar off instead of
      // quietly filling with titles the user never picked.
    } catch (_) {
      // The views lookup failed, so fall back to what the user picked. Those
      // saved ids can name a library access has since been revoked for, so
      // drop what the policy no longer allows before trusting them.
      allSources.addAll(libraryIds.map(_parseSourceToken));
      allSources.addAll(
        collectionIds.map(
          (id) => _MediaBarSource(serverId: '', libraryId: id),
        ),
      );
      final permittedOnActive = await GetIt.instance<LibraryScopeService>()
          .retainPermitted(libraryIds);
      allSources.removeWhere(
        (source) =>
            source.isActiveServer &&
            libraryIds.contains(source.libraryId) &&
            !permittedOnActive.contains(source.libraryId),
      );
    }

    try {
      // Each source's titles are kept apart so the random source can give them
      // an equal share of the banner (see [_interleaveBySource]) instead of
      // letting whichever library is largest crowd the others out.
      final perSource = <List<Map<String, dynamic>>>[];

      if (allSources.isEmpty && customSlides.isEmpty) {
        return const MediaBarDisabled();
      } else {
        // Use bounded concurrency to fetch from multiple sources in parallel
        // while keeping items per source for round-robin distribution.
        final seenIds = <String>{};
        final usable = _usableFor(excludedGenres);
        var usableCount = 0;
        final enough = maxItems * 2;

        await mapBounded(
          allSources.toList()..shuffle(_random),
          _sourceConcurrency,
          (source) async {
            if (!GetIt.instance.isRegistered<MediaBarRepository>() ||
                GetIt.instance<MediaBarRepository>() != this) {
              return null;
            }
            if (usableCount >= enough) return null;
            try {
              final targetTypes = allSourceItemTypes[source.sourceKey] ?? includeTypes;
              final client = _clientForSource(source);
              final batch = await _fetchItems(
                targetTypes,
                fetchLimit,
                parentId: source.libraryId,
                client: client,
              );
              final sourceBatch = <Map<String, dynamic>>[];
              for (final item in batch) {
                final id = item['Id']?.toString();
                if (id != null && !seenIds.add(id)) continue;
                if (source.serverId.isNotEmpty) {
                  item['_moonfinServerId'] = source.serverId;
                }
                sourceBatch.add(item);
                if (usable(item)) usableCount++;
              }
              if (sourceBatch.isNotEmpty) {
                perSource.add(sourceBatch);
              }
            } catch (_) {
              // Keep fetching remaining libraries if one fails
            }
            return null;
          },
        );
        if (!GetIt.instance.isRegistered<MediaBarRepository>() ||
            GetIt.instance<MediaBarRepository>() != this) {
          return const MediaBarDisabled();
        }

        final allItems = perSource.expand((batch) => batch).toList();

        var selected = _selectItemsWithBackdrops(
          allItems,
          maxItems,
          excludedGenres,
        // One source reads as before; several share the banner evenly, so the
        // random source rotates through the selected libraries rather than
        // leaning on whichever returned the most titles.
        perSource: perSource,
      );

      if (selected.isEmpty && allSources.isNotEmpty) {
        final fallbackItems = <Map<String, dynamic>>[];
        final first = allSources.first;
        final targetTypes = allSourceItemTypes[first.sourceKey] ?? includeTypes;
        final client = _clientForSource(first);
        final batch = await _fetchItems(
          targetTypes,
          fetchLimit,
          parentId: first.libraryId,
          client: client,
        );
        for (final item in batch) {
          if (first.serverId.isNotEmpty) {
            item['_moonfinServerId'] = first.serverId;
          }
        }
        fallbackItems.addAll(batch);

        selected = _selectItemsWithBackdrops(
          fallbackItems,
          maxItems,
          excludedGenres,
        );
      }

      // No arbitrary-library fallback here either: reaching this point means
      // the selected sources came back without usable backdrops, and the bar
      // reports that rather than borrowing titles from a library the user did
      // not choose.
      if (selected.isEmpty && customSlides.isEmpty) {
        return const MediaBarError('No items with backdrop images found');
      }

      return MediaBarReady(_mergedSlides(customSlides, selected, maxItems));
      }
    } catch (e) {
      // Custom lists were read before any of this, so they still stand even if
      // the server-side selection blew up.
      if (customSlides.isNotEmpty) {
        return MediaBarReady(customSlides);
      }
      return MediaBarError(e);
    }
  }

  List<Map<String, dynamic>> _selectItemsWithBackdrops(
    List<Map<String, dynamic>> source,
    int maxItems,
    Set<String> excludedGenres, {
    List<List<Map<String, dynamic>>>? perSource,
  }) {
    final filter = activeParentalFilter;
    bool keep(Map<String, dynamic> item) =>
        _hasBackdrop(item) &&
        !_isBoxSet(item) &&
        !_hasExcludedGenre(item, excludedGenres) &&
        !filter.isBlockedRaw(item);

    // Several sources: deal them out round-robin so the banner spends about
    // the same number of slides on each selected library. The random source
    // reads a fixed pool per library, so pooling them and shuffling would hand
    // the banner almost entirely to whichever library is biggest.
    if (perSource != null && perSource.length > 1) {
      final pools = perSource
          .map((batch) => batch.where(keep).toList()..shuffle(_random))
          .toList();
      final picked = <Map<String, dynamic>>[];
      var taken = true;
      var round = 0;
      while (taken && picked.length < maxItems) {
        taken = false;
        for (final pool in pools) {
          if (round >= pool.length) continue;
          picked.add(pool[round]);
          taken = true;
          if (picked.length >= maxItems) break;
        }
        round++;
      }
      return picked;
    }

    final withBackdrops = source.where(keep).toList()..shuffle();
    return withBackdrops.take(maxItems).toList();
  }

  /// The check an item has to pass to go on the bar.
  bool Function(Map<String, dynamic>) _usableFor(Set<String> excludedGenres) {
    final filter = activeParentalFilter;
    return (item) =>
        _hasBackdrop(item) &&
        !_isBoxSet(item) &&
        !_hasExcludedGenre(item, excludedGenres) &&
        !filter.isBlockedRaw(item);
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
    if (!_prefs.get(UserPreferences.mergeMediaBarLibraries)) return;
    try {
      final sessions =
          await GetIt.instance<MultiServerRepository>().getLoggedInServers();
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

  String _normalizeCollectionType(Object? value) {
    return value?.toString().trim().toLowerCase() ?? '';
  }

  /// How many titles each source hands the selector. The random source reads
  /// this many from a random place in the library, and the dated ones read
  /// this many of the newest.
  static const _poolSize = 40;

  /// How many libraries and collections are read at once.
  static const _sourceConcurrency = 6;

  Future<List<Map<String, dynamic>>> _fetchItems(
    List<String>? itemTypes,
    int limit, {
    String? parentId,
    MediaServerClient? client,
  }) async {
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
        client: client,
      );
    }
    final effectiveClient = client ?? _client;
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
            enableImageTypes: 'Backdrop,Logo,Banner',
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

  /// The banner's slides with the custom row lists folded in.
  ///
  /// Server picks already come back shuffled and cut to [maxItems]; a custom
  /// list arrives in its own order (the row's sort). A lone source keeps its
  /// shape — a single list stays in list order — and when both are present
  /// they are shuffled together and cut to [maxItems] so neither crowds the
  /// other out of the rotation.
  List<MediaBarSlideItem> _mergedSlides(
    List<MediaBarSlideItem> custom,
    List<Map<String, dynamic>> serverItems,
    int maxItems,
  ) {
    final server = serverItems.map(_toSlideItem).toList();
    if (custom.isEmpty || server.isEmpty) {
      return [...custom, ...server].take(maxItems).toList();
    }
    return ([...custom, ...server]..shuffle(_random)).take(maxItems).toList();
  }

  /// Slides for the custom row lists named by [tokens].
  ///
  /// Each list is read the way its home row reads it — cache first, then the
  /// server — and mapped straight from the list's own backdrop art, so the
  /// banner can show a title the library may not hold. The row's enabled flag
  /// is deliberately ignored: a list hidden from the home screen still feeds
  /// the banner once picked. A list that answers nothing contributes no slide;
  /// one that cannot be read at all is skipped without disturbing the others.
  Future<List<MediaBarSlideItem>> _loadCustomRowSlides(
    List<String> tokens,
    int maxItems,
  ) async {
    if (tokens.isEmpty) return const [];
    if (!GetIt.instance.isRegistered<CustomExternalListsService>()) {
      return const [];
    }
    final service = GetIt.instance<CustomExternalListsService>();
    final configs = _prefs.homeSectionsConfig;
    // One bucket per list, then dealt round-robin, so a longer list cannot use
    // up the whole banner and leave the others out of the rotation.
    final perList = <List<MediaBarSlideItem>>[];
    for (final token in tokens) {
      final section = customRowSectionForToken(token);
      if (section == null || section.isEmpty) continue;
      HomeSectionConfig? config;
      for (final candidate in configs) {
        if (candidate.isPluginDynamic &&
            candidate.pluginSource == HomeSectionPluginSource.custom &&
            candidate.pluginSection == section) {
          config = candidate;
          break;
        }
      }
      // A list deleted or switched off since it was picked is no longer a
      // source; the picker drops its stale token the next time it opens.
      if (config == null || !config.enabled) continue;
      try {
        var items = await service.loadCustomRowFromCache(
          config,
          maxAge: CustomExternalListsService.cacheMaxAge,
        );
        if (items.isEmpty) {
          items = await service.fetchCustomRow(config);
        }
        final slides = <MediaBarSlideItem>[];
        for (final item in items) {
          final slide = _customSlideFor(item);
          if (slide != null) slides.add(slide);
        }
        if (slides.isNotEmpty) perList.add(slides);
      } catch (_) {
        // A list that cannot be read contributes nothing; the rest still do.
      }
    }
    // Titles the library also holds get their logo, runtime and certification
    // filled in, so a custom list slide looks like any other banner title. The
    // lookups run together and are capped: this is a polish step on titles the
    // bar is already going to show, not a reason to stall it.
    final enriched = await _enrichCustomSlides(perList, maxItems);
    return _interleaveSlides(enriched, maxItems);
  }

  /// Fills in the library details behind each custom slide.
  ///
  /// Only the titles that will actually be shown are looked up, so the bar
  /// spends a bounded number of small provider-id queries no matter how long
  /// the lists are. A library that does not hold the title, or a slow one, just
  /// leaves the slide as the list described it.
  Future<List<List<MediaBarSlideItem>>> _enrichCustomSlides(
    List<List<MediaBarSlideItem>> perList,
    int maxItems,
  ) async {
    if (perList.isEmpty) return perList;
    // Round-robin first, then enrich: the cap applies to what is shown, not to
    // every title the lists hold.
    final shown = _interleaveSlides(perList, maxItems);
    final local = <String, Map<String, dynamic>>{};
    final tmdbLogos = <String, String>{}; // itemId -> logoUrl
    SeerrRepository? seerrRepo;
    if (GetIt.instance.isRegistered<SeerrRepository>()) {
      seerrRepo = GetIt.instance<SeerrRepository>();
    } else {
      try {
        seerrRepo = await GetIt.instance.getAsync<SeerrRepository>();
      } catch (_) {
        // Failed to get SeerrRepository, continue without TMDB lookup
        seerrRepo = null;
      }
    }

    for (final slide in shown) {
      final tmdbId = slide.tmdbId ?? '';
      final imdbId = slide.imdbId ?? '';
      if (tmdbId.isEmpty && imdbId.isEmpty) continue;
      final found = await _findLocalItemFor(tmdbId, imdbId, slide.itemType);
      if (found != null) {
        local[slide.itemId] = found;
      } else if (tmdbId.isNotEmpty && seerrRepo != null) {
        // Not in library, try to fetch logo from TMDB directly
        final isSeries = slide.itemType.toLowerCase() == 'series' ||
            slide.itemType.toLowerCase() == 'tv';
        try {
          final tmdbIdInt = int.tryParse(tmdbId);
          if (tmdbIdInt == null) {
            // Invalid TMDB ID, skip TMDB lookup
          } else {
            final images = isSeries
                ? await seerrRepo.getTvImages(tmdbIdInt)
                : await seerrRepo.getMovieImages(tmdbIdInt);
            if (images != null) {
              final logos = images['logos'] as List?;
              if (logos != null && logos.isNotEmpty) {
                final logoPath = (logos.firstWhere(
                  (l) => l['filePath'] != null,
                  orElse: () => <String, dynamic>{},
                )['filePath'] as String?);
                if (logoPath != null && logoPath.isNotEmpty) {
                  tmdbLogos[slide.itemId] =
                      'https://image.tmdb.org/t/p/w600$logoPath';
                }
              }
            }
          }
        } catch (e) {
          // Ignore TMDB fetch errors; fall back to no logo
        }
      }
    }
    if (local.isEmpty && tmdbLogos.isEmpty) return perList;

    // Rebuild each bucket with the looked-up details, keeping the original
    // order so the round-robin is unchanged.
    MediaBarSlideItem rebuild(MediaBarSlideItem slide) {
      final match = local[slide.itemId];
      final tmdbLogo = tmdbLogos[slide.itemId];
      if (match == null && tmdbLogo == null) return slide;
      return _customSlideFor(
        _asExternalItem(slide),
        local: match,
        tmdbLogoUrl: tmdbLogo,
      ) ?? slide;
    }

    return [for (final pool in perList) pool.map(rebuild).toList()];
  }

  /// The slide's own fields, shaped back into the list item [_customSlideFor]
  /// reads, so a rebuild after enrichment needs no second copy of the data.
  ImdbExternalListItem _asExternalItem(MediaBarSlideItem slide) =>
      ImdbExternalListItem(
        imdbId: slide.imdbId ?? '',
        tmdbId: slide.tmdbId ?? '',
        title: slide.title,
        // The backdrop is already absolute and sized; it passes through.
        backdropUrl: slide.backdropUrl,
        posterUrl: slide.posterUrl,
        year: slide.year,
        type: slide.itemType,
        officialRating: slide.officialRating,
        // Preserve the TMDB rating so it can be used as a fallback if the
        // library doesn't have the title.
        rating: slide.communityRating,
      );

  /// Deals [pools] out round-robin, up to [maxItems] in total.
  List<MediaBarSlideItem> _interleaveSlides(
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

  /// The banner slide for one custom list title.
  ///
  /// The list carries its own backdrop and poster, so the slide draws those
  /// directly instead of asking a server for art it may not hold. The id is
  /// the `tmdb:` route form so opening the slide lands on the Seerr-only
  /// detail (the same place a tapped custom row goes); a bare provider id is
  /// the fallback when the list gave no TMDB id. Titles with no backdrop at
  /// all are dropped — the banner is a backdrop surface.
  ///
  /// Only the clean backdrop paints the card. It is fetched at banner size and
  /// cover-fitted by the bar (a 16:9 backdrop cropped into the 21:9 frame),
  /// and never carries a baked-in title the way the plugin's titled thumb or a
  /// poster would. The title is left off the image: the bar overlays it (or
  /// the logo, when the server knows the title) in the bottom-left corner
  /// above the meta line and ratings.
  MediaBarSlideItem? _customSlideFor(
    ImdbExternalListItem item, {
    Map<String, dynamic>? local,
    String? tmdbLogoUrl,
  }) {
    final backdrop = mediaBarCustomImageUrl(item.backdropUrl, 'w1280');
    if (backdrop == null) return null;
    final tmdbId = item.tmdbId;
    final imdbId = item.imdbId;
    final kind =
        item.type.toLowerCase() == 'series' || item.type.toLowerCase() == 'tv' ? 'tv' : 'movie';
    final routeId = tmdbId.isNotEmpty
        ? 'tmdb:$kind:$tmdbId'
        : (imdbId.isNotEmpty ? imdbId : '');
    if (routeId.isEmpty) return null;
    return MediaBarSlideItem(
      itemId: routeId,
      serverId: 'seerr',
      title: item.title,
      // `bannerUrl` stays null so the bar paints the backdrop (cover-cropped,
      // no title) rather than a titled wide image.
      backdropUrl: backdrop,
      // Use library logo if available, otherwise TMDB logo, otherwise null
      logoUrl: local != null
          ? _serverLogoUrl(local)
          : tmdbLogoUrl,
      posterUrl: mediaBarCustomImageUrl(item.posterUrl, 'w500'),
      year: item.year,
      officialRating:
          (local?['OfficialRating'] as String?) ?? item.officialRating,
      genres: (local?['Genres'] as List?)?.cast<String>().take(3).toList() ??
          const [],
      // The list carries no runtime, so the library's answer is used when the
      // title is in one; the meta line just omits it otherwise.
      runtime: _serverRuntime(local),
      // Use library ratings if available, otherwise fall back to external list ratings
      communityRating: (local?['CommunityRating'] as num?)?.toDouble()
          ?? item.rating,
      criticRating: (local?['CriticRating'] as num?)?.toInt(),
      tmdbId: tmdbId.isNotEmpty ? tmdbId : null,
      imdbId: imdbId.isNotEmpty ? imdbId : null,
      itemType: item.type,
    );
  }

  /// The library's logo image for a matched item, so the bar overlays the real
  /// title mark the way it does for library titles instead of plain text.
  String? _serverLogoUrl(Map<String, dynamic> local) {
    final itemId = local['Id']?.toString();
    final tag = (local['ImageTags'] as Map?)?['Logo'] as String?;
    if (itemId == null || itemId.isEmpty || tag == null) return null;
    return _client.imageApi.getLogoImageUrl(itemId, tag: tag, maxWidth: 600);
  }

  Duration? _serverRuntime(Map<String, dynamic>? local) {
    final ticks = local?['RunTimeTicks'] as int?;
    return ticks == null ? null : Duration(microseconds: ticks ~/ 10);
  }

  /// The library's copy of a custom list title, by provider id.
  ///
  /// A list can name titles the library does not hold, so a miss is normal and
  /// simply leaves the slide as the list described it. A hit is what supplies
  /// the pieces the list has no answer for: the title logo, the runtime and
  /// the certification. Only the fields the slide reads are requested.
  ///
  /// The answer is verified before it is trusted. A server that ignores
  /// `anyProviderIdEquals` replies with an unfiltered page, so taking its first
  /// row would hand the same title's runtime and ratings to every custom slide.
  /// The id is matched on what the row actually carries, and only the type the
  /// list asked for is considered, since a series and one of its episodes can
  /// share a TMDB id.
  Future<Map<String, dynamic>?> _findLocalItemFor(
    String tmdbId,
    String imdbId,
    String itemType,
  ) async {
    final key = tmdbId.isNotEmpty ? 'Tmdb' : 'Imdb';
    final value = tmdbId.isNotEmpty ? tmdbId : imdbId;
    if (value.isEmpty) return null;
    // 'Series' for the list's 'Series', 'Movie' for its 'Movie'.
    final wantType = itemType.toLowerCase() == 'series' || itemType.toLowerCase() == 'tv'
        ? 'Series'
        : 'Movie';
    try {
      final response = await _client.itemsApi
          .getItems(
            anyProviderIdEquals: '$key.$value',
            includeItemTypes: const ['Movie', 'Series'],
            recursive: true,
            // Enough rows to skip a wrong-type match (a series and its episode
            // can share the id) before giving up on verification.
            limit: 10,
            fields: _customDetailFields,
            enableImageTypes: 'Logo,Backdrop,Primary',
          )
          .timeout(const Duration(seconds: 8));
      final items = (response['Items'] as List?) ?? const [];
      for (final raw in items) {
        if (raw is! Map<String, dynamic>) continue;
        if (raw['Type'] != wantType) continue;
        if (!_carriesProviderId(raw, key, value)) continue;
        return raw;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Whether [item] actually carries [key] = [value].
  ///
  /// Case is tolerated because servers are not consistent about the key casing,
  /// and the check exists precisely because the query cannot be trusted.
  static bool _carriesProviderId(
    Map<String, dynamic> item,
    String key,
    String value,
  ) {
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

  /// Fields [_findLocalItemFor] asks for: enough for the logo, the runtime and
  /// the ratings the banner's meta line shows.
  static const _customDetailFields =
      'Overview,Genres,OfficialRating,CommunityRating,CriticRating,'
      'RunTimeTicks,ProductionYear,ImageTags,ProviderIds';

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
                  enableImageTypes: 'Backdrop,Logo,Banner',
                )
                .timeout(const Duration(seconds: 15))
          : await effectiveClient.itemsApi
                .getLatestItems(
                  includeItemTypes: itemTypes,
                  parentId: parentId,
                  limit: _poolSize,
                  fields: _fields,
                  enableImageTypes: 'Backdrop,Logo,Banner',
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
            enableImageTypes: 'Backdrop,Logo,Banner',
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

    final bannerTag = (data['ImageTags'] as Map?)?['Banner'] as String?;
    final bannerUrl = bannerTag != null
        ? _client.imageApi.getBannerImageUrl(
            itemId,
            tag: bannerTag,
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
      bannerUrl: bannerUrl,
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

class _MediaBarSource {
  final String serverId;
  final String libraryId;

  const _MediaBarSource({required this.serverId, required this.libraryId});

  bool get isActiveServer => serverId.isEmpty;

  String get sourceKey =>
      serverId.isEmpty ? libraryId : '$serverId|$libraryId';
}

/// Source-library token for a custom row list the user added (TMDB /
/// Letterboxd / MDBList). The `custom:` prefix keeps a list distinct from a
/// bare library id and from the `serverId|libraryId` tokens, so the picker can
/// offer lists beside server libraries and the fetch side can tell them apart.
String customRowSourceToken(String pluginSection) => 'custom:$pluginSection';

/// The custom-row section [token] names, or null when it is a plain library id
/// or `serverId|libraryId` token rather than a custom list.
String? customRowSectionForToken(String token) =>
    token.startsWith('custom:') ? token.substring('custom:'.length) : null;

/// Whether [token] names a custom row list rather than a server library.
bool isCustomRowSourceToken(String token) => token.startsWith('custom:');

/// Whether the user picked anything at all for the bar to draw from.
///
/// The bar is a curated view: with no source library, collection or custom
/// list selected it stays empty rather than falling back to every library, so
/// "nothing chosen" has to read as "nothing to show" before any server query.
bool hasMediaBarSourceSelection({
  required List<String> libraryIds,
  required List<String> collectionIds,
  required List<String> customTokens,
}) =>
    libraryIds.isNotEmpty || collectionIds.isNotEmpty || customTokens.isNotEmpty;

/// A custom row list image as a fetchable absolute URL.
///
/// These lists come from TMDB, which hands back bare paths like `/abc.jpg`;
/// the bar (like the home rows) turns those into full image.tmdb.org URLs at a
/// chosen size so the image actually loads. Anything already absolute passes
/// through untouched, and a bare non-path value is dropped rather than fetched.
String? mediaBarCustomImageUrl(String? path, String size) {
  if (path == null || path.isEmpty) return null;
  if (path.startsWith('http')) return path;
  if (!path.startsWith('/')) return null;
  return 'https://image.tmdb.org/t/p/$size$path';
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
