/// Shared corner geometry for glass surfaces and the controls inside them.
abstract final class GlassGeometry {
  static const double surfaceRadius = 24;
  static const double compactRadius = 16;
  static const double flushRadius = 0;
  static const double dockInset = 6;
  static const double segmentInset = 4;

  /// Concentric inner corners follow the distance from the outer surface.
  static double insetRadius(double inset,
          {double outerRadius = surfaceRadius}) =>
      (outerRadius - inset).clamp(0.0, outerRadius);
}
