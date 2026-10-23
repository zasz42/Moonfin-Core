import 'package:flutter/material.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../../data/models/aggregated_item.dart';
import '../../../util/focus/dpad_keys.dart';
import '../../../util/playback_time_label.dart';
import '../book/book_see_all_button.dart';
import '../focus/focusable_wrapper.dart';
import '../focus/locked_focus_row.dart';
import '../horizontal_scroll_section.dart';
import '../offline_aware_image.dart';
import '../settings/preference_tiles.dart';

TextStyle musicSectionTitleStyle({required bool large}) => TextStyle(
  fontSize: large ? 22 : 20,
  fontWeight: FontWeight.w800,
  color: AppColorScheme.onSurface,
);

/// Album art, or a music glyph while it's missing.
Widget musicArt(String? url, {IconData icon = Icons.album}) {
  final placeholder = ColoredBox(
    color: AppColorScheme.onSurface.withValues(alpha: 0.06),
    child: Center(
      child: Icon(icon, color: AppColorScheme.onSurface.withValues(alpha: 0.3)),
    ),
  );
  if (url == null) return placeholder;
  return OfflineAwareImage(
    imageUrl: url,
    fit: BoxFit.cover,
    errorWidget: (_, _, _) => placeholder,
  );
}

/// A music section heading over its row of items, with an optional See All.
/// Up from the row reaches See All before the section above.
class MusicShelf extends StatelessWidget {
  final String title;
  final VoidCallback? onSeeAll;
  final FocusNode? seeAllFocusNode;
  final List<AggregatedItem> items;
  final String hubKey;
  final GlobalKey<LockedFocusRowState> rowKey;
  final GlobalKey containerKey;
  final double itemExtent;
  final double height;
  final double leadingInset;
  final bool large;
  final LockedFocusItemBuilder<AggregatedItem> itemBuilder;
  final void Function(AggregatedItem item) onSelect;
  final bool Function(bool isUp)? onVerticalNavigation;
  final VoidCallback? onLeftEdge;

  /// Told the index the D-pad reached, so the row can page in more.
  final void Function(int index)? onIndexChanged;

  const MusicShelf({
    super.key,
    required this.title,
    required this.items,
    required this.hubKey,
    required this.rowKey,
    required this.containerKey,
    required this.itemExtent,
    required this.height,
    required this.itemBuilder,
    required this.onSelect,
    this.onSeeAll,
    this.seeAllFocusNode,
    this.leadingInset = 16,
    this.large = false,
    this.onVerticalNavigation,
    this.onLeftEdge,
    this.onIndexChanged,
  });

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: containerKey,
      child: Padding(
        padding: EdgeInsets.only(top: large ? 28 : 22),
        child: HorizontalScrollSection(
          title: title,
          titleStyle: musicSectionTitleStyle(large: large),
          headerPadding: EdgeInsets.only(left: leadingInset, right: 12),
          contentSpacing: 6,
          trailing: onSeeAll == null
              ? null
              : BookSeeAllButton(
                  onPressed: onSeeAll!,
                  focusNode: seeAllFocusNode,
                  onNavigateUp: () => onVerticalNavigation?.call(true),
                  onNavigateDown: () =>
                      rowKey.currentState?.requestFocusFromMemory(),
                ),
          builder: (context, controller) => LockedFocusRow<AggregatedItem>(
            key: rowKey,
            items: items,
            hubKey: hubKey,
            itemKey: (item, _) => item.id,
            controller: controller,
            height: height,
            itemExtent: itemExtent,
            itemSpacing: large ? 20 : 14,
            clipBehavior: Clip.none,
            padding: EdgeInsets.fromLTRB(leadingInset, 5, 20, 5),
            onVerticalNavigation: (isUp) {
              final seeAll = seeAllFocusNode;
              if (isUp && onSeeAll != null && seeAll != null) {
                seeAll.requestFocus();
                return true;
              }
              return onVerticalNavigation?.call(isUp) ?? false;
            },
            onLeftEdge: onLeftEdge,
            onIndexChanged: onIndexChanged == null
                ? null
                : (index, _) => onIndexChanged!(index),
            onTap: (_, item) => onSelect(item),
            itemBuilder: itemBuilder,
          ),
        ),
      ),
    );
  }
}

