import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:celechron/design/refractive_glass.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _boundaryKey = ValueKey('glass-scene');
const _cardSize = Size(170, 146);

class _Grid extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xFFF6F1E6), BlendMode.src);
    final paint = Paint()..color = const Color(0xFF245378);
    for (var x = 0.0; x < size.width; x += 12) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 3, size.height), paint);
    }
    paint.color = const Color(0xFFBA4836);
    for (var y = 0.0; y < size.height; y += 17) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 2), paint);
    }
  }

  @override
  bool shouldRepaint(_Grid oldDelegate) => false;
}

Widget _scene(Widget card, {bool opacity = false}) {
  Widget content = CustomPaint(
    painter: _Grid(),
    child: Stack(
      children: [
        Positioned(
          left: 31,
          top: 57,
          width: _cardSize.width,
          height: _cardSize.height,
          child: card,
        ),
      ],
    ),
  );
  if (opacity) content = Opacity(opacity: 0.65, child: content);
  return Directionality(
    textDirection: TextDirection.ltr,
    child: RepaintBoundary(
      key: _boundaryKey,
      child: ColoredBox(color: const Color(0xFFFFFFFF), child: content),
    ),
  );
}

Future<Uint8List> _capture(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(widget);
  await tester.pumpAndSettle();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  return (await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_boundaryKey),
    );
    final image = await boundary.toImage();
    try {
      return (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }))!;
}

