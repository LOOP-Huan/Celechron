import 'dart:ui' show Tristate;

import 'package:celechron/design/animate_button.dart';
import 'package:celechron/design/liquid_glass.dart';
import 'package:celechron/design/persistent_headers.dart';
import 'package:celechron/design/refractive_glass.dart';
import 'package:celechron/design/round_rectangle_card.dart';
import 'package:celechron/design/two_line_card.dart';
import 'package:celechron/page/home_page.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child,
        {double keyboard = 0,
        bool reducedMotion = false,
        bool highContrast = false,
        double textScale = 1}) =>
    CupertinoApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(320, 568),
          padding: EdgeInsets.only(top: 24, bottom: keyboard > 0 ? 0 : 34),
          viewPadding: const EdgeInsets.only(top: 24, bottom: 34),
          viewInsets: EdgeInsets.only(bottom: keyboard),
          disableAnimations: reducedMotion,
          highContrast: highContrast,
          textScaler: TextScaler.linear(textScale),
        ),
        child: child,
      ),
    );

class _Tab extends StatefulWidget {
  const _Tab(this.index);
  final int index;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  int count = 0;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Column(
          children: [
            const Expanded(child: SizedBox.expand()),
            CupertinoButton(
              key: ValueKey('page-footer-${widget.index}'),
              onPressed: () => setState(() => count++),
              child: Text('page ${widget.index}: $count'),
            ),
          ],
        ),
      );
}

