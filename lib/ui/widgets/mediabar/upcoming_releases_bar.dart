import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../../data/models/aggregated_item.dart';
import '../../../data/services/plugin_sync_service.dart';
import '../../../data/services/upcoming_calendar_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../preference/user_preferences.dart';
import '../focus/locked_focus_row.dart';
import '../media_card.dart';
import '../../navigation/destinations.dart';

class UpcomingReleasesBar extends StatefulWidget {
  final double height;
  final Color backgroundColor;
  final UserPreferences prefs;

  /// The color drawn around the focused poster. Mirrors the Focus Border
  /// Color preference so the bar matches the rest of the UI.
  final Color? focusColor;

  /// Called when the user presses Up while the bar is focused, so the home
  /// screen can hand focus back to the navbar.
  final VoidCallback? onExitUp;

  /// Called when the user presses Down while the bar is focused, so the home
  /// screen can hand focus back to the first home row.
  final VoidCallback? onExitDown;

  /// Called when the user presses Left while on the first rail item, so the
  /// home screen can hand focus back to the Compact Aya media bar.
  final VoidCallback? onExitLeft;

  const UpcomingReleasesBar({
    super.key,
    required this.height,
    required this.prefs,
    this.focusColor,
    this.backgroundColor = Colors.transparent,
    this.onExitUp,
    this.onExitDown,
    this.onExitLeft,
  });

  @override
  State<UpcomingReleasesBar> createState() => UpcomingReleasesBarState();
}

class UpcomingReleasesBarState extends State<UpcomingReleasesBar> {
  static const _cacheDuration = Duration(minutes: 5);

  final FocusNode _focusNode = FocusNode(debugLabel: 'upcoming_releases_bar');
  final ScrollController _scrollController = ScrollController();

  List<AggregatedItem>? _items;
  bool _loading = false;
  bool _available = false;
  DateTime? _lastFetch;
  int _fetchGeneration = 0;

  bool get _isUpToDate =>
      _lastFetch != null &&
      DateTime.now().difference(_lastFetch!) < _cacheDuration;

  bool get hasFocus => _focusNode.hasFocus;
  bool get hasItems => _items?.isNotEmpty ?? false;

  @override
  void initState() {
    super.initState();
    _available = GetIt.instance<PluginSyncService>().seerrAvailable;
    _startFetch();
  }

  @override
  void didUpdateWidget(covariant UpcomingReleasesBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nowAvailable = GetIt.instance<PluginSyncService>().seerrAvailable;
    if (nowAvailable != _available) {
      _available = nowAvailable;
      _items = null;
      _lastFetch = null;
      _startFetch();
    }
  }

  @override
  void dispose() {
    _fetchGeneration++;
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Gives the bar keyboard/DPAD focus and scrolls to the remembered title.
  bool requestFocus() {
    if (!hasItems) return false;
    _focusNode.requestFocus();
    return true;
  }

  bool _exit(bool isUp) {
    if (isUp) {
      widget.onExitUp?.call();
    } else {
      widget.onExitDown?.call();
    }
    return true;
  }

  void _startFetch() {
    if (!_available || _loading || _isUpToDate) {
      return;
    }
    _loading = true;
    if (mounted) {
      setState(() {});
    }
    final generation = ++_fetchGeneration;
    unawaited(_fetch(generation));
  }

  Future<void> _fetch(int generation) async {
    try {
      final items = await GetIt
          .instance<UpcomingCalendarService>()
          .loadMergedCalendar();
      if (!mounted || generation != _fetchGeneration) {
        return;
      }
      final filtered = _withPoster(items);
      if (!mounted || generation != _fetchGeneration) {
        return;
      }
      setState(() {
        _items = filtered;
        _loading = false;
        _lastFetch = DateTime.now();
      });
    } catch (_) {
      if (!mounted || generation != _fetchGeneration) {
        return;
      }
      setState(() {
        _loading = false;
        _items = const [];
        _lastFetch = DateTime.now();
      });
    }
  }

  List<AggregatedItem> _withPoster(List<AggregatedItem> items) {
    return items
        .where(
          (item) =>
              item.rawData['PosterPath'] is String &&
              (item.rawData['PosterPath'] as String).isNotEmpty,
        )
        .toList();
  }

  void _openItem(AggregatedItem item) {
    if (!mounted) return;
    context.push(
      Destinations.itemOrPhoto(
        item.id,
        serverId: item.serverId,
        type: item.type,
        channelId: item.channelId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final items = _items;
    final loading = _loading;
    final available = _available;
    final hasEntries = items != null && items.isNotEmpty;

    final content = !available
        ? _buildPlaceholder(null)
        : loading && items == null
        ? _buildPlaceholder(null)
        : !hasEntries
        ? _buildPlaceholder(l10n.upcomingReleases)
        : _buildList(items);

    return Container(
      height: widget.height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: widget.backgroundColor,
        borderRadius: AppRadius.circular(18),
      ),
      child: content,
    );
  }

  Widget _buildList(List<AggregatedItem> items) {
    final l10n = AppLocalizations.of(context);
    // Reserve a title row at the top of the bar, then a small inset
    // around the poster row so the focus border (drawn just past the card
    // edges) stays clear of the bar's left and top edges.
    const titleBudget = 32.0;
    // Inset around the poster row. Must stay a few px past the focus border
    // extent (drawn ~3.5px beyond the card) so the glow/border is never cut
    // off at the bar's left/top edges.
    const rowInset = 8.0;
    final listHeight = (widget.height - titleBudget).clamp(40.0, double.infinity);
    final posterArea = (listHeight - (rowInset * 2)).clamp(40.0, listHeight);

    final metadataBudget = 46.0;
    var posterHeight = posterArea - metadataBudget;
    posterHeight = posterHeight.clamp(40.0, posterArea);
    final posterWidth = posterHeight * (2 / 3);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: titleBudget,
          width: double.infinity,
          child: Padding(
            padding: EdgeInsets.only(left: rowInset),
            child: Text(
              l10n.upcomingReleases,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: AppColorScheme.onSurface,
              ),
            ),
          ),
        ),
        LockedFocusRow<AggregatedItem>(
          items: items,
          hubKey: 'home_upcoming_releases',
          controller: _scrollController,
          focusNode: _focusNode,
          height: listHeight,
          itemExtent: posterWidth,
          itemSpacing: 12,
          clipBehavior: Clip.hardEdge,
          padding: EdgeInsets.fromLTRB(rowInset, rowInset, rowInset, rowInset),
          onVerticalNavigation: _exit,
          onLeftEdge: widget.onExitLeft,
          onTap: (_, item) => _openItem(item),
          itemBuilder: (context, item, index, isFocused) {
            return MediaCard(
              title: item.name,
              subtitle: item.rawData['Subtitle'] as String? ?? '',
              imageUrl: item.rawData['PosterPath'] as String,
              width: posterWidth,
              aspectRatio: 2 / 3,
              externalIsFocused: isFocused,
              cardFocusExpansion: false,
              focusColor: widget.focusColor,
              onTap: () => _openItem(item),
            );
          },
        ),
      ],
    );
  }

  Widget _buildPlaceholder(String? label) {
    final text = !_available ? 'Moonbase / Seerr' : (label ?? '');
    return Center(
      child: Text(
        text.isEmpty ? '...' : text,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: AppColorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}
