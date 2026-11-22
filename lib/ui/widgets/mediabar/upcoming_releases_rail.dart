import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../../data/models/calendar_entry.dart';
import '../../../data/repositories/calendar_repository.dart';
import '../../../data/services/better_posters_service.dart';
import '../bounded_network_image.dart';

/// Eight upcoming-release poster cards in the compact media-bar side rail.
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
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: AppColorScheme.onSurface,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 6),
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
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    );
                  }
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final tileWidth = (constraints.maxWidth / 8).clamp(
                        34.0,
                        110.0,
                      );
                      return ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: entries.length.clamp(0, 8),
                        separatorBuilder: (_, _) => const SizedBox(width: 5),
                        itemBuilder: (context, index) => _ReleasePoster(
                          entry: entries[index],
                          width: tileWidth,
                          height: constraints.maxHeight,
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

class _ReleasePoster extends StatelessWidget {
  const _ReleasePoster({
    required this.entry,
    required this.width,
    required this.height,
  });

  final CalendarEntry entry;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final external = BetterPostersService.posterUrlForCalendarEntry(entry);
    final url = external ?? entry.posterUrl;
    final days = DateTime(entry.date.year, entry.date.month, entry.date.day)
        .difference(
          DateTime(
            DateTime.now().year,
            DateTime.now().month,
            DateTime.now().day,
          ),
        )
        .inDays;
    final releaseText = days <= 0
        ? 'today'
        : days <= 7
        ? '$days ${days == 1 ? 'day' : 'days'}'
        : '${entry.date.month}/${entry.date.day}';
    final posterHeight = (height * 0.66).clamp(30.0, 150.0);
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: posterHeight,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (external != null && entry.posterUrl != null)
                    BoundedNetworkImage(
                      imageUrl: entry.posterUrl!,
                      fit: BoxFit.cover,
                      maxWidth: 220,
                    ),
                  if (url != null && url.isNotEmpty)
                    BoundedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.cover,
                      maxWidth: 220,
                      cacheManager: BetterPostersService.cacheManagerForUrl(
                        url,
                      ),
                      errorBuilder: (_, _, _) => external != null
                          ? const SizedBox.shrink()
                          : const ColoredBox(
                              color: Colors.black12,
                              child: Icon(Icons.movie_outlined, size: 16),
                            ),
                    )
                  else
                    const ColoredBox(
                      color: Colors.black12,
                      child: Icon(Icons.movie_outlined, size: 16),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            entry.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w700,
              fontSize: 10,
              color: AppColorScheme.onSurface,
            ),
          ),
          Text(
            releaseText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontSize: 9,
              color: AppColorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}
