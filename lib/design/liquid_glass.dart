import 'package:flutter/cupertino.dart';
import 'package:celechron/design/app_background_scope.dart';
import 'package:celechron/design/glass_geometry.dart';
import 'package:celechron/design/refractive_glass.dart';

/// Shared colors. Optical distortion is provided separately by RefractiveGlass;
/// these low-opacity fills keep controls readable without hiding the backdrop.
abstract final class GlassPalette {
  static const background = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFF1F3F6),
    darkColor: Color(0xFF101720),
  );
  static const barColor = CupertinoDynamicColor.withBrightnessAndContrast(
    color: Color(0x66F1F3F6),
    darkColor: Color(0x66101720),
    highContrastColor: Color(0xFFF9FBFF),
    darkHighContrastColor: Color(0xFF1D2A40),
  );
  static const accent = CupertinoDynamicColor.withBrightness(
    color: Color(0xFF245DD8),
    darkColor: Color(0xFF8ABEFF),
  );
  static const onAccent = CupertinoDynamicColor.withBrightness(
    color: CupertinoColors.white,
    darkColor: Color(0xFF0B1220),
  );

  static bool isDark(BuildContext context) =>
      CupertinoTheme.brightnessOf(context) == Brightness.dark;

  static bool hasCustomBackground(BuildContext context) =>
      _backgroundImage(context) != null && !MediaQuery.highContrastOf(context);

  static Color secondaryLabel(BuildContext context) => hasCustomBackground(
          context)
      ? isDark(context)
          ? const Color(0xFFE1E7EF)
          : const Color(0xFF24303F)
      : CupertinoDynamicColor.resolve(CupertinoColors.secondaryLabel, context);

  static Color accentColor(BuildContext context) => hasCustomBackground(context)
      ? isDark(context)
          ? const Color(0xFFD6E8FF)
          : const Color(0xFF0E2C64)
      : CupertinoDynamicColor.resolve(accent, context);

  static Color surfaceColor(BuildContext context) =>
      isDark(context) ? const Color(0xFF1D2A40) : const Color(0xFFF9FBFF);

  static Color fieldColor(BuildContext context) {
    final dark = isDark(context);
    if (MediaQuery.highContrastOf(context)) {
      return dark ? const Color(0xFF121D30) : CupertinoColors.white;
    }
    return dark ? const Color(0x30121D30) : const Color(0x50FFFFFF);
  }

  static BoxDecoration decoration(
    BuildContext context, {
    double radius = GlassGeometry.surfaceRadius,
    Color? tint,
    bool selected = false,
  }) {
    final dark = isDark(context);
    final contrast = MediaQuery.highContrastOf(context);
    final hasPhoto = _backgroundImage(context) != null;
    final color = tint == null
        ? accentColor(context)
        : CupertinoDynamicColor.resolve(tint, context);
    final neutral = dark
        ? hasPhoto
            ? const Color(0xFF101720)
            : const Color(0xFFCCD7E5)
        : CupertinoColors.white;
    final fill = selected
        ? color.withValues(alpha: dark ? 0.16 : 0.11)
        : Color.alphaBlend(
            color.withValues(alpha: tint == null ? 0 : 0.025),
            neutral.withValues(alpha: hasPhoto ? 0.30 : (dark ? 0.055 : 0.12)),
          );
    return BoxDecoration(
      color: contrast ? surfaceColor(context) : fill,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        width: contrast ? 1.2 : 0.65,
        color: selected
            ? contrast
                ? CupertinoDynamicColor.resolve(accent, context)
                : color.withValues(alpha: 0.36)
            : contrast
                ? CupertinoDynamicColor.resolve(CupertinoColors.label, context)
                : CupertinoColors.white.withValues(alpha: dark ? 0.2 : 0.55),
      ),
    );
  }
}