int _pixelDifferences(Uint8List a, Uint8List b, {Rect? region}) {
  var differences = 0;
  final area = region ?? const Rect.fromLTWH(0, 0, 240, 320);
  for (var y = area.top.toInt(); y < area.bottom.toInt(); y++) {
    for (var x = area.left.toInt(); x < area.right.toInt(); x++) {
      final offset = (y * 240 + x) * 4;
      if (List.generate(
        4,
        (channel) => (a[offset + channel] - b[offset + channel]).abs(),
      ).any((delta) => delta > 1)) {
        differences++;
      }
    }
  }
  return differences;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    expect(await RefractiveGlass.preload(), RefractiveGlass.isSupported);
  });

  Future<void> initialize(WidgetTester tester) async {
    tester.view.physicalSize = const Size(240, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('反复装卸玻璃不会访问已释放shader', (tester) async {
    await initialize(tester);
    for (var index = 0; index < 3; index++) {
      await tester.pumpWidget(
        _scene(
          RefractiveGlass(key: ValueKey(index), child: const SizedBox.expand()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled完全保留背景像素，不偷偷应用模糊', (tester) async {
    await initialize(tester);
    final plain = await _capture(
      tester,
      _scene(
        const ClipRRect(
          borderRadius: BorderRadius.all(Radius.circular(24)),
          child: SizedBox.expand(),
        ),
      ),
    );
    final disabled = await _capture(
      tester,
      _scene(const RefractiveGlass(enabled: false, child: SizedBox.expand())),
    );
    expect(_pixelDifferences(plain, disabled), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('嵌套玻璃不会对外层材质再折射或模糊一次', (tester) async {
    await initialize(tester);
    final single = await _capture(
      tester,
      _scene(const RefractiveGlass(child: SizedBox.expand())),
    );
    final nested = await _capture(
      tester,
      _scene(
        const RefractiveGlass(child: RefractiveGlass(child: SizedBox.expand())),
      ),
    );
    expect(
      _pixelDifferences(
        single,
        nested,
        region: const Rect.fromLTWH(37, 63, 158, 134),
      ),
      0,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('透明离屏祖先使用轻blur回退，不用错误全屏原点折射', (tester) async {
    await initialize(tester);
    final expected = await _capture(
      tester,
      _scene(
        ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(
              sigmaX: 0.9,
              sigmaY: 0.9,
              tileMode: ui.TileMode.clamp,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        opacity: true,
      ),
    );
    final actual = await _capture(
      tester,
      _scene(const RefractiveGlass(child: SizedBox.expand()), opacity: true),
    );
    expect(_pixelDifferences(expected, actual), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('native同一状态切换模糊和启用后可复用图层，移除重插仍恢复原像素', (tester) async {
    await initialize(tester);
    final glassKey = GlobalKey();
    Widget frame({
      double sigma = 0.9,
      bool enabled = true,
      bool present = true,
    }) => _scene(
      present
          ? RefractiveGlass(
              key: glassKey,
              blurSigma: sigma,
              enabled: enabled,
              child: const SizedBox.expand(),
            )
          : const SizedBox.expand(),
    );

    Future<Uint8List> capture(Widget widget) async {
      final pixels = await _capture(tester, widget);
      expect(
        tester.takeException(),
        isNull,
        reason: 'Every composition must avoid reusing a disposed EngineLayer.',
      );
      return pixels;
    }

    final plain = await capture(frame(present: false));
    final original = await capture(frame());
    final originalState = tester.state(find.byKey(glassKey));

    final unblurred = await capture(frame(sigma: 0));
    expect(tester.state(find.byKey(glassKey)), same(originalState));
    expect(
      _pixelDifferences(
        original,
        unblurred,
        region: const Rect.fromLTWH(65, 92, 95, 70),
      ),
      greaterThan(0),
      reason: 'The native smoothing pass must actually affect the backdrop.',
    );

    final blurredAgain = await capture(frame());
    expect(tester.state(find.byKey(glassKey)), same(originalState));
    expect(_pixelDifferences(original, blurredAgain), 0);

    final disabled = await capture(frame(enabled: false));
    expect(tester.state(find.byKey(glassKey)), same(originalState));
    expect(
      _pixelDifferences(plain, disabled),
      0,
      reason: 'Disabling must remove both refraction and smoothing.',
    );
    final enabledAgain = await capture(frame());
    expect(tester.state(find.byKey(glassKey)), same(originalState));
    expect(_pixelDifferences(original, enabledAgain), 0);

    final removed = await capture(frame(present: false));
    expect(originalState.mounted, false);
    expect(_pixelDifferences(plain, removed), 0);
    final reinserted = await capture(frame());
    expect(tester.state(find.byKey(glassKey)), isNot(same(originalState)));
    expect(
      _pixelDifferences(original, reinserted),
      0,
      reason: 'Reinserting the same key must create fresh native resources.',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  }, skip: !RefractiveGlass.isSupported);

  testWidgets('native保留子树进出透明离屏祖先只回退一次blur并恢复折射', (tester) async {
    await initialize(tester);
    final glassKey = GlobalKey();
    final opacity = ValueNotifier(1.0);
    addTearDown(opacity.dispose);
    final retainedScene = Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: _boundaryKey,
        child: ColoredBox(
          color: const Color(0xFFFFFFFF),
          child: ValueListenableBuilder<double>(
            valueListenable: opacity,
            // Only Opacity rebuilds when the notifier changes. The card keeps
            // both its State and retained render subtree across these frames.
            child: CustomPaint(
              painter: _Grid(),
              child: Stack(
                children: [
                  Positioned(
                    left: 31,
                    top: 57,
                    width: _cardSize.width,
                    height: _cardSize.height,
                    child: RefractiveGlass(
                      key: glassKey,
                      child: const SizedBox.expand(),
                    ),
                  ),
                ],
              ),
            ),
            builder: (context, value, child) =>
                Opacity(opacity: value, child: child),
          ),
        ),
      ),
    );
    final singleBlur = await _capture(
      tester,
      _scene(
        ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(
              sigmaX: 0.9,
              sigmaY: 0.9,
              tileMode: ui.TileMode.clamp,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        opacity: true,
      ),
    );
    expect(tester.takeException(), isNull);
    final original = await _capture(tester, retainedScene);
    final originalState = tester.state(find.byKey(glassKey));
    expect(tester.takeException(), isNull);

    for (var cycle = 0; cycle < 2; cycle++) {
      opacity.value = 0.65;
      final offscreen = await _capture(tester, retainedScene);
      expect(tester.takeException(), isNull);
      expect(tester.state(find.byKey(glassKey)), same(originalState));
      expect(
        _pixelDifferences(singleBlur, offscreen),
        0,
        reason: 'Entering an offscreen ancestor must apply exactly one blur.',
      );

      opacity.value = 1;
      final restored = await _capture(tester, retainedScene);
      expect(tester.takeException(), isNull);
      expect(tester.state(find.byKey(glassKey)), same(originalState));
      expect(
        _pixelDifferences(original, restored),
        0,
        reason: 'Retained geometry must recover the original refraction.',
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  }, skip: !RefractiveGlass.isSupported);
}
