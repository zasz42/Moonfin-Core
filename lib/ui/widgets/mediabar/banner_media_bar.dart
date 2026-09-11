import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../../data/models/media_bar_slide_item.dart';
import 'media_bar_title.dart';
import '../../../data/models/media_bar_state.dart';
import '../../../data/viewmodels/media_bar_view_model.dart';
import '../../../preference/preference_constants.dart';
import '../../../preference/user_preferences.dart';
import '../../../util/platform_detection.dart';
import '../../navigation/destinations.dart';
import '../bounded_network_image.dart';
import '../offline_aware_image.dart';
import '../rating_display.dart';
import 'media_bar_status_focus.dart';
import 'upcoming_releases_bar.dart';

class BannerMediaBar extends StatefulWidget {
  final MediaBarViewModel viewModel;
  final UserPreferences prefs;
  final double height;
  final bool externallyPaused;
  final FocusNode? focusNode;
  final void Function(MediaBarSlideItem item) onOpen;
  final void Function(MediaBarSlideItem item) onPlay;
  final Future<void> Function()? onNavigateDown;
  final VoidCallback? onNavigateUp;
  final VoidCallback? onNavigateLeft;
  final GlobalKey<UpcomingReleasesBarState>? upcomingKey;

  const BannerMediaBar({
    super.key,
    required this.viewModel,
    required this.prefs,
    required this.height,
    required this.onOpen,
    required this.onPlay,
    this.externallyPaused = false,
    this.focusNode,
    this.onNavigateDown,
    this.onNavigateUp,
    this.onNavigateLeft,
    this.upcomingKey,
  });

  /// The banner card is always a fixed-size 21:9 rectangle; it never scales
  /// with the Upcoming Releases rail or the compact banner height adjustment.
  /// Only the rail resizes around it.
  static const double fixedHeight = 280.0;
  static const double aspectRatio = 21 / 9;

  @override
  State<BannerMediaBar> createState() => _BannerMediaBarState();
}

class _BannerMediaBarState extends State<BannerMediaBar> {
  static const _keyLongPressThreshold = Duration(milliseconds: 500);
  static const _slideTransitionDuration = Duration(milliseconds: 420);
  static const _slideScaleBegin = 1.006;
  Timer? _autoAdvance;
  int _index = 0;
  bool _focused = false;
  DateTime? _keyDownTime;
  DateTime? _arrowRightDownTime;
  bool _arrowRightLongPressHandled = false;

  @override
  void initState() {
    super.initState();
    widget.viewModel.addListener(_onChanged);
    widget.prefs.addListener(_onChanged);
    _startAutoAdvance();
    _ensureRatingsForCurrent();
  }

