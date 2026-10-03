import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:celechron/design/refractive_glass.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// Native-only overlap diagnostic. The two glass surfaces are Stack siblings,
// matching a floating dock over a content card, rather than nested materials.
// Run with --enable-impeller --concurrency=1. Optional dart defines:
// GLASS_OVERLAP_CAPTURE_DIR: PNG and metrics output directory.
// GLASS_OVERLAP_FONT: path to a CJK font, for realistic Chinese/Latin captures.
// Frequency metrics are observational. Foreground isolation and quarter-pixel
// temporal changes have behavioral assertions, independent of the blur profile.
const _captureDirectory = String.fromEnvironment('GLASS_OVERLAP_CAPTURE_DIR');
const _fontPath = String.fromEnvironment('GLASS_OVERLAP_FONT');
const _fontFamily = 'GlassOverlapFixture';
const _viewSize = Size(390, 560);
const _lower = Rect.fromLTWH(18, 76, 354, 446);
const _upper = Rect.fromLTWH(36, 220, 318, 188);
const _foreground = Rect.fromLTWH(50, 370, 290, 26);
const _offsets = [0.0, .25, .5, .75];

String _dprLabel(double dpr) =>
    dpr == dpr.roundToDouble() ? dpr.toInt().toString() : dpr.toString();

class _BackgroundPattern extends CustomPainter {
  const _BackgroundPattern();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFCADBE8),
    );
    for (var x = 0.0; x < size.width; x += 29) {
      canvas.drawRect(
        Rect.fromLTWH(x, 0, 10, size.height),
        Paint()..color = const Color(0xFFC2D0C4),
      );
    }
    canvas.drawCircle(
      const Offset(325, 96),
      90,
      Paint()..color = const Color(0xFFF3D5B5),
    );
  }

  @override
  bool shouldRepaint(_BackgroundPattern oldDelegate) => false;
}

class _FineLines extends CustomPainter {
  const _FineLines(this.dpr);
  final double dpr;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..isAntiAlias = false
      ..color = const Color(0xFF425569);
    for (var row = 0; row < 16; row++) {
      // Alternate a physical-pixel rule and a logical-pixel rule.
      canvas.drawRect(
        Rect.fromLTWH(
          12,
          33 + row * 26,
          size.width - 24,
          row.isEven ? 1 / dpr : 1,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_FineLines oldDelegate) => dpr != oldDelegate.dpr;
}

TextStyle _textStyle(double size, {FontWeight? weight}) => TextStyle(
  fontFamily: _fontPath.isEmpty ? null : _fontFamily,
  fontSize: size,
  height: 1.15,
  fontWeight: weight,
  color: const Color(0xFF172230),
);

Widget _lowerGlass(double dpr) => RefractiveGlass(
  key: const ValueKey('overlap-lower-glass'),
  child: DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0x18FFFFFF),
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0x99FFFFFF), width: .6),
    ),
    child: Stack(
      children: [
        Positioned.fill(child: CustomPaint(painter: _FineLines(dpr))),
        for (var row = 0; row < 16; row++)
          Positioned(
            left: 14,
            top: 12 + row * 26,
            child: Text(
              row.isEven
                  ? '下层14px 课程 Library Aa 012345'
                  : '下层16px 小组讨论 Study Bb 2026',
              style: _textStyle(row.isEven ? 14 : 16),
            ),
          ),
      ],
    ),
  ),
);

Widget _upperGlass({required bool enabled}) => RefractiveGlass(
  key: const ValueKey('overlap-upper-glass'),
  enabled: enabled,
  child: DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0x12FFFFFF),
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0xB3FFFFFF), width: .6),
    ),
    child: Stack(
      children: [
        // An opaque witness isolates foreground rasterization from changes
        // behind antialiased glyph edges. It is painted AFTER the filter.
        Positioned(
          left: 14,
          top: 150,
          width: 290,
          height: 26,
          child: ColoredBox(
            color: const Color(0xFFF7F9FC),
            child: Center(
              child: Text(
                '上层前景 Foreground 16px',
                style: _textStyle(16, weight: FontWeight.w600),
              ),
            ),
          ),
        ),
      ],
    ),
  ),
);

