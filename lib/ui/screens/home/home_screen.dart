import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/gestures.dart';

import 'package:flutter/foundation.dart'
    show kIsWeb, listEquals, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:moonfin/util/language_matching.dart';
import 'package:moonfin_design/moonfin_design.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:moonfin_native_video/moonfin_native_video.dart';
import 'package:playback_core/playback_core.dart';
import 'package:server_core/server_core.dart' hide ImageType;
import 'package:window_manager/window_manager.dart';

import '../../../data/models/aggregated_item.dart';
import '../../../data/models/home_row.dart';
import '../../../data/repositories/mdblist_repository.dart';
import '../../../data/repositories/seerr_repository.dart';
import '../../../data/repositories/tmdb_repository.dart';
import '../../widgets/seerr/seerr_shortcuts.dart';
import '../../../data/services/background_service.dart';
import '../../../data/services/better_posters_service.dart';
import '../../widgets/modern_row.dart';
import '../../../data/services/theme_music_service.dart';
import '../../../data/services/media_server_client_factory.dart';
import '../../../data/services/plugin_sync_service.dart';
import '../../../data/services/user_data_sync.dart';
import '../../../data/services/youtube_stream_resolver.dart';
import '../../../data/services/connectivity_service.dart';
import '../../../data/services/log_service.dart';
import '../../../data/utils/media_type_badges.dart';
import '../../../l10n/app_localizations.dart';
import '../../../playback/appletv_preview_player.dart';
import '../../../playback/inline_preview_engine.dart';
import '../../../playback/media3_player_backend.dart';
import '../../../playback/mpv_client_certificate.dart';
import '../../../playback/mpv_player_registry.dart';
import '../../../preference/home_section_config.dart';
import '../../../preference/preference_constants.dart';
import '../../../preference/user_preferences.dart';
import '../../widgets/exit_confirmation_dialog.dart';
import '../../widgets/overlay_sheet.dart';
import '../../widgets/quick_return_wrapper.dart';
import '../../../util/app_exit.dart';
import '../../../util/global_shortcut_focus.dart';
import '../../widgets/focus/context_menu_sheet.dart';
import '../../widgets/focus/locked_focus_row.dart';
import '../../widgets/focus/row_glide.dart';
import '../../../util/focus/dpad_keys.dart';
import '../../../util/focus/input_mode_tracker.dart';
import '../../../util/focus/scroll_utils.dart';
import '../../../util/artwork_request_size.dart';
import '../../../util/clock_format.dart';
import '../../../util/device_performance.dart';
import '../../../util/platform_detection.dart';
import '../../../util/server_url.dart';
import '../../../util/tmdb_thumb.dart';
import '../../navigation/app_router.dart';
import '../../navigation/destinations.dart';
import '../../../data/models/media_bar_state.dart';
import '../../../data/viewmodels/media_bar_view_model.dart';
import '../../widgets/grid_button_card.dart';
import '../../widgets/info_area.dart';
import '../../widgets/left_sidebar.dart';
import '../../widgets/library_row.dart';
import '../../widgets/media_bar.dart';
import '../../widgets/mediabar/banner_media_bar.dart';
import '../../widgets/image_source.dart';
import '../../widgets/mediabar/upcoming_releases_bar.dart';
import '../../widgets/media_card.dart';
import '../../widgets/selector_builder.dart';
import '../../widgets/bottom_nav/bottom_navbar.dart';
import '../../widgets/navigation_layout.dart';
import '../../widgets/responsive_layout.dart';
import '../../widgets/seasonal/seasonal_effects.dart';
import '../../widgets/settings/settings_panel.dart';
import '../../widgets/top_toolbar.dart';
import '../../navigation/home_refresh_bus.dart';
import '../../widgets/bounded_network_image.dart';
import '../../widgets/fullscreen_backdrop_switcher.dart';
import '../../navigation/route_lifecycle_observer.dart';
import '../../screensaver/screensaver_controller.dart';
import '../../util/home_row_title_localizer.dart';
import '../../../util/game_library.dart';
import 'home_row_prefetch.dart';
import 'home_row_shift.dart';
import 'home_view_model.dart';
import '../../widgets/seerr/seerr_genre_label.dart';
import '../../widgets/skeleton/skeleton_home_row.dart';
import '../../widgets/skeleton/skeleton_shimmer.dart';
import '../../../preference/seerr_preferences.dart';

Color get _homeBackground => AppColorScheme.background;

/// How far the rows have to scroll before the return is worth offering.
const _kHomeStartThreshold = 20.0;

/// Room for the title, subtitle and gaps that sit under classic card artwork.
const _classicCardMetadataHeight = 50.0;

/// Room above a row's title. Classic rows on mobile keep a wider gap.
double _rowHeaderPaddingTop(bool isRowsV2) =>
    isRowsV2 || !PlatformDetection.useMobileUi ? 6.0 : 16.0;

/// How far a focused card grows past the top of its row. The scale is anchored
/// at the bottom of the artwork, so all of the growth goes upward.
double _focusHeadroom(double imageHeight, bool cardExpansion) =>
    cardExpansion && !PlatformDetection.useMobileUi
    ? imageHeight * (MediaCard.focusScale - 1)
    : 0.0;

/// Clips inactive Classic rows where they pass behind the pinned info area.
///
/// The focused row must remain complete: it is the user's active navigation
/// target, and clipping its artwork can leave only the card metadata visible.
/// [isFocused] means the row holds focus. A mouse scroll makes the row nearest
/// the top the active one without focusing it, so that row still passes
/// behind the info area like the rest.
@visibleForTesting
double classicHomeRowOverlayClipTop({
  required bool isFocused,
  required double rowViewportTop,
  required double rowExtent,
  required double overlayBottom,
}) {
  if (isFocused) return 0.0;
  return (overlayBottom - rowViewportTop).clamp(0.0, rowExtent);
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @visibleForTesting
  static bool isRowModern(HomeRow row, UserPreferences prefs) =>
      _ContentRowsState._isRowModern(row, prefs);

  @visibleForTesting
  static bool isModernMyMediaStatic(HomeRow row, UserPreferences prefs) =>
      _ContentRowsState._isModernMyMediaStatic(row, prefs);

  @visibleForTesting
  static ImageType homeRowImageTypeForRow(HomeRow row, UserPreferences prefs) =>
      _ContentRowsState._homeRowImageTypeForRow(row, prefs);

  @visibleForTesting
  static Widget topBackdrop(Widget backdrop) =>
      const _Backdrop(blurAmount: 0)._top(backdrop);

  @override
  Widget build(BuildContext context) {
    return const ResponsiveLayout(
      mobileBody: _HomeShell(),
      tvBody: _HomeShell(),
    );
  }
}

class _HomeShell extends StatefulWidget {
  const _HomeShell();

  @override
  State<_HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<_HomeShell>
    with WidgetsBindingObserver, RouteAware {
  final _backgroundService = GetIt.instance<BackgroundService>();
  final _userPrefs = GetIt.instance<UserPreferences>();
  final _themeMusicService = GetIt.instance<ThemeMusicService>();
  final _pluginSyncService = GetIt.instance<PluginSyncService>();
  final _connectivity = GetIt.instance.isRegistered<ConnectivityService>()
      ? GetIt.instance<ConnectivityService>()
      : null;
  bool _lastCanReachServer = true;
  late final HomeViewModel _viewModel;

  final ValueNotifier<AggregatedItem?> _selectedItemNotifier = ValueNotifier(
    null,
  );
  final GlobalKey<_ContentRowsState> _contentRowsKey =
      GlobalKey<_ContentRowsState>();
  final ValueNotifier<String?> _backdropUrlNotifier = ValueNotifier(null);
  Timer? _selectionDebounce;
  Timer? _backdropDebounce;
  Timer? _hoverPauseTimer;
  StreamSubscription<String?>? _backgroundSub;
  final ValueNotifier<bool> _isHoverPausedNotifier = ValueNotifier(false);
  final ValueNotifier<bool> _isScrolledToTopNotifier = ValueNotifier(true);
  String _lastSectionsJson = '';
  bool _lastMultiServer = false;
  bool _lastMergeContinueWatchingNextUp = false;
  String _lastHiddenCW = '{}';
  String _lastHiddenNU = '{}';
  String _lastBlockedParentalRatings = '';
  bool _lastSeerrAvailable = false;
  bool _themeMusicRegistered = false;
  String? _lastObservedPath;
  ModalRoute<dynamic>? _observedRoute;

  bool _lastEnableRadarrCalendar = false;
  bool _lastEnableSonarrCalendar = false;
  bool _lastMergeRadarrSonarrCalendars = false;
  bool _lastRadarrCalendarShowCinema = false;
  bool _lastRadarrCalendarShowDigital = true;
  bool _lastRadarrCalendarShowPhysical = true;
  bool _lastRadarrCalendarShowDate = true;
  bool _lastSonarrCalendarShowEpisodeInfo = true;
  bool _lastSonarrCalendarShowDate = true;
  bool _lastRadarrCalendarHideDownloaded = true;
  bool _lastSonarrCalendarHideDownloaded = true;

  static const _selectionDelay = Duration(milliseconds: 150);
  static const _backdropDelay = Duration(milliseconds: 200);

  @override
  void initState() {
    super.initState();
    _viewModel = GetIt.instance<HomeViewModel>();
    WidgetsBinding.instance.addObserver(this);
    appRouter.routerDelegate.addListener(_onRouteChanged);
    _lastObservedPath = appRouter.routerDelegate.currentConfiguration.uri.path;
    homeRefreshBus.addListener(_onHomeRefreshRequested);
    userDataSync.addListener(_onUserDataChanged);
    if (homeRefreshBus.consumePending()) {
      _viewModel.refresh(preserveExisting: true);
    }
    _backgroundSub = _backgroundService.backgroundStream.listen((url) {
      if (mounted) _backdropUrlNotifier.value = url;
    });
    _backdropUrlNotifier.value = _backgroundService.currentUrl;

    _lastSectionsJson = _userPrefs.get(UserPreferences.homeSectionsJson);
    _lastMultiServer = _userPrefs.get(
      UserPreferences.enableMultiServerLibraries,
    );
    _lastMergeContinueWatchingNextUp = _userPrefs.get(
      UserPreferences.mergeContinueWatchingNextUp,
    );
    _lastHiddenCW = _userPrefs.get(UserPreferences.hiddenContinueWatchingItems);
    _lastHiddenNU = _userPrefs.get(UserPreferences.hiddenNextUpSeries);
    _lastBlockedParentalRatings = _userPrefs.get(
      UserPreferences.blockedParentalRatings,
    );
    _lastSeerrAvailable = _pluginSyncService.seerrAvailable;
    _lastEnableRadarrCalendar = _userPrefs.get(UserPreferences.enableRadarrCalendar);
    _lastEnableSonarrCalendar = _userPrefs.get(UserPreferences.enableSonarrCalendar);
    _lastMergeRadarrSonarrCalendars = _userPrefs.get(UserPreferences.mergeRadarrSonarrCalendars);
    _lastRadarrCalendarShowCinema = _userPrefs.get(UserPreferences.radarrCalendarShowCinema);
    _lastRadarrCalendarShowDigital = _userPrefs.get(UserPreferences.radarrCalendarShowDigital);
    _lastRadarrCalendarShowPhysical = _userPrefs.get(UserPreferences.radarrCalendarShowPhysical);
    _lastRadarrCalendarShowDate = _userPrefs.get(UserPreferences.radarrCalendarShowDate);
    _lastSonarrCalendarShowEpisodeInfo = _userPrefs.get(UserPreferences.sonarrCalendarShowEpisodeInfo);
    _lastSonarrCalendarShowDate = _userPrefs.get(UserPreferences.sonarrCalendarShowDate);
    _lastRadarrCalendarHideDownloaded = _userPrefs.get(UserPreferences.radarrCalendarHideDownloaded);
    _lastSonarrCalendarHideDownloaded = _userPrefs.get(UserPreferences.sonarrCalendarHideDownloaded);

    _pluginSyncService.addListener(_onPluginSyncChanged);
    _userPrefs.addListener(_onPrefsChanged);
    _lastCanReachServer = _connectivity?.canReachServer ?? true;
    _connectivity?.addListener(_onServerReachabilityChanged);
    _maybeRegisterThemeMusic();
    _viewModel.load(preserveExisting: _viewModel.rows.isNotEmpty);
  }

  /// The rows on screen were built before the watched state changed, so patch
  /// them rather than refetch.
  void _onUserDataChanged() {
    if (!mounted) return;
    _viewModel.applyUserDataChanges();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == null || route == _observedRoute) return;
    if (_observedRoute != null) {
      routeLifecycleObserver.unsubscribe(this);
    }
    _observedRoute = route;
    routeLifecycleObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    if (_observedRoute != null) {
      routeLifecycleObserver.unsubscribe(this);
      _observedRoute = null;
    }
    appRouter.routerDelegate.removeListener(_onRouteChanged);
    homeRefreshBus.removeListener(_onHomeRefreshRequested);
    userDataSync.removeListener(_onUserDataChanged);
    WidgetsBinding.instance.removeObserver(this);
    _selectionDebounce?.cancel();
    _backdropDebounce?.cancel();
    _hoverPauseTimer?.cancel();
    _backgroundSub?.cancel();
    _selectedItemNotifier.dispose();
    _backdropUrlNotifier.dispose();
    _isHoverPausedNotifier.dispose();
    _isScrolledToTopNotifier.dispose();
    _pluginSyncService.removeListener(_onPluginSyncChanged);
    _userPrefs.removeListener(_onPrefsChanged);
    _connectivity?.removeListener(_onServerReachabilityChanged);
    if (_themeMusicRegistered) {
      _themeMusicService.unregisterDetailScreen(this);
      _themeMusicRegistered = false;
    }
    super.dispose();
  }

  void _onPluginSyncChanged() {
    if (!mounted) return;
    final seerrAvailable = _pluginSyncService.seerrAvailable;
    if (seerrAvailable == _lastSeerrAvailable) return;
    _lastSeerrAvailable = seerrAvailable;
    _viewModel.refresh(newSectionsOnly: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _viewModel.refresh(preserveExisting: true);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        (state == AppLifecycleState.inactive &&
            !PlatformDetection.isDesktop &&
            !PlatformDetection.isWeb)) {
      _themeMusicService.fadeOutAndStop();
    }
  }

