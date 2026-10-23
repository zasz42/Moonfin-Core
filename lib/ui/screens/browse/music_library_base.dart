import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:moonfin_design/moonfin_design.dart';
import 'package:playback_core/playback_core.dart';
import 'package:server_core/server_core.dart';

import '../../../data/models/aggregated_item.dart';
import '../../../data/models/home_row.dart';
import '../../../data/services/row_data_source.dart';
import '../../../data/viewmodels/music_browse_view_model.dart';
import '../../../l10n/app_localizations.dart';
import '../../../preference/preference_constants.dart';
import '../../../preference/user_preferences.dart';
import '../../../util/focus/row_focus_coordinator.dart';
import '../../../util/platform_detection.dart';
import '../../navigation/destinations.dart';
import '../../util/home_row_title_localizer.dart';
import '../../widgets/book/book_navigation.dart';
import '../../widgets/book/book_see_all_button.dart';
import '../../widgets/bottom_nav/bottom_navbar.dart';
import '../../widgets/focus/can_claim_initial_focus.dart';
import '../../widgets/focus/locked_focus_row.dart';
import '../../widgets/focus/request_initial_focus.dart';
import '../../widgets/left_sidebar.dart';
import '../../widgets/media_card.dart';
import '../../widgets/music/music_navigation.dart';
import '../../widgets/music/music_widgets.dart';
import '../../widgets/navigation_layout.dart';
import '../../widgets/overlay_sheet.dart';
import '../../widgets/skeleton/skeleton_music_browse.dart';
import '../../widgets/top_toolbar.dart';
import 'music_browse_screen.dart';

/// What the Quick Access and Immersive music libraries share: the view
/// model, the D-pad stops and the shelf each row is drawn as.
abstract class MusicLibraryState<T extends StatefulWidget> extends State<T> {
  String get libraryId;

  late final MusicBrowseViewModel vm;
  final coordinator = RowFocusCoordinator();

  // Never attached. As the initial focus target it keeps RequestInitialFocus
  // from parking focus in the sidebar before the content loads, and
  // _onChanged lands focus on the content once it does.
  final initialFocusNode = FocusNode(debugLabel: 'musicInitialContent');
  bool _landedOnContent = false;

  /// The coordinator index of the header. Focus first lands on the stop
  /// under it.
  int headerIndex = -1;

  final _nodes = <String, FocusNode>{};
  List<RowFocusEntry> _entries = [];
  List<Widget> _sections = [];
  final _rowKeys = <String, GlobalKey<LockedFocusRowState>>{};
  final _sectionKeys = <String, GlobalKey>{};
  StreamSubscription<void>? _queueSub;
  double _musicBarHeight = TopToolbar.musicBarExtraHeight();

  bool get wide => !PlatformDetection.useMobileUi;

  /// Where the page's own header starts, below the top navbar and the music
  /// pill under it while music plays.
  double get topReserve =>
      MediaQuery.paddingOf(context).top +
      (NavigationLayout.sanitizeNavbarPosition(
                GetIt.instance<UserPreferences>().get(
                  UserPreferences.navbarPosition,
                ),
              ) ==
              NavbarPosition.top
          ? TopToolbar.heightFor(context)
          : 56);

  @override
  void initState() {
    super.initState();
    vm = MusicBrowseViewModel(
      libraryId: libraryId,
      dataSource: GetIt.instance<RowDataSource>(),
      client: GetIt.instance<MediaServerClient>(),
    );
    vm.addListener(_onChanged);
    reload();
    _queueSub = GetIt.instance<PlaybackManager>()
        .queueService
        .queueChangedStream
        .listen((_) {
          final height = TopToolbar.musicBarExtraHeight();
          if (height != _musicBarHeight && mounted) {
            setState(() => _musicBarHeight = height);
          }
        });
  }