Widget _scene(
  GlobalKey boundary,
  ValueNotifier<double> position,
  double dpr, {
  required bool upperEnabled,
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: RepaintBoundary(
    key: boundary,
    child: Stack(
      fit: StackFit.expand,
      children: [
        const CustomPaint(painter: _BackgroundPattern()),
        Positioned(
          left: 18,
          top: 20,
          child: Text('双层玻璃 · 下层文字与上层浮动卡片', style: _textStyle(16)),
        ),
        Positioned.fromRect(rect: _lower, child: _lowerGlass(dpr)),
        Positioned.fromRect(
          rect: _upper,
          child: ValueListenableBuilder<double>(
            valueListenable: position,
            child: _upperGlass(enabled: upperEnabled),
            builder: (context, value, child) =>
                Transform.translate(offset: Offset(value, value), child: child),
          ),
        ),
      ],
    ),
  ),
);

Future<Uint8List> _capture(
  WidgetTester tester,
  GlobalKey boundary,
  double dpr,
  String name,
) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  final rgba = await tester.runAsync(() async {
    final image =
        await (boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary)
            .toImage(pixelRatio: dpr);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (_captureDirectory.isNotEmpty) {
      final directory = Directory(_captureDirectory)
        ..createSync(recursive: true);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '${directory.path}/$name-dpr${_dprLabel(dpr)}.png',
      ).writeAsBytesSync(png!.buffer.asUint8List());
    }
    image.dispose();
    return bytes!.buffer.asUint8List();
  });
  expect(tester.takeException(), isNull);
  return rgba!;
}

double _difference(Uint8List first, Uint8List second, Rect region, double dpr) {
  final width = (_viewSize.width * dpr).round();
  var sum = 0;
  var samples = 0;
  for (var y = (region.top * dpr).ceil(); y < region.bottom * dpr; y++) {
    for (var x = (region.left * dpr).ceil(); x < region.right * dpr; x++) {
      final index = (y * width + x) * 4;
      for (var channel = 0; channel < 3; channel++) {
        sum += (first[index + channel] - second[index + channel]).abs();
        samples++;
      }
    }
  }
  return sum / samples;
}

int _maximumDifference(
  Uint8List first,
  Uint8List second,
  Rect region,
  double dpr,
) {
  final width = (_viewSize.width * dpr).round();
  var maximum = 0;
  for (var y = (region.top * dpr).ceil(); y < region.bottom * dpr; y++) {
    for (var x = (region.left * dpr).ceil(); x < region.right * dpr; x++) {
      final index = (y * width + x) * 4;
      for (var channel = 0; channel < 3; channel++) {
        final difference = (first[index + channel] - second[index + channel])
            .abs();
        if (difference > maximum) maximum = difference;
      }
    }
  }
  return maximum;
}