/// A heading over a block of D-pad stops, with an optional See All.
class MusicSection extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final bool large;
  final EdgeInsets padding;
  final Widget child;

  const MusicSection({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.large = false,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding.add(EdgeInsets.only(top: large ? 28 : 22)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 44,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: musicSectionTitleStyle(large: large),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// [children] laid out [columns] across, in rows [spacing] apart. Each child
/// is its own D-pad stop, so the D-pad moves between them by position.
class MusicGrid extends StatelessWidget {
  final int columns;
  final double spacing;
  final List<Widget> children;

  const MusicGrid({
    super.key,
    required this.columns,
    required this.children,
    this.spacing = 10,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var start = 0; start < children.length; start += columns)
          Padding(
            padding: EdgeInsets.only(
              bottom: start + columns < children.length ? spacing : 0,
            ),
            child: Row(
              children: [
                for (var i = start; i < start + columns; i++) ...[
                  if (i > start) SizedBox(width: spacing),
                  Expanded(
                    child: i < children.length
                        ? children[i]
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// Edge handlers for one item of a [MusicGrid] or list. Moves inside the
/// grid are left to the D-pad's own traversal, only the edges are routed.
class MusicGridEdges {
  final VoidCallback? up;
  final VoidCallback? down;
  final VoidCallback? left;

  const MusicGridEdges({this.up, this.down, this.left});

  factory MusicGridEdges.of(
    int index, {
    required int count,
    required int columns,
    required VoidCallback onLeaveUp,
    required VoidCallback onLeaveDown,
    VoidCallback? onLeaveLeft,
  }) => MusicGridEdges(
    up: index < columns ? onLeaveUp : null,
    down: index + columns >= count ? onLeaveDown : null,
    left: index % columns == 0 ? onLeaveLeft : null,
  );
}

/// A song's length as `m:ss`, or null when the server didn't say.
String? musicRunTime(AggregatedItem item) {
  final ticks = item.runTimeTicks;
  if (ticks == null || ticks <= 0) return null;
  // A tick is 100 nanoseconds.
  return formatPlaybackDuration(Duration(microseconds: ticks ~/ 10));
}

/// A card in a [MusicGrid]: one D-pad stop drawn by [builder], which is told
/// whether it has focus. Select runs [onTap] and the grid's edges leave
/// through [edges].
class MusicGridCard extends StatefulWidget {
  final FocusNode focusNode;
  final VoidCallback onTap;
  final MusicGridEdges edges;
  final Widget Function(bool focused) builder;

  const MusicGridCard({
    super.key,
    required this.focusNode,
    required this.onTap,
    required this.builder,
    this.edges = const MusicGridEdges(),
  });

  @override
  State<MusicGridCard> createState() => _MusicGridCardState();
}

class _MusicGridCardState extends State<MusicGridCard> {
  bool _focused = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!event.isActionable) return KeyEventResult.ignored;
    if (isActivateKey(event)) {
      widget.onTap();
      return KeyEventResult.handled;
    }
    final key = event.logicalKey;
    final edge = key.isUpKey
        ? widget.edges.up
        : key.isDownKey
        ? widget.edges.down
        : key.isLeftKey
        ? widget.edges.left
        : null;
    if (edge == null) return KeyEventResult.ignored;
    edge();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      onKeyEvent: _onKey,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (focused) {
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeInOut,
          );
        }
      },
      child: widget.builder(_focused),
    );
  }
}

/// A song as a row: its art or track number, title and artist, and its
/// length at the end. Focus fills the row with a solid color and dark text,
/// so it stays readable in every theme.
class MusicTrackTile extends StatefulWidget {
  final String title;
  final String subtitle;

  /// Art at the start. Without it [leadingLabel] (a track number) shows.
  final String? imageUrl;
  final String? leadingLabel;
  final String? trailing;

  /// The song played last on this album.
  final bool highlighted;
  final FocusNode? focusNode;
  final VoidCallback onTap;
  final MusicGridEdges edges;
  final VoidCallback? onNavigateRight;

  const MusicTrackTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.imageUrl,
    this.leadingLabel,
    this.trailing,
    this.highlighted = false,
    this.focusNode,
    this.edges = const MusicGridEdges(),
    this.onNavigateRight,
  });

  @override
  State<MusicTrackTile> createState() => _MusicTrackTileState();
}

class _MusicTrackTileState extends State<MusicTrackTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final invert = _focused && settingsTileInvertsOnFocus;
    final text = invert
        ? AppColors.black.withValues(alpha: 0.87)
        : AppColorScheme.onSurface;
    final muted = invert
        ? AppColors.black.withValues(alpha: 0.6)
        : AppColorScheme.onSurface.withValues(alpha: 0.65);
    final accent = AppColorScheme.accent;
    final Color? fill = _focused
        ? (invert
              ? AppColorScheme.buttonFocused
              : AppColorScheme.buttonFocused.withValues(alpha: 0.14))
        : (widget.highlighted ? accent.withValues(alpha: 0.16) : null);
    return FocusableWrapper(
      highlightOnHover: true,
      focusNode: widget.focusNode,
      borderRadius: 10,
      disableScale: true,
      autoScroll: true,
      suppressFocusGlow: true,
      onFocusChange: (focused) => setState(() => _focused = focused),
      onSelect: widget.onTap,
      onNavigateUp: widget.edges.up,
      onNavigateDown: widget.edges.down,
      onNavigateLeft: widget.edges.left,
      onNavigateRight: widget.onNavigateRight,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: AppRadius.circular(10),
        ),
        child: Row(
          children: [
            if (widget.imageUrl != null || widget.leadingLabel == null)
              ClipRRect(
                borderRadius: AppRadius.circular(6),
                child: SizedBox.square(
                  dimension: 44,
                  child: musicArt(widget.imageUrl, icon: Icons.music_note),
                ),
              )
            else
              SizedBox(
                width: 28,
                child: Text(
                  widget.leadingLabel!,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: widget.highlighted ? FontWeight.w700 : null,
                    color: widget.highlighted && !invert ? accent : muted,
                  ),
                ),
              ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: text,
                    ),
                  ),
                  if (widget.subtitle.isNotEmpty)
                    Text(
                      widget.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: muted),
                    ),
                ],
              ),
            ),
            if (widget.trailing != null) ...[
              const SizedBox(width: 12),
              Text(
                widget.trailing!,
                style: TextStyle(fontSize: 13, color: muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A compact album or playlist tile: its art at the start and its name.
class MusicQuickTile extends StatelessWidget {
  final String title;
  final String? imageUrl;
  final bool large;
  final FocusNode? focusNode;
  final VoidCallback onTap;
  final MusicGridEdges edges;

  const MusicQuickTile({
    super.key,
    required this.title,
    required this.imageUrl,
    required this.onTap,
    this.large = false,
    this.focusNode,
    this.edges = const MusicGridEdges(),
  });

  @override
  Widget build(BuildContext context) {
    final height = large ? 64.0 : 56.0;
    return FocusableWrapper(
      highlightOnHover: true,
      focusNode: focusNode,
      borderRadius: 10,
      autoScroll: true,
      onSelect: onTap,
      onNavigateUp: edges.up,
      onNavigateDown: edges.down,
      onNavigateLeft: edges.left,
      child: Container(
        height: height,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColorScheme.onSurface.withValues(alpha: 0.08),
          borderRadius: AppRadius.circular(10),
        ),
        child: Row(
          children: [
            SizedBox.square(dimension: height, child: musicArt(imageUrl)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: large ? 14 : 13,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                  color: AppColorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }
}

/// A category or genre tile: a label at the bottom, with an icon over it or
/// a solid [color] behind it.
class MusicTile extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color? color;
  final double height;
  final FocusNode? focusNode;
  final VoidCallback onTap;
  final MusicGridEdges edges;

  const MusicTile({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.color,
    this.height = 76,
    this.focusNode,
    this.edges = const MusicGridEdges(),
  });

  @override
  Widget build(BuildContext context) {
    final onSurface = AppColorScheme.onSurface;
    return FocusableWrapper(
      highlightOnHover: true,
      focusNode: focusNode,
      borderRadius: 14,
      autoScroll: true,
      onSelect: onTap,
      onNavigateUp: edges.up,
      onNavigateDown: edges.down,
      onNavigateLeft: edges.left,
      child: Container(
        height: height,
        padding: const EdgeInsets.all(12),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: color ?? onSurface.withValues(alpha: 0.06),
          borderRadius: AppRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: icon != null
              ? MainAxisAlignment.spaceBetween
              : MainAxisAlignment.end,
          children: [
            if (icon != null) Icon(icon, size: 24, color: AppColorScheme.accent),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: color != null ? 18 : 14,
                fontWeight: color != null ? FontWeight.w800 : FontWeight.w700,
                color: color != null ? Colors.white : onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