/// Quiet, static shapes give the real backdrop a little structure to refract.
/// Content scrolling under floating controls is sampled from the same frame.
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key, required this.child, this.baseColor})
      : _forcePaint = false;

  const GlassBackdrop._preview({required this.child})
      : baseColor = null,
        _forcePaint = true;

  final Widget child;
  final Color? baseColor;
  final bool _forcePaint;

  @override
  Widget build(BuildContext context) {
    final dark = GlassPalette.isDark(context);
    final contrast = MediaQuery.highContrastOf(context);
    final image = _backgroundImage(context);
    final painted =
        context.dependOnInheritedWidgetOfExactType<_PaintedGlassBackdrop>();
    // The tab host owns the full-screen backdrop. Pages inside it must not
    // crop and veil the same image again when keyboard/safe-area sizes change.
    if (!_forcePaint && painted != null && painted.image == image) return child;

    final base = CupertinoDynamicColor.resolve(
      baseColor ?? GlassPalette.background,
      context,
    );
    Widget defaultBackground() => ColoredBox(
          color: base,
          child: contrast
              ? null
              : CustomPaint(painter: _BackdropShapes(dark: dark)),
        );
    return _PaintedGlassBackdrop(
      image: image,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: ExcludeSemantics(
              child: IgnorePointer(
                child: image == null || contrast
                    ? defaultBackground()
                    : Stack(
                        fit: StackFit.expand,
                        children: [
                          ColoredBox(color: base),
                          Image(
                            image: image,
                            fit: BoxFit.cover,
                            alignment: Alignment.center,
                            filterQuality: FilterQuality.medium,
                            excludeFromSemantics: true,
                            errorBuilder: (_, __, ___) => defaultBackground(),
                          ),
                          ColoredBox(
                            color: (dark
                                    ? const Color(0xFF070D17)
                                    : CupertinoColors.white)
                                .withValues(alpha: dark ? .64 : .60),
                          ),
                        ],
                      ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

ImageProvider<Object>? _backgroundImage(BuildContext context) {
  final preview =
      context.dependOnInheritedWidgetOfExactType<_PreviewBackground>();
  return preview != null
      ? preview.image
      : AppBackgroundScope.maybeOf(context)?.image;
}

class _PaintedGlassBackdrop extends InheritedWidget {
  const _PaintedGlassBackdrop({required this.image, required super.child});
  final ImageProvider<Object>? image;

  @override
  bool updateShouldNotify(_PaintedGlassBackdrop oldWidget) =>
      image != oldWidget.image;
}

class _PreviewBackground extends InheritedWidget {
  const _PreviewBackground({required this.image, required super.child});
  final ImageProvider<Object>? image;

  @override
  bool updateShouldNotify(_PreviewBackground oldWidget) =>
      image != oldWidget.image;
}

/// Uses the exact app backdrop and material while leaving saved settings alone.
class GlassBackgroundPreview extends StatelessWidget {
  const GlassBackgroundPreview({
    super.key,
    required this.image,
    required this.child,
  });

  final ImageProvider<Object>? image;
  final Widget child;

  @override
  Widget build(BuildContext context) => _PreviewBackground(
        image: image,
        child: GlassBackdrop._preview(child: child),
      );
}

class _BackdropShapes extends CustomPainter {
  const _BackdropShapes({required this.dark});

  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final span = size.shortestSide;
    final paint = Paint()
      ..color = const Color(0xFF789DCC).withValues(alpha: dark ? 0.09 : 0.08);
    canvas.drawCircle(
      Offset(size.width * .03, size.height * .18),
      span * .66,
      paint,
    );
    paint.color = const Color(0xFF949CC6).withValues(alpha: dark ? .08 : .055);
    canvas.drawCircle(
      Offset(size.width * 1.08, size.height * .72),
      span * .77,
      paint,
    );
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0xFF7696BD).withValues(alpha: dark ? .12 : .095);
    canvas.drawCircle(
      Offset(size.width * .03, size.height * .18),
      span * .75,
      paint,
    );
    canvas.drawCircle(
      Offset(size.width * 1.08, size.height * .72),
      span * .88,
      paint,
    );
  }

  @override
  bool shouldRepaint(_BackdropShapes oldDelegate) => dark != oldDelegate.dark;
}

class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.margin = EdgeInsets.zero,
    this.borderRadius = GlassGeometry.surfaceRadius,
    this.tint,
    this.blur = false,
    this.emphasized = false,
    this.modal = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final double borderRadius;
  final Color? tint;
  final bool blur;
  final bool emphasized;

  /// Sheets cover other text, so they need a stronger neutral veil than cards.
  final bool modal;

  @override
  Widget build(BuildContext context) {
    final dark = GlassPalette.isDark(context);
    final contrast = MediaQuery.highContrastOf(context);
    final decoration = GlassPalette.decoration(
      context,
      radius: borderRadius,
      tint: tint,
      selected: emphasized,
    );
    final surface = DecoratedBox(
      decoration: modal && !contrast
          ? decoration.copyWith(
              color: GlassPalette.surfaceColor(context).withValues(alpha: .9),
            )
          : decoration,
      child: Padding(padding: padding, child: child),
    );
    return Padding(
      padding: margin,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          boxShadow: contrast
              ? const []
              : [
                  BoxShadow(
                    color: const Color(
                      0xFF07101C,
                    ).withValues(alpha: dark ? 0.12 : 0.035),
                    blurRadius: blur ? 20 : 12,
                    offset: const Offset(0, 4),
                  ),
                ],
        ),
        child: RefractiveGlass(
          borderRadius: borderRadius,
          enabled: !contrast,
          child: surface,
        ),
      ),
    );
  }
}

/// Retains Cupertino keyboard, navigation and safe-area behavior while keeping
/// the material's backdrop behind both the page and translucent navigation.
class GlassPageScaffold extends StatelessWidget {
  const GlassPageScaffold({
    super.key,
    required this.child,
    this.navigationBar,
    this.backgroundColor,
    this.resizeToAvoidBottomInset = true,
  });

  final Widget child;
  final ObstructingPreferredSizeWidget? navigationBar;
  final Color? backgroundColor;
  final bool resizeToAvoidBottomInset;

  @override
  Widget build(BuildContext context) => GlassBackdrop(
        baseColor: backgroundColor,
        child: CupertinoPageScaffold(
          backgroundColor: CupertinoColors.transparent,
          navigationBar: navigationBar,
          resizeToAvoidBottomInset: resizeToAvoidBottomInset,
          child: child,
        ),
      );
}