// High-frequency energy can change with legitimate refraction as well as
// aliasing. Record it for side-by-side diagnosis, never as a quality verdict.
double _highFrequencyEnergy(Uint8List rgba, Rect region, double dpr) {
  final width = (_viewSize.width * dpr).round();
  double luminance(int x, int y) {
    final index = (y * width + x) * 4;
    return .2126 * rgba[index] +
        .7152 * rgba[index + 1] +
        .0722 * rgba[index + 2];
  }

  var energy = 0.0;
  var samples = 0;
  for (var y = (region.top * dpr).ceil(); y < region.bottom * dpr; y++) {
    for (var x = (region.left * dpr).ceil(); x < region.right * dpr; x++) {
      final laplacian =
          luminance(x - 1, y) +
          luminance(x + 1, y) +
          luminance(x, y - 1) +
          luminance(x, y + 1) -
          4 * luminance(x, y);
      energy += laplacian * laplacian;
      samples++;
    }
  }
  return energy / samples;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final unsupported = !RefractiveGlass.isSupported;
  setUpAll(() async {
    if (unsupported) return;
    if (_fontPath.isNotEmpty) {
      final font = FontLoader(_fontFamily)
        ..addFont(
          Future.value(ByteData.sublistView(File(_fontPath).readAsBytesSync())),
        );
      await font.load();
    }
    expect(await RefractiveGlass.preload(), isTrue);
  });

  for (final dpr in [1.0, 2.0, 2.75, 3.0, 3.5]) {
    testWidgets('sibling glass overlap and subpixel motion at DPR $dpr', (
      tester,
    ) async {
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = _viewSize * dpr;
      addTearDown(tester.view.reset);
      final boundary = GlobalKey();
      final position = ValueNotifier<double>(0);
      addTearDown(position.dispose);
      final references = <double, Uint8List>{};
      await tester.pumpWidget(
        _scene(boundary, position, dpr, upperEnabled: false),
      );
      for (final offset in _offsets) {
        position.value = offset;
        references[offset] = await _capture(
          tester,
          boundary,
          dpr,
          'reference-offset-${offset.toStringAsFixed(2)}',
        );
      }

      await tester.pumpWidget(
        _scene(boundary, position, dpr, upperEnabled: true),
      );
      final upperElement = tester.element(
        find.byKey(const ValueKey('overlap-upper-glass')),
      );
      var glassAncestors = 0;
      upperElement.visitAncestorElements((element) {
        if (element.widget is RefractiveGlass) glassAncestors++;
        return true;
      });
      expect(
        glassAncestors,
        0,
        reason: 'Nested materials bypass refraction and would miss this bug.',
      );
      expect(find.byType(RefractiveGlass), findsNWidgets(2));

      final metrics = <Map<String, Object>>[];
      Uint8List? previous;
      const regions = {
        'top-edge': Rect.fromLTWH(60, 223, 265, 19),
        'left-edge': Rect.fromLTWH(39, 252, 19, 94),
        'center': Rect.fromLTWH(80, 265, 240, 80),
        'bottom-coverage': Rect.fromLTWH(80, 398, 240, 6),
        'right-coverage': Rect.fromLTWH(334, 252, 15, 94),
      };
      for (final offset in _offsets) {
        position.value = offset;
        final image = await _capture(
          tester,
          boundary,
          dpr,
          'overlap-offset-${offset.toStringAsFixed(2)}',
        );
        final reference = references[offset]!;
        final foreground = _foreground.shift(Offset(offset, offset)).deflate(2);
        expect(
          _difference(reference, image, foreground, dpr),
          0,
          reason: 'The upper surface must not filter its own text or strokes.',
        );
        expect(
          _difference(
            reference,
            image,
            const Rect.fromLTWH(36, 118, 310, 58),
            dpr,
          ),
          0,
          reason: 'Lower text outside the upper surface stays untouched.',
        );
        // A composed intermediate filter once cropped the translated card's
        // lower third to identity. Check far sides as well as the center so a
        // sharp, unfiltered strip cannot pass the foreground/temporal checks.
        for (final name in ['bottom-coverage', 'right-coverage']) {
          expect(
            _difference(reference, image, regions[name]!, dpr),
            greaterThan(1),
            reason: 'The non-origin surface must still filter its $name.',
          );
        }
        if (dpr == 1 && previous != null) {
          // A quarter-pixel translation in the gently magnified center must
          // not pop by more than a quarter of the full RGB intensity range.
          // The nearest-sampled baseline changed by 95–103 here; interpolation
          // stays well inside this deliberately broad bound with real glyphs.
          expect(
            _maximumDifference(previous, image, regions['center']!, dpr),
            lessThanOrEqualTo(64),
            reason:
                'Subpixel dock movement must not cause texel-sized pops '
                'in the lower text.',
          );
        }
        metrics.add({
          'dpr': dpr,
          'offset': offset,
          'foregroundMeanAbsoluteDifference': _difference(
            reference,
            image,
            foreground,
            dpr,
          ),
          'regions': {
            for (final region in regions.entries)
              region.key: {
                'rect': [
                  region.value.left,
                  region.value.top,
                  region.value.width,
                  region.value.height,
                ],
                'referenceMeanAbsoluteDifference': _difference(
                  reference,
                  image,
                  region.value,
                  dpr,
                ),
                'highFrequencyEnergy': _highFrequencyEnergy(
                  image,
                  region.value,
                  dpr,
                ),
                if (previous != null)
                  'previousFrameMaximumDifference': _maximumDifference(
                    previous,
                    image,
                    region.value,
                    dpr,
                  ),
                if (previous != null)
                  'previousFrameMeanAbsoluteDifference': _difference(
                    previous,
                    image,
                    region.value,
                    dpr,
                  ),
              },
          },
        });
        previous = image;
      }
      if (_captureDirectory.isNotEmpty) {
        File(
          '$_captureDirectory/metrics-dpr${_dprLabel(dpr)}.json',
        ).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(metrics),
        );
      }
      await tester.pumpWidget(const SizedBox());
    }, skip: unsupported);
  }
}
