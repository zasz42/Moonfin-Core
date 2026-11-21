import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../../data/models/calendar_entry.dart';
import '../../../data/repositories/calendar_repository.dart';
import '../../../data/services/better_posters_service.dart';
import '../bounded_network_image.dart';

/// A compact, read-only view of the next two weeks of Radarr/Sonarr releases.
/// Artwork intentionally uses the calendar's ordinary image URL; poster
/// resolution enhancements belong to the separate Better Posters feature.
class UpcomingReleasesRail extends StatefulWidget {
  const UpcomingReleasesRail({super.key});

  @override
  State<UpcomingReleasesRail> createState() => _UpcomingReleasesRailState();
}

class _UpcomingReleasesRailState extends State<UpcomingReleasesRail> {
  late Future<CalendarResult> _entries;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    _entries = GetIt.instance<CalendarRepository>().load(
      start: start,
      end: start.add(const Duration(days: 14)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColorScheme.surface.withValues(alpha: 0.94),
        borderRadius: AppRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'UPCOMING RELEASES',
              maxLines: 1,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: AppColorScheme.onSurface,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 5),
            Expanded(
              child: FutureBuilder<CalendarResult>(
                future: _entries,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final entries =
                      snapshot.data?.entries ?? const <CalendarEntry>[];
                  if (entries.isEmpty) {
                    return Center(
                      child: Text(
                        'No upcoming releases',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColorScheme.onSurface.withValues(
                            alpha: 0.7,
                          ),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    );
                  }
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final itemHeight = ((constraints.maxHeight - 14) / 8)
                          .clamp(14.0, 30.0);
                      return ListView.separated(
                        padding: EdgeInsets.zero,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: entries.length.clamp(0, 8),
                        separatorBuilder: (_, _) => const SizedBox(height: 2),
                        itemBuilder: (context, index) => _ReleaseTile(
                          entry: entries[index],
                          height: itemHeight,
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReleaseTile extends StatelessWidget {
  const _ReleaseTile({required this.entry, required this.height});

  final CalendarEntry entry;
  final double height;

  @override
  Widget build(BuildContext context) {
    final detail = entry.isEpisode
        ? 'S${(entry.seasonNumber ?? 0).toString().padLeft(2, '0')} · E${(entry.episodeNumber ?? 0).toString().padLeft(2, '0')}'
        : switch (entry.release) {
            CalendarRelease.cinema => 'In cinemas',
            CalendarRelease.digital => 'Digital',
            CalendarRelease.physical => 'Physical',
            CalendarRelease.airing => 'Airing',
          };
    final externalPoster = BetterPostersService.posterUrlForCalendarEntry(
      entry,
    );
    final imageUrl = externalPoster ?? entry.posterUrl;

    return LayoutBuilder(
      builder: (context, constraints) {
        // The 21:9 compact banner leaves a deliberately narrow fifth of its
        // width for the rail. Drop thumbnails and secondary release text at
        // that size so all eight titles remain legible without flex overflow.
        final narrow = constraints.maxWidth < 180;
        final date = '${entry.date.month}/${entry.date.day}';
        return SizedBox(
          height: height,
          child: Row(
            children: [
              if (!narrow && imageUrl != null && imageUrl.isNotEmpty)
                SizedBox(
                  width: height * 2 / 3,
                  height: height,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (externalPoster != null &&
                          entry.posterUrl != null &&
                          entry.posterUrl!.isNotEmpty)
                        BoundedNetworkImage(
                          imageUrl: entry.posterUrl!,
                          fit: BoxFit.cover,
                          maxWidth: 160,
                        ),
                      BoundedNetworkImage(
                        imageUrl: imageUrl,
                        fit: BoxFit.cover,
                        maxWidth: 160,
                        cacheManager: BetterPostersService.cacheManagerForUrl(
                          imageUrl,
                        ),
                        priority: externalPoster != null
                            ? ImageFetchPriority.low
                            : ImageFetchPriority.normal,
                        errorBuilder: (_, _, _) =>
                            externalPoster != null &&
                                entry.posterUrl != null &&
                                entry.posterUrl!.isNotEmpty
                            ? const SizedBox.shrink()
                            : const Icon(Icons.movie_outlined, size: 12),
                      ),
                    ],
                  ),
                )
              else if (!narrow)
                SizedBox(
                  width: height * 2 / 3,
                  height: height,
                  child: const Icon(Icons.movie_outlined, size: 12),
                ),
              if (!narrow) const SizedBox(width: 6),
              Expanded(
                child: Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                    fontSize: narrow ? 8 : null,
                  ),
                ),
              ),
              SizedBox(width: narrow ? 3 : 6),
              SizedBox(
                width: narrow ? 26 : null,
                child: Text(
                  narrow ? date : '$detail · $date',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: narrow ? TextAlign.end : TextAlign.start,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: AppColorScheme.onSurface.withValues(alpha: 0.7),
                    fontSize: narrow ? 7 : 9,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
