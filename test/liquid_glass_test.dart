import 'package:celechron/design/liquid_glass.dart';
import 'package:celechron/design/refractive_glass.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app({
  required Widget child,
  Brightness brightness = Brightness.light,
  bool highContrast = false,
}) =>
    CupertinoApp(
      theme: CupertinoThemeData(
        brightness: brightness,
        primaryColor: GlassPalette.accent,
        primaryContrastingColor: GlassPalette.onAccent,
        barBackgroundColor: GlassPalette.barColor,
      ),
      builder: (context, value) => MediaQuery(
        data: MediaQuery.of(context).copyWith(highContrast: highContrast),
        child: value!,
      ),
      home: GlassPageScaffold(child: SafeArea(child: child)),
    );

void main() {
  testWidgets('浅深色主按钮文字与填充背景均有足够对比度', (tester) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(_app(
        brightness: brightness,
        child: CupertinoButton.filled(
          onPressed: () {},
          child: const Text('确认预约'),
        ),
      ));
      final context = tester.element(find.text('确认预约'));
      final foreground = DefaultTextStyle.of(context).style.color!;
      final background = CupertinoTheme.of(context).primaryColor;
      final a = foreground.computeLuminance();
      final b = background.computeLuminance();
      final ratio = a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05);
      expect(ratio, greaterThanOrEqualTo(4.5), reason: brightness.name);
    }
  });

  testWidgets('高对比度玻璃采用实色并关闭背景模糊，按钮仍可操作', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_app(
      highContrast: true,
      child: Center(
        child: GlassSurface(
          blur: true,
          child: CupertinoButton(
            onPressed: () => taps++,
            child: const Text('确认'),
          ),
        ),
      ),
    ));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(
      tester.widgetList<RefractiveGlass>(find.byType(RefractiveGlass)),
      everyElement(isA<RefractiveGlass>()
          .having((glass) => glass.enabled, 'enabled', isFalse)),
    );
    final context = tester.element(find.byType(GlassSurface));
    final material = GlassPalette.decoration(context);
    expect(material.color!.a, 1);
    expect(material.gradient, isNull);
    await tester.tap(find.text('确认'));
    expect(taps, 1);
  });

  testWidgets('主题变化更新玻璃材质且保留输入内容与焦点', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    Widget field() => GlassSurface(
          key: const ValueKey('form'),
          padding: const EdgeInsets.all(16),
          child: CupertinoTextField(controller: controller),
        );
    await tester.pumpWidget(_app(child: Center(child: field())));
    await tester.enterText(find.byType(CupertinoTextField), '预约主题');
    final light =
        GlassPalette.surfaceColor(tester.element(find.byType(GlassSurface)));
    await tester.pumpWidget(
        _app(brightness: Brightness.dark, child: Center(child: field())));
    final dark =
        GlassPalette.surfaceColor(tester.element(find.byType(GlassSurface)));
    expect(dark.computeLuminance(), lessThan(light.computeLuminance()));
    expect(controller.text, '预约主题');
    expect(tester.testTextInput.isVisible, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('玻璃页面保留导航返回和键盘避让', (tester) async {
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(CupertinoApp(
      home: Builder(
        builder: (context) => GlassPageScaffold(
          child: Center(
            child: CupertinoButton(
              onPressed: () => Navigator.of(context).push(CupertinoPageRoute(
                builder: (_) => const GlassPageScaffold(
                  navigationBar: CupertinoNavigationBar(middle: Text('详情')),
                  child: SafeArea(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Text('底部内容', key: ValueKey('bottom')),
                    ),
                  ),
                ),
              )),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final media =
        MediaQuery.of(tester.element(find.byKey(const ValueKey('bottom'))));
    expect(
        tester.getBottomLeft(find.byKey(const ValueKey('bottom'))).dy,
        lessThanOrEqualTo(
            media.size.height - 240 / tester.view.devicePixelRatio));
    await tester.tap(find.byType(CupertinoNavigationBarBackButton));
    await tester.pumpAndSettle();
    expect(find.text('打开'), findsOneWidget);
    expect(find.text('底部内容'), findsNothing);
  });
}
