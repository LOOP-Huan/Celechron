import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:celechron/design/refractive_glass.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// Run with `flutter test --enable-impeller` for actual backdrop shader coverage.
// The default software-Skia suite cannot execute ImageFilter.shader.
const _viewSize = Size(390, 620);
const _cardSize = Size(260, 176);
const _captureDirectory = String.fromEnvironment('GLASS_CAPTURE_DIR');

class _BackdropPattern extends CustomPainter {
  _BackdropPattern(this.phase) : super(repaint: phase);

  final ValueNotifier<int> phase;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
        Offset.zero & size, Paint()..color = const Color(0xFFF4EEDC));
    for (var x = 0; x < size.width; x += 20) {
      canvas.drawRect(
        Rect.fromLTWH(x.toDouble(), 0, 7, size.height),
        Paint()
          ..color = phase.value == 0
              ? const Color(0xFF234E64)
              : const Color(0xFFCA563A),
      );
    }
    for (var y = 0; y < size.height; y += 28) {
      canvas.drawRect(Rect.fromLTWH(0, y.toDouble(), size.width, 2),
          Paint()..color = const Color(0xFF71816C));
    }
  }

  @override
  bool shouldRepaint(_BackdropPattern oldDelegate) =>
      phase != oldDelegate.phase;
}

class _ForegroundPattern extends CustomPainter {
  const _ForegroundPattern();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
        Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));
    for (var x = 0; x < size.width; x += 4) {
      canvas.drawRect(Rect.fromLTWH(x.toDouble(), 0, 2, size.height),
          Paint()..color = const Color(0xFF000000));
    }
  }

  @override
  bool shouldRepaint(_ForegroundPattern oldDelegate) => false;
}

class _BuildCounter extends StatelessWidget {
  const _BuildCounter({required this.onBuild, required this.child});

  final VoidCallback onBuild;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return child;
  }
}

Widget _glass(
        {bool enabled = true, double refraction = 1.15, double blur = .9}) =>
    SizedBox.fromSize(
      size: _cardSize,
      child: RefractiveGlass(
        enabled: enabled,
        refraction: refraction,
        blurSigma: blur,
        borderRadius: 30,
        child: const Stack(children: [
          Positioned(
            left: 30,
            top: 32,
            width: 64,
            height: 20,
            child: CustomPaint(painter: _ForegroundPattern()),
          ),
        ]),
      ),
    );

Widget _scene(GlobalKey boundary, ValueNotifier<int> phase, Widget overlay) =>
    Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: boundary,
        child: Stack(fit: StackFit.expand, children: [
          CustomPaint(painter: _BackdropPattern(phase)),
          overlay,
        ]),
      ),
    );

Future<Uint8List> _capture(
    WidgetTester tester, GlobalKey boundary, double dpr, String name) async {
  // The shader cache was warmed outside fake async. Let newly mounted widgets'
  // real-zone completion callbacks request their first shader-backed frame.
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  final bytes = await tester.runAsync(() async {
    final image = await (boundary.currentContext!.findRenderObject()!
            as RenderRepaintBoundary)
        .toImage(pixelRatio: dpr);
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (_captureDirectory.isNotEmpty) {
      final directory = Directory(_captureDirectory)
        ..createSync(recursive: true);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${directory.path}/$name-dpr${dpr.toInt()}.png')
          .writeAsBytesSync(png!.buffer.asUint8List());
    }
    image.dispose();
    return rgba!.buffer.asUint8List();
  });
  expect(tester.takeException(), isNull);
  return bytes!;
}

