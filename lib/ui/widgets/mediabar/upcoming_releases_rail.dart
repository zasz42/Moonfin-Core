import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../../data/models/calendar_entry.dart';
import '../../../data/repositories/calendar_repository.dart';
import '../../../data/services/better_posters_service.dart';
import '../bounded_network_image.dart';

/// Eight upcoming-release poster cards in the compact media-bar side rail.
/// This is a passive rail: all eight cards are visible and it cannot receive
/// focus or scroll independently of the banner.
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
    return IgnorePointer(
      child: FutureBuilder<CalendarResult>(
        future: _entries,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final entries = (snapshot.data?.entries ?? const <CalendarEntry>[])
              .take(8)
              .toList(growable: false);
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
              const gap = 8.0;
              final posterWidth = (constraints.maxWidth - gap * 7) / 8;
              final posterHeight = posterWidth * 1.5;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < entries.length; i++) ...[
                    if (i > 0) const SizedBox(width: gap),
                    SizedBox(
                      width: posterWidth,
                      child: _ReleasePoster(
                        entry: entries[i],
                        posterHeight: posterHeight,
                      ),
                    ),
                  ],
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _ReleasePoster extends StatelessWidget {
  const _ReleasePoster({required this.entry, required this.posterHeight});

  final CalendarEntry entry;
  final double posterHeight;

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
    return Column(
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
                    cacheManager: BetterPostersService.cacheManagerForUrl(url),
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
    );
  }
}
