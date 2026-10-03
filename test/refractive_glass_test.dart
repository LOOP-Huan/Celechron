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
    child: Stack(children: [
      Positioned(
        left: 31,
        top: 57,
        width: _cardSize.width,
        height: _cardSize.height,
        child: card,
      ),
    ]),
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
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(_boundaryKey));
    final image = await boundary.toImage();
    try {
      return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
          .buffer
          .asUint8List();
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
              4, (channel) => (a[offset + channel] - b[offset + channel]).abs())
          .any((delta) => delta > 1)) {
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
      await tester.pumpWidget(_scene(RefractiveGlass(
        key: ValueKey(index),
        child: const SizedBox.expand(),
      )));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled完全保留背景像素，不偷偷应用模糊', (tester) async {
    await initialize(tester);
    final plain = await _capture(
        tester,
        _scene(const ClipRRect(
            borderRadius: BorderRadius.all(Radius.circular(24)),
            child: SizedBox.expand())));
    final disabled = await _capture(
        tester,
        _scene(const RefractiveGlass(
          enabled: false,
          child: SizedBox.expand(),
        )));
    expect(_pixelDifferences(plain, disabled), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('嵌套玻璃不会对外层材质再折射或模糊一次', (tester) async {
    await initialize(tester);
    final single = await _capture(
        tester,
        _scene(const RefractiveGlass(
          child: SizedBox.expand(),
        )));
    final nested = await _capture(
        tester,
        _scene(const RefractiveGlass(
          child: RefractiveGlass(child: SizedBox.expand()),
        )));
    expect(
        _pixelDifferences(single, nested,
            region: const Rect.fromLTWH(37, 63, 158, 134)),
        0);
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
                  sigmaX: 0.9, sigmaY: 0.9, tileMode: ui.TileMode.clamp),
              child: const SizedBox.expand(),
            ),
          ),
          opacity: true,
        ));
    final actual = await _capture(
        tester,
        _scene(
            const RefractiveGlass(
              child: SizedBox.expand(),
            ),
            opacity: true));
    expect(_pixelDifferences(expected, actual), 0);
    expect(tester.takeException(), isNull);
  });
}
