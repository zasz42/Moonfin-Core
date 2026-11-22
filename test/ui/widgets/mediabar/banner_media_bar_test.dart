import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/data/models/calendar_entry.dart';
import 'package:moonfin/data/models/media_bar_slide_item.dart';
import 'package:moonfin/data/repositories/calendar_repository.dart';
import 'package:moonfin/data/models/media_bar_state.dart';
import 'package:moonfin/data/viewmodels/media_bar_view_model.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/preference/preference_constants.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/widgets/bounded_network_image.dart';
import 'package:moonfin/ui/widgets/mediabar/banner_media_bar.dart';
import 'package:moonfin/ui/widgets/mediabar/upcoming_releases_rail.dart';
import 'package:moonfin/util/platform_detection.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ViewModel extends ChangeNotifier implements MediaBarViewModel {
  _ViewModel(this.item);

  final MediaBarSlideItem item;

  @override
  List<MediaBarSlideItem> get items => [item];

  @override
  MediaBarState get state => MediaBarReady([item]);

  @override
  Map<String, double> ratingsFor(String itemId) => const {};

  @override
  Future<void> ensureRatings(String itemId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CalendarRepository implements CalendarRepository {
  _CalendarRepository(this.entries);

  final List<CalendarEntry> entries;

  @override
  Future<CalendarResult> load({
    required DateTime start,
    required DateTime end,
    bool unmonitored = false,
    bool refresh = false,
  }) async => CalendarResult(entries);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Issue #1265: the Banner bar shows an item's banner art where it has one,
// leaving off the title it already carries.
void main() {
  late UserPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    prefs = UserPreferences(store);
    await prefs.set(UserPreferences.mediaBarAutoAdvance, false);
  });

  tearDown(
    () => PlatformDetection.setInterfaceLayout(InterfaceLayout.automatic),
  );

  Future<void> pumpBar(WidgetTester tester, MediaBarSlideItem item) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: const [Locale('en')],
        home: Scaffold(
          body: BannerMediaBar(
            viewModel: _ViewModel(item),
            prefs: prefs,
            height: 240,
            onOpen: (_) {},
            onPlay: (_) {},
          ),
        ),
      ),
    );
  }

  Iterable<String> imageUrls(WidgetTester tester) => tester
      .widgetList<BoundedNetworkImage>(find.byType(BoundedNetworkImage))
      .map((image) => image.imageUrl);

  const withBanner = MediaBarSlideItem(
    itemId: 'show',
    serverId: 'server',
    title: 'The Show',
    year: 2020,
    backdropUrl: 'http://server/backdrop',
    bannerUrl: 'http://server/banner',
  );

  testWidgets('a banner replaces the backdrop and the title on desktop', (
    tester,
  ) async {
    PlatformDetection.setInterfaceLayout(InterfaceLayout.desktop);
    await pumpBar(tester, withBanner);

    expect(imageUrls(tester), ['http://server/banner', 'http://server/banner']);
    final whole = tester
        .widgetList<BoundedNetworkImage>(find.byType(BoundedNetworkImage))
        .where((image) => image.blurSigma == 0);
    expect(whole.single.fit, BoxFit.contain);
    expect(find.text('The Show'), findsNothing);
    expect(find.text('2020'), findsOneWidget);
  });

  testWidgets('an item without a banner keeps its backdrop and title', (
    tester,
  ) async {
    PlatformDetection.setInterfaceLayout(InterfaceLayout.desktop);
    await pumpBar(
      tester,
      const MediaBarSlideItem(
        itemId: 'film',
        serverId: 'server',
        title: 'The Film',
        backdropUrl: 'http://server/backdrop',
      ),
    );

    expect(imageUrls(tester), ['http://server/backdrop']);
    expect(find.text('The Film'), findsOneWidget);
  });

  testWidgets('compact TV banner shows eight upcoming releases', (
    tester,
  ) async {
    PlatformDetection.setInterfaceLayout(InterfaceLayout.tv);
    await prefs.set(UserPreferences.compactBannerEnabled, true);
    await prefs.set(UserPreferences.compactBannerUpcomingReleases, true);
    final entries = [
      for (var i = 0; i < 9; i++)
        CalendarEntry(
          key: 'radarr:$i:digital',
          kind: CalendarEntryKind.movie,
          release: CalendarRelease.digital,
          date: DateTime(2026, 11, 21 + i),
          hasTime: false,
          title: 'Release $i',
        ),
    ];
    final getIt = GetIt.instance;
    if (getIt.isRegistered<CalendarRepository>()) {
      await getIt.unregister<CalendarRepository>();
    }
    getIt.registerSingleton<CalendarRepository>(_CalendarRepository(entries));
    addTearDown(() async => getIt.reset());

    await pumpBar(tester, withBanner);
    await tester.pumpAndSettle();

    expect(find.text('The Show'), findsOneWidget);
    expect(find.byType(UpcomingReleasesRail), findsOneWidget);
    final compactImageRect = tester.getRect(
      find.byType(BoundedNetworkImage).first,
    );
    expect(
      compactImageRect.width / compactImageRect.height,
      closeTo(16 / 9, 0.001),
    );
    // The test's Scaffold vertically centers the bar in the 1080px body;
    // within the bar itself the image starts 20px down and ends at its edge.
    expect(compactImageRect.top, 440);
    expect(compactImageRect.height, 220);
    final railRect = tester.getRect(find.byType(UpcomingReleasesRail));
    expect(railRect.top, compactImageRect.top);
    expect(railRect.bottom, compactImageRect.bottom);
    expect(railRect.right, 1920);
    expect(railRect.left, compactImageRect.right + 12);
    expect(
      find.ancestor(
        of: find.byType(BoundedNetworkImage).first,
        matching: find.byType(ClipRRect),
      ),
      findsWidgets,
    );
    expect(find.text('UPCOMING RELEASES'), findsOneWidget);
    for (var i = 0; i < 8; i++) {
      expect(find.text('Release $i'), findsOneWidget);
    }
    expect(find.text('Release 8'), findsNothing);
  });

  testWidgets('a phone keeps the backdrop even when there is a banner', (
    tester,
  ) async {
    PlatformDetection.setInterfaceLayout(InterfaceLayout.phone);
    await prefs.set(UserPreferences.navbarPosition, NavbarPosition.bottom);
    await pumpBar(tester, withBanner);

    expect(imageUrls(tester), ['http://server/backdrop']);
    expect(find.text('The Show'), findsOneWidget);
  });
}
