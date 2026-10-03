import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:celechron/design/refractive_glass.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// These tests observe the filters actually submitted to the engine rather than
// adding counters to production code. Run them with --enable-impeller.
class _RecordingSceneBuilder extends Fake implements ui.SceneBuilder {
  final ui.SceneBuilder delegate = ui.SceneBuilder();
  final List<ui.ImageFilter> filters = [];

  @override
  ui.OffsetEngineLayer pushOffset(
    double dx,
    double dy, {
    ui.OffsetEngineLayer? oldLayer,
  }) => delegate.pushOffset(dx, dy, oldLayer: oldLayer);

  @override
  ui.BackdropFilterEngineLayer pushBackdropFilter(
    ui.ImageFilter filter, {
    ui.BlendMode blendMode = ui.BlendMode.srcOver,
    ui.BackdropFilterEngineLayer? oldLayer,
    int? backdropId,
  }) {
    filters.add(filter);
    return delegate.pushBackdropFilter(
      filter,
      blendMode: blendMode,
      oldLayer: oldLayer,
      backdropId: backdropId,
    );
  }

  @override
  void addPicture(
    ui.Offset offset,
    ui.Picture picture, {
    bool isComplexHint = false,
    bool willChangeHint = false,
  }) => delegate.addPicture(
    offset,
    picture,
    isComplexHint: isComplexHint,
    willChangeHint: willChangeHint,
  );

  @override
  void addRetained(ui.EngineLayer layer) => delegate.addRetained(layer);

  @override
  void pop() => delegate.pop();

  @override
  ui.Scene build() => delegate.build();
}

class _PaintBackdrop extends CustomPainter {
  _PaintBackdrop(this.phase) : super(repaint: phase);

  final ValueNotifier<int> phase;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawColor(
    phase.value == 0 ? const Color(0xFF245378) : const Color(0xFFCA563A),
    BlendMode.src,
  );

  @override
  bool shouldRepaint(_PaintBackdrop oldDelegate) => phase != oldDelegate.phase;
}

List<ui.ImageFilter> _composeLayer(ContainerLayer layer) {
  final builder = _RecordingSceneBuilder();
  layer.addToScene(builder);
  builder.build().dispose();
  return builder.filters;
}

class _Fixture {
  final glassKey = GlobalKey();
  final phase = ValueNotifier(0);
  final transform = ValueNotifier(Matrix4.identity());
  final blur = ValueNotifier(0.9);
  final radius = ValueNotifier(24.0);
  final refraction = ValueNotifier(1.15);
  final cardSize = ValueNotifier(const Size(260, 176));
  late final settings = Listenable.merge([blur, radius, refraction, cardSize]);

  Widget build() => Directionality(
    textDirection: TextDirection.ltr,
    child: Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(painter: _PaintBackdrop(phase)),
        Positioned(
          left: 40,
          top: 210,
          child: ValueListenableBuilder<Matrix4>(
            valueListenable: transform,
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: settings,
                builder: (context, child) => SizedBox(
                  width: cardSize.value.width,
                  height: cardSize.value.height,
                  child: RefractiveGlass(
                    key: glassKey,
                    blurSigma: blur.value,
                    borderRadius: radius.value,
                    refraction: refraction.value,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
            builder: (context, matrix, child) =>
                Transform(transform: matrix, child: child),
          ),
        ),
      ],
    ),
  );

  ContainerLayer layer(WidgetTester tester) {
    final clip = tester.renderObject<RenderClipRRect>(find.byKey(glassKey));
    return clip.child!.debugLayer!;
  }

  List<ui.ImageFilter> compose(WidgetTester tester) {
    return _composeLayer(layer(tester));
  }