void main() {
  Future<void> narrowViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  const tabs = GlassHomeTabs(
    pages: [_Tab(0), _Tab(1), _Tab(2), _Tab(3), _Tab(4)],
  );

  testWidgets('悬浮五标签避开安全区，点击与滑动同步选中且保留页面状态', (tester) async {
    await narrowViewport(tester);
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(_app(tabs, textScale: 2));
      final dock =
          tester.getRect(find.byKey(const ValueKey('home-glass-dock')));
      final footer =
          tester.getRect(find.byKey(const ValueKey('page-footer-0')));
      expect(dock.left, greaterThan(0));
      expect(dock.right, lessThan(320));
      expect(dock.bottom, lessThanOrEqualTo(568 - 34));
      expect(footer.bottom, lessThan(dock.top));
      for (var index = 0; index < 5; index++) {
        expect(find.byKey(ValueKey('home-tab-$index')), findsOneWidget);
      }

      await tester.tap(find.byKey(const ValueKey('page-footer-0')));
      await tester.tap(find.byKey(const ValueKey('home-tab-4')));
      await tester.pumpAndSettle();
      expect(find.text('page 4: 0'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-tab-0')));
      await tester.pumpAndSettle();
      expect(find.text('page 0: 1'), findsOneWidget);

      await tester.drag(
          find.byKey(const ValueKey('home-pages')), const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(find.text('page 1: 0'), findsOneWidget);
      expect(
          tester
              .getSemantics(find.byKey(const ValueKey('home-tab-semantics-1')))
              .flagsCollection
              .isSelected,
          Tristate.isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('键盘弹出隐藏胶囊并只避让一次，收起后恢复底部操作空间', (tester) async {
    await narrowViewport(tester);
    await tester.pumpWidget(_app(tabs));
    await tester.pumpWidget(_app(tabs, keyboard: 220));
    expect(find.byKey(const ValueKey('home-glass-dock')), findsNothing);
    expect(tester.getBottomLeft(find.byKey(const ValueKey('page-footer-0'))).dy,
        closeTo(348, 0.1));
    final pageContext = tester.element(find.byType(_Tab).first);
    expect(MediaQuery.viewInsetsOf(pageContext).bottom, 0);
    expect(MediaQuery.paddingOf(pageContext).bottom, 0);

    await tester.pumpWidget(_app(tabs));
    final dock = tester.getRect(find.byKey(const ValueKey('home-glass-dock')));
    expect(tester.getBottomLeft(find.byKey(const ValueKey('page-footer-0'))).dy,
        lessThan(dock.top));
    expect(tester.takeException(), isNull);
  });

  testWidgets('高对比玻璃导航无需模糊，减少动画仍可切换', (tester) async {
    await narrowViewport(tester);
    await tester
        .pumpWidget(_app(tabs, highContrast: true, reducedMotion: true));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(
        tester
            .widgetList<RefractiveGlass>(find.byType(RefractiveGlass))
            .every((glass) => !glass.enabled),
        isTrue);
    await tester.tap(find.byKey(const ValueKey('home-tab-3')));
    await tester.pumpAndSettle();
    expect(find.text('page 3: 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('共享卡片快点和长按释放只回调一次，拖动取消不回调', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_app(Center(
      child: RoundRectangleCard(
          onTap: () => taps++, child: const SizedBox(width: 220, height: 80)),
    )));
    final card = find.byType(RoundRectangleCard);
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(taps, 1);
    final hold = await tester.startGesture(tester.getCenter(card));
    await tester.pump(const Duration(milliseconds: 700));
    await hold.up();
    await tester.pumpAndSettle();
    expect(taps, 2);
    final cancelled = await tester.startGesture(tester.getCenter(card));
    await cancelled.moveBy(const Offset(120, 180));
    await cancelled.up();
    await tester.pumpAndSettle();
    expect(taps, 2);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('按压时切换动画或销毁共享卡片不遗留回调', (tester) async {
    var taps = 0;
    Widget card(bool animate) => _app(Center(
          child: RoundRectangleCard(
            key: const ValueKey('card'),
            animate: animate,
            onTap: () => taps++,
            child: const SizedBox(width: 220, height: 80),
          ),
        ));
    await tester.pumpWidget(card(false));
    await tester.pumpWidget(card(true));
    final gesture = await tester
        .startGesture(tester.getCenter(find.byKey(const ValueKey('card'))));
    await tester.pump(const Duration(milliseconds: 110));
    await tester.pumpWidget(const SizedBox());
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(taps, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄尺寸双行卡保留点击与长按，透明占位不操作', (tester) async {
    var taps = 0;
    var longPresses = 0;
    Widget card({bool transparent = false, bool animate = true}) => _app(
        Center(
          child: TwoLineCard(
            key: const ValueKey('two-line'),
            title: '本学期已完成的所有课程学分',
            content: '1234.5678',
            extraContent: '9999.9999',
            width: 90,
            height: 78,
            animate: animate,
            transparent: transparent,
            onTap: () => taps++,
            onLongPress: () => longPresses++,
          ),
        ),
        textScale: 2);
    await tester.pumpWidget(card(animate: false));
    await tester.pumpWidget(card());
    await tester.longPress(find.byKey(const ValueKey('two-line')));
    await tester.pumpAndSettle();
    expect(longPresses, 1);
    expect(taps, 0);
    await tester.tap(find.byKey(const ValueKey('two-line')));
    await tester.pumpAndSettle();
    expect(taps, 1);
    await tester.pumpWidget(card(transparent: true));
    await tester.tapAt(tester.getCenter(find.byType(TwoLineCard)));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('减少动画下小按钮仍执行操作，窄宽度不溢出', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_app(
      Center(
        child: SizedBox(
          width: 80,
          height: 44,
          child: AnimateButton(
            text: '查看本学期课程',
            onTap: () => taps++,
          ),
        ),
      ),
      reducedMotion: true,
      textScale: 2,
    ));
    await tester.tap(find.byType(AnimateButton));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('高对比下学期按钮保留非颜色的选中提示和语义', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(_app(
        Center(
          child: SizedBox(
            width: 220,
            height: 44,
            child: Row(children: [
              Expanded(
                child: AnimateButton(
                  key: const ValueKey('selected-semester'),
                  text: '当前学期',
                  selected: true,
                  onTap: () {},
                ),
              ),
              Expanded(child: AnimateButton(text: '其他学期', onTap: () {})),
            ]),
          ),
        ),
        highContrast: true,
      ));
      expect(find.byIcon(CupertinoIcons.check_mark), findsOneWidget);
      expect(
          tester
              .getSemantics(find.byKey(const ValueKey('selected-semester')))
              .flagsCollection
              .isSelected,
          Tristate.isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('窄屏玻璃标题保留返回和右侧操作，不与长标题重叠', (tester) async {
    await narrowViewport(tester);
    var actions = 0;
    await tester.pumpWidget(_app(
      GlassPageScaffold(
        child: CustomScrollView(slivers: [
          CelechronSliverTextHeader(
            subtitle: '编辑本学期可用工作时段',
            right: CupertinoButton(
              onPressed: () => actions++,
              child: const Text('完成'),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 1000)),
        ]),
      ),
      textScale: 2,
    ));
    final title = tester.getRect(find.text('编辑本学期可用工作时段'));
    final action = tester.getRect(find.text('完成'));
    expect(title.right, lessThanOrEqualTo(action.left));
    await tester.tap(find.text('完成'));
    expect(actions, 1);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(find.text('编辑本学期可用工作时段'), findsOneWidget);
    expect(
        tester
            .widget<RefractiveGlass>(find.descendant(
              of: find.byType(SliverPersistentHeader),
              matching: find.byType(RefractiveGlass),
            ))
            .enabled,
        isTrue);
    expect(tester.takeException(), isNull);
  });
}
