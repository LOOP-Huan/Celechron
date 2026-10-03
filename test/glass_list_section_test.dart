import 'package:celechron/design/glass_list_section.dart';
import 'package:celechron/design/liquid_glass.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

const _separator = Color(0xFFB126C8);

Widget _app(Widget section,
        {TextDirection direction = TextDirection.ltr,
        Brightness brightness = Brightness.light,
        bool highContrast = false}) =>
    CupertinoApp(
      theme: CupertinoThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          highContrast: highContrast,
          textScaler: const TextScaler.linear(1.3),
        ),
        child: Directionality(textDirection: direction, child: child!),
      ),
      home: CupertinoPageScaffold(
        child: Align(alignment: Alignment.topLeft, child: section),
      ),
    );

void main() {
  for (final scenario in [
    (name: '默认无标题', header: false, leading: true, custom: false, rtl: false),
    (name: '默认标题和页脚', header: true, leading: true, custom: false, rtl: false),
    (
      name: '没有 leading',
      header: true,
      leading: false,
      custom: false,
      rtl: false
    ),
    (name: '自定义边距和 RTL', header: true, leading: false, custom: true, rtl: true),
  ]) {
    testWidgets('${scenario.name}保持原生行、标题、页脚及分隔线的位置', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final header =
          scenario.header ? const Text('分组标题', key: ValueKey('header')) : null;
      final footer =
          scenario.header ? const Text('分组说明', key: ValueKey('footer')) : null;
      final rows = [
        const SizedBox(
            key: ValueKey('first-row'), height: 48, width: double.infinity),
        const SizedBox(
            key: ValueKey('second-row'), height: 60, width: double.infinity),
      ];
      final EdgeInsetsGeometry? margin = scenario.custom
          ? const EdgeInsetsDirectional.fromSTEB(7, 3, 19, 11)
          : null;
      final direction = scenario.rtl ? TextDirection.rtl : TextDirection.ltr;
      Widget section(bool glass) => glass
          ? GlassListSection(
              header: header,
              footer: footer,
              margin: margin,
              topMargin: 27,
              dividerMargin: scenario.custom ? 9 : 14,
              additionalDividerMargin: scenario.custom ? 2 : null,
              hasLeading: scenario.leading,
              separatorColor: _separator,
              children: rows,
            )
          : CupertinoListSection.insetGrouped(
              header: header,
              footer: footer,
              margin: margin,
              topMargin: 27,
              dividerMargin: scenario.custom ? 9 : 14,
              additionalDividerMargin: scenario.custom ? 2 : null,
              hasLeading: scenario.leading,
              separatorColor: _separator,
              children: rows,
            );
      final finders = [
        find.byKey(const ValueKey('first-row')),
        find.byKey(const ValueKey('second-row')),
        find.byWidgetPredicate(
            (widget) => widget is ColoredBox && widget.color == _separator),
        if (scenario.header) ...[
          find.byKey(const ValueKey('header')),
          find.byKey(const ValueKey('footer')),
        ],
      ];
      await tester.pumpWidget(_app(section(false), direction: direction));
      final nativeRects = finders.map(tester.getRect).toList();
      final nativeHeaderStyle = scenario.header
          ? DefaultTextStyle.of(tester.element(finders[3])).style
          : null;
      await tester.pumpWidget(_app(section(true), direction: direction));
      expect(finders.map(tester.getRect).toList(), nativeRects);
      if (scenario.header) {
        expect(DefaultTextStyle.of(tester.element(finders[3])).style,
            nativeHeaderStyle);
      }
      expect(find.byType(GlassSurface), findsOneWidget);
      for (final name in ['header', 'footer']) {
        expect(
            find.descendant(
                of: find.byType(GlassSurface),
                matching: find.byKey(ValueKey(name))),
            findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('只有标题的空分组不生成玻璃框或多余边距', (tester) async {
    const header = Text('暂无记录', key: ValueKey('empty-header'));
    await tester.pumpWidget(
        _app(const CupertinoListSection.insetGrouped(header: header)));
    final native = tester.getRect(find.byKey(const ValueKey('empty-header')));
    await tester
        .pumpWidget(_app(const GlassListSection(header: header, children: [])));
    expect(tester.getRect(find.byKey(const ValueKey('empty-header'))), native);
    expect(find.byType(GlassSurface), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('整组玻璃保留输入、开关和行点击，高对比不增加模糊', (tester) async {
    final text = TextEditingController();
    addTearDown(text.dispose);
    var enabled = false;
    var taps = 0;
    Widget section() => GlassListSection(
          header: const Text('设置'),
          footer: const Text('分组之外的说明'),
          children: [
            CupertinoTextFormFieldRow(controller: text, placeholder: '名称'),
            StatefulBuilder(
                builder: (context, setState) => CupertinoListTile(
                      title: const Text('允许提醒'),
                      trailing: CupertinoSwitch(
                          value: enabled,
                          onChanged: (value) =>
                              setState(() => enabled = value)),
                    )),
            CupertinoListTile(title: const Text('查看详情'), onTap: () => taps++),
          ],
        );
    await tester.pumpWidget(_app(section(), highContrast: true));
    await tester.enterText(find.byType(CupertinoTextField), '小组研讨');
    await tester.tap(find.byType(CupertinoSwitch));
    await tester.tap(find.text('查看详情'));
    await tester.pump();
    expect(enabled, isTrue);
    expect(taps, 1);
    expect(find.byType(GlassSurface), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    await tester.pumpWidget(
        _app(section(), brightness: Brightness.dark, highContrast: true));
    expect(text.text, '小组研讨');
    expect(enabled, isTrue);
    expect(tester.takeException(), isNull);
  });
}
