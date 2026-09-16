part of '../settings_side_panel.dart';

class _LibrariesCategoryScreen extends StatefulWidget {
  const _LibrariesCategoryScreen();

  @override
  State<_LibrariesCategoryScreen> createState() =>
      _LibrariesCategoryScreenState();
}

class _LibrariesCategoryScreenState extends State<_LibrariesCategoryScreen> {
  List<ServerUserSession>? _servers;

  @override
  void initState() {
    super.initState();
    _loadServers();
  }

  Future<void> _loadServers() async {
    try {
      final servers =
          await GetIt.instance<MultiServerRepository>().getLoggedInServers();
      if (!mounted) return;
      setState(() => _servers = servers);
    } catch (_) {
      if (!mounted) return;
      setState(() => _servers = const []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final servers = _servers;
    return Scaffold(
      appBar: buildSettingsAppBar(context, Text(l10n.libraries)),
      body: ListView(
        children: [
          _SectionHeader(l10n.general),
          adaptiveListSection(
            children: [
              _TvSettingsListTile(
                leading: const Icon(Icons.visibility),
                title: Text(l10n.libraryVisibility),
                subtitle: Text(l10n.settingsLibraryVisibilitySubtitle),
                onTap: () =>
                    context.pushSettingsScreen(const LibraryVisibilityScreen()),
              ),
              SwitchPreferenceTile(
                preference: UserPreferences.enableMultiServerLibraries,
                title: l10n.multiServerLibraries,
                subtitle: l10n.showLibrariesFromAllServers,
                icon: Icons.dns,
                onChanged: _pushPersonalizationSync,
              ),
              SwitchPreferenceTile(
                preference: UserPreferences.mergeRecentRowsByType,
                title: l10n.mergeRecentRowsByType,
                subtitle: l10n.mergeRecentRowsByTypeDescription,
                icon: Icons.library_books,
                onChanged: _pushPersonalizationSync,
              ),
              if (servers != null && servers.length >= 2)
                StringPickerPreferenceTile(
                  preference: UserPreferences.primaryServerForLocalMedia,
                  title: l10n.primaryServerForLocalMedia,
                  description: l10n.primaryServerForLocalMediaDescription,
                  icon: Icons.play_circle_outline,
                  options: {
                    '': l10n.interfaceStyleAutomatic,
                    for (final session in servers)
                      session.server.id: session.server.name,
                  },
                  onChanged: _pushPersonalizationSync,
                ),
              SwitchPreferenceTile(
                preference: UserPreferences.showBookDiscoverTab,
                title: l10n.showBookDiscoverTab,
                subtitle: l10n.showBookDiscoverTabDescription,
                icon: Icons.explore,
                onChanged: _pushPersonalizationSync,
              ),
              EnumPreferenceTile<RecentlyReleasedSeriesType>(
                preference: UserPreferences.recentlyReleasedSeriesType,
                title: l10n.recentlyReleasedSeriesType,
                description: l10n.recentlyReleasedSeriesTypeDescription,
                icon: Icons.ondemand_video,
                labelOf: (v) => switch (v) {
                  RecentlyReleasedSeriesType.series => l10n.series,
                  RecentlyReleasedSeriesType.season => l10n.season,
                  RecentlyReleasedSeriesType.episode => l10n.episode,
                },
                onChanged: _pushPersonalizationSync,
              ),
            ],
          ),
          _SectionHeader(l10n.libraryView),
          adaptiveListSection(
            children: [
              SwitchPreferenceTile(
                preference: UserPreferences.groupItemsIntoCollections,
                title: l10n.groupItemsIntoCollections,
                subtitle: l10n.hideCollectionAssociatedItems,
                icon: Icons.collections_bookmark,
                onChanged: () async {
                  _pushPersonalizationSync();
                  final prefs = GetIt.instance<PreferenceStore>();
                  final isEnabled = prefs.get(UserPreferences.groupItemsIntoCollections);
                  if (isEnabled) {
                    final client = GetIt.instance<MediaServerClient>();
                    try {
                      final config =
                          await client.adminSystemApi.getServerConfiguration();
                      final groupMovies =
                          (config['EnableGroupingMoviesIntoCollections'] as bool?) ??
                          (config['EnableGroupingIntoCollections'] as bool?) ??
                          false;
                      final groupShows =
                          (config['EnableGroupingShowsIntoCollections'] as bool?) ??
                          (config['EnableGroupingIntoCollections'] as bool?) ??
                          false;
                      if (groupMovies && groupShows) {
                        return;
                      }
                    } catch (_) {}

                    if (!context.mounted) return;
                    showFocusRestoringDialog(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: Text(l10n.groupItemsIntoCollectionsDialogTitle),
                        content: Text(l10n.groupItemsIntoCollectionsDialogMessage),
                        actions: [
                          TextButton(
                            autofocus: true,
                            onPressed: () => Navigator.pop(dialogContext),
                            child: Text(l10n.ok),
                          ),
                        ],
                      ),
                    );
                  }
                },
              ),
              SwitchPreferenceTile(
                preference: UserPreferences.showMediaDetailsOnLibraryPage,
                title: l10n.showMediaDetailsOnLibraryPage,
                subtitle: l10n.showMediaDetailsOnLibraryPageDescription,
                icon: Icons.info_outline,
                onChanged: _pushPersonalizationSync,
              ),
              SwitchPreferenceTile(
                preference: UserPreferences.useDetailedSubHeadings,
                title: l10n.useDetailedSubHeadings,
                subtitle: l10n.useDetailedSubHeadingsDescription,
                icon: Icons.subtitles,
                onChanged: _pushPersonalizationSync,
              ),
              SwitchPreferenceTile(
                preference: UserPreferences.hideBackdropsInLibraries,
                title: l10n.hideBackdropsInLibraries,
                icon: Icons.hide_image_outlined,
                onChanged: _pushPersonalizationSync,
              ),
            ],
          ),
        ],
      ),
    );
  }
}