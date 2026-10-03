import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Live backdrop refraction using Impeller's image-filter input texture.
///
/// The shader never captures the widget tree. Nested surfaces deliberately
/// share their outer glass material instead of repeatedly filtering its pixels.
/// Unsupported renderers and ambiguous offscreen render passes use a clear,
/// light blur; that fallback does not simulate or claim to provide refraction.
class RefractiveGlass extends StatefulWidget {
  const RefractiveGlass({
    super.key,
    required this.child,
    this.borderRadius = 24,
    this.enabled = true,
    this.refraction = 1.15,
    this.blurSigma = 0.9,
  })  : assert(borderRadius >= 0),
        assert(refraction >= 0),
        assert(blurSigma >= 0);

  final Widget child;
  final double borderRadius;
  final bool enabled;
  final double refraction;
  final double blurSigma;

  static bool get isSupported => ui.ImageFilter.isShaderFilterSupported;

  /// Optional startup warmup. Loading is shared, while shader uniforms and
  /// shader disposal belong to each visible surface's render object.
  static Future<bool> preload() async => await _GlassProgram.load() != null;

  @override
  State<RefractiveGlass> createState() => _RefractiveGlassState();
}

class _GlassProgram {
  static Future<ui.FragmentProgram?>? _loading;
  static ui.FragmentProgram? loaded;

  static Future<ui.FragmentProgram?> load() {
    if (!RefractiveGlass.isSupported) return Future.value();
    return _loading ??= _load();
  }

  static Future<ui.FragmentProgram?> _load() async {
    try {
      return loaded =
          await ui.FragmentProgram.fromAsset('shaders/liquid_glass.frag');
    } on Object catch (error) {
      debugPrint(
          'RefractiveGlass: shader unavailable; using light blur ($error)');
      return null;
    }
  }
}

class _GlassScope extends InheritedWidget {
  const _GlassScope({required super.child});

  @override
  bool updateShouldNotify(_GlassScope oldWidget) => false;
}

