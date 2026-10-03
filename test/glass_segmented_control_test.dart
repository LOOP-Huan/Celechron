import 'package:celechron/design/glass_geometry.dart';
import 'package:celechron/design/glass_segmented_control.dart';
import 'package:celechron/design/liquid_glass.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _labels = {0: Text('预约研讨间'), 1: Text('我的预约'), 2: Text('其他')};

Widget _host({
  required ValueChanged<int>? onChanged,
  int selected = 0,
  Set<int> disabled = const {},
  Map<int, Widget> children = _labels,
  double width = 300,
  double scale = 1,
  TextDirection direction = TextDirection.ltr,
}) => CupertinoApp(
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Directionality(
      textDirection: direction,
      child: Center(
        child: SizedBox(
          width: width,
          child: GlassSegmentedControl<int>(
            groupValue: selected,
            children: children,
            disabledChildren: disabled,
            onValueChanged: onChanged,
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('tap updates selection once with accessible selected state', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final changes = <int>[];
    var selected = 0;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          return _host(
            selected: selected,
            onChanged: (value) {
              changes.add(value);
              setState(() => selected = value);
            },
          );
        },
      ),
    );
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('预约研讨间'))
          .flagsCollection
          .isSelected
          .toBoolOrNull(),
      true,
    );
    await tester.tap(find.text('我的预约'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的预约'));
    await tester.pumpAndSettle();
    expect(changes, [1]);
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('我的预约'))
          .flagsCollection
          .isSelected
          .toBoolOrNull(),
      true,
    );
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('预约研讨间'))
          .flagsCollection
          .isSelected
          .toBoolOrNull(),
      false,
    );
    semantics.dispose();
  });

  testWidgets('disabled segments cannot activate and arrows skip them', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final changes = <int>[];
    await tester.pumpWidget(
      _host(
        onChanged: (value) {
          changes.add(value);
          // The booking pages dismiss focused text fields when changing tabs.
          FocusManager.instance.primaryFocus?.unfocus();
        },
        disabled: {1},
      ),
    );
    await tester.tap(find.text('我的预约'));
    expect(changes, isEmpty);
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('我的预约'))
          .flagsCollection
          .isEnabled
          .toBoolOrNull(),
      false,
    );
    tester
        .widget<CupertinoButton>(find.widgetWithText(CupertinoButton, '预约研讨间'))
        .focusNode!
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(changes, [2]);
    expect(
      tester
          .widget<CupertinoButton>(find.widgetWithText(CupertinoButton, '其他'))
          .focusNode!
          .hasFocus,
      true,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    expect(changes, [2, 2]);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(changes, [2, 2, 2]);

    await tester.pumpWidget(_host(onChanged: null));
    await tester.tap(find.text('其他'));
    await tester.pumpAndSettle();
    expect(changes, [2, 2, 2]);
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('预约研讨间'))
          .flagsCollection
          .isEnabled
          .toBoolOrNull(),
      false,
    );
    semantics.dispose();
  });

  testWidgets('RTL arrows follow visual direction', (tester) async {
    final changes = <int>[];
    await tester.pumpWidget(
      _host(onChanged: changes.add, direction: TextDirection.rtl),
    );
    tester
        .widget<CupertinoButton>(find.widgetWithText(CupertinoButton, '预约研讨间'))
        .focusNode!
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(changes, [2]);
    expect(
      tester.getCenter(find.text('预约研讨间')).dx,
      greaterThan(tester.getCenter(find.text('其他')).dx),
    );
  });

  testWidgets(
    'drag previews without committing until release; cancel is inert',
    (tester) async {
      final changes = <int>[];
      await tester.pumpWidget(_host(onChanged: changes.add));
      final start = tester.getCenter(find.text('预约研讨间'));
      final end = tester.getCenter(find.text('其他'));
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(25, 0));
      await tester.pump();
      await gesture.moveTo(end);
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(changes, [2]);
      final cancelled = await tester.startGesture(start);
      await cancelled.moveBy(const Offset(25, 0));
      await cancelled.moveTo(end);
      await cancelled.cancel();
      await tester.pumpAndSettle();
      expect(changes, [2]);
    },
  );

  testWidgets(
    'large labels grow vertically and thumb uses concentric corners',
    (tester) async {
      await tester.pumpWidget(
        _host(
          onChanged: (_) {},
          width: 280,
          scale: 2.5,
          children: const {0: Text('预约研讨间'), 1: Text('我的预约记录')},
        ),
      );
      await tester.pumpAndSettle();
      final surface = tester.widget<GlassSurface>(find.byType(GlassSurface));
      expect(surface.borderRadius, GlassGeometry.surfaceRadius);
      expect(surface.padding, const EdgeInsets.all(GlassGeometry.segmentInset));
      final thumb = find.descendant(
        of: find.byType(AnimatedAlign),
        matching: find.byType(DecoratedBox),
      );
      final decoration =
          tester.widget<DecoratedBox>(thumb).decoration as BoxDecoration;
      expect(
        decoration.borderRadius,
        BorderRadius.circular(
          GlassGeometry.insetRadius(GlassGeometry.segmentInset),
        ),
      );
      final rect = tester.getRect(find.byType(GlassSegmentedControl<int>));
      expect(rect.height, greaterThan(80));
      for (final text in ['预约研讨间', '我的预约记录']) {
        final label = tester.getRect(find.text(text));
        expect(rect.contains(label.topLeft), true);
        expect(rect.contains(label.bottomRight), true);
      }
      expect(tester.takeException(), isNull);
    },
  );
}