  void _onHomeRefreshRequested() {
    if (!mounted) return;
    _viewModel.refresh(
      newMediaBar: homeRefreshBus.consumeNewMediaBar(),
      newSectionsOnly: homeRefreshBus.consumeNewSectionsOnly(),
    );
  }

  void _onServerReachabilityChanged() {
    final canReach = _connectivity?.canReachServer ?? true;
    final reloads = HomeViewModel.reloadsOnReachability(
      canReachServer: canReach,
      couldReachServer: _lastCanReachServer,
    );
    _lastCanReachServer = canReach;
    if (!reloads || !mounted) return;
    _viewModel.refresh(preserveExisting: true);
  }

  void _onPrefsChanged() {
    if (!mounted) return;
    final currentJson = _userPrefs.get(UserPreferences.homeSectionsJson);
    final currentMultiServer = _userPrefs.get(
      UserPreferences.enableMultiServerLibraries,
    );
    final currentMergeContinueWatchingNextUp = _userPrefs.get(
      UserPreferences.mergeContinueWatchingNextUp,
    );
    final currentBlocked = _userPrefs.get(
      UserPreferences.blockedParentalRatings,
    );
    final currentHiddenCW = _userPrefs.get(
      UserPreferences.hiddenContinueWatchingItems,
    );
    final currentHiddenNU = _userPrefs.get(UserPreferences.hiddenNextUpSeries);
    final currentEnableRadarr = _userPrefs.get(UserPreferences.enableRadarrCalendar);
    final currentEnableSonarr = _userPrefs.get(UserPreferences.enableSonarrCalendar);
    final currentMerge = _userPrefs.get(UserPreferences.mergeRadarrSonarrCalendars);
    final currentShowCinema = _userPrefs.get(UserPreferences.radarrCalendarShowCinema);
    final currentShowDigital = _userPrefs.get(UserPreferences.radarrCalendarShowDigital);
    final currentShowPhysical = _userPrefs.get(UserPreferences.radarrCalendarShowPhysical);
    final currentShowDate = _userPrefs.get(UserPreferences.radarrCalendarShowDate);
    final currentShowEpisodeInfo = _userPrefs.get(UserPreferences.sonarrCalendarShowEpisodeInfo);
    final currentShowSonarrDate = _userPrefs.get(UserPreferences.sonarrCalendarShowDate);
    final currentRadarrHideDownloaded = _userPrefs.get(UserPreferences.radarrCalendarHideDownloaded);
    final currentSonarrHideDownloaded = _userPrefs.get(UserPreferences.sonarrCalendarHideDownloaded);
    }
    if (row.id == 'merged_calendar') return l10n.arrCalendarsRowSubtitle;
    if (row.id == 'radarr_calendar') return l10n.radarrCalendarRowSubtitle;
    if (row.id == 'sonarr_calendar') return l10n.sonarrCalendarRowSubtitle;
    if (row.id.startsWith('seerr_')) return seerrBrand(l10n.seerrDiscoveryRows);
    if (row.id.startsWith('tmdb_')) return 'TMDB Lists';
    if (row.id.startsWith('imdb_')) return 'IMDb List';
    if (row.id == 'seasonal') return l10n.seasonalRowSubtitle;