class _RefractiveGlassState extends State<RefractiveGlass> {
  ui.FragmentProgram? _program;
  bool _loadStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadIfNeeded();
  }

  @override
  void didUpdateWidget(covariant RefractiveGlass oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadIfNeeded();
  }

  void _loadIfNeeded() {
    if (_loadStarted ||
        !widget.enabled ||
        !RefractiveGlass.isSupported ||
        context.getInheritedWidgetOfExactType<_GlassScope>() != null) {
      return;
    }
    _loadStarted = true;
    // Startup can warm the program before runApp. Use that program during the
    // first build rather than briefly painting the asynchronous blur fallback.
    final cached = _GlassProgram.loaded;
    if (cached != null) {
      _program = cached;
      return;
    }
    unawaited(_GlassProgram.load().then((program) {
      if (!mounted || program == null) return;
      setState(() => _program = program);
    }));
  }

  @override
  Widget build(BuildContext context) {
    final nested =
        context.dependOnInheritedWidgetOfExactType<_GlassScope>() != null;
    Widget content = widget.child;
    if (widget.enabled && !nested) {
      content = _GlassScope(
        child: _GlassBackdrop(
          program: _program,
          borderRadius: widget.borderRadius,
          refraction: widget.refraction,
          blurSigma: widget.blurSigma,
          child: content,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: content,
    );
  }
}

class _GlassBackdrop extends SingleChildRenderObjectWidget {
  const _GlassBackdrop({
    required this.program,
    required this.borderRadius,
    required this.refraction,
    required this.blurSigma,
    required super.child,
  });

  final ui.FragmentProgram? program;
  final double borderRadius;
  final double refraction;
  final double blurSigma;

  @override
  _RenderGlassBackdrop createRenderObject(BuildContext context) =>
      _RenderGlassBackdrop(program, borderRadius, refraction, blurSigma);

  @override
  void updateRenderObject(
      BuildContext context, _RenderGlassBackdrop renderObject) {
    renderObject.update(program, borderRadius, refraction, blurSigma);
  }
}

class _RenderGlassBackdrop extends RenderProxyBox {
  _RenderGlassBackdrop(
      this._program, this.radius, this.refraction, this.blurSigma) {
    _shader = _program?.fragmentShader();
  }

  ui.FragmentProgram? _program;
  ui.FragmentShader? _shader;
  double radius;
  double refraction;
  double blurSigma;

  void update(ui.FragmentProgram? program, double newRadius,
      double newRefraction, double newBlurSigma) {
    if (program != _program) {
      _shader?.dispose();
      _program = program;
      _shader = program?.fragmentShader();
    }
    radius = newRadius;
    refraction = newRefraction;
    blurSigma = newBlurSigma;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || size.isEmpty) {
      layer = null;
      return;
    }
    layer ??= _GlassBackdropLayer(this);
    context.pushLayer(layer!, (context, offset) {
      context.paintChild(child!, offset);
    }, offset);
  }

  ui.ImageFilter get fallback => ui.ImageFilter.blur(
      sigmaX: blurSigma, sigmaY: blurSigma, tileMode: ui.TileMode.clamp);

  ui.ImageFilter filterForScene(bool offscreenInput) {
    final shader = _shader;
    final root = owner?.rootNode;
    if (shader == null || offscreenInput || root is! RenderView || !attached) {
      return fallback;
    }
    final viewSize = root.size;
    if (viewSize.isEmpty) return fallback;
    final transform = getTransformTo(null);
    final m = transform.storage;
    // Ordinary translation, scale, rotation and skew are supported. Perspective
    // and singular transforms cannot be mapped to the input's 2D pixel plane.
    if (m.any((value) => !value.isFinite) ||
        m[2] != 0 ||
        m[6] != 0 ||
        m[8] != 0 ||
        m[9] != 0 ||
        m[3] != 0 ||
        m[7] != 0 ||
        m[15] != 1) {
      return fallback;
    }
    final inverse = Matrix4.copy(transform);
    if (inverse.invert().abs() < 0.00000001) return fallback;
    final inv = inverse.storage;
    // The engine overwrites float indices 0 and 1 with the input texture size.
    // Dividing by that size in GLSL also handles DPR and scene capture scaling.
    final values = <double>[
      viewSize.width,
      viewSize.height,
      size.width,
      size.height,
      inv[0],
      inv[4],
      inv[12],
      inv[1],
      inv[5],
      inv[13],
      m[0],
      m[4],
      m[1],
      m[5],
      radius,
      refraction,
      blurSigma,
    ];
    for (var index = 0; index < values.length; index++) {
      shader.setFloat(index + 2, values[index]);
    }
    // A new filter snapshots these uniforms for the raster thread. Reusing an
    // ImageFilter instance would retain its earlier native uniform snapshot.
    return ui.ImageFilter.shader(shader);
  }

  @override
  void dispose() {
    _shader?.dispose();
    _shader = null;
    super.dispose();
  }
}

class _GlassBackdropLayer extends ContainerLayer {
  _GlassBackdropLayer(this.geometry);

  final _RenderGlassBackdrop geometry;

  // Scrolling a retained RepaintBoundary can move its layer without calling
  // RenderObject.paint. Refresh coordinates at composition, not only at paint.
  @override
  bool get alwaysNeedsAddToScene => true;

  bool get _hasOffscreenInput {
    for (Layer? ancestor = parent;
        ancestor != null;
        ancestor = ancestor.parent) {
      if ((ancestor is OpacityLayer && ancestor.alpha != 255) ||
          ancestor is ImageFilterLayer ||
          ancestor is ColorFilterLayer ||
          ancestor is ShaderMaskLayer ||
          ancestor is BackdropFilterLayer ||
          ancestor is _GlassBackdropLayer ||
          (ancestor is ClipRectLayer &&
              ancestor.clipBehavior == Clip.antiAliasWithSaveLayer) ||
          (ancestor is ClipRRectLayer &&
              ancestor.clipBehavior == Clip.antiAliasWithSaveLayer) ||
          (ancestor is ClipRSuperellipseLayer &&
              ancestor.clipBehavior == Clip.antiAliasWithSaveLayer) ||
          (ancestor is ClipPathLayer &&
              ancestor.clipBehavior == Clip.antiAliasWithSaveLayer)) {
        return true;
      }
    }
    return false;
  }

  @override
  void addToScene(ui.SceneBuilder builder) {
    // Such ancestors may crop/rebase the input texture. Flutter 3.38 exposes
    // its size but not that origin, so using screen coordinates would be wrong.
    engineLayer = builder.pushBackdropFilter(
      geometry.filterForScene(_hasOffscreenInput),
      oldLayer: engineLayer as ui.BackdropFilterEngineLayer?,
    );
    addChildrenToScene(builder);
    builder.pop();
  }
}