  @override
  void dispose() {
    _queueSub?.cancel();
    vm.removeListener(_onChanged);
    vm.dispose();
    initialFocusNode.dispose();
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> reload() async {
    await vm.load();
    if (mounted) onLoaded();
  }

  /// Runs after every load, for what a style loads on top of the rows.
  void onLoaded() {}

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    if (!wide || vm.isLoading) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          vm.isLoading ||
          !canClaimInitialFocus(context) ||
          LeftSidebar.isFocusedNotifier.value ||
          TopToolbar.isFocusedNotifier.value) {
        return;
      }
      // The first load lands under the header. After that, an update only
      // steps in when a rebuild took the focused stop away, never while the
      // viewer is somewhere on the page.
      if (_landedOnContent && !bookFocusIsLost) return;
      _landedOnContent = true;
      focusContent();
    });
  }

  /// Focuses the first stop under the header.
  void focusContent() {
    if (!coordinator.moveVertical(fromIndex: headerIndex, isUp: false)) {
      coordinator.focusFirst();
    }
  }

  FocusNode node(String id) =>
      _nodes.putIfAbsent(id, () => FocusNode(debugLabel: 'music:$id'));

  GlobalKey<LockedFocusRowState> rowKey(String id) =>
      _rowKeys.putIfAbsent(id, GlobalKey<LockedFocusRowState>.new);

  GlobalKey sectionKey(String id) => _sectionKeys.putIfAbsent(id, GlobalKey.new);

  bool move(int fromIndex, bool isUp) =>
      moveBookFocus(coordinator, fromIndex, isUp);

  void openItem(AggregatedItem item) => openMusicItem(context, item);

  void search() => context.push(Destinations.searchInLibrary(libraryId));

  void showSortAndFilter() => OverlaySheetController.show<void>(
    context,
    builder: (_) => MusicRowVisibilityDialog(
      libraryName: vm.libraryName,
      onChanged: reload,
    ),
  );

  /// The row the view model loaded under [prefix], if it has items.
  HomeRow? rowOf(String prefix) {
    for (final row in vm.rows) {
      if (row.id.startsWith(prefix) && row.items.isNotEmpty) return row;
    }
    return null;
  }

  /// The page in the app's chrome, a skeleton until the rows load.
  Widget buildPage(Widget Function() content) => RequestInitialFocus(
    targetNode: initialFocusNode,
    child: Scaffold(
      backgroundColor: AppColorScheme.background,
      body: NavigationLayout(
        activeRoute: '/music/$libraryId',
        showBackButton: true,
        child: vm.isLoading ? const SkeletonMusicBrowse() : content(),
      ),
    ),
  );

  /// The sections [addSections] adds, in a list that pulls to refresh.
  Widget buildSectionList(VoidCallback addSections) => RefreshIndicator(
    onRefresh: reload,
    child: BottomNavPadded(
      fallback: 120,
      builder: (_, bottom) {
        _entries = [];
        _sections = [];
        addSections();
        coordinator.entries = _entries;
        return ListView(
          padding: EdgeInsets.only(bottom: bottom + 24),
          children: _sections,
        );
      },
    ),
  );

  /// Adds a D-pad stop to the page and returns its coordinator index.
  int addStop(RowFocusEntry entry) {
    _entries.add(entry);
    return _entries.length - 1;
  }

  void addSection(Widget section) => _sections.add(section);

  void addShelf(
    HomeRow? row, {
    required double inset,
    required VoidCallback onLeftEdge,
  }) {
    if (row == null) return;
    final index = addStop(
      RowFocusEntry.row(rowKey(row.id), containerKey: sectionKey(row.id)),
    );
    addSection(
      _buildShelf(row, entryIndex: index, inset: inset, onLeftEdge: onLeftEdge),
    );
  }

  void addList(
    HomeRow? row, {
    required String title,
    required double inset,
    required VoidCallback onLeftEdge,
    int max = 5,
  }) {
    if (row == null) return;
    final index = addStop(
      RowFocusEntry.node(node('${row.id}:0'), containerKey: sectionKey(row.id)),
    );
    addSection(
      _buildList(
        row,
        title: title,
        entryIndex: index,
        inset: inset,
        onLeftEdge: onLeftEdge,
        max: max,
      ),
    );
  }

  static bool _isArtistRow(HomeRow row) =>
      row.id.startsWith('albumartist_') || row.id.startsWith('musicartist_');

  /// [row] as a shelf of covers, or circles for artists.
  Widget _buildShelf(
    HomeRow row, {
    required int entryIndex,
    required double inset,
    required VoidCallback onLeftEdge,
  }) {
    final l10n = AppLocalizations.of(context);
    final round = _isArtistRow(row);
    final width = wide ? 168.0 : 140.0;
    final seeAll = musicSeeAllRoute(libraryId, row.id);
    final rowIndex = vm.rows.indexOf(row);
    return MusicShelf(
      title: localizeHomeRowTitle(row: row, l10n: l10n),
      onSeeAll: seeAll == null ? null : () => context.push(seeAll),
      seeAllFocusNode: seeAll == null ? null : node('seeAll:${row.id}'),
      items: row.items,
      hubKey: 'music_${row.id}',
      rowKey: rowKey(row.id),
      containerKey: sectionKey(row.id),
      itemExtent: width,
      height: width + 64,
      leadingInset: inset,
      large: wide,
      onSelect: openItem,
      onVerticalNavigation: (isUp) => move(entryIndex, isUp),
      onLeftEdge: onLeftEdge,
      onIndexChanged: (index) {
        if (index >= row.items.length - 8) vm.loadMoreForRow(rowIndex);
      },
      itemBuilder: (context, item, index, focused) => Align(
        alignment: Alignment.topLeft,
        child: MediaCard(
          width: width,
          aspectRatio: 1,
          title: item.name,
          subtitle: vm.getMusicSubtitle(item),
          imageUrl: vm.getMusicImageUrl(item),
          // MediaCard only draws Person cards round.
          itemType: round ? 'Person' : item.type,
          isFavorite: item.isFavorite,
          externalIsFocused: focused,
          onTap: () => openItem(item),
        ),
      ),
    );
  }

  /// The first [max] items of [row] as a list of rows, songs with their
  /// length and playlists with their size.
  Widget _buildList(
    HomeRow row, {
    required String title,
    required int entryIndex,
    required double inset,
    required VoidCallback onLeftEdge,
    int max = 5,
  }) {
    final items = row.items.take(max).toList();
    final seeAll = musicSeeAllRoute(libraryId, row.id);
    final seeAllNode = seeAll == null ? null : node('seeAll:${row.id}');
    return KeyedSubtree(
      key: sectionKey(row.id),
      child: MusicSection(
        title: title,
        large: wide,
        padding: EdgeInsets.symmetric(horizontal: inset),
        trailing: seeAll == null
            ? null
            : BookSeeAllButton(
                onPressed: () => context.push(seeAll),
                focusNode: seeAllNode,
                onNavigateUp: () => move(entryIndex, true),
                onNavigateDown: node('${row.id}:0').requestFocus,
              ),
        child: Column(
          children: [
            for (var i = 0; i < items.length; i++)
              MusicTrackTile(
                title: items[i].name,
                subtitle: _songSubtitle(items[i]),
                imageUrl: vm.getMusicImageUrl(items[i]),
                trailing: musicRunTime(items[i]),
                focusNode: node('${row.id}:$i'),
                onTap: () => openItem(items[i]),
                edges: MusicGridEdges.of(
                  i,
                  count: items.length,
                  columns: 1,
                  onLeaveUp: seeAllNode == null
                      ? () => move(entryIndex, true)
                      : seeAllNode.requestFocus,
                  onLeaveDown: () => move(entryIndex, false),
                  onLeaveLeft: onLeftEdge,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// A song's artist and album, or the view model's subtitle for the rest.
  String _songSubtitle(AggregatedItem item) {
    final subtitle = vm.getMusicSubtitle(item);
    final album = item.album;
    if (item.type != 'Audio' || album == null || album.isEmpty) return subtitle;
    return subtitle.isEmpty ? album : '$subtitle · $album';
  }
}
