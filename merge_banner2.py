#!/usr/bin/env python3
"""
Create merged banner_media_bar.dart
"""

merged_build_method = '''  @override
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
      final message = describeError(
        (state as MediaBarError).error,
        AppLocalizations.of(context),
      );
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
    // A phone's bar is about 2:1, where a banner would be a thin strip.
    final bannerUrl = isMobile ? null : item.bannerUrl;
    final navbarPosition = widget.prefs.get(UserPreferences.navbarPosition);
    final navbarAtTop = navbarPosition == NavbarPosition.top;
    final topInset = isMobile
        ? MediaQuery.paddingOf(context).top + (navbarAtTop ? 60.0 : 0.0)
        : 0.0;
    // The left sidebar is drawn over the banner, so the banner starts past it.
    final sidebarInset =
        !isMobile && navbarPosition == NavbarPosition.left ? 56.0 : 0.0;
    final showArrows = items.length > 1 && PlatformDetection.useDesktopUi;

    // Compact banner: half the display width at 21:9 proportions; the
    // Upcoming Releases rail takes the other half when enabled.
    final showUpcomingRow = _compact && _showUpcoming;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final compactBannerWidth = BannerMediaBar.compactWidthFor(
      screenWidth,
      withUpcoming: showUpcomingRow,
    );
    final compactBannerHeight = BannerMediaBar.compactHeightFor(
      screenWidth,
      withUpcoming: showUpcomingRow,
    );

    // Build the banner frame (used for both compact and full-width)
    final bannerFrame = AnimatedContainer(
      width: _compact ? compactBannerWidth : null,
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
          width: _compact ? compactBannerWidth : null,
          height: _compact ? compactBannerHeight : widget.height,
          child: GestureDetector(
            onTap: () => widget.onOpen(item),
            onLongPress: () => _launchTrailer(item),
            onHorizontalDragUpdate: items.length > 1
                ? (details) {
                    // Track horizontal drag for visual feedback (optional)
                    // This helps on tvOS where remote touchpad generates
                    // continuous drag updates rather than high-velocity flings
                    _dragOffset =
                        (details.primaryDelta ?? 0) + (_dragOffset ?? 0);
                    if (mounted) setState(() {});
                  }
                : null,
            onHorizontalDragEnd: items.length > 1
                ? (details) {
                    _advanceFromGesture(details.primaryVelocity ?? 0, items);
                  }
                : null,
            // tvOS remote touchpad may generate pan gestures instead of
            // horizontal drag gestures. Handle both for robustness.
            onPanUpdate: items.length > 1 && PlatformDetection.isAppleTV
                ? (details) {
                    final delta = details.delta.dx;
                    _dragOffset = (delta) + (_dragOffset ?? 0);
                    if (mounted) setState(() {});
                  }
                : null,
            onPanEnd: items.length > 1 && PlatformDetection.isAppleTV
                ? (details) {
                    _advanceFromGesture(
                      details.velocity.pixelsPerSecond.dx,
                      items,
                    );
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
                        if (bannerUrl != null)
                          _banner(bannerUrl, item)
                        else
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
                          // Leaves room for the previous arrow when not compact.
                          left: showArrows && !_compact ? 72 : 20,
                          right: 20,
                          bottom: 16,
                          child: _content(
                            context,
                            item,
                            // The banner carries the title already.
                            showTitle: bannerUrl == null,
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
                        if (showArrows && !_compact)
                          ...mediaBarNavArrows(
                            context,
                            onPrevious: index > 0
                                ? () => _setIndex(index - 1)
                                : null,
                            onNext: () => _setIndex(index + 1),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // Focus wrapper - from main branch
    final focusedBanner = Focus(
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
      child: _compact
          ? Align(alignment: Alignment.center, child: bannerFrame)
          : bannerFrame,
    );

    Widget banner = Padding(
      padding: EdgeInsets.fromLTRB(16 + sidebarInset, topInset, 16, _compact ? 4 : 8),
      child: focusedBanner,
    );

    if (showUpcomingRow) {
      final focusColor = Color(
        widget.prefs.get(UserPreferences.focusColor).colorValue,
      );
      // The rail matches the banner height on every platform and is pinned
      // to the same bottom edge. Full height (not the old TV 0.75) leaves
      // room for the width-sized posters plus their title/subtitle lines.
      final upcomingHeight = compactBannerHeight;
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
        padding: EdgeInsets.fromLTRB(16 + sidebarInset, topInset, 16, 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            SizedBox(
              width: compactBannerWidth,
              height: compactBannerHeight,
              child: focusedBanner,
            ),
            const SizedBox(width: BannerMediaBar.compactGap),
            SizedBox(
              width: compactBannerWidth,
              height: upcomingHeight,
              child: upcoming,
            ),
          ],
        ),
      );
    }

    return banner;
  }
'''

# Read the original file
with open('/home/plasma/projects/Moonfin-Core/lib/ui/widgets/mediabar/banner_media_bar.dart', 'r') as f:
    content = f.read()

# Find the build method
build_start = content.find('  @override\n  Widget build(BuildContext context) {')
if build_start == -1:
    build_start = content.find('  @override\n  Widget build(BuildContext context) {')

print(f"Build method starts at: {build_start}")

# Find the end of the build method (matching brace)
brace_count = 0
in_method = False
method_end = -1
for i in range(build_start, len(content)):
    if content[i] == '{':
        brace_count += 1
        in_method = True
    elif content[i] == '}':
        brace_count -= 1
        if in_method and brace_count == 0:
            method_end = i
            break

print(f"Build method ends at: {method_end}")

# Replace the build method
new_content = content[:build_start] + merged_build_method + content[method_end+1:]

# Write the result
with open('/home/plasma/projects/Moonfin-Core/lib/ui/widgets/mediabar/banner_media_bar.dart', 'w') as f:
    f.write(new_content)

print("Done! File written.")