double _difference(Uint8List first, Uint8List second, Rect region, double dpr) {
  final width = (_viewSize.width * dpr).round();
  var total = 0;
  var samples = 0;
  for (var y = (region.top * dpr).ceil(); y < region.bottom * dpr; y++) {
    for (var x = (region.left * dpr).ceil(); x < region.right * dpr; x++) {
      final index = (y * width + x) * 4;
      for (var channel = 0; channel < 3; channel++) {
        total += (first[index + channel] - second[index + channel]).abs();
        samples++;
      }
    }
  }
  return total / samples;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final unsupported = !RefractiveGlass.isSupported;
  // Load once outside a widget test's fake-async zone. The production cache
  // deliberately retains this Future across widgets and test cases.
  setUpAll(() async {
    if (!unsupported) expect(await RefractiveGlass.preload(), isTrue);
  });

  for (final dpr in [1.0, 2.0]) {
    testWidgets(
        'native glass refracts live backdrop and keeps foreground sharp at DPR $dpr',
        (tester) async {
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = _viewSize * dpr;
      addTearDown(tester.view.reset);
      final phase = ValueNotifier<int>(0);
      addTearDown(phase.dispose);
      final boundary = GlobalKey();
      const card = Rect.fromLTWH(40, 210, 260, 176);
      const foreground = Rect.fromLTWH(72, 244, 60, 16);
      Future<Uint8List> render(String name,
          {bool enabled = true, double refraction = 1.15}) async {
        await tester.pumpWidget(_scene(
            boundary,
            phase,
            Positioned.fromRect(
                rect: card,
                child: _glass(enabled: enabled, refraction: refraction))));
        await tester.pumpAndSettle();
        return _capture(tester, boundary, dpr, name);
      }

      final plain = await render('plain', enabled: false);
      final zero = await render('zero-refraction', refraction: 0);
      final glass = await render('glass');
      expect(_difference(plain, glass, card.deflate(4), dpr), greaterThan(1));
      expect(_difference(zero, glass, card.deflate(4), dpr), greaterThan(1),
          reason: 'Blur or an opaque tint alone must not satisfy refraction.');
      expect(_difference(plain, glass, foreground, dpr), 0,
          reason: 'Foreground strokes must remain sharp and unfiltered.');

      // Only the background CustomPainter repaints; the glass widget stays put.
      phase.value = 1;
      final live = await _capture(tester, boundary, dpr, 'live-background');
      expect(_difference(glass, live, card.deflate(4), dpr), greaterThan(5));
      expect(_difference(glass, live, foreground, dpr), 0);
      await tester.pumpWidget(const SizedBox());
    }, skip: unsupported);

    testWidgets(
        'retained native glass follows scrolling without a widget rebuild at DPR $dpr',
        (tester) async {
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = _viewSize * dpr;
      addTearDown(tester.view.reset);
      final boundary = GlobalKey();
      final phase = ValueNotifier<int>(0);
      final scroll = ScrollController();
      addTearDown(phase.dispose);
      addTearDown(scroll.dispose);
      var builds = 0;
      final retained = RepaintBoundary(
          child: _BuildCounter(onBuild: () => builds++, child: _glass()));
      await tester.pumpWidget(_scene(
        boundary,
        phase,
        SingleChildScrollView(
            controller: scroll,
            child: SizedBox(
                height: 1500,
                child: Stack(children: [
                  Positioned(left: 40, top: 400, child: retained)
                ]))),
      ));
      await tester.pumpAndSettle();
      final initialBuilds = builds;
      await _capture(tester, boundary, dpr, 'before-scroll');
      scroll.jumpTo(140);
      await tester.pump();
      final moved = await _capture(tester, boundary, dpr, 'retained-scroll');
      expect(builds, initialBuilds,
          reason:
              'This case must exercise retained layers, not a glass rebuild.');

      await tester.pumpWidget(_scene(
          boundary, phase, Positioned(left: 40, top: 260, child: _glass())));
      await tester.pumpAndSettle();
      final fresh =
          await _capture(tester, boundary, dpr, 'fresh-scroll-position');
      expect(
          _difference(
              moved, fresh, const Rect.fromLTWH(40, 260, 260, 176), dpr),
          lessThan(.1),
          reason:
              'Retained glass must match fresh geometry at its new screen position.');
      await tester.pumpWidget(const SizedBox());
    }, skip: unsupported);
  }

  testWidgets(
      'retained native glass follows a scaled ancestor without rebuilding',
      (tester) async {
    const dpr = 2.0;
    tester.view.devicePixelRatio = dpr;
    tester.view.physicalSize = _viewSize * dpr;
    addTearDown(tester.view.reset);
    final phase = ValueNotifier<int>(0);
    final transform = ValueNotifier<Matrix4>(Matrix4.identity());
    addTearDown(phase.dispose);
    addTearDown(transform.dispose);
    final boundary = GlobalKey();
    var builds = 0;
    final retained = RepaintBoundary(
        child: _BuildCounter(onBuild: () => builds++, child: _glass()));
    Widget placement(Widget child) => Positioned(
        left: 55,
        top: 230,
        child: ValueListenableBuilder<Matrix4>(
            valueListenable: transform,
            child: child,
            builder: (context, matrix, child) =>
                Transform(transform: matrix, child: child)));
    await tester.pumpWidget(_scene(boundary, phase, placement(retained)));
    await tester.pumpAndSettle();
    final initialBuilds = builds;
    await _capture(tester, boundary, dpr, 'before-transform');
    transform.value = Matrix4.diagonal3Values(.8, .8, 1)
      ..setTranslationRaw(12, 26, 0);
    final moved = await _capture(tester, boundary, dpr, 'retained-transform');
    expect(builds, initialBuilds);
    await tester.pumpWidget(_scene(boundary, phase, placement(_glass())));
    await tester.pumpAndSettle();
    final fresh =
        await _capture(tester, boundary, dpr, 'fresh-transform-position');
    expect(
        _difference(moved, fresh, const Rect.fromLTWH(67, 256, 208, 140), dpr),
        lessThan(.1));
    await tester.pumpWidget(const SizedBox());
  }, skip: unsupported);
}