  @override
  void didUpdateWidget(BannerMediaBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.externallyPaused != oldWidget.externallyPaused) {
      _startAutoAdvance();
    }
  }

  @override
  void dispose() {
    _autoAdvance?.cancel();
    widget.viewModel.removeListener(_onChanged);
    widget.prefs.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
      _startAutoAdvance();
    }
  }

  void _ensureRatingsForCurrent() {
    final items = widget.viewModel.items;
    if (_index < items.length) {
      unawaited(widget.viewModel.ensureRatings(items[_index].itemId));
    }
  }

  void _startAutoAdvance() {
    _autoAdvance?.cancel();
    if (widget.externallyPaused) return;
    if (!widget.prefs.get(UserPreferences.mediaBarAutoAdvance)) return;
    final intervalMs = widget.prefs.get(UserPreferences.mediaBarIntervalMs);
    _autoAdvance = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      final items = widget.viewModel.items;
      if (items.length <= 1 || !mounted) return;
      setState(() => _index = (_index + 1) % items.length);
      _ensureRatingsForCurrent();
    });
  }

  void _setIndex(int next) {
    final items = widget.viewModel.items;
    if (items.isEmpty) return;
    setState(() => _index = next % items.length);
    _ensureRatingsForCurrent();
    _startAutoAdvance();
  }

  String? _trailerUrl(MediaBarSlideItem item) {
    for (final trailer in item.remoteTrailers) {
      final url = trailer['Url'];
      if (url is String && url.isNotEmpty) return url;
    }
    return null;
  }

  bool _hasTrailer(MediaBarSlideItem item) => _trailerUrl(item) != null;

  void _launchTrailer(MediaBarSlideItem item) {
    final url = _trailerUrl(item);
    if (url == null) return;
    context.push(Destinations.trailer(url: url));
  }

  bool _focusUpcomingReleases() {
    if (!_compact || !_showUpcoming || !mounted) return false;
    final state = widget.upcomingKey?.currentState;
    if (state == null || !state.hasItems) return false;
    return state.requestFocus();
  }

  void _requestBannerFocus() {
    final focusNode = widget.focusNode;
    if (focusNode != null && !focusNode.hasFocus && mounted) {
      focusNode.requestFocus();
    }
  }

  bool _rightModifierPressed() {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight) ||
        keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight);
  }

  KeyEventResult _handleKey(KeyEvent event, MediaBarSlideItem item) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        _keyDownTime ??= DateTime.now();
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent) {
        final downTime = _keyDownTime;
        _keyDownTime = null;
        final longPress = downTime != null &&
            DateTime.now().difference(downTime) >= _keyLongPressThreshold;
        if (longPress) {
          _launchTrailer(item);
        } else {
          widget.onOpen(item);
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // tvOS (Apple TV remote): a single press of the right DPAD button hands
    // focus to the Upcoming Releases rail. This path only sees key events,
    // which the remote's physical DPAD produces; clickpad swipes arrive as
    // gestures (advance-only) and never reach this handler, so they never
    // change focus.
    if (PlatformDetection.isAppleTV &&
        key == LogicalKeyboardKey.arrowRight &&
        _compact &&
        _showUpcoming) {
      if (event is KeyDownEvent) {
        _focusUpcomingReleases();
        return KeyEventResult.handled;
      }
      if (event is KeyRepeatEvent) {
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent) {
        return KeyEventResult.handled;
      }
    }

    // Long-pressing Right (or CTRL+Right on a keyboard) jumps focus to the
    // Upcoming Releases rail without disturbing normal arrow navigation.
    if (key == LogicalKeyboardKey.arrowRight &&
        _compact &&
        _showUpcoming &&
        _rightModifierPressed()) {
      if (event is KeyDownEvent) {
        _arrowRightLongPressHandled = true;
        _focusUpcomingReleases();
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent) {
        _arrowRightDownTime = null;
        _arrowRightLongPressHandled = false;
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowRight && _compact && _showUpcoming) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        if (event is KeyDownEvent) _arrowRightLongPressHandled = false;
        _arrowRightDownTime ??= DateTime.now();
        final held =
            DateTime.now().difference(_arrowRightDownTime!) >=
            _keyLongPressThreshold;
        if (held) {
          if (!_arrowRightLongPressHandled) {
            _arrowRightLongPressHandled = true;
            _focusUpcomingReleases();
          }
          return KeyEventResult.handled;
        }
      } else if (event is KeyUpEvent) {
        _arrowRightDownTime = null;
        _arrowRightLongPressHandled = false;
      }
    } else if (event is KeyDownEvent &&
        key == LogicalKeyboardKey.arrowRight &&
        _compact &&
        _showUpcoming &&
        _arrowRightLongPressHandled) {
      return KeyEventResult.handled;
    }

    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final items = widget.viewModel.items;
    if (key == LogicalKeyboardKey.arrowDown) {
      unawaited(widget.onNavigateDown?.call());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      widget.onNavigateUp?.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      final isRtl = Directionality.of(context) == TextDirection.rtl;
      final isPhysicalLeftKey = key == LogicalKeyboardKey.arrowLeft;
      final advances = isPhysicalLeftKey == isRtl;
      final beforeIndex = _index;
      if (advances) {
        if (items.length > 1) _setIndex(_index + 1);
      } else if (_index > 0) {
        _setIndex(_index - 1);
      }
      if (_index == beforeIndex &&
          isPhysicalLeftKey &&
          widget.onNavigateLeft != null) {
        widget.onNavigateLeft!();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _wrapStatusFocus(Widget child, {VoidCallback? onSelect}) {
    return MediaBarStatusFocus(
      focusNode: widget.focusNode,
      onNavigateUp: widget.onNavigateUp,
      onNavigateDown: widget.onNavigateDown,
      onNavigateLeft: widget.onNavigateLeft,
      onSelect: onSelect,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.viewModel.items;
    if (items.isEmpty) {
      final state = widget.viewModel.state;
      if (state is! MediaBarLoading && state is! MediaBarError) {
        return const SizedBox.shrink();
      }
      final navbarAtTop =
          widget.prefs.get(UserPreferences.navbarPosition) ==
          NavbarPosition.top;
      final topInset = PlatformDetection.useMobileUi
          ? MediaQuery.paddingOf(context).top + (navbarAtTop ? 60.0 : 0.0)
          : 0.0;
      if (state is MediaBarLoading) {
        final loadingHeight = (widget.height - topInset - 12.0).clamp(
          0.0,
          double.infinity,
        );
        return Padding(
          padding: EdgeInsets.fromLTRB(16, topInset, 16, 8),
          child: _wrapStatusFocus(
            SizedBox(
              height: loadingHeight,
              width: double.infinity,
              child: const Center(child: CircularProgressIndicator()),
            ),
          ),
        );
      }
      final message = (state as MediaBarError).message;
      return Padding(
        padding: EdgeInsets.fromLTRB(16, topInset, 16, 8),
        child: _wrapStatusFocus(
          SizedBox(
            height: 72,
            width: double.infinity,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.slideshow, color: AppColorScheme.accent),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColorScheme.onSurface,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      widget.viewModel.load(context: context, force: true),
                  child: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          onSelect: () => widget.viewModel.load(context: context, force: true),
        ),
      );
    }
    final index = _index.clamp(0, items.length - 1);
    final item = items[index];

    final isMobile = PlatformDetection.useMobileUi;
    final navbarAtTop =
        widget.prefs.get(UserPreferences.navbarPosition) == NavbarPosition.top;
    final topInset = isMobile
        ? MediaQuery.paddingOf(context).top + (navbarAtTop ? 60.0 : 0.0)
        : 0.0;

    final AnimatedContainer bannerFrame = AnimatedContainer(
      width: _compact ? _containerWidth : null,
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        borderRadius: AppRadius.circular(16),
        border: Border.all(
          color: _focused ? AppColorScheme.accent : Colors.transparent,
          width: 2.5,
        ),
        boxShadow: _focused
            ? [
                BoxShadow(
                  color: AppColorScheme.accent.withValues(alpha: 0.4),
                  blurRadius: 18,
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: AppRadius.circular(14),
        child: SizedBox(
          width: _compact ? _containerWidth : null,
          height: widget.height,
          child: GestureDetector(
            onTap: () => widget.onOpen(item),
            onLongPress: () => _launchTrailer(item),
            onHorizontalDragEnd: items.length > 1
                ? (details) {
                    final v = details.primaryVelocity ?? 0;
                    if (v < -300) {
                      _setIndex(_index + 1);
                    } else if (v > 300) {
                      _setIndex(_index == 0 ? items.length - 1 : _index - 1);
                    }
                  }
                : null,
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnimatedSwitcher(
                  duration: _slideTransitionDuration,
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) {
                    final scale =
                        Tween<double>(
                          begin: _slideScaleBegin,
                          end: 1.0,
                        ).animate(
                          CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeOutCubic,
                          ),
                        );
                    return FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(scale: scale, child: child),
                    );
                  },
                  child: KeyedSubtree(
                    key: ValueKey('banner_slide_${item.itemId}'),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _backdrop(item),
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: [Color(0xE6000000), Color(0x00000000)],
                            ),
                          ),
                        ),
                        Positioned(
                          left: 20,
                          right: 20,
                          bottom: 16,
                          child: _content(context, item),
                        ),
                      ],
                    ),
                  ),
                ),
                if (items.length > 1)
                  Positioned(
                    top: 12,
                    right: 16,
                    child: _Dots(count: items.length, active: index),
                  ),
                if (_compact && _hasTrailer(item))
                  const Positioned(
                    bottom: 16,
                    right: 16,
                    child: IgnorePointer(child: _TrailerBadge()),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    Focus focusedBanner(Widget child) => Focus(
      focusNode: widget.focusNode,
      autofocus: widget.focusNode == null && PlatformDetection.useLeanbackUi,
      onFocusChange: (f) {
        if (mounted) setState(() => _focused = f);
      },
      onKeyEvent: (node, event) => _handleKey(event, item),
      // The Focus widget sits inside a ListView.builder item, which hands
      // its child tight width constraints matching the viewport. Without an
      // Align to loosen those constraints, the AnimatedContainer's `width`
      // below is overridden and it stretches to fill the screen instead of
      // sizing to the compact banner width.
      child: child,
    );

    Widget banner = Padding(
      padding: EdgeInsets.fromLTRB(16, topInset, 16, _compact ? 4 : 8),
      child: focusedBanner(
        _compact ? Align(alignment: Alignment.center, child: bannerFrame) : bannerFrame,
      ),
    );

    if (_compact && _showUpcoming) {
      final focusColor = Color(
        widget.prefs.get(UserPreferences.focusColor).colorValue,
      );
      // On TV builds the upcoming rail is 25% shorter than the media bar and
      // is pinned to the same bottom edge, leaving breathing room above it.
      // Its posters/title scale down proportionally with the reduced height.
      final upcomingHeight =
          PlatformDetection.isTV ? widget.height * 0.75 : widget.height;
      final upcoming = UpcomingReleasesBar(
        key: widget.upcomingKey,
        height: upcomingHeight,
        prefs: widget.prefs,
        focusColor: focusColor,
        onExitUp: _requestBannerFocus,
        onExitDown: () {
          // Home screen's down-nav only proceeds once focus is on the media
          // bar's focus node, so move focus back to it before handing off so
          // Down exits the rail into the 1st home row.
          _requestBannerFocus();
          unawaited(widget.onNavigateDown?.call());
        },
        onExitLeft: _requestBannerFocus,
      );
      banner = Padding(
        padding: EdgeInsets.fromLTRB(16, topInset, 16, 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            SizedBox(
              width: _containerWidth,
              height: widget.height,
              child: focusedBanner(bannerFrame),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: SizedBox(height: upcomingHeight, child: upcoming),
            ),
          ],
        ),
      );
    }

    return banner;
  }

  double get _containerWidth => BannerMediaBar.fixedHeight * BannerMediaBar.aspectRatio;

  bool get _showUpcoming =>
      widget.prefs.get(UserPreferences.compactBannerUpcomingReleases);

  bool get _compact {
    final mode = UserPreferences.normalizeMediaBarMode(
      widget.prefs.get(UserPreferences.mediaBarMode),
    );
    return mode == UserPreferences.mediaBarModeBanner &&
        widget.prefs.get(UserPreferences.compactBannerEnabled);
  }

  Widget _backdrop(MediaBarSlideItem item) {
    final url = item.backdropUrl;
    if (url == null) {
      return ColoredBox(color: AppColorScheme.surface);
    }
    return BoundedNetworkImage(
      imageUrl: url,
      minWidth: 640,
      maxWidth: 1280,
      errorBuilder: (_, _, _) => ColoredBox(color: AppColorScheme.surface),
    );
  }

  Widget _content(BuildContext context, MediaBarSlideItem item) {
    final theme = Theme.of(context);
    final shadows = <Shadow>[
      Shadow(blurRadius: 10, color: AppColorScheme.scrim.withValues(alpha: 0.8)),
    ];
    final meta = <String>[
      if (item.year != null) '${item.year}',
      if (item.itemType != 'Series' && item.runtime != null)
        _formatRuntime(item.runtime!),
      if (item.officialRating != null) item.officialRating!,
    ].join('  ·  ');

    final ratingsMap = widget.viewModel.ratingsFor(item.itemId);
    final hasRatings =
        ratingsMap.isNotEmpty ||
        item.communityRating != null ||
        item.criticRating != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (item.logoUrl != null)
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 240,
              height: 56,
              child: OfflineAwareImage(
                imageUrl: item.logoUrl!,
                fit: BoxFit.contain,
                alignment: Alignment.centerLeft,
                fadeInDuration: Duration.zero,
                errorWidget: (_, _, _) =>
                    MediaBarTitle(title: item.title, shadows: shadows),
              ),
            ),
          )
        else
          MediaBarTitle(title: item.title, shadows: shadows),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            meta,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: AppColorScheme.onSurface.withValues(alpha: 0.75),
              fontWeight: FontWeight.w600,
              shadows: shadows,
            ),
          ),
        ],
        if (hasRatings) ...[
          const SizedBox(height: 8),
          RatingsRow(
            ratings: ratingsMap,
            communityRating: item.communityRating,
            criticRating: item.criticRating,
            enableAdditionalRatings: widget.prefs.get(
              UserPreferences.enableAdditionalRatings,
            ),
            enabledRatings: widget.prefs.get(UserPreferences.enabledRatings),
            showLabels: false,
            showBadges: false,
          ),
        ],
      ],
    );
  }


  String _formatRuntime(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }
}

class _TrailerBadge extends StatelessWidget {
  const _TrailerBadge();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        width: 36,
        height: 36,
        child: Stack(
          children: [
            Opacity(
              opacity: 0.2,
              child: Container(
                decoration: BoxDecoration(
                  color: AppColorScheme.scrim.withValues(alpha: 0.7),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ),
            const Center(
              child: Icon(Icons.movie_outlined, size: 20, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  final int count;
  final int active;

  const _Dots({required this.count, required this.active});

  @override
  Widget build(BuildContext context) {
    final shown = count > 7 ? 7 : count;
    final start = (active - shown ~/ 2).clamp(0, count - shown < 0 ? 0 : count - shown);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = start; i < start + shown; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            margin: const EdgeInsets.symmetric(horizontal: 2),
            width: i == active ? 16 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i == active
                  ? AppColorScheme.onSurface
                  : AppColorScheme.onSurface.withValues(alpha: 0.4),
              borderRadius: AppRadius.circular(3),
            ),
          ),
      ],
    );
  }
}
