import 'package:celechron/design/glass_geometry.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart' show Icons;
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'package:celechron/design/liquid_glass.dart';

import 'package:celechron/page/scholar/scholar_view.dart';
import 'package:celechron/page/flow/flow_view.dart';
import 'package:celechron/page/task/task_view.dart';
import 'package:celechron/page/calendar/calendar_view.dart';
import 'package:celechron/page/option/option_view.dart';

import 'package:celechron/worker/fuse.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.title});

  final String title;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // 只构建一次，保持各页 widget 身份稳定，切页时不会重跑各页构造器里的 Get.put
  late final List<Widget> _pages = [
    FlowPage(),
    CalendarPage(),
    TaskPage(),
    ScholarPage(),
    OptionPage(),
  ];

  @override
  void initState() {
    super.initState();
    initFuse();
  }

  @override
  Widget build(BuildContext context) => GlassHomeTabs(pages: _pages);

  Future<void> initFuse() async {
    await Future.delayed(const Duration(seconds: 1));
    if (!mounted) return;
    var fuse = Get.find<Rx<Fuse>>(tag: 'fuse');
    var response = await fuse.value.checkUpdate().whenComplete(
          () => fuse.refresh(),
        );
    if (response != null) {
      if (!mounted) return;
      showCupertinoDialog(
        context: context,
        builder: (context) {
          return CupertinoAlertDialog(
            title: const Text('更新可用'),
            content: Text(response),
            actions: [
              CupertinoDialogAction(
                child: const Text('忽略'),
                onPressed: () async {
                  Navigator.of(context).pop();
                },
              ),
              CupertinoDialogAction(
                child: const Text('访问网站'),
                onPressed: () async {
                  await launchUrlString(
                    'https://celechron.top',
                    mode: LaunchMode.externalApplication,
                  );
                },
              ),
            ],
          );
        },
      );
    }
  }
}

/// Five persistent app pages with an inset navigation dock.
///
/// The dock occupies bottom safe-area space, while the scrollable pages remain
/// underneath it so the single glass blur can sample their backgrounds.
class GlassHomeTabs extends StatefulWidget {
  const GlassHomeTabs({super.key, required this.pages});

  final List<Widget> pages;

  @override
  State<GlassHomeTabs> createState() => _GlassHomeTabsState();
}

class _GlassHomeTabsState extends State<GlassHomeTabs> {
  static const _dockHeight = 68.0;
  static const _dockGap = 12.0;
  static const _tabs = [
    (icon: CupertinoIcons.time, label: '接下来'),
    (icon: CupertinoIcons.calendar, label: '日程'),
    (icon: CupertinoIcons.check_mark, label: '任务'),
    (icon: Icons.school_rounded, label: '学业'),
    (icon: CupertinoIcons.settings, label: '设置'),
  ];

  int _indexNum = 0;
  final PageController _pageController = PageController();

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _selectTab(int index) {
    if (index != _indexNum) _pageController.jumpToPage(index);
  }

  Widget _dock(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final accent = GlassPalette.accentColor(context);
    final inactive = GlassPalette.secondaryLabel(context);
    return GlassSurface(
      key: const ValueKey('home-glass-dock'),
      borderRadius: GlassGeometry.surfaceRadius,
      padding: const EdgeInsets.all(GlassGeometry.dockInset),
      tint: CupertinoDynamicColor.resolve(GlassPalette.barColor, context),
      blur: true,
      emphasized: true,
      child: SizedBox(
        height: _dockHeight - 12,
        child: Row(
          children: [
            for (var index = 0; index < _tabs.length; index++)
              Expanded(
                child: Semantics(
                  key: ValueKey('home-tab-semantics-$index'),
                  label: _tabs[index].label,
                  selected: index == _indexNum,
                  button: true,
                  excludeSemantics: true,
                  onTap: () => _selectTab(index),
                  child: CupertinoButton(
                    key: ValueKey('home-tab-$index'),
                    padding: EdgeInsets.zero,
                    onPressed: () => _selectTab(index),
                    child: AnimatedContainer(
                      duration: reducedMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      decoration: index == _indexNum
                          ? GlassPalette.decoration(
                              context,
                              radius: GlassGeometry.insetRadius(
                                GlassGeometry.dockInset,
                              ),
                              selected: true,
                            )
                          : BoxDecoration(
                              borderRadius: BorderRadius.circular(
                                GlassGeometry.insetRadius(
                                  GlassGeometry.dockInset,
                                ),
                              ),
                            ),
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _tabs[index].icon,
                            size: 24,
                            color: index == _indexNum ? accent : inactive,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _tabs[index].label,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.15,
                              fontWeight: index == _indexNum
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: index == _indexNum ? accent : inactive,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    assert(widget.pages.length == _tabs.length);
    final media = MediaQuery.of(context);
    final keyboardVisible = media.viewInsets.bottom > 0;
    final dockBottom = media.padding.bottom + _dockGap;
    final contentMedia = media.removeViewInsets(removeBottom: true).copyWith(
          padding: media.padding.copyWith(
            bottom: keyboardVisible ? 0 : _dockHeight + dockBottom + _dockGap,
          ),
        );
    final scrollBehavior = ScrollConfiguration.of(context);
    return GlassBackdrop(
      child: Stack(
        fit: StackFit.expand,
        children: [
          MediaQuery(
            data: contentMedia,
            child: Padding(
              padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
              child: HeroMode(
                enabled: false,
                child: PageView(
                  key: const ValueKey('home-pages'),
                  controller: _pageController,
                  onPageChanged: (index) {
                    if (index != _indexNum) {
                      setState(() => _indexNum = index);
                    }
                  },
                  scrollBehavior: scrollBehavior.copyWith(
                    scrollbars: false,
                    dragDevices: {
                      ...scrollBehavior.dragDevices,
                      PointerDeviceKind.mouse,
                    },
                  ),
                  children: [
                    for (final page in widget.pages)
                      _KeepAlivePage(child: page),
                  ],
                ),
              ),
            ),
          ),
          if (!keyboardVisible)
            Positioned(
              left: media.padding.left + 16,
              right: media.padding.right + 16,
              bottom: dockBottom,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  // Match native tab bars: keep labels compact while exposing
                  // each complete label and selected state to accessibility.
                  child: MediaQuery.withNoTextScaling(child: _dock(context)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// 离屏页面保活：保留滚动位置等临时状态，等价于原先 CupertinoTabScaffold
// 对已构建标签页的常驻行为
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});

  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