  void dispose() {
    phase.dispose();
    transform.dispose();
    blur.dispose();
    radius.dispose();
    refraction.dispose();
    cardSize.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final unsupported = !RefractiveGlass.isSupported;
  setUpAll(() async {
    if (!unsupported) expect(await RefractiveGlass.preload(), isTrue);
  });

  Future<_Fixture> mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 2.75;
    tester.view.physicalSize = const Size(390, 620) * 2.75;
    addTearDown(tester.view.reset);
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.build());
    await tester.pumpAndSettle();
    return fixture;
  }

  testWidgets(
    'native unchanged composition reuses filters with a live backdrop',
    (tester) async {
      final fixture = await mount(tester);
      final original = fixture.compose(tester);
      expect(original, hasLength(2));
      for (var frame = 0; frame < 12; frame++) {
        final filters = fixture.compose(tester);
        expect(
          filters[0],
          same(original[0]),
          reason: 'Unchanged geometry must reuse the native uniform snapshot.',
        );
        expect(
          filters[1],
          same(original[1]),
          reason: 'Unchanged blur must reuse its Gaussian filter.',
        );
      }
      fixture.phase.value = 1;
      await tester.pump();
      final changedBackdrop = fixture.compose(tester);
      expect(changedBackdrop[0], same(original[0]));
      expect(
        changedBackdrop[1],
        same(original[1]),
        reason: 'A new backdrop needs new pixels, not new filter objects.',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: unsupported,
  );

  testWidgets(
    'native retained geometry and blur invalidate only their filters',
    (tester) async {
      final fixture = await mount(tester);
      final originalState = tester.state(find.byKey(fixture.glassKey));
      final original = fixture.compose(tester);
      fixture.transform.value = Matrix4.translationValues(12.25, 26.5, 0);
      await tester.pump();
      final translated = fixture.compose(tester);
      expect(tester.state(find.byKey(fixture.glassKey)), same(originalState));
      expect(translated[0], isNot(same(original[0])));
      expect(translated[1], same(original[1]));
      expect(fixture.compose(tester)[0], same(translated[0]));

      fixture.transform.value = Matrix4.diagonal3Values(.8, .8, 1)
        ..setTranslationRaw(12.25, 26.5, 0);
      await tester.pump();
      final scaled = fixture.compose(tester);
      expect(scaled[0], isNot(same(translated[0])));
      expect(scaled[1], same(original[1]));
      expect(fixture.compose(tester)[0], same(scaled[0]));

      fixture.blur.value = 1.2;
      await tester.pump();
      final blurred = fixture.compose(tester);
      expect(
        blurred[0],
        same(scaled[0]),
        reason: 'Blur changes must not recreate the refraction filter.',
      );
      expect(blurred[1], isNot(same(scaled[1])));
      expect(fixture.compose(tester)[1], same(blurred[1]));
      fixture.blur.value = 0;
      await tester.pump();
      final unblurred = fixture.compose(tester);
      expect(unblurred, hasLength(1));
      expect(unblurred.single, same(scaled[0]));
      fixture.blur.value = .9;
      await tester.pump();
      final restored = fixture.compose(tester);
      expect(restored, hasLength(2));
      expect(restored[0], same(scaled[0]));
      expect(tester.state(find.byKey(fixture.glassKey)), same(originalState));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: unsupported,
  );

  testWidgets(
    'native optical parameters and surface or viewport resize refresh snapshots',
    (tester) async {
      final fixture = await mount(tester);
      var previous = fixture.compose(tester);
      final originalState = tester.state(find.byKey(fixture.glassKey));
      Future<void> expectNewSnapshot() async {
        await tester.pump();
        final current = fixture.compose(tester);
        expect(current[0], isNot(same(previous[0])));
        expect(current[1], same(previous[1]));
        expect(fixture.compose(tester)[0], same(current[0]));
        expect(tester.state(find.byKey(fixture.glassKey)), same(originalState));
        previous = current;
      }

      fixture.radius.value = 30;
      await expectNewSnapshot();
      fixture.refraction.value = .85;
      await expectNewSnapshot();
      fixture.cardSize.value = const Size(270, 184);
      await expectNewSnapshot();
      tester.view.physicalSize = const Size(430, 650) * 2.75;
      await expectNewSnapshot();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: unsupported,
  );

  // Opt-in diagnostic, never a timing threshold in CI. It measures debug-mode
  // CPU composition/SceneBuilder submission, including this recorder's overhead.
  // It does not rasterize scenes or measure GPU frame time, FPS, or battery use.
  testWidgets(
    'native glass composition diagnostic benchmark',
    (tester) async {
      final fixture = await mount(tester);
      final glassLayer = fixture.layer(tester);
      const warmupIterations = 5000;
      for (var warmup = 0; warmup < warmupIterations; warmup++) {
        _composeLayer(glassLayer);
      }
      const iterations = 1000;
      final samples = <double>[];
      for (var batch = 0; batch < 7; batch++) {
        final watch = Stopwatch()..start();
        for (var iteration = 0; iteration < iterations; iteration++) {
          _composeLayer(glassLayer);
        }
        watch.stop();
        samples.add(watch.elapsedMicroseconds / iterations);
      }
      // Count identities after timing. Retaining every old filter in a Set
      // would otherwise add allocation/GC pressure to only the old implementation.
      const identitySamples = 1000;
      final uniqueRefraction = Set<ui.ImageFilter>.identity();
      final uniqueSmoothing = Set<ui.ImageFilter>.identity();
      for (var sample = 0; sample < identitySamples; sample++) {
        final filters = _composeLayer(glassLayer);
        uniqueRefraction.add(filters[0]);
        uniqueSmoothing.add(filters[1]);
      }
      final sorted = [...samples]..sort();
      final report = {
        'scope': 'debug CPU scene composition; no raster/GPU measurement',
        'platform': Platform.operatingSystem,
        'dart': Platform.version,
        'dpr': 2.75,
        'surfaces': 1,
        'warmup': warmupIterations,
        'batches': samples.length,
        'iterationsPerBatch': iterations,
        'microsecondsPerComposition': samples,
        'medianMicroseconds': sorted[sorted.length ~/ 2],
        'identitySamples': identitySamples,
        'uniqueRefractionFilters': uniqueRefraction.length,
        'uniqueSmoothingFilters': uniqueSmoothing.length,
      };
      final encoded = const JsonEncoder.withIndent('  ').convert(report);
      const destination = String.fromEnvironment(
        'GLASS_COMPOSITION_BENCHMARK_OUTPUT',
      );
      if (destination.isNotEmpty) {
        File(destination)
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('$encoded\n');
      }
      debugPrint(encoded);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip:
        unsupported ||
        !const bool.fromEnvironment('GLASS_COMPOSITION_BENCHMARK'),
  );
}
