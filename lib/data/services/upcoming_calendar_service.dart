import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/models/aggregated_item.dart';
import '../../preference/user_preferences.dart';
import '../repositories/seerr_repository.dart';
import '../utils/bounded_concurrency.dart';

/// Loads, caches and formats the Radarr / Sonarr upcoming calendars.
///
/// Both the home "Upcoming Calendars" rows and the Compact Aya media bar's
/// companion panel render this, so the fetch + cache + formatting lives here
/// once and both consumers stay identical by construction.
class UpcomingCalendarService {
  UpcomingCalendarService();

  UserPreferences get _prefs => GetIt.instance<UserPreferences>();

  /// The merged Radarr + Sonarr calendar, filtered and formatted per the
  /// calendar preferences, sorted by release date ascending.
  Future<List<AggregatedItem>> loadMergedCalendar({
    bool forceRefresh = false,
  }) async {
    try {
      // 1. Load Radarr items
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final lastRadarrFetch = _prefs.get(UserPreferences.lastRadarrCalendarFetchTime);
      final radarrCacheAge = nowMs - lastRadarrFetch;
      final shouldFetchRadarr = forceRefresh || radarrCacheAge > const Duration(days: 1).inMilliseconds;

      List<AggregatedItem> radarrItems;
      if (shouldFetchRadarr) {
        final fetched = await _fetchRadarrCalendarFromApi();
        if (fetched != null) {
          radarrItems = fetched;
          await _saveRadarrCalendarToCache(radarrItems);
          await _prefs.set(UserPreferences.lastRadarrCalendarFetchTime, nowMs);
        } else {
          radarrItems = await _loadRadarrCalendarFromCache();
        }
      } else {
        radarrItems = await _loadRadarrCalendarFromCache();
        if (radarrItems.isEmpty) {
          final fetched = await _fetchRadarrCalendarFromApi();
          if (fetched != null) {
            radarrItems = fetched;
            await _saveRadarrCalendarToCache(radarrItems);
            await _prefs.set(UserPreferences.lastRadarrCalendarFetchTime, nowMs);
          }
        }
      }

      // 2. Load Sonarr items
      final lastSonarrFetch = _prefs.get(UserPreferences.lastSonarrCalendarFetchTime);
      final sonarrCacheAge = nowMs - lastSonarrFetch;
      final shouldFetchSonarr = forceRefresh || sonarrCacheAge > const Duration(days: 1).inMilliseconds;

      List<AggregatedItem> sonarrItems;
      if (shouldFetchSonarr) {
        final fetched = await _fetchSonarrCalendarFromApi();
        if (fetched != null) {
          sonarrItems = fetched;
          await _saveSonarrCalendarToCache(sonarrItems);
          await _prefs.set(UserPreferences.lastSonarrCalendarFetchTime, nowMs);
        } else {
          sonarrItems = await _loadSonarrCalendarFromCache();
        }
      } else {
        sonarrItems = await _loadSonarrCalendarFromCache();
        if (sonarrItems.isEmpty) {
          final fetched = await _fetchSonarrCalendarFromApi();
          if (fetched != null) {
            sonarrItems = fetched;
            await _saveSonarrCalendarToCache(sonarrItems);
            await _prefs.set(UserPreferences.lastSonarrCalendarFetchTime, nowMs);
          }
        }
      }

      // 3. Merge and sort
      final filteredRadarr = _filterAndFormatRadarrItems(radarrItems);
      final filteredSonarr = _formatSonarrItems(sonarrItems);
      final mergedItems = [...filteredRadarr, ...filteredSonarr];
      mergedItems.sort((a, b) {
        final dateA = a.rawData['CalendarDate'] as String? ?? '';
        final dateB = b.rawData['CalendarDate'] as String? ?? '';
        return dateA.compareTo(dateB);
      });

      return mergedItems;
    } catch (e) {
      debugPrint('[MergedCalendar] Failed to load merged calendar: $e');
      return const [];
    }
  }