    final config = widget.prefs.homeSectionsConfig.firstWhereOrNull((c) => c.stableId == row.id);
    if (config != null && config.pluginSource == HomeSectionPluginSource.seerr) {
      return seerrBrand(l10n.seerrDiscoveryRows);
    }
    if (config != null &&
        config.isPluginDynamic &&
        config.pluginSource == HomeSectionPluginSource.server) {
      return l10n.siloServerRowSubtitle;
    }
    if (config != null &&
        config.pluginSource == HomeSectionPluginSource.custom) {
      Map<String, dynamic> rowConfig = {};
      try {
        rowConfig = jsonDecode(
          config.pluginAdditionalData ?? '{}',
        ) as Map<String, dynamic>;
      } catch (_) {}
      final source = rowConfig['source'] as String? ?? 'imdb';
      final type = rowConfig['type'] as String? ?? 'user_list';
      final sourceLabel = switch (source) {
        'imdb' => 'IMDb',
        'tmdb' => 'TMDB',
        'letterboxd' => 'Letterboxd',
        'mdblist' => 'MDBList',
        _ => source.toUpperCase(),
      };
      final typeLabel = switch (type) {
        'user_list' =>
          source == 'tmdb'
              ? 'List'
              : (source == 'mdblist' ? '' : 'List from URL'),
        'user_diary' => 'Diary',
        'watchlist' => 'Watchlist',
        'films' => 'Complete Films',
        'awards_events' => 'Awards/Events',
        'movie_collection' => 'Collection',
        _ => type,
      };
      return '$sourceLabel $typeLabel'.trim();
    }
    return null;
  }

  Widget _buildHomeInitialLoadingSkeleton({
    required BuildContext context,
    required UserPreferences prefs,
    required PosterSize posterSize,
  }) {
    final safeTop = MediaQuery.of(context).padding.top;
    final desktopScale = _desktopUiScaleFactor();
    final isRowsV2 = _isHomeRowsStyleV2();
    final navbarIsTop =
        prefs.get(UserPreferences.navbarPosition) == NavbarPosition.top;
    final tvTopNavbarInset =
        navbarIsTop && PlatformDetection.isTV && !PlatformDetection.useMobileUi
        ? 48.0
        : 0.0;
    final navbarLeftInset = navbarIsTop ? 16.0 + tvTopNavbarInset : 56.0;
    final platformScale = PlatformDetection.isTV
        ? 1.0
        : (PlatformDetection.useMobileUi ? 1.0 : desktopScale);
    final v2ImageHeight = modernImageHeight(posterSize, platformScale);
    final v2PortraitWidth = v2ImageHeight * (2 / 3);
    final cardWidth = isRowsV2
        ? v2PortraitWidth
        : (posterSize.portraitHeight.toDouble() * platformScale * (2 / 3));
    final imageHeight = isRowsV2
        ? v2ImageHeight
        : (posterSize.portraitHeight.toDouble() * platformScale);

    return SkeletonShimmer(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.only(
          top: safeTop + (navbarIsTop ? 70.0 : 24.0),
          bottom: 48.0,
        ),
        children: [
          for (int i = 0; i < 4; i++) ...[
            Padding(
              padding: EdgeInsets.only(
                left: navbarLeftInset + (isRowsV2 ? _kHomeRowLabelInset : 0),
                bottom: 8.0,
                top: i == 0 ? 0 : 24.0,
              ),
              child: SkeletonBox(
                width: 140.0 + (i * 24),
                height: 18,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            SkeletonHomeRow(
              cardWidth: cardWidth,
              imageHeight: imageHeight,
              leadingPadding:
                  navbarLeftInset + (isRowsV2 ? _kHomeRowLabelInset : 0),
              itemSpacing: 14.0,
              isModern: isRowsV2,
              count: 8,
            ),
          ],
        ],
      ),
    );
  }

  // Phones pull Home down to refresh it, the same as tapping Home.
  Widget _pullToRefresh(Widget list) {
    if (!PlatformDetection.useMobileUi) return list;
    return RefreshIndicator(
      edgeOffset: MediaQuery.paddingOf(context).top,
      onRefresh: () => widget.viewModel.refresh(newMediaBar: true),
      child: list,
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.viewModel.rows;
    // Guard against a stale focused-row index pointing past the end of the
    // (potentially shorter) new row list
    if (_activeFocusedRowIndex != null &&
        _activeFocusedRowIndex! >= rows.length) {
      _activeFocusedRowIndex = null;
    }
    final prefs = widget.prefs;
    final posterSize = _homePosterSize();
    final watchedBehavior = prefs.get(UserPreferences.watchedIndicatorBehavior);
    final focusColor = Color(prefs.get(UserPreferences.focusColor).colorValue);
    final cardExpansion = prefs.get(UserPreferences.cardFocusExpansion);
    final useSeriesThumbs = prefs.get(UserPreferences.seriesThumbnailsEnabled);

    if (widget.viewModel.isLoading && rows.isEmpty) {
      return _buildHomeInitialLoadingSkeleton(
        context: context,
        prefs: prefs,
        posterSize: posterSize,
      );
    }

    _updateOffsets();
    final includeMediaBar = _isMediaBarIncluded();
    final bannerMode = _isBannerMode();
    final mediaBarExtent = _mediaBarExtent();
    final mediaBarMode = UserPreferences.normalizeMediaBarMode(
      prefs.get(UserPreferences.mediaBarMode),
    );
    // Moonfin and MakD keep their backdrop full height under a peeking row and
    // move their content above it. The other styles shrink to what is left.
    final mediaBarUnderRows =
        mediaBarMode == UserPreferences.mediaBarModeMoonfin ||
        mediaBarMode == UserPreferences.mediaBarModeMakd;
    final mediaBarHeight = _rowPeek == 0
        ? _mediaBarHeight()
        : mediaBarUnderRows
        ? MediaQuery.sizeOf(context).height
        : MediaQuery.sizeOf(context).height - _rowPeekCover;
    final mediaBarRowPeek = mediaBarUnderRows ? _rowPeekCover : 0.0;
    // The peeking row steps aside with the navbar while a trailer fills the
    // screen.
    final rowsFadeForTrailer = mediaBarRowPeek > 0;
    final showInfoOverlay = _showHomeRowInfoOverlay();
    final safeTop = MediaQuery.of(context).padding.top;
    final desktopScale = _desktopUiScaleFactor();
    final fullScreenRows =
        !PlatformDetection.useMobileUi &&
        prefs.get(UserPreferences.fullScreenRows);
    final navbarIsTop =
        widget.prefs.get(UserPreferences.navbarPosition) == NavbarPosition.top;
    final navbarIsLeft = !navbarIsTop;
    final navbarHeight = PlatformDetection.isTV
        ? (fullScreenRows ? 95.0 : (navbarIsTop ? 45.0 : 15.0))
        : (navbarIsTop
              ? (PlatformDetection.useMobileUi ? 60.0 : 80.0)
              : (fullScreenRows ? 0.0 : 80.0));
    final listTopPadding = includeMediaBar || showInfoOverlay
        ? 0.0
        : _isHomeRowsStyleV2()
        ? (fullScreenRows
              ? (safeTop + navbarHeight + 8.0).clamp(56.0, double.infinity)
              : safeTop + navbarHeight + 8)
        : safeTop + 56;
    final tvTopNavbarInset =
        navbarIsTop && PlatformDetection.isTV && !PlatformDetection.useMobileUi
        ? 48.0
        : 0.0;
    final rowLeftInset =
        (navbarIsLeft && !PlatformDetection.useMobileUi
            ? 56.0
            : tvTopNavbarInset) +
        (!PlatformDetection.useMobileUi ? 16.0 : 0.0);
    final infoTopBasePadding =
        (!PlatformDetection.useMobileUi && navbarHeight == 0) ? 14.0 : 8.0;
    final infoTopPadding = safeTop + navbarHeight + infoTopBasePadding;
    final infoAreaHeight = InfoArea.fixedHeight(
      isMobile: PlatformDetection.useMobileUi,
      desktopScale: desktopScale,
    );
    final infoBottomPadding = includeMediaBar ? 20.0 : 8.0;
    // Reserve the info band height up-front so revealing/hiding the InfoArea
    // overlay (a Stack child) does not shift row positions in the ListView.
    final infoOverlayPlaceholder = showInfoOverlay && _rowPeek == 0
        ? infoTopPadding + infoAreaHeight + infoBottomPadding
        : 0.0;

    final infoPlaceholderHeightBuilder = bannerMode
        ? ValueListenableBuilder<bool>(
            valueListenable: _infoRevealedNotifier,
            builder: (context, revealed, _) =>
                SizedBox(height: revealed ? infoOverlayPlaceholder : 0.0),
          )
        : SizedBox(height: infoOverlayPlaceholder);

    final overlayBottom = _overlayBottom;
    final rowTopOffsets = _rowTopOffsets;
    final rowExtents = _rowExtents;
    final headerCount = (includeMediaBar ? 1 : 0) + 1;

    final minBottomPadding = _isHomeRowsStyleV2() ? 24.0 : 32.0;
    final double neededBottomPadding;
    if (PlatformDetection.useMobileUi) {
      // Touch moves the list rather than a row at a time, so the room kept
      // below for that reads as blank space here. It only needs to clear the
      // navbar the rows scroll behind.
      neededBottomPadding = minBottomPadding + _bottomNavbarInset();
    } else {
      // Ensure the last row can be scrolled so its top sits just below the
      // info overlay, otherwise scroll targets clamp to maxScrollExtent and
      // rows drift higher in the viewport as the user navigates downward.
      final viewportHeight = MediaQuery.of(context).size.height;
      final lastRowExtent = rowExtents.isEmpty ? 0.0 : rowExtents.last;
      neededBottomPadding =
          (viewportHeight -
                  (overlayBottom + (_isHomeRowsStyleV2() ? 4.0 : 8.0)) -
                  lastRowExtent)
              .clamp(minBottomPadding, double.infinity);
    }

    _ensureInitialHomeFocus(rows);

    if (!widget.viewModel.isLoading && rows.isEmpty && !includeMediaBar) {
      final l10n = AppLocalizations.of(context);
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.noHomeRowsLoaded,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.noHomeRowsHint,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withAlpha(160),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () =>
                  widget.viewModel.refresh(preserveExisting: false),
              child: Text(l10n.retryHomeRows),
            ),
          ],
        ),
      );
    }

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _markUserGesture(),
      onPointerSignal: (pointerSignal) {
        if (pointerSignal is PointerScrollEvent) {
          _lastMouseWheelTime = DateTime.now();
          // A wheel tick is the user taking over, so the delayed realign on
          // return must not fight it.
          _returnScrollRowId = null;
        }
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: (_, event) => _handleRowsKeyEvent(event),
              child: _pullToRefresh(
                ListView.builder(
                  controller: _scrollController,
                  // A Home too short to scroll still has to take the pull.
                  physics: PlatformDetection.useMobileUi
                      ? const AlwaysScrollableScrollPhysics()
                      : null,
                  padding: EdgeInsets.only(
                    top: listTopPadding,
                    bottom: neededBottomPadding,
                  ),
                  itemCount: rows.length + headerCount,
                  scrollCacheExtent: const ScrollCacheExtent.pixels(600.0),
                  itemBuilder: (context, index) {
                    if (includeMediaBar && index == 0) {
                      return ValueListenableBuilder<bool>(
                        valueListenable: _mediaBarVisibleNotifier,
                        builder: (context, mediaBarVisible, _) {
                          return AnimatedOpacity(
                            duration: _mediaBarFadeDuration,
                            curve: Curves.easeInOutCubic,
                            opacity: mediaBarVisible ? 1.0 : 0.0,
                            child: IgnorePointer(
                              ignoring: !mediaBarVisible,
                              child: ValueListenableBuilder<bool>(
                                valueListenable: widget.isHoverPausedNotifier,
                                builder: (context, isHoverPaused, _) {
                                  return ValueListenableBuilder<bool>(
                                    valueListenable:
                                        widget.isScrolledToTopNotifier,
                                    builder: (context, isScrolledToTop, _) {
                                      return ListenableBuilder(
                                        listenable: _mediaBarPauseInputs,
                                        builder: (context, _) {
                                          final chromeAudioActive =
                                              _chromeAudioActiveNotifier.value;
                                          // Mobile leaves _isActivelyScrolling out. Nothing listens
                                          // for its idle reset, so a stale true would pin the bar
                                          // paused after scrolling back to the top, and
                                          // isScrolledToTop already covers pausing during a scroll.
                                          final barPaused =
                                              isHoverPaused ||
                                              !isScrolledToTop ||
                                              (!PlatformDetection.isMobile &&
                                                  _isActivelyScrolling) ||
                                              chromeAudioActive ||
                                              _screensaverVisible.value;

                                          // Let the banner auto-advance while focus is on the home rows.
                                          final bannerPaused =
                                              _screensaverVisible.value ||
                                              _activePreviewKey != null ||
                                              _mediaBarFocusNode.hasFocus &&
                                                  (isHoverPaused ||
                                                      (!PlatformDetection
                                                              .isMobile &&
                                                          _isActivelyScrolling) ||
                                                      chromeAudioActive);

                                          final bar = RepaintBoundary(
                                            child: bannerMode
                                                ? BannerMediaBar(
                                                    viewModel: widget
                                                        .mediaBarViewModel,
                                                    prefs: prefs,
                                                    height: mediaBarHeight,
                                                    externallyPaused:
                                                        bannerPaused ||
                                                        !mediaBarVisible,
                                                    focusNode:
                                                        _mediaBarFocusNode,
                                                    onNavigateDown:
                                                        _moveFocusFromMediaBarToRows,
                                                    onNavigateUp:
                                                        _navigateFromMediaBarToNavbar,
                                                    onNavigateLeft: navbarIsLeft
                                                        ? _navigateFromMediaBarToNavbar
                                                        : null,
                                                    onOpen: (item) =>
                                                        context.push(
                                                          Destinations.item(
                                                            item.itemId,
                                                            serverId:
                                                                item.serverId,
                                                          ),
                                                        ),
                                                    onPlay: (item) =>
                                                        context.push(
                                                          Destinations.item(
                                                            item.itemId,
                                                            serverId:
                                                                item.serverId,
                                                            autoPlay: true,
                                                          ),
                                                        ),
                                                  )
                                                : MediaBar(
                                                    viewModel: widget
                                                        .mediaBarViewModel,
                                                    prefs: prefs,
                                                    externallyPaused:
                                                        barPaused ||
                                                        !mediaBarVisible ||
                                                        _activePreviewKey !=
                                                            null,
                                                    // A TV trailer hides the navbar,
                                                    // so it only plays while the bar
                                                    // itself has focus.
                                                    trailerPaused:
                                                        PlatformDetection
                                                            .isTV &&
                                                        !_mediaBarFocusNode
                                                            .hasFocus,
                                                    height: mediaBarHeight,
                                                    rowPeek: mediaBarRowPeek,
                                                    onNavigateDown:
                                                        _moveFocusFromMediaBarToRows,
                                                    onNavigateUp:
                                                        _navigateFromMediaBarToNavbar,
                                                    onNavigateLeft: navbarIsLeft
                                                        ? _navigateFromMediaBarToNavbar
                                                        : null,
                                                    focusNode:
                                                        _mediaBarFocusNode,
                                                  ),
                                          );
                                          if (_rowPeek == 0) return bar;
                                          // The slot ends where the first row
                                          // starts, and the bar draws on under it.
                                          return SizedBox(
                                            height: mediaBarExtent,
                                            child: OverflowBox(
                                              alignment: Alignment.topCenter,
                                              minHeight: mediaBarHeight,
                                              maxHeight: mediaBarHeight,
                                              child: bar,
                                            ),
                                          );
                                        },
                                      );
                                    },
                                  );
                                },
                              ),
                            ),
                          );
                        },
                      );
                    }
                    final infoIndex = includeMediaBar ? 1 : 0;
                    if (index == infoIndex) {
                      return infoPlaceholderHeightBuilder;
                    }
                    final row = rows[index - headerCount];
                    final rowIndex = index - headerCount;
                    final l10n = AppLocalizations.of(context);
                    late final Widget rowChild;
                    if (row.isLoading) {
                      rowChild = LibraryRow(
                        title: _localizedRowTitle(row, l10n),
                        isLoading: true,
                        children: const [],
                      );
                    } else if (row.rowType == HomeRowType.liveTv) {
                      rowChild = _buildLiveTvRow(
                        row,
                        focusColor,
                        cardExpansion,
                        posterSize: posterSize,
                        rowIndex: rowIndex,
                        rows: rows,
                      );
                    } else if (row.rowType == HomeRowType.libraryTilesSmall) {
                      rowChild = _buildLibraryButtonsRow(
                        row,
                        focusColor,
                        cardExpansion,
                        posterSize: posterSize,
                        rowIndex: rowIndex,
                        rows: rows,
                      );
                    } else {
                      rowChild = _buildMediaRow(
                        row: row,
                        rowIndex: rowIndex,
                        rows: rows,
                        prefs: prefs,
                        posterSize: posterSize,
                        watchedBehavior: watchedBehavior,
                        focusColor: focusColor,
                        cardExpansion: cardExpansion,
                        useSeriesThumbs: useSeriesThumbs,
                        l10n: l10n,
                      );
                    }

                    final contentHeight = _rowContentHeight(
                      row,
                      posterSize,
                      prefs,
                    );
                    final targetExtent = rowExtents[rowIndex];
                    final isRowsV2 = _isRowModern(row, prefs);
                    final extraTopPadding = isRowsV2
                        ? ((targetExtent - contentHeight) * 0.1).clamp(
                            0.0,
                            double.infinity,
                          )
                        : ((targetExtent - contentHeight) / 2.0).clamp(
                            0.0,
                            double.infinity,
                          );

                    final paddedRowChild = extraTopPadding > 0.0
                        ? Padding(
                            padding: EdgeInsets.only(top: extraTopPadding),
                            child: rowChild,
                          )
                        : rowChild;
                    final shownRowChild = rowsFadeForTrailer
                        ? ListenableBuilder(
                            listenable:
                                NavigationLayout.trailerChromeListenable,
                            builder: (context, child) => AnimatedOpacity(
                              opacity: NavigationLayout.trailerHidesChrome
                                  ? 0.0
                                  : 1.0,
                              duration: const Duration(milliseconds: 200),
                              child: child,
                            ),
                            child: paddedRowChild,
                          )
                        : paddedRowChild;

                    // Padding only bites if rows honour the extent worked out
                    // above, so all of them are pinned to it apart from mobile
                    // full screen rows, which size themselves.
                    final bool lockRowHeight =
                        !PlatformDetection.useMobileUi || !fullScreenRows;

                    if (row.isLoading) {
                      final itemWidget = Padding(
                        padding: EdgeInsets.only(left: rowLeftInset),
                        child: ValueListenableBuilder<double>(
                          valueListenable: _scrollOffsetNotifier,
                          builder: (context, scrollOffset, _) {
                            return _buildShiftedRow(
                              child: shownRowChild,
                              rowIndex: rowIndex,
                              rowTopOffsets: rowTopOffsets,
                              rowExtents: rowExtents,
                              showInfoOverlay: showInfoOverlay,
                              overlayBottom: overlayBottom,
                            );
                          },
                        ),
                      );
                      if (lockRowHeight) {
                        return SizedBox(
                          height: rowExtents[rowIndex],
                          child: itemWidget,
                        );
                      }
                      return itemWidget;
                    }

                    final itemWidget = Padding(
                      padding: EdgeInsets.only(left: rowLeftInset),
                      child: ValueListenableBuilder<int?>(
                        valueListenable: _activeFocusedRowNotifier,
                        builder: (context, activeRowIndex, _) {
                          return AnimatedPadding(
                            duration: _focusedRowSpacingDuration,
                            curve: Curves.easeOut,
                            padding: EdgeInsets.symmetric(
                              vertical:
                                  (PlatformDetection.isTV &&
                                      !fullScreenRows &&
                                      !showInfoOverlay &&
                                      rowIndex == activeRowIndex)
                                  ? _focusedRowExtraSpacingFor()
                                  : 0,
                            ),
                            child: ValueListenableBuilder<double>(
                              valueListenable: _scrollOffsetNotifier,
                              builder: (context, scrollOffset, _) {
                                return _buildShiftedRow(
                                  child: shownRowChild,
                                  rowIndex: rowIndex,
                                  rowTopOffsets: rowTopOffsets,
                                  rowExtents: rowExtents,
                                  showInfoOverlay: showInfoOverlay,
                                  overlayBottom: overlayBottom,
                                );
                              },
                            ),
                          );
                        },
                      ),
                    );
                    if (lockRowHeight) {
                      return SizedBox(
                        height: rowExtents[rowIndex],
                        child: itemWidget,
                      );
                    }
                    return itemWidget;
                  },
                ),
              ),
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: _infoRevealedNotifier,
            builder: (context, infoRevealed, _) {
              if (infoRevealed && showInfoOverlay) {
                return Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        rowLeftInset + _kHomeRowLabelInset,
                        infoTopPadding,
                        16,
                        8,
                      ),
                      child: ValueListenableBuilder<AggregatedItem?>(
                        valueListenable: widget.selectedItemNotifier,
                        builder: (context, selectedItem, _) {
                          return InfoArea(item: selectedItem);
                        },
                      ),
                    ),
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
          // TV builds with the left sidebar navbar have no top toolbar, so the
          // toolbar's top-right clock is gone too. Re-enable a clock overlay in
          // the same corner on the home screen (compact-banner owns this).
          if (PlatformDetection.isTV && navbarIsLeft)
            Positioned(
              top: safeTop + 27.0,
              right: 48.0,
              child: _TvSidebarClock(prefs: prefs),
            ),
        ],
      ),
    );
  }

  Widget _buildLiveTvRow(
    HomeRow row,
    Color focusColor,
    bool cardExpansion, {
    required PosterSize posterSize,
    required int rowIndex,
    required List<HomeRow> rows,
  }) {
    final l10n = AppLocalizations.of(context);
    final metadataScale = _desktopUiScaleFactor();
    final squarePosterSide = _squarePosterSide(posterSize);
    final rowHeight = squarePosterSide + (56 * metadataScale);
    final actions = <_LiveTvAction>[
      _LiveTvAction(Icons.tv_rounded, l10n.guide, Destinations.liveTvGuide),
      _LiveTvAction(
        Icons.fiber_manual_record_rounded,
        l10n.recordings,
        Destinations.liveTvRecordings,
      ),
      _LiveTvAction(
        Icons.schedule_rounded,
        l10n.schedule,
        Destinations.liveTvSchedule,
      ),
      _LiveTvAction(
        Icons.movie_creation,
        l10n.series,
        Destinations.liveTvSeriesRecordings,
      ),
    ];
    return _buildTitledRow(
      key: _rowContainerKey(rowIndex),
      title: _localizedRowTitle(row, l10n),
      rowIndex: rowIndex,
      hasItems: actions.isNotEmpty,
      height: rowHeight,
      child: LockedFocusRow<_LiveTvAction>(
        key: _rowKey(rowIndex),
        items: actions,
        hubKey: _hubKeyForRow(row),
        controller: _rowHorizontalController(rowIndex),
        height: rowHeight,
        itemExtent: squarePosterSide,
        itemSpacing: _rowItemSpacing(squarePosterSide, cardExpansion),
        leadingPadding: _isHomeRowsStyleV2() ? _kHomeRowLabelInset : 0,
        clipBehavior: cardExpansion ? Clip.none : Clip.hardEdge,
        padding: EdgeInsets.fromLTRB(
          _kHomeRowLabelInset,
          _isHomeRowsStyleV2() ? 5 : (_isCompactClassicMode ? 2 : 5),
          20,
          _isHomeRowsStyleV2() ? 5 : (_isCompactClassicMode ? 2 : 5),
        ),
        onIndexChanged: (_, _) {
          _onHomeRowTileFocused(null);
        },
        onFocusChange: (has) => _onRowFocusTracked(rowIndex, has),
        onVerticalNavigation: (isUp) => _onRowVerticalNavigation(
          rowIndex: rowIndex,
          rows: rows,
          isUp: isUp,
        ),
        onLeftEdge: _onRowLeftEdge,
        onTap: (_, action) => context.push(action.destination),
        itemBuilder: (ctx, action, idx, isFocused) {
          return Align(
            alignment: Alignment.topCenter,
            child: SizedBox.square(
              dimension: squarePosterSide,
              child: GridButtonCard(
                icon: action.icon,
                label: action.label,
                width: squarePosterSide,
                height: squarePosterSide,
                focusColor: focusColor,
                cardFocusExpansion: cardExpansion,
                externalIsFocused: isFocused,
                onTap: () => context.push(action.destination),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildLibraryButtonsRow(
    HomeRow row,
    Color focusColor,
    bool cardExpansion, {
    required PosterSize posterSize,
    required int rowIndex,
    required List<HomeRow> rows,
  }) {
    final l10n = AppLocalizations.of(context);
    final metadataScale = _desktopUiScaleFactor();
    final squarePosterSide = _squarePosterSide(posterSize);
    final headroom = _focusHeadroom(squarePosterSide, cardExpansion);
    final rowHeight = squarePosterSide + (56 * metadataScale) + headroom;
    return _buildTitledRow(
      key: _rowContainerKey(rowIndex),
      title: _localizedRowTitle(row, l10n),
      rowIndex: rowIndex,
      hasItems: row.items.isNotEmpty,
      height: rowHeight,
      child: LockedFocusRow<AggregatedItem>(
        key: _rowKey(rowIndex),
        items: row.items,
        itemKey: _rowItemIdentity,
        hubKey: _hubKeyForRow(row),
        controller: _rowHorizontalController(rowIndex),
        height: rowHeight,
        itemExtent: squarePosterSide,
        itemSpacing: _rowItemSpacing(squarePosterSide, cardExpansion),
        leadingPadding: _isHomeRowsStyleV2() ? _kHomeRowLabelInset : 0,
        clipBehavior: cardExpansion ? Clip.none : Clip.hardEdge,
        padding: EdgeInsets.fromLTRB(
          _kHomeRowLabelInset,
          (_isHomeRowsStyleV2() ? 5 : (_isCompactClassicMode ? 2 : 5)) +
              headroom,
          20,
          _isHomeRowsStyleV2() ? 5 : (_isCompactClassicMode ? 2 : 5),
        ),
        onIndexChanged: (_, item) {
          _onHomeRowTileFocused(item);
        },
        onFocusChange: (has) => _onRowFocusTracked(rowIndex, has),
        onVerticalNavigation: (isUp) => _onRowVerticalNavigation(
          rowIndex: rowIndex,
          rows: rows,
          isUp: isUp,
        ),
        onLeftEdge: _onRowLeftEdge,
        onTap: (_, item) => _navigateToLibrary(context, item),
        onLongPress: (_, item) =>
            showContextMenu(context, item, onChanged: () => setState(() {})),
        itemBuilder: (ctx, item, idx, isFocused) {
          final collectionType =
              (item.rawData['CollectionType'] as String? ?? '').toLowerCase();
          final icon = isGameLibrary(item.id, collectionType, item.name)
              ? gameLibraryIcon
              : _iconForCollectionType(collectionType);
          return Align(
            alignment: Alignment.topCenter,
            child: SizedBox.square(
              dimension: squarePosterSide,
              child: GridButtonCard(
                icon: icon,
                label: item.name,
                width: squarePosterSide,
                height: squarePosterSide,
                focusColor: focusColor,
                cardFocusExpansion: cardExpansion,
                externalIsFocused: isFocused,
                onTap: () => _navigateToLibrary(context, item),
                onLongPress: () => showContextMenu(
                  context,
                  item,
                  onChanged: () => setState(() {}),
                ),
                onSecondaryTap: () => showContextMenu(
                  context,
                  item,
                  onChanged: () => setState(() {}),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMediaRow({
    required HomeRow row,
    required int rowIndex,
    required List<HomeRow> rows,
    required UserPreferences prefs,
    required PosterSize posterSize,
    required WatchedIndicatorBehavior watchedBehavior,
    required Color focusColor,
    required bool cardExpansion,
    required bool useSeriesThumbs,
    required AppLocalizations l10n,
  }) {
    final suppressFocusGlow = ThemeRegistry.active.borders.focusGlow.isNotEmpty;
    final hideWatchProgress = prefs.get(UserPreferences.hideHomeWatchProgress);
    final hideUnwatchedCount = prefs.get(UserPreferences.hideHomeUnwatchedCount);
    final showMediaTypeBadges = showsMediaTypeBadges(
      prefs.get(UserPreferences.mediaTypeBadgeBehavior),
      row.items,
    );
    final isSeerrRowOverride = _isSeerrFilterRow(row);
    final isRowsV2 = _isRowModern(row, prefs);
    final isModernMyMediaStatic = _isModernMyMediaStatic(row, prefs);
    final rowImageType = isSeerrRowOverride
        ? ImageType.thumb
        : (isRowsV2
              ? (isModernMyMediaStatic ? ImageType.thumb : ImageType.poster)
              : _homeRowImageTypeForRow(row, prefs));
    final desktopScale = _desktopUiScaleFactor();
    final metadataScale = desktopScale;
    final platformScale = _rowPlatformScale(desktopScale);
    final v2ImageHeight = modernImageHeight(posterSize, platformScale);
    final v2MetadataHeightBudget = _v2MetadataBudgetFor(row, prefs);
    final v2PortraitAspect = row.isAudio ? 1.0 : 2 / 3;
    final v2FocusedAspect = row.isAudio ? 1.0 : 16 / 9;
    final v2PortraitWidth = v2ImageHeight * v2PortraitAspect;
    final v2FocusedWidth = v2ImageHeight * v2FocusedAspect;
    final navbarIsTopV2 =
        widget.prefs.get(UserPreferences.navbarPosition) == NavbarPosition.top;
    final rowLeftInsetV2 =
        (navbarIsTopV2
            ? (PlatformDetection.isTV && !PlatformDetection.useMobileUi
                  ? 48.0
                  : 0.0)
            : (!PlatformDetection.useMobileUi ? 56.0 : 0.0)) +
        (!PlatformDetection.useMobileUi ? 16.0 : 0.0);
    final v2ExtendedWidth = isRowsV2
        ? (MediaQuery.of(context).size.width -
                  rowLeftInsetV2 -
                  16.0 -
                  MediaQuery.paddingOf(context).right -
                  16.0)
              .clamp(v2PortraitWidth, double.infinity)
              .toDouble()
        : v2PortraitWidth;
    // A phone caps a focused card at the row width, so the static My Media
    // card has to use the capped number or it ends up wider than any focused
    // card ever gets.
    final v2FocusedWidthForCurrentViewport =
        isRowsV2 && PlatformDetection.useMobileUi
        ? v2FocusedWidth.clamp(v2PortraitWidth, v2ExtendedWidth).toDouble()
        : v2FocusedWidth;

    double maxCardHeight = 0;
    double maxImageHeight = 0;
    double firstCardWidth = 0;
    if (isRowsV2) {
      maxImageHeight = v2ImageHeight;
      maxCardHeight = v2ImageHeight + (v2MetadataHeightBudget * metadataScale);
      firstCardWidth = isModernMyMediaStatic
          ? v2FocusedWidthForCurrentViewport
          : v2PortraitWidth;
      if (!isModernMyMediaStatic) {
        _prefetchV2RowLeadImage(
          row: row,
          rowIndex: rowIndex,
          v2ImageHeight: v2ImageHeight,
          v2FocusedWidth: v2FocusedWidth,
          useSeriesThumbs: useSeriesThumbs,
        );
      }
    } else {
      for (final item in row.items) {
        final ar = _aspectRatioForRowItem(item, row, rowImageType);
        final height =
            (ar > 1
                ? posterSize.landscapeHeight.toDouble()
                : posterSize.portraitHeight.toDouble()) *
            platformScale;
        if (height > maxImageHeight) maxImageHeight = height;
        final cardHeight =
            height + (_classicCardMetadataHeight * metadataScale);
        if (cardHeight > maxCardHeight) maxCardHeight = cardHeight;
        if (firstCardWidth == 0) firstCardWidth = height * ar;
      }
      maxCardHeight += _classicRowPadding(row, prefs);
    }

    if (firstCardWidth == 0) {
      final defaultAspect = row.isAudio ? 1.0 : 2 / 3;
      firstCardWidth =
          posterSize.portraitHeight.toDouble() * platformScale * defaultAspect;
    }
    if (maxCardHeight == 0) {
      maxImageHeight = posterSize.portraitHeight.toDouble() * platformScale;
      maxCardHeight =
          maxImageHeight + (_classicCardMetadataHeight * metadataScale);
    }

    final rowPadding = (_isCompactClassicMode ? 2.0 : 5.0) * metadataScale;
    // The Continue Watching & Next Up row sits tight to the row below it
    // in compact-classic: its bottom rail padding is dropped.
    final bottomPadding = (_isCompactClassicMode && row.id == 'resume')
        ? _compactClassicResumeBottomPadding
        : rowPadding;
    final topPadding =
        rowPadding + _focusHeadroom(maxImageHeight, cardExpansion);
    final lockedRowHeight = maxCardHeight + topPadding + bottomPadding;

    final subtitle = _rowSubtitle(row, l10n);
    final hasSubtitle = subtitle != null && subtitle.isNotEmpty;
    final rowTotalHeight =
        lockedRowHeight + (hasSubtitle ? (row.id == 'mdblist_watching_now' ? 26.0 : 18.0) : 0.0);

    if (row.isLoading && row.items.isEmpty) {
      return _buildTitledRow(
        key: _rowContainerKey(rowIndex),
        title: _localizedRowTitle(row, l10n),
        subtitle: subtitle,
        isWatchingNow: row.id == 'mdblist_watching_now',
        rowIndex: rowIndex,
        hasItems: false,
        height: rowTotalHeight,
        child: SkeletonHomeRow(
          cardWidth: firstCardWidth,
          imageHeight: isRowsV2
              ? v2ImageHeight
              : (posterSize.portraitHeight.toDouble() * platformScale),
          itemSpacing: _rowItemSpacing(firstCardWidth, cardExpansion),
          leadingPadding: isRowsV2 ? _kHomeRowLabelInset : 0,
          isModern: isRowsV2,
        ),
      );
    }

    final itemSpacing = _rowItemSpacing(firstCardWidth, cardExpansion);
    // A tap grows a card on touch screens, so the glide is for remotes and
    // keyboards only.
    final glide = isRowsV2 &&
            !row.isAudio &&
            !isModernMyMediaStatic &&
            !PlatformDetection.useMobileUi
        ? (_rowGlide(rowIndex)..growth = v2FocusedWidth - v2PortraitWidth)
        : null;

    return _buildTitledRow(
      key: _rowContainerKey(rowIndex),
      title: _localizedRowTitle(row, l10n),
      subtitle: subtitle,
      isWatchingNow: row.id == 'mdblist_watching_now',
      rowIndex: rowIndex,
      hasItems: row.items.isNotEmpty,
      height: rowTotalHeight,
      child: LockedFocusRow<AggregatedItem>(
        key: _rowKey(rowIndex),
        items: row.items,
        itemKey: _rowItemIdentity,
        hubKey: _hubKeyForRow(row),
        controller: _rowHorizontalController(rowIndex),
        height:
            lockedRowHeight +
            (PlatformDetection.isTV && _isCompactClassicMode
                ? _tvCompactClassicRailHeadroom
                : 0.0),
        itemExtent: firstCardWidth,
        itemSpacing: itemSpacing,
        leadingPadding: isRowsV2 ? _kHomeRowLabelInset : 0,
        glide: glide,
        clipBehavior: (isRowsV2 || cardExpansion) ? Clip.none : Clip.hardEdge,
        padding: EdgeInsets.fromLTRB(
          _kHomeRowLabelInset,
          topPadding +
              (PlatformDetection.isTV && _isCompactClassicMode
                  ? _tvCompactClassicRailHeadroom
                  : 0.0),
          _kHomeRowTrailingInset,
          bottomPadding,
        ),
        onFocusChange: (has) => _onRowFocusTracked(rowIndex, has),
        onVerticalNavigation: (isUp) => _onRowVerticalNavigation(
          rowIndex: rowIndex,
          rows: rows,
          isUp: isUp,
        ),
        onLeftEdge: _onRowLeftEdge,
        onIndexChanged: (index, item) {
          final forceReveal = _forceRevealOnNextRowFocusFromMediaBar;
          _forceRevealOnNextRowFocusFromMediaBar = false;
          widget.onItemSelected(item);
          if (isRowsV2) {
            final previewKey = _previewKeyFor(item, rowIndex);
            final delayExpansion = prefs.get(
              UserPreferences.delayCardExpansionOnRapidScroll,
            );
            _v2Expansion.settle(
              previewKey,
              delayExpansion: delayExpansion && !PlatformDetection.useMobileUi,
            );
          }
          if (isRowsV2 && !row.isAudio && !isModernMyMediaStatic) {
            _primeV2FocusedRatings(item);
            _prefetchV2FocusNeighbors(
              row: row,
              focusedIndex: index,
              v2ImageHeight: v2ImageHeight,
              v2FocusedWidth: v2FocusedWidth,
              useSeriesThumbs: useSeriesThumbs,
            );
          }
          unawaited(
            _revealAndScrollToPinnedInfo(ignoreScrollCooldown: forceReveal),
          );
          final canPreview = _supportsPreview(
            item,
            widget.prefs.resolveMediaPreviewMode(),
          );
          if (!PlatformDetection.useMobileUi && canPreview) {
            _schedulePreview(
              item,
              delay: _previewStartDelay,
              rowIndex: rowIndex,
            );
          } else {
            _finishSharedPreview();
          }
          if (index >= row.items.length - 8) {
            widget.viewModel.loadMoreForRow(rowIndex);
          }
        },
        onLongPress: (_, item) => showContextMenu(
          context,
          item,
          onChanged: () => setState(() {}),
          isContinueWatchingOrNextUp: _isContinueWatchingOrNextUp(row),
        ),
        onTap: (_, item) {
          _finishSharedPreview(releaseResources: true);
          if (_playedOnSelect(row, item)) return;
          if (row.rowType == HomeRowType.libraryTiles) {
            _navigateToLibrary(context, item);
          } else if (row.rowType == HomeRowType.genres && row.id == 'genres') {
            context.push(Destinations.genre(item.name, genreId: item.id));
          } else if (row.rowType == HomeRowType.studios &&
              row.id == 'studios') {
            context.push(Destinations.studio(item.name));
          } else if (item.serverId == 'seerr') {
            _navigateToSeerrItem(context, item);
          } else {
            context.push(
              Destinations.itemOrPhoto(
                item.id,
                serverId: item.serverId,
                type: item.type,
                channelId: item.channelId,
              ),
            );
          }
        },
        itemBuilder: (ctx, item, idx, isFocused) {
          final requestScale = MediaQuery.devicePixelRatioOf(context)
              .clamp(1.0, 2.0);
          final imageApi = widget.viewModel.imageApiForServer(item.serverId);
          final previewKey = _previewKeyFor(item, rowIndex);
          final isV2MobileTouch =
              isRowsV2 &&
              PlatformDetection.useMobileUi &&
              InputModeTracker.of(ctx) == InputMode.pointer;
          final delayExpansion = prefs.get(
            UserPreferences.delayCardExpansionOnRapidScroll,
          );

          return SelectorBuilder<bool>(
            listenable: _v2Expansion.listenable,
            select: () => isRowsV2
                ? _v2Expansion.isExpanded(
                    previewKey,
                    isFocused: isFocused,
                    isTouch: isV2MobileTouch,
                    delayExpansion:
                        delayExpansion && !PlatformDetection.useMobileUi,
                  )
                : isFocused,
            builder: (ctx, effectiveV2Focused) {
              late final double ar;
              late final double width;
              late final String? imageUrl;
              String? fallbackImageUrl;
              final canUseExpandedV2Card =
                  isRowsV2 &&
                  effectiveV2Focused &&
                  !row.isAudio &&
                  !isModernMyMediaStatic;

              if (isRowsV2) {
                if (isModernMyMediaStatic) {
                  ar = v2FocusedAspect;
                  width = v2FocusedWidthForCurrentViewport;
                  imageUrl = _cachedRowImageUrl(
                    item,
                    imageApi,
                    v2ImageHeight,
                    ImageType.thumb,
                    false,
                    requestScale,
                    isMyMediaRow: true,
                  );
                } else {
                  ar = canUseExpandedV2Card
                      ? v2FocusedAspect
                      : v2PortraitAspect;
                  width = canUseExpandedV2Card
                      ? v2FocusedWidthForCurrentViewport
                      : v2PortraitWidth;
                  final posterUrl = _cachedRowImageUrl(
                    item,
                    imageApi,
                    v2ImageHeight,
                    ImageType.poster,
                    item.type == 'Episode' ? true : useSeriesThumbs,
                    requestScale,
                    isMyMediaRow: row.rowType == HomeRowType.libraryTiles,
                  );
                  imageUrl = canUseExpandedV2Card
                      ? (_resolveV2FocusedImageUrl(
                              item,
                              imageApi,
                              v2ImageHeight,
                              useSeriesThumbs,
                              requestScale,
                            ) ??
                            posterUrl)
                      : posterUrl;
                  // The focused URL is server art (never blank); only the plain
                  // poster row needs the server twin underneath the external one.
                  fallbackImageUrl = imageUrl == posterUrl
                      ? _fallbackFor(
                          posterUrl,
                          _cachedRowImageUrl(
                            item,
                            imageApi,
                            v2ImageHeight,
                            ImageType.poster,
                            item.type == 'Episode' ? true : useSeriesThumbs,
                            requestScale,
                            isMyMediaRow:
                                row.rowType == HomeRowType.libraryTiles,
                            includeExternal: false,
                          ),
                        )
                      : null;
                }
              } else {
                final image = _unfocusedCardImage(
                  row,
                  item,
                  prefs: prefs,
                  posterSize: posterSize,
                  useSeriesThumbs: useSeriesThumbs,
                  requestScale: requestScale,
                );
                ar = image.aspectRatio;
                width = image.width;
                imageUrl = image.url;
                fallbackImageUrl = image.fallbackUrl;
              }

              final canPreview = _supportsPreview(
                item,
                widget.prefs.resolveMediaPreviewMode(),
              );

              return ValueListenableBuilder<String?>(
                valueListenable: _activePreviewKeyNotifier,
                builder: (context, activePreviewKey, _) {
                  return ValueListenableBuilder<bool>(
                    valueListenable: _previewReadyNotifier,
                    builder: (context, previewReady, _) {
                      final showPreviewVideo =
                          activePreviewKey == previewKey && previewReady;

                      void navigateToItem() {
                        if (_playedOnSelect(row, item)) return;
                        if (row.rowType == HomeRowType.libraryTiles) {
                          _navigateToLibrary(context, item);
                        } else if (row.rowType == HomeRowType.genres &&
                            row.id == 'genres') {
                          context.push(
                            Destinations.genre(item.name, genreId: item.id),
                          );
                        } else if (item.serverId == 'seerr') {
                          _navigateToSeerrItem(context, item);
                        } else {
                          context.push(
                            Destinations.itemOrPhoto(
                              item.id,
                              serverId: item.serverId,
                              type: item.type,
                              channelId: item.channelId,
                            ),
                          );
                        }
                      }

                      final String cardTitle;
                      final String? cardSubtitle;
                      final Widget? cardSubtitleWidget;

                      if (item.type == 'Episode') {
                        final s = item.parentIndexNumber;
                        final e = item.indexNumber;
                        final episodeInfo = switch ((s, e)) {
                          (final season?, final episode?) =>
                            'S$season:E$episode',
                          _ => null,
                        };
                        cardTitle = item.seriesName ?? item.name;
                        if (isRowsV2 && effectiveV2Focused) {
                          cardSubtitle = null;
                          final row2Text = episodeInfo != null
                              ? '$episodeInfo - ${item.name}'
                              : item.name;
                          final row3Text = _v2MetadataLine(item);
                          final isNeon =
                              ThemeRegistry.active.id ==
                              ThemeRegistry.neonPulseId;
                          final baseTextStyle =
                              Theme.of(context).textTheme.bodySmall ??
                              const TextStyle(fontSize: 12);
                          final subtitleColor = isNeon
                              ? AppColorScheme.onSurface
                              : Theme.of(context).colorScheme.onSurface
                                    .withAlpha(180);
                          final subtitleStyle = baseTextStyle.copyWith(
                            color: subtitleColor,
                            shadows: const [
                              Shadow(blurRadius: 4, color: Colors.black54),
                            ],
                          );

                          cardSubtitleWidget = Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                row2Text,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: subtitleStyle,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                row3Text,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: subtitleStyle,
                              ),
                            ],
                          );
                        } else if (isRowsV2) {
                          cardSubtitle = episodeInfo ?? item.name;
                          cardSubtitleWidget = null;
                        } else {
                          // Classic cards never expand, so their one subtitle line carries
                          // the episode name alongside the numbers.
                          cardSubtitle = episodeInfo != null
                              ? '$episodeInfo - ${item.name}'
                              : item.name;
                          cardSubtitleWidget = null;
                        }
                      } else if (isRowsV2 && item.type == 'Season') {
                        cardTitle = item.seriesName ?? item.name;
                        cardSubtitle = item.name;
                        cardSubtitleWidget = null;
                      } else {
                        cardTitle = item.name;
                        final showUserRatings =
                            item.rawData['ShowUserRatings'] == true;
                        final userRating =
                            item.rawData['UserRating'] as String? ?? '';
                        if (showUserRatings && userRating.isNotEmpty) {
                          cardSubtitle = userRating;
                        } else {
                          cardSubtitle =
                              (canUseExpandedV2Card &&
                                  row.id != 'radarr_calendar' &&
                                  row.id != 'sonarr_calendar' &&
                                  row.id != 'merged_calendar')
                              ? _v2MetadataLine(item)
                              : item.subtitle;
                        }
                        cardSubtitleWidget = null;
                      }

                      // Seerr genre cards print their name across the artwork,
                      // the way the Jellyfin genre row does.
                      final isSeerrGenreCard =
                          _isSeerrFilterRow(row) && item.type == 'Genre';
                      final card = MediaCard(
                        animeMarkerItemId: isSeerrGenreCard ? null : item.id,
                        recordingItemId: isSeerrGenreCard ? null : item.id,
                        title: cardTitle,
                        imageOverlays: isSeerrGenreCard
                            ? [
                                Positioned.fill(
                                  child: SeerrGenreLabel(name: item.name),
                                ),
                              ]
                            : const <Widget>[],
                        subtitle: cardSubtitle,
                        subtitleWidget: cardSubtitleWidget,
                        imageUrl: imageUrl,
                        fallbackImageUrl: fallbackImageUrl,
                        cacheManager: BetterPostersService.cacheManagerForUrl(
                          imageUrl,
                        ),
                        width: width,
                        aspectRatio: ar,
                        // Safe to compare doubles here, since ar is assigned
                        // this same constant and audio and Seerr filter rows
                        // already get a different ratio.
                        isBanner: ar == kBannerAspectRatio,
                        isFavorite: item.isFavorite,
                        isPlayed: item.isPlayed,
                        unplayedCount: item.unplayedItemCount,
                        playedPercentage: item.playedPercentage,
                        watchedBehavior: watchedBehavior,
                        itemType: item.type,
                        seerrMediaType: showMediaTypeBadges
                            ? item.seerrMediaType
                            : null,
                        seerrStatus: item.seerrStatus,
                        isGenreFallback:
                            (row.rowType == HomeRowType.genres &&
                                row.id == 'genres') &&
                            (() {
                              final primaryAr =
                                  item.rawData['PrimaryImageAspectRatio']
                                      as num?;
                              return primaryAr == null || primaryAr >= 1.0;
                            })(),
                        focusColor:
                            (row.rowType == HomeRowType.genres &&
                                row.id == 'genres')
                            ? ThemeRegistry.active.borders.focusBorder.color
                            : focusColor,
                        cardFocusExpansion: _isHomeRowsStyleV2()
                            ? false
                            : cardExpansion && !showPreviewVideo,
                        externalIsFocused: effectiveV2Focused,
                        suppressImageFocusBorder: showPreviewVideo,
                        suppressFocusGlow: suppressFocusGlow,
                        onHoverStart: () {
                          unawaited(
                            _revealAndScrollToPinnedInfo(fromMouseHover: true),
                          );
                          widget.onItemSelected(item);
                          if (isRowsV2) {
                            _v2Expansion.hoveredKey.value = previewKey;
                            if (!row.isAudio) {
                              _primeV2FocusedRatings(item);
                            }
                          }
                          if (!PlatformDetection.useMobileUi && canPreview) {
                            _schedulePreview(
                              item,
                              delay: _previewStartDelay,
                              rowIndex: rowIndex,
                            );
                          } else {
                            _finishSharedPreview();
                          }
                        },
                        onHoverEnd: () {
                          if (isRowsV2) {
                            if (_v2Expansion.hoveredKey.value == previewKey) {
                              _v2Expansion.hoveredKey.value = null;
                            }
                            _finishSharedPreview();
                          } else {
                            _stopPreviewFor(item, rowIndex);
                          }
                        },
                        onLongPress: () => showContextMenu(
                          context,
                          item,
                          onChanged: () => setState(() {}),
                          isContinueWatchingOrNextUp:
                              _isContinueWatchingOrNextUp(row),
                        ),
                        onTap: () {
                          if (isV2MobileTouch) {
                            if (_v2Expansion.tapToOpen(previewKey)) {
                              _finishSharedPreview(releaseResources: true);
                              navigateToItem();
                            } else {
                              widget.onItemSelected(item);
                              _primeV2FocusedRatings(item);
                            }
                            return;
                          }

if (isRowsV2) _v2Expansion.clearPointer();
                          _finishSharedPreview(releaseResources: true);
                          navigateToItem();
                        },
                      );

                      final previewWrappedCard = !canPreview
                          ? card
                          : _PreviewCardShell(
                              card: card,
                              width: width,
                              aspectRatio: ar,
                              showVideo: showPreviewVideo,
                              useMedia3:
                                  showPreviewVideo && _previewUsingMedia3,
                              controller: _previewController,
                              appleTvTextureId:
                                  showPreviewVideo && _previewUsingAppleTv
                                  ? _appleTvPreviewPlayer?.textureId
                                  : null,
                              isFocused: isFocused,
                              focusColor: focusColor,
                            );

                      if (isRowsV2) {
                        final rowController = _rowHorizontalController(
                          rowIndex,
                        );
                        return ModernExpandingCard(
                          card: previewWrappedCard,
                          prefs: prefs,
                          details: effectiveV2Focused
                              ? ModernHoverBuilder(
                                  expansion: _v2Expansion,
                                  cardKey: previewKey,
                                  controller: rowController,
                                  builder: (context, hovered) =>
                                      _buildV2ExtendedSection(
                                        item,
                                        // Ratings are cached under the global item key,
                                        // so look them up without the row index.
                                        _previewKeyFor(item),
                                        cardWidth: width,
                                        detailsWidth: modernDetailsWidth(
                                          controller: rowController,
                                          index: idx,
                                          itemCount: row.items.length,
                                          itemExtent: firstCardWidth,
                                          itemSpacing: itemSpacing,
                                          focusedWidth: width,
                                          maxWidth: v2ExtendedWidth,
                                          leadingInset: _kHomeRowLabelInset,
                                          trailingInset: _kHomeRowTrailingInset,
                                          hovered: hovered,
                                        ),
                                        isAudioRow: row.isAudio,
                                      ),
                                )
                              : null,
                        );
                      }

                      return previewWrappedCard;
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildV2ExtendedSection(
    AggregatedItem item,
    String itemKey, {
    required double cardWidth,
    required double detailsWidth,
    required bool isAudioRow,
  }) {
    return ValueListenableBuilder<Map<String, Map<String, double>>>(
      valueListenable: _v2AdditionalRatingsNotifier,
      builder: (context, ratingsByKey, _) => ModernCardDetails(
        prefs: widget.prefs,
        ratingSettings: UserPreferences.homeRowsRatings,
        cardWidth: cardWidth,
        detailsWidth: detailsWidth,
        overview: isAudioRow ? null : item.overview,
        communityRating: item.communityRating,
        criticRating: item.criticRating,
        personalRating: item.personalRating,
        additionalRatings: ratingsByKey[itemKey] ?? const {},
      ),
    );
  }

  static String _v2MetadataLine(AggregatedItem item) {
    final parts = <String>[];
    if (item.type == 'MusicAlbum' || item.type == 'Audio') {
      final artist = (item.albumArtist ?? '').trim().isNotEmpty
          ? item.albumArtist!.trim()
          : (item.albumArtists.isNotEmpty
                ? (item.albumArtists.first['Name'] as String?)?.trim()
                : (item.artists.isNotEmpty ? item.artists.first.trim() : ''));
      final year = item.productionYear;
      if (artist != null && artist.isNotEmpty) {
        if (year != null) {
          parts.add('$artist ($year)');
        } else {
          parts.add(artist);
        }
      } else if (year != null) {
        parts.add('$year');
      }
    } else {
      final year = item.productionYear;
      if (year != null) {
        parts.add('$year');
      }
    }
    final genreLabel = item.genres.take(2).join(' • ');
    if (genreLabel.isNotEmpty) {
      parts.add(genreLabel);
    }

    final runtimeLabel = _formatRuntime(item.runtime);
    if (runtimeLabel.isNotEmpty) {
      parts.add(runtimeLabel);
    }

    return parts.join(' • ');
  }

  static String _formatRuntime(Duration? runtime) {
    if (runtime == null || runtime <= Duration.zero) {
      return '';
    }

    final totalMinutes = runtime.inMinutes;
    if (totalMinutes <= 0) {
      return '';
    }

    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    if (hours <= 0) {
      return '${minutes}m';
    }
    if (minutes == 0) {
      return '${hours}h';
    }
    return '${hours}h ${minutes}m';
  }


  List<Widget> _buildWatchingNowOverlays(
    AggregatedItem item,
    AppLocalizations l10n,
  ) {
    final rank = (item.rawData['Rank'] ?? item.rawData['WatchingNowRank'])?.toString() ?? '';
    final mediaType = (item.rawData['MediaType'] ?? item.rawData['WatchingNowType']) as String? ?? 'movie';
    final watchers = (item.rawData['Watchers'] ?? item.rawData['WatchingNowWatchers']) as int? ?? 0;
    final logoUrl = (item.rawData['LogoUrl'] ?? item.rawData['LogoPath']) as String?;

    return [
      Positioned.fill(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.25),
                Colors.transparent,
                Colors.black.withValues(alpha: 0.85),
              ],
              stops: const [0.0, 0.4, 1.0],
            ),
          ),
        ),
      ),
      if (rank.isNotEmpty)
        Positioned(
          top: 10,
          left: 12,
          child: Text(
            rank,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
              shadows: [
                Shadow(blurRadius: 6, color: Colors.black),
                Shadow(blurRadius: 12, color: Colors.black87),
              ],
            ),
          ),
        ),
      Positioned(
        top: 10,
        right: 12,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.white24, width: 0.5),
          ),
          child: Text(
            mediaType.toUpperCase(),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ),
      ),
      Positioned(
        left: 14,
        right: 14,
        bottom: 26,
        height: 44,
        child: (logoUrl != null && logoUrl.isNotEmpty)
            ? Align(
                alignment: Alignment.bottomCenter,
                child: Semantics(
                  label: item.name,
                  child: BoundedNetworkImage(
                    imageUrl: logoUrl,
                    fit: BoxFit.contain,
                    maxWidth: 300,
                    errorBuilder: (_, _, _) => Align(
                      alignment: Alignment.bottomCenter,
                      child: Text(
                        item.name,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          shadows: [
                            Shadow(blurRadius: 6, color: Colors.black),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              )
            : Align(
                alignment: Alignment.bottomCenter,
                child: Text(
                  item.name,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    shadows: [
                      Shadow(blurRadius: 6, color: Colors.black),
                    ],
                  ),
                ),
              ),
      ),
      Positioned(
        left: 12,
        bottom: 8,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                color: Color(0xFF22C55E),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Color(0x8822C55E),
                    blurRadius: 4,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Text(
              l10n.watchingNowWatchersCount(watchers),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                shadows: [
                  Shadow(blurRadius: 4, color: Colors.black),
                ],
              ),
            ),
          ],
        ),
      ),
    ];
  }

  Widget _buildWatchingNowSubtitle(BuildContext context, String subtitle) {
    return Text(
      subtitle,
      style: TextStyle(
        fontSize: 13.0,
        fontWeight: FontWeight.w700,
        color: AppColorScheme.onSurface.withValues(alpha: 0.95),
      ),
    );
  }

  Widget _buildTitledRow({
    Key? key,
    required String title,
    String? subtitle,
    bool isWatchingNow = false,
    required int rowIndex,
    required bool hasItems,
    required double height,
    required Widget child,
  }) {
    final isRowsV2 = _isHomeRowsStyleV2();
    final showHeaderControls =
        hasItems && PlatformDetection.useDesktopUi && !PlatformDetection.isTV;
    return RepaintBoundary(
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        clipBehavior: Clip.none,
        child: Column(
          key: key,
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
Padding(
              padding: EdgeInsets.fromLTRB(
                _kHomeRowLabelInset,
                _isCompactClassicMode ? 4.0 : _rowHeaderPaddingTop(isRowsV2),
                8,
                isWatchingNow ? 12.0 : (isRowsV2 ? 1.0 : (_isCompactClassicMode ? 2.0 : 8.0)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (isWatchingNow) ...[
                              Icon(
                                Icons.public,
                                size: 18,
                                color: AppColorScheme.onSurface,
                              ),
                              const SizedBox(width: 6),
                            ],
                            Flexible(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  color: AppColorScheme.onSurface,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (subtitle != null && subtitle.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isWatchingNow) ...[
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFF22C55E),
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: Color(0xAA22C55E),
                                        blurRadius: 5,
                                        spreadRadius: 1.5,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 6),
                              ],
                              Flexible(
                                child: isWatchingNow
                                    ? _buildWatchingNowSubtitle(context, subtitle)
                                    : Text(
                                        subtitle,
                                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: AppColorScheme.onSurface.withValues(
                                            alpha: 0.8,
                                          ),
                                        ),
                                      ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (showHeaderControls) ...[
                    Focus(
                      canRequestFocus: false,
                      skipTraversal: true,
                      descendantsAreFocusable: false,
                      child: IconButton(
                        icon: const Icon(Icons.chevron_left),
                        onPressed: () =>
                            _scrollHomeRowHorizontal(rowIndex, -480),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    Focus(
                      canRequestFocus: false,
                      skipTraversal: true,
                      descendantsAreFocusable: false,
                      child: IconButton(
                        icon: const Icon(Icons.chevron_right),
                        onPressed: () =>
                            _scrollHomeRowHorizontal(rowIndex, 480),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            child,
          ],
        ),
      ),
    );
  }

  static IconData _iconForCollectionType(String collectionType) {
    return switch (collectionType) {
      'movies' => Icons.movie,
      'tvshows' => Icons.tv,
      'music' => Icons.music_note,
      'books' => Icons.book,
      'photos' => Icons.photo,
      'homevideos' => Icons.videocam,
      'livetv' => Icons.live_tv,
      'playlists' => Icons.playlist_play,
      'boxsets' => Icons.collections_bookmark,
      _ => Icons.folder_rounded,
    };
  }

  static bool _isSeerrFilterRow(HomeRow row) =>
      row.id == 'seerr_shortcuts' ||
      row.id == 'seerr_movie_genres' ||
      row.id == 'seerr_series_genres' ||
      row.id == 'seerr_studios' ||
      row.id == 'seerr_networks';

  /// Rows whose artwork is a wide logo rather than cover art. The modern style
  /// draws every card portrait, which crops those, so these rows stay on the
  /// classic layout whichever style is picked.
  static bool _isWideArtworkRow(HomeRow row) =>
      _isSeerrFilterRow(row) ||
      row.id == 'mdblist_watching_now' ||
      (row.rowType == HomeRowType.studios && row.id == 'studios');

  static bool _isRowModern(HomeRow row, UserPreferences prefs) {
    if (prefs.get(UserPreferences.homeRowsStyle) != HomeRowsStyle.v2) {
      return false;
    }
    if (_isWideArtworkRow(row)) {
      return false;
    }
    return true;
  }

  static bool _isModernMyMediaStatic(HomeRow row, UserPreferences prefs) {
    return _isRowModern(row, prefs) &&
        (row.rowType == HomeRowType.libraryTiles ||
            row.rowType == HomeRowType.libraryTilesSmall) &&
        !prefs.get(UserPreferences.modernCardsOnMyMediaRow);
  }

  static String? _seerrTmdbImageUrl(String? path, int width) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http')) return path;
    return 'https://image.tmdb.org/t/p/w$width$path';
  }

  static String? _seerrThumbUrl(AggregatedItem item) => seerrThumbUrl(
    type: item.seerrMediaType,
    tmdbId: item.tmdbId ?? (int.tryParse(item.id) != null ? item.id : null),
    imdbId: item.imdbId,
  );

  static void _navigateToSeerrItem(BuildContext context, AggregatedItem item) {
    final shortcut = SeerrShortcut.fromName(
      item.rawData['SeerrShortcut'] as String?,
    );
    if (shortcut != null) {
      shortcut.open(context);
      return;
    }
    final filterType = item.rawData['FilterType'] as String?;
    if (filterType != null) {
      final mediaType = item.rawData['MediaType'] as String? ?? 'movie';
      final filterName = item.rawData['FilterName'] as String? ?? item.name;
      final uri = Uri(
        path: Destinations.seerrBrowse,
        queryParameters: {
          'filterId': item.id,
          'filterName': filterName,
          'mediaType': mediaType,
          'filterType': filterType,
        },
      );
      context.push(uri.toString());
    } else {
      final mediaType = item.type == 'Series' || item.type == 'tv'
          ? 'tv'
          : 'movie';
      // External rows key their items by IMDb id where they have one, which
      // Seerr can only resolve by searching, and a search can land on the
      // wrong title. The TMDB id these items also carry names exactly one.
      final tmdbId = item.tmdbId;
      context.push(
        Destinations.seerrMedia(
          tmdbId != null && tmdbId.isNotEmpty ? tmdbId : item.id,
          mediaType: mediaType,
          title: item.name,
        ),
      );
    }
  }

  static bool _isContinueWatchingOrNextUp(HomeRow row) =>
      row.rowType == HomeRowType.resume || row.rowType == HomeRowType.nextUp;

  /// Plays a Continue Watching or Next Up card when the user set those rows
  /// to play on select, and says whether it did.
  bool _playedOnSelect(HomeRow row, AggregatedItem item) {
    if (!_isContinueWatchingOrNextUp(row) ||
        widget.prefs.get(UserPreferences.continueWatchingDefaultAction) !=
            ContinueWatchingDefaultAction.play) {
      return false;
    }
    context.push(
      Destinations.item(item.id, serverId: item.serverId, autoPlay: true),
    );
    return true;
  }

  static void _navigateToLibrary(BuildContext context, AggregatedItem item) {
    // Game libraries route to the EmulatorJS browser, everything else by its
    // collection type. Shared with the sidebar, toolbar and bottom nav.
    context.push(
      libraryRoute(
        item.id,
        item.rawData['CollectionType'] as String?,
        item.name,
        serverId: item.serverId,
      ),
    );
  }

  static String? _resolveImageUrl(
    AggregatedItem item,
    ImageApi imageApi,
    double height,
    bool useSeriesThumbs,
    double requestScale, {
    bool includeExternal = true,
  }) {
    final maxH = artworkRequestWidth(height, requestScale, ArtworkShape.poster);
    if (useSeriesThumbs && item.type == 'Episode') {
      final sId = item.seriesId ?? item.parentPrimaryImageItemId;
      final sTag = item.seriesPrimaryImageTag ?? item.parentPrimaryImageTag;
      if (sId != null) {
        return imageApi.getPrimaryImageUrl(sId, maxHeight: maxH, tag: sTag);
      }
    }
    return _resolvePrimaryImageUrl(
      item,
      imageApi,
      maxHeight: maxH,
      includeExternal: includeExternal,
    );
  }

  static String? _resolvePrimaryImageUrl(
    AggregatedItem item,
    ImageApi imageApi, {
    int? maxHeight,
    int? maxWidth,
    bool includeExternal = true,
  }) {
    String? primary(String? id, String? tag) {
      if (id == null || tag == null) return null;
      return imageApi.getPrimaryImageUrl(
        id,
        maxHeight: maxHeight,
        maxWidth: maxWidth,
        tag: tag,
      );
    }

    // Better Posters (btttr.cc) wins for home rows when an external id is
    // available. Checked before any server artwork so known movies, series
    // and seasons (and episodes via their series) never show the server
    // default. Detail pages do not call this path, so they keep server art.
    // Skipped when resolving the server fallback twin (see
    // `_unfocusedCardImage`), which is what paints underneath while the
    // external poster is still rendering (or when btttr.cc has none).
    final externalPoster = includeExternal
        ? BetterPostersService.posterUrlFor(item)
        : null;
    if (externalPoster != null) return externalPoster;
    // Items that borrow another item's art (genre tiles, inherited primary
    // ids) resolve the borrowed id against the registry as well.
    for (final borrowedId in [
      item.primaryImageItemId,
      item.parentPrimaryImageItemId,
    ]) {
      if (borrowedId != null && borrowedId.isNotEmpty) {
        final borrowed = includeExternal
            ? BetterPostersService.urlForId(borrowedId)
            : null;
        if (borrowed != null) return borrowed;
      }
    }

    if (item.type == 'Genre' || item.type == 'MusicGenre') {
      final primaryAr = item.rawData['PrimaryImageAspectRatio'] as num?;
      if (primaryAr == null || primaryAr >= 1.0) {
        final repUrl = primary(
          item.primaryImageItemId,
          item.primaryImageTagField,
        );
        if (repUrl != null) return repUrl;
      }
    }

    return primary(item.id, item.primaryImageTag) ??
        primary(item.primaryImageItemId, item.primaryImageTagField) ??
        primary(item.parentPrimaryImageItemId, item.parentPrimaryImageTag);
  }

  static String? _resolveLandscapeImageUrl(
    AggregatedItem item,
    ImageApi imageApi,
    double height,
    double requestScale,
  ) {
    final maxW = artworkRequestWidth(
      height * 16 / 9,
      requestScale,
      ArtworkShape.landscape,
    );
    if (item.backdropImageTags.isNotEmpty) {
      return imageApi.getBackdropImageUrl(
        item.id,
        maxWidth: maxW,
        tag: item.backdropImageTags.first,
      );
    }
    if (item.type != 'Video' && item.type != 'MusicVideo') {
      final parentId = item.parentBackdropItemId;
      final parentTags = item.parentBackdropImageTags;
      if (parentId != null && parentTags.isNotEmpty) {
        return imageApi.getBackdropImageUrl(
          parentId,
          maxWidth: maxW,
          tag: parentTags.first,
        );
      }
    }
    return _resolvePrimaryImageUrl(item, imageApi, maxWidth: maxW);
  }

  /// Whether a stored path already points at artwork. External rows hold either
  /// a TMDB path or a full URL, and both mean there is nothing to look up.
  static bool _hasSeerrBackdrop(String? path) =>
      path != null && (path.startsWith('/') || path.startsWith('http'));

  void _fetchBackdropIfNeeded(AggregatedItem item) async {
    if (item.serverId != 'seerr') return;
    if (_hasSeerrBackdrop(item.rawData['BackdropPath'] as String?)) return;
    if (_dynamicBackdrops.containsKey(item.id)) return;
    if (!_fetchingBackdrops.add(item.id)) return;

    try {
      final repo = await GetIt.instance.getAsync<SeerrRepository>();
      await repo.ensureInitialized();

      final title = item.rawData['Name'] as String?;
      final searchPage = await repo.search(
        title != null && title.isNotEmpty ? title : item.id,
      );
      if (searchPage.results.isNotEmpty) {
        final year = item.rawData['ProductionYear'] as int?;
        var matchedItem = searchPage.results.first;
        if (year != null) {
          for (final result in searchPage.results) {
            final resultYearStr = result.releaseDate ?? result.firstAirDate;
            if (resultYearStr != null && resultYearStr.length >= 4) {
              final resultYear = int.tryParse(resultYearStr.substring(0, 4));
              if (resultYear == year) {
                matchedItem = result;
                break;
              }
            }
          }
        }
        if (matchedItem.backdropPath != null &&
            matchedItem.backdropPath!.isNotEmpty) {
          if (mounted) {
            setState(() {
              _dynamicBackdrops[item.id] = matchedItem.backdropPath!;
            });
          }
        }
      }
    } catch (e) {
      debugPrint('[HomeScreen] Failed to fetch backdrop for ${item.id}: $e');
    } finally {
      _fetchingBackdrops.remove(item.id);
    }
  }

  String? _resolveV2FocusedImageUrl(
    AggregatedItem item,
    ImageApi imageApi,
    double height,
    bool useSeriesThumbs,
    double requestScale, {
    bool isPrefetch = false,
  }) {
    if (item.type == 'Genre' || item.type == 'MusicGenre') {
      final parentBackdropItemId = item.parentBackdropItemId;
      final parentBackdropTags = item.parentBackdropImageTags;
      final maxW = artworkRequestWidth(
        height * 16 / 9,
        requestScale,
        ArtworkShape.landscape,
      );
      if (parentBackdropItemId != null && parentBackdropTags.isNotEmpty) {
        return imageApi.getBackdropImageUrl(
          parentBackdropItemId,
          maxWidth: maxW,
          tag: parentBackdropTags.first,
        );
      }
    }

    if (item.serverId == 'seerr') {
      final thumb = _seerrThumbUrl(item);
      if (thumb != null) return thumb;
      if (!isPrefetch) {
        _fetchBackdropIfNeeded(item);
      }
      final dynamicBackdrop = _dynamicBackdrops[item.id];
      if (dynamicBackdrop != null) {
        return _seerrTmdbImageUrl(dynamicBackdrop, 1280);
      }
      final backdrop = item.rawData['BackdropPath'] as String?;
      if (_hasSeerrBackdrop(backdrop)) {
        return _seerrTmdbImageUrl(backdrop, 1280);
      }
      return _seerrTmdbImageUrl(item.rawData['PosterPath'] as String?, 300);
    }
    final maxW = artworkRequestWidth(
      height * 16 / 9,
      requestScale,
      ArtworkShape.landscape,
    );
    final maxH = artworkRequestWidth(height, requestScale, ArtworkShape.poster);
    if (!useSeriesThumbs) {
      if (item.type == 'Episode') {
        final episodePrimary = _resolvePrimaryImageUrl(
          item,
          imageApi,
          maxHeight: maxH,
          maxWidth: maxW,
        );
        if (episodePrimary != null) {
          return episodePrimary;
        }
      }
    }
    final itemThumbTag = _tagForType(item, 'Thumb');
    if (itemThumbTag != null) {
      return imageApi.getThumbImageUrl(
        item.id,
        maxWidth: maxW,
        tag: itemThumbTag,
      );
    }

    final parentThumbItemId = item.rawData['ParentThumbItemId']?.toString();
    final parentThumbTag = item.rawData['ParentThumbImageTag'] as String?;
    if (parentThumbItemId != null && parentThumbTag != null) {
      return imageApi.getThumbImageUrl(
        parentThumbItemId,
        maxWidth: maxW,
        tag: parentThumbTag,
      );
    }

    if (item.backdropImageTags.isNotEmpty) {
      return imageApi.getBackdropImageUrl(
        item.id,
        maxWidth: maxW,
        tag: item.backdropImageTags.first,
      );
    }

    final parentBackdropItemId = item.parentBackdropItemId;
    final parentBackdropTags = item.parentBackdropImageTags;
    if (parentBackdropItemId != null && parentBackdropTags.isNotEmpty) {
      return imageApi.getBackdropImageUrl(
        parentBackdropItemId,
        maxWidth: maxW,
        tag: parentBackdropTags.first,
      );
    }

    return _resolvePrimaryImageUrl(
      item,
      imageApi,
      maxHeight: maxH,
      maxWidth: maxW,
    );
  }

  static ImageType _homeRowImageTypeForRow(HomeRow row, UserPreferences prefs) {
    if (row.isAudio) {
      return ImageType.poster;
    }
    if (_isSeerrFilterRow(row)) {
      return ImageType.thumb;
    }
    if (row.rowType == HomeRowType.latestMedia && _isLatestMusicRow(row)) {
      return ImageType.poster;
    }

    if (prefs.get(UserPreferences.homeRowsUniversalOverride)) {
      return prefs.get(UserPreferences.homeRowsUniversalImageType);
    }

    final sectionType = _sectionTypeForRow(row, prefs);
    if (sectionType == null) {
      return ImageType.poster;
    }
    return prefs.get(UserPreferences.homeRowImageType(sectionType));
  }

  static HomeSectionType? _sectionTypeForRow(
    HomeRow row,
    UserPreferences prefs,
  ) => HomeViewModel.sectionConfigForRow(row, prefs.homeSectionsConfig)?.type;

  static bool _isLatestMusicRow(HomeRow row) {
    if (row.rowType != HomeRowType.latestMedia || row.items.isEmpty) {
      return false;
    }
    return row.items.every(
      (item) =>
          item.type == 'Audio' ||
          item.type == 'MusicAlbum' ||
          item.type == 'MusicArtist',
    );
  }

  /// The image an unfocused card in [row] paints for [item], with the width
  /// it paints it at. The item builder and the row prefetch both read this,
  /// so the prefetch always warms the entry the card looks up.
  /// Pairs an external (btttr.cc) primary URL with its server fallback for
  /// [MediaCard.fallbackImageUrl]: the server poster paints instantly and
  /// stays if the external poster is slow or missing. Null when there is
  /// nothing to fall back to (or from).
  static String? _fallbackFor(String? primary, String? server) {
    if (primary == null || server == null || primary == server) return null;
    return server;
  }

  ({String? url, String? fallbackUrl, double width, double aspectRatio})
  _unfocusedCardImage(
    HomeRow row,
    AggregatedItem item, {
    required UserPreferences prefs,
    required PosterSize posterSize,
    required bool useSeriesThumbs,
    required double requestScale,
  }) {
    final imageApi = widget.viewModel.imageApiForServer(item.serverId);
    final isRowsV2 = _isRowModern(row, prefs);
    final isModernMyMediaStatic = _isModernMyMediaStatic(row, prefs);
    final rowImageType = _isSeerrFilterRow(row)
        ? ImageType.thumb
        : (isRowsV2
              ? (isModernMyMediaStatic ? ImageType.thumb : ImageType.poster)
              : _homeRowImageTypeForRow(row, prefs));
    final platformScale = _rowPlatformScale(_desktopUiScaleFactor());
    final isMyMediaRow = row.rowType == HomeRowType.libraryTiles;
    if (row.id == 'mdblist_watching_now') {
      final height = posterSize.landscapeHeight.toDouble() * platformScale;
      return (
        url: item.rawData['BackdropPath'] as String?,
        width: height * (16 / 9),
        aspectRatio: 16 / 9,
      );
    }
    if (isRowsV2 && !isModernMyMediaStatic) {
      final v2ImageHeight = modernImageHeight(posterSize, platformScale);
      final aspect = row.isAudio ? 1.0 : 2 / 3;
      final url = _cachedRowImageUrl(
        item,
        imageApi,
        v2ImageHeight,
        ImageType.poster,
        item.type == 'Episode' ? true : useSeriesThumbs,
        requestScale,
        isMyMediaRow: isMyMediaRow,
      );
      final fallbackUrl = _cachedRowImageUrl(
        item,
        imageApi,
        v2ImageHeight,
        ImageType.poster,
        item.type == 'Episode' ? true : useSeriesThumbs,
        requestScale,
        isMyMediaRow: isMyMediaRow,
        includeExternal: false,
      );
      return (
        url: url,
        fallbackUrl: _fallbackFor(url, fallbackUrl),
        width: v2ImageHeight * aspect,
        aspectRatio: aspect,
      );
    }
    final ar = _aspectRatioForRowItem(item, row, rowImageType);
    final height =
        (ar > 1
            ? posterSize.landscapeHeight.toDouble()
            : posterSize.portraitHeight.toDouble()) *
        platformScale;
    final url = _cachedRowImageUrl(
      item,
      imageApi,
      height,
      rowImageType,
      useSeriesThumbs,
      requestScale,
      isMyMediaRow: isMyMediaRow,
    );
    final fallbackUrl = _cachedRowImageUrl(
      item,
      imageApi,
      height,
      rowImageType,
      useSeriesThumbs,
      requestScale,
      isMyMediaRow: isMyMediaRow,
      includeExternal: false,
    );
    return (
      url: url,
      fallbackUrl: _fallbackFor(url, fallbackUrl),
      width: height * ar,
      aspectRatio: ar,
    );
  }

  void _scheduleRowPrefetch() {
    if (!mounted || _isBackgrounded) return;
    _loadSectionsNearViewport();
    _rowPrefetchDebounce?.cancel();
    _rowPrefetchDebounce = Timer(_rowPrefetchDelay, _runRowPrefetch);
  }

  /// Loads the deferred sections of the rows from a screen above the viewport
  /// to two screens below it. Not debounced, so a held key or a fling keeps
  /// loading ahead instead of waiting for the list to stop.
  void _loadSectionsNearViewport() {
    final viewModel = widget.viewModel;
    if (!viewModel.hasDeferredSections || !_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    final from = position.pixels - position.viewportDimension;
    final to = position.pixels + 2 * position.viewportDimension;
    final rows = viewModel.rows;
    final tops = _rowTopOffsets;
    final extents = _rowExtents;
    viewModel.loadSectionsNear([
      for (var i = 0; i < rows.length && i < tops.length; i++)
        if (tops[i] < to && tops[i] + extents[i] > from) rows[i],
    ]);
  }

  void _runRowPrefetch() {
    _rowPrefetchDebounce = null;
    if (!mounted) return;
    final prefs = widget.prefs;
    final connectivity = GetIt.instance.isRegistered<ConnectivityService>()
        ? GetIt.instance<ConnectivityService>()
        : null;
    final budget = rowPrefetchBudget(
      tier: prefs.resolveDevicePerformanceTier(),
      canReachServer: connectivity?.canReachServer ?? true,
      isBackgrounded: _isBackgrounded,
      cellularOnly: connectivity?.isCellularOnly ?? false,
    );
    if (budget == null) return;

    final rows = widget.viewModel.rows;
    if (rows.isEmpty) return;
    final posterSize = _homePosterSize();
    final useSeriesThumbs = prefs.get(UserPreferences.seriesThumbnailsEnabled);
    final requestScale = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.0);
    final viewportWidth = MediaQuery.sizeOf(context).width;

    bool isMediaRow(HomeRow row) =>
        !row.isLoading &&
        row.items.isNotEmpty &&
        row.rowType != HomeRowType.liveTv &&
        row.rowType != HomeRowType.libraryTilesSmall;

    ({String? url, String? fallbackUrl, double width, double aspectRatio})
    imageOf(HomeRow row, AggregatedItem item) => _unfocusedCardImage(
      row,
      item,
      prefs: prefs,
      posterSize: posterSize,
      useSeriesThumbs: useSeriesThumbs,
      requestScale: requestScale,
    );

    final targets = homeRowPrefetchTargets(
      rowCount: rows.length,
      fromRow: _activeFocusedRowIndex ?? 0,
      rowsAhead: budget.rowsAhead,
      visibleCards: (index) => visibleCardsFor(
        viewportWidth: viewportWidth,
        cardWidth: imageOf(rows[index], rows[index].items.first).width,
        spacing: _rowPrefetchCardSpacing,
      ),
      extraCards: budget.extraCards,
      isRowReady: (index) => isMediaRow(rows[index]),
      itemCount: (index) => rows[index].items.length,
    );
    if (_rowPrefetchedUrls.length > 800) _rowPrefetchedUrls.clear();

    for (final target in targets) {
      final row = rows[target.row];
      for (final item in row.items.take(target.count)) {
        final image = imageOf(row, item);
        final url = image.url;
        if (url == null || !_rowPrefetchedUrls.add(url)) continue;
        if (_rowPrefetchInFlight >= _rowPrefetchMaxInFlight) return;
        _rowPrefetchInFlight++;
        unawaited(
          ArtworkDecode.precache(
            context,
            url,
            layoutWidth: image.width,
            maxWidth: MediaCard.decodeMaxWidthFor(image.aspectRatio),
            priority: ImageFetchPriority.low,
          ).whenComplete(() => _rowPrefetchInFlight--).catchError((_) {
            _rowPrefetchedUrls.remove(url);
          }),
        );
      }
    }
  }

  /// What keeps a card's element across a page append. Server and id
  /// together, since a multi-server home can list the same id twice.
  static Object _rowItemIdentity(AggregatedItem item, int index) =>
      '${item.serverId}|${item.id}';

  static double _aspectRatioForRowItem(
    AggregatedItem item,
    HomeRow row,
    ImageType imageType,
  ) {
    if (row.id == 'mdblist_watching_now') {
      return 16 / 9;
    }
    if (row.isAudio) {
      return 1.0;
    }
    if (row.rowType == HomeRowType.liveTvFavorites) {
      return 1.0;
    }
    if (_isSeerrFilterRow(row)) {
      return 16 / 9;
    }
    double thumbAspectRatio() {
      return switch (item.type) {
        'MusicAlbum' || 'MusicArtist' || 'Audio' || 'Playlist' || 'Person' => 1,
        _ => 16 / 9,
      };
    }

    return switch (imageType) {
      ImageType.thumb => thumbAspectRatio(),
      ImageType.banner => kBannerAspectRatio,
      ImageType.poster => switch (item.type) {
        'MusicAlbum' ||
        'MusicArtist' ||
        'Audio' ||
        'Playlist' ||
        'Person' => 1.0,
        'Studio' || 'Network' => 16 / 9,
        _ => 2 / 3,
      },
    };
  }

  static String? _resolveRowImageUrl(
    AggregatedItem item,
    ImageApi imageApi,
    double height,
    ImageType imageType,
    bool useSeriesThumbs,
    double requestScale, {
    bool isMyMediaRow = false,
    bool includeExternal = true,
  }) {
    if (imageType == ImageType.poster && isMyMediaRow) {
      final primaryAr = item.rawData['PrimaryImageAspectRatio'] as num?;
      if (primaryAr != null && primaryAr >= 1.0) {
        return null;
      }
    }

    if (item.type == 'Studio' || item.type == 'Network') {
      final primaryUrl = _resolvePrimaryImageUrl(
        item,
        imageApi,
        maxHeight: artworkRequestWidth(
          height,
          requestScale,
          ArtworkShape.poster,
        ),
        maxWidth: artworkRequestWidth(
          height * 16 / 9,
          requestScale,
          ArtworkShape.landscape,
        ),
        includeExternal: includeExternal,
      );
      if (primaryUrl != null) return primaryUrl;
    }

    if (item.serverId == 'seerr') {
      // Better Posters wins for external poster rows when an IMDb id is
      // available (btttr.cc only resolves IMDb); thumb/banner rows keep
      // TMDB landscape art since btttr.cc only provides portrait posters.
      // Render-time (not stored) so toggling the feature applies instantly.
      // Skipped for the server fallback twin (see `_unfocusedCardImage`).
      if (includeExternal &&
          BetterPostersService.enabled &&
          imageType == ImageType.poster) {
        final external = BetterPostersService.buildUrl(item);
        if (external != null) return external;
      }
      final backdrop = _seerrTmdbImageUrl(
        item.rawData['BackdropPath'] as String?,
        1280,
      );
      final poster = _seerrTmdbImageUrl(
        item.rawData['PosterPath'] as String?,
        300,
      );
      if (imageType == ImageType.thumb) {
        return _seerrThumbUrl(item) ?? backdrop ?? poster;
      }
      if (imageType == ImageType.banner) return backdrop ?? poster;
      return poster ?? backdrop;
    }

    if (Destinations.isLiveTvChannelType(item.type)) {
      final logoTag = item.logoImageTag;
      if (logoTag != null) {
        return imageApi.getLogoImageUrl(
          item.id,
          maxWidth: artworkRequestWidth(
            height,
            requestScale,
            ArtworkShape.poster,
          ),
          tag: logoTag,
        );
      }
    }

    final itemThumbTag = _tagForType(item, 'Thumb');
    final itemBannerTag = _tagForType(item, 'Banner');
    final parentThumbItemId = item.rawData['ParentThumbItemId']?.toString();
    final parentThumbTag = item.rawData['ParentThumbImageTag'] as String?;

    // Episodes have no poster of their own, so a poster row falls back to the
    // series poster even when the series-thumb preference is off.
    if (item.type == 'Episode' &&
        (useSeriesThumbs || imageType == ImageType.poster)) {
      // A portrait btttr.cc poster wins on poster rows when the parent
      // series is registered; thumb/banner rows keep landscape server art
      // (btttr.cc only provides portrait posters).
      if (includeExternal && imageType == ImageType.poster) {
        final external = BetterPostersService.posterUrlFor(item);
        if (external != null) return external;
      }
      final seriesImage = _resolveSeriesImageForRowType(
        item,
        imageApi,
        height,
        imageType,
        requestScale,
      );
      if (seriesImage != null) {
        return seriesImage;
      }
    }

    if (imageType == ImageType.banner) {
      // Ask for the banner ratio. At 16/9 the artwork comes back about three
      // times too narrow for the card and has to be upscaled.
      final maxW = artworkRequestWidth(
        height * kBannerAspectRatio,
        requestScale,
        ArtworkShape.landscape,
      );
      if (isMyMediaRow) {
        final myMediaPrimary = _resolvePrimaryImageUrl(
          item,
          imageApi,
          maxWidth: maxW,
        );
        if (myMediaPrimary != null) {
          return myMediaPrimary;
        }
      }
      if (itemBannerTag != null) {
        return imageApi.getBannerImageUrl(
          item.id,
          maxWidth: maxW,
          tag: itemBannerTag,
        );
      }
      if (itemThumbTag != null) {
        return imageApi.getThumbImageUrl(
          item.id,
          maxWidth: maxW,
          tag: itemThumbTag,
        );
      }
      if (item.backdropImageTags.isNotEmpty) {
        return imageApi.getBackdropImageUrl(
          item.id,
          maxWidth: maxW,
          tag: item.backdropImageTags.first,
        );
      }
      return _resolveImageUrl(
        item,
        imageApi,
        height,
        useSeriesThumbs,
        requestScale,
      );
    }

    if (imageType == ImageType.thumb) {
      final maxW = artworkRequestWidth(
        height * 16 / 9,
        requestScale,
        ArtworkShape.landscape,
      );
      final maxH = artworkRequestWidth(
        height,
        requestScale,
        ArtworkShape.poster,
      );
      if (!useSeriesThumbs ||
          item.type == 'Video' ||
          item.type == 'MusicVideo') {
        if (item.type == 'Episode' ||
            item.type == 'Video' ||
            item.type == 'MusicVideo') {
          final videoPrimary = _resolvePrimaryImageUrl(
            item,
            imageApi,
            maxHeight: maxH,
            maxWidth: maxW,
          );
          if (videoPrimary != null) {
            return videoPrimary;
          }
        }
      }
      if (itemThumbTag != null) {
        return imageApi.getThumbImageUrl(
          item.id,
          maxWidth: maxW,
          tag: itemThumbTag,
        );
      }
      if (item.backdropImageTags.isNotEmpty) {
        return imageApi.getBackdropImageUrl(
          item.id,
          maxWidth: maxW,
          tag: item.backdropImageTags.first,
        );
      }
      if (useSeriesThumbs || item.type != 'Episode') {
        if (parentThumbItemId != null && parentThumbTag != null) {
          return imageApi.getThumbImageUrl(
            parentThumbItemId,
            maxWidth: maxW,
            tag: parentThumbTag,
          );
        }
        if (item.parentBackdropItemId != null &&
            item.parentBackdropImageTags.isNotEmpty) {
          return imageApi.getBackdropImageUrl(
            item.parentBackdropItemId!,
            maxWidth: maxW,
            tag: item.parentBackdropImageTags.first,
          );
        }
      }
      return _resolveLandscapeImageUrl(item, imageApi, height, requestScale);
    }

    return _resolveImageUrl(
      item,
      imageApi,
      height,
      useSeriesThumbs,
      requestScale,
      includeExternal: includeExternal,
    );
  }

  static String? _resolveSeriesImageForRowType(
    AggregatedItem item,
    ImageApi imageApi,
    double height,
    ImageType imageType,
    double requestScale,
  ) {
    // The banner branch below shares this width, so it has to account for the
    // banner ratio or that artwork comes back too narrow.
    final maxW =
        (height *
                (imageType == ImageType.banner ? kBannerAspectRatio : 16 / 9) *
                requestScale)
            .toInt();
    final maxH = artworkRequestWidth(height, requestScale, ArtworkShape.poster);
    final seriesId = item.seriesId;
    final seriesPrimaryTag = item.seriesPrimaryImageTag;
    final parentThumbItemId = item.rawData['ParentThumbItemId']?.toString();
    final parentThumbTag = item.rawData['ParentThumbImageTag'] as String?;
    final parentBackdropItemId = item.parentBackdropItemId;
    final parentBackdropTags = item.parentBackdropImageTags;

    if (imageType == ImageType.poster) {
      final sId = seriesId ?? item.parentPrimaryImageItemId;
      final sTag = seriesPrimaryTag ?? item.parentPrimaryImageTag;
      if (sId != null) {
        return imageApi.getPrimaryImageUrl(sId, maxHeight: maxH, tag: sTag);
      }
      return null;
    }

    if (imageType == ImageType.thumb) {
      if (parentThumbItemId != null && parentThumbTag != null) {
        return imageApi.getThumbImageUrl(
          parentThumbItemId,
          maxWidth: maxW,
          tag: parentThumbTag,
        );
      }
      if (parentBackdropItemId != null && parentBackdropTags.isNotEmpty) {
        return imageApi.getBackdropImageUrl(
          parentBackdropItemId,
          maxWidth: maxW,
          tag: parentBackdropTags.first,
        );
      }
      if (seriesId != null && seriesPrimaryTag != null) {
        return imageApi.getPrimaryImageUrl(
          seriesId,
          maxWidth: maxW,
          tag: seriesPrimaryTag,
        );
      }
      return null;
    }

    if (imageType == ImageType.banner) {
      final seriesBannerTag =
          (item.rawData['SeriesImageTags'] as Map?)?['Banner'] as String?;
      if (seriesId != null && seriesBannerTag != null) {
        return imageApi.getBannerImageUrl(
          seriesId,
          maxWidth: maxW,
          tag: seriesBannerTag,
        );
      }
      if (parentThumbItemId != null && parentThumbTag != null) {
        return imageApi.getThumbImageUrl(
          parentThumbItemId,
          maxWidth: maxW,
          tag: parentThumbTag,
        );
      }
      if (parentBackdropItemId != null && parentBackdropTags.isNotEmpty) {
        return imageApi.getBackdropImageUrl(
          parentBackdropItemId,
          maxWidth: maxW,
          tag: parentBackdropTags.first,
        );
      }
      if (seriesId != null && seriesPrimaryTag != null) {
        return imageApi.getPrimaryImageUrl(
          seriesId,
          maxWidth: maxW,
          tag: seriesPrimaryTag,
        );
      }
      return null;
    }

    return null;
  }

  static String? _tagForType(AggregatedItem item, String imageType) {
    final tags = item.rawData['ImageTags'];
    if (tags is! Map) return null;
    return tags[imageType] as String?;
  }
}

/// TV-only clock overlay for the home screen when the left sidebar is the
/// navbar. The top toolbar (and its top-right clock) is not built in that
/// mode, so without this the home screen has no clock. Non-interactive and
/// never focusable; mirrors the toolbar clock prefs ([ClockBehavior], the
/// 24-hour toggle) and tick cadence (30s). Owned by compact-banner.
class _TvSidebarClock extends StatefulWidget {
  final UserPreferences prefs;

  const _TvSidebarClock({required this.prefs});

  @override
  State<_TvSidebarClock> createState() => _TvSidebarClockState();
}

class _TvSidebarClockState extends State<_TvSidebarClock> {
  Timer? _timer;
  late String _time;

  @override
  void initState() {
    super.initState();
    _time = _formattedNow();
    widget.prefs.addListener(_onPrefsChanged);
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.prefs.removeListener(_onPrefsChanged);
    super.dispose();
  }

  void _onPrefsChanged() {
    if (!mounted) return;
    setState(() => _time = _formattedNow());
  }

  void _tick() {
    if (!mounted) return;
    final now = _formattedNow();
    if (now != _time) setState(() => _time = now);
  }

  String _formattedNow() => formatClockTime(
    DateTime.now(),
    use24Hour: widget.prefs.get(UserPreferences.use24HourClock),
  );

  @override
  Widget build(BuildContext context) {
    final behavior = widget.prefs.get(UserPreferences.clockBehavior);
    final show =
        behavior == ClockBehavior.always || behavior == ClockBehavior.inMenus;
    if (!show) return const SizedBox.shrink();
    return IgnorePointer(
      child: Text(
        _time,
        textDirection: TextDirection.ltr,
        style: const TextStyle(
          color: Color(0xE6FFFFFF),
          fontSize: 22,
          fontWeight: FontWeight.w500,
          shadows: [Shadow(color: Color(0xB3000000), blurRadius: 8)],
        ),
      ),
    );
  }
}

class _LiveTvAction {
  final IconData icon;
  final String label;
  final String destination;

  const _LiveTvAction(this.icon, this.label, this.destination);
}

class _OverlayTopClipper extends CustomClipper<Rect> {
  const _OverlayTopClipper(this.top);

  final double top;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(0, top.clamp(0.0, size.height), size.width, size.height);

  @override
  bool shouldReclip(_OverlayTopClipper oldClipper) => oldClipper.top != top;
}

class _PreviewCardShell extends StatelessWidget {
  final Widget card;
  final double width;
  final double aspectRatio;
  final bool showVideo;
  final bool useMedia3;
  final VideoController? controller;
  final int? appleTvTextureId;
  final bool isFocused;
  final Color focusColor;

  const _PreviewCardShell({
    required this.card,
    required this.width,
    required this.aspectRatio,
    required this.showVideo,
    required this.useMedia3,
    required this.controller,
    this.appleTvTextureId,
    required this.isFocused,
    required this.focusColor,
  });

  @override
  Widget build(BuildContext context) {
    if (!showVideo) {
      return card;
    }

    final Widget? previewSurface;
    if (useMedia3) {
      previewSurface = const Media3VideoView(
        fill: Colors.black,
        role: 'preview',
      );
    } else if (appleTvTextureId != null) {
      previewSurface = FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: 1920,
          height: 1080,
          child: Texture(textureId: appleTvTextureId!),
        ),
      );
    } else if (controller != null) {
      previewSurface = Video(
        controller: controller!,
        controls: NoVideoControls,
        fit: BoxFit.cover,
        pauseUponEnteringBackgroundMode: false,
        fill: Colors.black,
      );
    } else {
      previewSurface = null;
    }

    if (previewSurface == null) {
      return card;
    }

    return SizedBox(
      width: width,
      child: Stack(
        children: [
          card,
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SizedBox(
              height: width / aspectRatio,
              child: IgnorePointer(
                child: ClipRRect(
                  borderRadius: AppRadius.circular(8),
                  child: ColoredBox(
                    color: AppColorScheme.background,
                    child: previewSurface,
                  ),
                ),
              ),
            ),
          ),
          if (isFocused)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: IgnorePointer(
                child: Container(
                  height: width / aspectRatio,
                  decoration: BoxDecoration(
                    borderRadius: AppRadius.circular(8),
                    border: Border.fromBorderSide(
                      ThemeRegistry.active.borders.focusBorder.copyWith(
                        color: focusColor,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Where a card's preview comes from. A YouTube trailer isn't a server
/// transcode, so it has no encoding to stop and needs YouTube's headers, and a
/// trailer of either kind plays to its end where a clip stops at 30 seconds.
typedef _PreviewSource = ({
  String url,
  Duration start,
  bool youTube,
  bool trailer,
  String? audioLanguage,
  String label,
});