  /// The Radarr calendar alone, filtered and formatted, sorted by date.
  Future<List<AggregatedItem>> loadRadarrCalendar({
    bool forceRefresh = false,
  }) async {
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final lastFetch = _prefs.get(UserPreferences.lastRadarrCalendarFetchTime);
      final cacheAge = nowMs - lastFetch;
      final shouldFetch = forceRefresh || cacheAge > const Duration(days: 1).inMilliseconds;

      List<AggregatedItem> items;
      if (shouldFetch) {
        final fetchedItems = await _fetchRadarrCalendarFromApi();
        if (fetchedItems != null) {
          await _saveRadarrCalendarToCache(fetchedItems);
          await _prefs.set(UserPreferences.lastRadarrCalendarFetchTime, nowMs);
          items = _filterAndFormatRadarrItems(fetchedItems);
        } else {
          final cached = await _loadRadarrCalendarFromCache();
          items = _filterAndFormatRadarrItems(cached);
        }
      } else {
        final cached = await _loadRadarrCalendarFromCache();
        items = _filterAndFormatRadarrItems(cached);
        if (items.isEmpty) {
          final fetchedItems = await _fetchRadarrCalendarFromApi();
          if (fetchedItems != null) {
            await _saveRadarrCalendarToCache(fetchedItems);
            await _prefs.set(UserPreferences.lastRadarrCalendarFetchTime, nowMs);
            items = _filterAndFormatRadarrItems(fetchedItems);
          }
        }
      }

      return items;
    } catch (e) {
      debugPrint('[RadarrCalendar] Failed to load: $e');
      return const [];
    }
  }

  /// The Sonarr calendar alone, formatted, sorted by date.
  Future<List<AggregatedItem>> loadSonarrCalendar({
    bool forceRefresh = false,
  }) async {
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final lastFetch = _prefs.get(UserPreferences.lastSonarrCalendarFetchTime);
      final cacheAge = nowMs - lastFetch;
      final shouldFetch = forceRefresh || cacheAge > const Duration(days: 1).inMilliseconds;

      List<AggregatedItem> items;
      if (shouldFetch) {
        final fetchedItems = await _fetchSonarrCalendarFromApi();
        if (fetchedItems != null) {
          await _saveSonarrCalendarToCache(fetchedItems);
          await _prefs.set(UserPreferences.lastSonarrCalendarFetchTime, nowMs);
          items = _formatSonarrItems(fetchedItems);
        } else {
          final cached = await _loadSonarrCalendarFromCache();
          items = _formatSonarrItems(cached);
        }
      } else {
        final cached = await _loadSonarrCalendarFromCache();
        items = _formatSonarrItems(cached);
        if (items.isEmpty) {
          final fetchedItems = await _fetchSonarrCalendarFromApi();
          if (fetchedItems != null) {
            await _saveSonarrCalendarToCache(fetchedItems);
            await _prefs.set(UserPreferences.lastSonarrCalendarFetchTime, nowMs);
            items = _formatSonarrItems(fetchedItems);
          }
        }
      }

      return items;
    } catch (e) {
      debugPrint('[SonarrCalendar] Failed to load: $e');
      return const [];
    }
  }

  List<AggregatedItem> _filterAndFormatRadarrItems(List<AggregatedItem> rawItems) {
    final now = DateTime.now();
    final showCinema = _prefs.get(UserPreferences.radarrCalendarShowCinema);
    final showDigital = _prefs.get(UserPreferences.radarrCalendarShowDigital);
    final showPhysical = _prefs.get(UserPreferences.radarrCalendarShowPhysical);
    final showDate = _prefs.get(UserPreferences.radarrCalendarShowDate);

    final List<AggregatedItem> filtered = [];

    for (final item in rawItems) {
      final inCinemasStr = item.rawData['InCinemas'] as String?;
      final digitalReleaseStr = item.rawData['DigitalRelease'] as String?;
      final physicalReleaseStr = item.rawData['PhysicalRelease'] as String?;

      final inCinemas = inCinemasStr != null ? DateTime.tryParse(inCinemasStr) : null;
      final digitalRelease = digitalReleaseStr != null ? DateTime.tryParse(digitalReleaseStr) : null;
      final physicalRelease = physicalReleaseStr != null ? DateTime.tryParse(physicalReleaseStr) : null;

      final enabledReleases = <DateTime, String>{};
      if (showCinema && inCinemas != null && inCinemas.isAfter(now.subtract(const Duration(days: 1)))) {
        enabledReleases[inCinemas] = 'Cinema: ';
      }
      if (showDigital && digitalRelease != null && digitalRelease.isAfter(now.subtract(const Duration(days: 1)))) {
        enabledReleases[digitalRelease] = 'Digital: ';
      }
      if (showPhysical && physicalRelease != null && physicalRelease.isAfter(now.subtract(const Duration(days: 1)))) {
        enabledReleases[physicalRelease] = 'Physical: ';
      }

      if (enabledReleases.isEmpty) continue;

      final sortedDates = enabledReleases.keys.toList()..sort();
      final targetReleaseDate = sortedDates.first;
      final releaseType = enabledReleases[targetReleaseDate]!;

      String? subtitleText;
      if (showDate) {
        final dateStr = _formatDateHuman(targetReleaseDate);
        subtitleText = '$releaseType$dateStr';
      }

      final newRawData = Map<String, dynamic>.from(item.rawData);
      newRawData['Subtitle'] = subtitleText;
      newRawData['CalendarDate'] = targetReleaseDate.toIso8601String();

      filtered.add(AggregatedItem(
        id: item.id,
        serverId: item.serverId,
        rawData: newRawData,
      ));
    }

    filtered.sort((a, b) {
      final dateA = a.rawData['CalendarDate'] as String? ?? '';
      final dateB = b.rawData['CalendarDate'] as String? ?? '';
      return dateA.compareTo(dateB);
    });

    return filtered;
  }

  List<AggregatedItem> _formatSonarrItems(List<AggregatedItem> rawItems) {
    final showDate = _prefs.get(UserPreferences.sonarrCalendarShowDate);
    final showEpisodeInfo = _prefs.get(UserPreferences.sonarrCalendarShowEpisodeInfo);
    // beta.1 has no dedicated "Compact Classic" rows style; gate the stripped
    // label on the Compact Banner toggle added by this feature instead.
    final stripNextEpisodePrefix =
        _prefs.get(UserPreferences.compactBannerEnabled);

    return rawItems.map((item) {
      final airDateUtcStr = item.rawData['CalendarDate'] as String?;
      final airDateUtc = airDateUtcStr != null ? DateTime.tryParse(airDateUtcStr) : null;
      if (airDateUtc == null) return item;

      final sNum = item.rawData['SeasonNumber'] as String? ?? '0';
      final eNum = item.rawData['EpisodeNumber'] as String? ?? '0';

      String? subtitleText;
      if (showDate && showEpisodeInfo) {
        final dateStr = _formatDateHuman(airDateUtc);
        subtitleText = stripNextEpisodePrefix
            ? '$dateStr (S$sNum:E$eNum)'
            : 'Next Episode: $dateStr (S$sNum:E$eNum)';
      } else if (showDate) {
        final dateStr = _formatDateHuman(airDateUtc);
        subtitleText = stripNextEpisodePrefix
            ? dateStr
            : 'Next Episode: $dateStr';
      } else if (showEpisodeInfo) {
        subtitleText = stripNextEpisodePrefix
            ? '(S$sNum:E$eNum)'
            : 'Next Episode: (S$sNum:E$eNum)';
      }

      final newRawData = Map<String, dynamic>.from(item.rawData);
      newRawData['Subtitle'] = subtitleText;

      return AggregatedItem(
        id: item.id,
        serverId: item.serverId,
        rawData: newRawData,
      );
    }).toList();
  }

  Future<List<AggregatedItem>?> _fetchRadarrCalendarFromApi() async {
    try {
      final repo = await GetIt.instance.getAsync<SeerrRepository>();
      final now = DateTime.now();
      final start = now.toIso8601String().substring(0, 10);
      final end = now.add(const Duration(days: 90)).toIso8601String().substring(0, 10);

      // The plugin fetches the Radarr calendar server side, so the API key stays on the server and
      // this still works when a remote client cant reach a LAN only Radarr.
      final results = await repo.getRadarrCalendar(start: start, end: end);

      final enrichCompleters = await mapBounded(
        results,
        5,
        (res) async {
          if (res is! Map) return null;
          final tmdbIdVal = res['tmdbId'];
          if (tmdbIdVal == null || tmdbIdVal == 0) return null;
          final tmdbId = tmdbIdVal.toString();

          final title = res['title'] as String? ?? 'Unknown';
          final overview = res['overview'] as String? ?? '';
          final year = res['year'] as int?;

          final inCinemasStr = res['inCinemas'] as String?;
          final digitalReleaseStr = res['digitalRelease'] as String?;
          final physicalReleaseStr = res['physicalRelease'] as String?;

          final inCinemas = inCinemasStr != null ? DateTime.tryParse(inCinemasStr) : null;
          final digitalRelease = digitalReleaseStr != null ? DateTime.tryParse(digitalReleaseStr) : null;
          final physicalRelease = physicalReleaseStr != null ? DateTime.tryParse(physicalReleaseStr) : null;

          final allReleases = <DateTime>[];
          if (inCinemas != null && inCinemas.isAfter(now.subtract(const Duration(days: 1)))) {
            allReleases.add(inCinemas);
          }
          if (digitalRelease != null && digitalRelease.isAfter(now.subtract(const Duration(days: 1)))) {
            allReleases.add(digitalRelease);
          }
          if (physicalRelease != null && physicalRelease.isAfter(now.subtract(const Duration(days: 1)))) {
            allReleases.add(physicalRelease);
          }

          if (allReleases.isEmpty) return null;

          final sortedDates = allReleases..sort();
          final defaultReleaseDate = sortedDates.first;

          String? posterPath;
          String? backdropPath;
          final images = res['images'] as List?;
          if (images != null) {
            for (final img in images) {
              if (img is! Map) continue;
              final type = img['coverType'] as String?;
              final remoteUrl = img['remoteUrl'] as String? ?? img['url'] as String?;
              // Only external image URLs are used. A local arr image would need the API key and
              // wouldnt be reachable from a remote client anyway.
              if (remoteUrl != null && remoteUrl.startsWith('http')) {
                if (type == 'poster') {
                  posterPath = remoteUrl;
                } else if (type == 'fanart') {
                  backdropPath = remoteUrl;
                }
              }
            }
          }

          if (posterPath == null || posterPath.isEmpty) {
            try {
              final details = await repo.getMovieDetails(int.parse(tmdbId));
              posterPath = _tmdbImageUrl(details.posterPath, 300) ?? '';
              backdropPath = _tmdbImageUrl(details.backdropPath, 1280) ?? '';
            } catch (_) {}
          }

          return _CalendarItemWithDate(
            item: AggregatedItem(
              id: tmdbId,
              serverId: 'seerr',
              rawData: {
                'Name': title,
                'Type': 'Movie',
                'Overview': overview,
                'PosterPath': posterPath,
                'BackdropPath': backdropPath,
                'ProductionYear': year,
                'SeerrMediaType': 'movie',
                'InCinemas': inCinemasStr,
                'DigitalRelease': digitalReleaseStr,
                'PhysicalRelease': physicalReleaseStr,
                'CalendarDate': defaultReleaseDate.toIso8601String(),
                'CacheVerV2': true,
              },
            ),
            date: defaultReleaseDate,
          );
        },
      );

      final calendarItems = enrichCompleters.whereType<_CalendarItemWithDate>().toList()
        ..sort((a, b) => a.date.compareTo(b.date));

      return calendarItems.map((c) => c.item).toList();
    } catch (e) {
      debugPrint('[RadarrCalendarApi] Failed to fetch: $e');
      return null;
    }
  }

  Future<List<AggregatedItem>?> _fetchSonarrCalendarFromApi() async {
    try {
      final repo = await GetIt.instance.getAsync<SeerrRepository>();
      final now = DateTime.now();
      final start = now.toIso8601String().substring(0, 10);
      final end = now.add(const Duration(days: 90)).toIso8601String().substring(0, 10);

      // The plugin fetches the Sonarr calendar server side, so the API key stays on the server and
      // this still works when a remote client cant reach a LAN only Sonarr.
      final results = await repo.getSonarrCalendar(start: start, end: end);

      final groupedEpisodes = <int, Map<String, dynamic>>{};
      for (final res in results) {
        if (res is! Map) continue;
        final seriesMap = res['series'];
        if (seriesMap is! Map) continue;

        final tvdbIdVal = seriesMap['tvdbId'];
        if (tvdbIdVal == null || tvdbIdVal == 0) continue;
        final tvdbId = tvdbIdVal as int;

        final airDateUtcStr = res['airDateUtc'] as String?;
        final airDateUtc = airDateUtcStr != null ? DateTime.tryParse(airDateUtcStr) : null;
        if (airDateUtc == null) continue;

        final existing = groupedEpisodes[tvdbId];
        if (existing == null) {
          groupedEpisodes[tvdbId] = {
            'series': seriesMap,
            'airDate': airDateUtc,
            'seasonNumber': res['seasonNumber'],
            'episodeNumber': res['episodeNumber'],
          };
        } else {
          final existingAirDate = existing['airDate'] as DateTime;
          if (airDateUtc.isBefore(existingAirDate)) {
            existing['airDate'] = airDateUtc;
            existing['seasonNumber'] = res['seasonNumber'];
            existing['episodeNumber'] = res['episodeNumber'];
          }
        }
      }

      final enrichCompleters = await mapBounded(
        groupedEpisodes.values.toList(),
        5,
        (episodeInfo) async {
          final seriesMap = episodeInfo['series'] as Map;
          final tvdbId = seriesMap['tvdbId'] as int;
          final seriesTitle = seriesMap['title'] as String? ?? 'Unknown';
          final overview = seriesMap['overview'] as String? ?? '';
          final airDateUtc = episodeInfo['airDate'] as DateTime;

          int? tmdbId;
          final tmdbIdVal = seriesMap['tmdbId'];
          if (tmdbIdVal != null && tmdbIdVal != 0) {
            tmdbId = tmdbIdVal as int;
          } else {
            try {
              final tvDetails = await repo.getTvDetailsByTvdb(tvdbId);
              tmdbId = tvDetails.id;
            } catch (_) {}
          }

          if (tmdbId == null || tmdbId == 0) return null;

          String? posterPath;
          String? backdropPath;
          final images = seriesMap['images'] as List?;
          if (images != null) {
            for (final img in images) {
              if (img is! Map) continue;
              final type = img['coverType'] as String?;
              final remoteUrl = img['remoteUrl'] as String? ?? img['url'] as String?;
              // Only external image URLs are used. A local arr image would need the API key and
              // wouldnt be reachable from a remote client anyway.
              if (remoteUrl != null && remoteUrl.startsWith('http')) {
                if (type == 'poster') {
                  posterPath = remoteUrl;
                } else if (type == 'fanart') {
                  backdropPath = remoteUrl;
                }
              }
            }
          }

          if (posterPath == null || posterPath.isEmpty) {
            try {
              final details = await repo.getTvDetails(tmdbId);
              posterPath = _tmdbImageUrl(details.posterPath, 300) ?? '';
              backdropPath = _tmdbImageUrl(details.backdropPath, 1280) ?? '';
            } catch (_) {}
          }

          final sNum = (episodeInfo['seasonNumber'] ?? 0).toString();
          final eNum = (episodeInfo['episodeNumber'] ?? 0).toString();

          return _CalendarItemWithDate(
            item: AggregatedItem(
              id: tmdbId.toString(),
              serverId: 'seerr',
              rawData: {
                'Name': seriesTitle,
                'Type': 'Series',
                'Overview': overview,
                'PosterPath': posterPath,
                'BackdropPath': backdropPath,
                'SeerrMediaType': 'tv',
                'SeasonNumber': sNum,
                'EpisodeNumber': eNum,
                'CalendarDate': airDateUtc.toIso8601String(),
                'CacheVerV2': true,
              },
            ),
            date: airDateUtc,
          );
        },
      );

      final calendarItems = enrichCompleters.whereType<_CalendarItemWithDate>().toList()
        ..sort((a, b) => a.date.compareTo(b.date));

      return calendarItems.map((c) => c.item).toList();
    } catch (e) {
      debugPrint('[SonarrCalendarApi] Failed to fetch: $e');
      return null;
    }
  }

  String? _tmdbImageUrl(String? path, int width) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http')) return path;
    return 'https://image.tmdb.org/t/p/w$width$path';
  }

  String _formatDateHuman(DateTime date) {
    final months = [
      'Jan.',
      'Feb.',
      'Mar.',
      'Apr.',
      'May',
      'Jun.',
      'Jul.',
      'Aug.',
      'Sep.',
      'Oct.',
      'Nov.',
      'Dec.'
    ];
    final month = months[date.month - 1];
    final day = date.day;
    final suffix = switch (day) {
      1 || 21 || 31 => 'st',
      2 || 22 => 'nd',
      3 || 23 => 'rd',
      _ => 'th',
    };
    return '$month $day$suffix';
  }

  /// Entries written before CacheVerV2 have a different shape, so the marker on
  /// its own decides staleness. Artwork fields are deliberately not checked,
  /// because an entry whose poster is genuinely missing is still valid and
  /// refetching it only writes the same empty value back.
  static bool _isStaleCalendarCache(List<AggregatedItem> items) =>
      items.any((x) => !x.rawData.containsKey('CacheVerV2'));

  Future<List<AggregatedItem>> _loadRadarrCalendarFromCache() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/radarr_calendar_cache.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final list = jsonDecode(content) as List;
        final items = list.map((x) => _aggregatedItemFromJson(x as Map<String, dynamic>)).toList();
        if (_isStaleCalendarCache(items)) {
          debugPrint('[RadarrCalendarCache] Old cache detected, invalidating to force fresh fetch');
          try {
            await file.delete();
          } catch (_) {}
          return const [];
        }
        return items;
      }
    } catch (e) {
      debugPrint('[RadarrCalendarCache] Failed to load: $e');
    }
    return const [];
  }

  Future<void> _saveRadarrCalendarToCache(List<AggregatedItem> items) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/radarr_calendar_cache.json');
      final content = jsonEncode(items.map((x) => _aggregatedItemToJson(x)).toList());
      await file.writeAsString(content, flush: true);
    } catch (e) {
      debugPrint('[RadarrCalendarCache] Failed to save: $e');
    }
  }

  Future<List<AggregatedItem>> _loadSonarrCalendarFromCache() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/sonarr_calendar_cache.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final list = jsonDecode(content) as List;
        final items = list.map((x) => _aggregatedItemFromJson(x as Map<String, dynamic>)).toList();
        if (_isStaleCalendarCache(items)) {
          debugPrint('[SonarrCalendarCache] Old cache detected, invalidating to force fresh fetch');
          try {
            await file.delete();
          } catch (_) {}
          return const [];
        }
        return items;
      }
    } catch (e) {
      debugPrint('[SonarrCalendarCache] Failed to load: $e');
    }
    return const [];
  }

  Future<void> _saveSonarrCalendarToCache(List<AggregatedItem> items) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/sonarr_calendar_cache.json');
      final content = jsonEncode(items.map((x) => _aggregatedItemToJson(x)).toList());
      await file.writeAsString(content, flush: true);
    } catch (e) {
      debugPrint('[SonarrCalendarCache] Failed to save: $e');
    }
  }

  Map<String, dynamic> _aggregatedItemToJson(AggregatedItem item) {
    return {
      'id': item.id,
      'serverId': item.serverId,
      'rawData': item.rawData,
    };
  }

  AggregatedItem _aggregatedItemFromJson(Map<String, dynamic> json) {
    return AggregatedItem(
      id: json['id'] as String,
      serverId: json['serverId'] as String,
      rawData: Map<String, dynamic>.from(json['rawData'] as Map),
    );
  }
}

class _CalendarItemWithDate {
  final AggregatedItem item;
  final DateTime date;

  _CalendarItemWithDate({required this.item, required this.date});
}
