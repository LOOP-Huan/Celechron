import 'package:flutter/cupertino.dart';

import 'liquid_glass.dart';

/// An inset Cupertino section with one glass material around its rows.
///
/// Native sections still own the header/footer typography, directional margins
/// and row dividers. Header and footer content stays outside the glass surface.
class GlassListSection extends StatelessWidget {
  const GlassListSection({
    super.key,
    this.children,
    this.header,
    this.footer,
    this.margin,
    this.dividerMargin = 14,
    this.additionalDividerMargin,
    this.topMargin,
    this.hasLeading = true,
    this.separatorColor,
    this.borderRadius = 24,
    this.blur = true,
  }) : assert(header != null || (children != null && children.length > 0));

  final List<Widget>? children;
  final Widget? header;
  final Widget? footer;
  final EdgeInsetsGeometry? margin;
  final double dividerMargin;
  final double? additionalDividerMargin;
  final double? topMargin;
  final bool hasLeading;
  final Color? separatorColor;
  final double borderRadius;
  final bool blur;

  static const _transparentDecoration =
      BoxDecoration(color: CupertinoColors.transparent);

  @override
  Widget build(BuildContext context) => CupertinoListSection.insetGrouped(
        header: header,
        footer: footer,
        margin: margin,
        topMargin: topMargin,
        backgroundColor: CupertinoColors.transparent,
        decoration: _transparentDecoration,
        clipBehavior: Clip.none,
        children: children == null || children!.isEmpty
            ? null
            : [
                GlassSurface(
                  borderRadius: borderRadius,
                  blur: blur,
                  child: CupertinoListSection.insetGrouped(
                    margin: EdgeInsets.zero,
                    topMargin: 0,
                    backgroundColor: CupertinoColors.transparent,
                    decoration: _transparentDecoration,
                    clipBehavior: Clip.none,
                    dividerMargin: dividerMargin,
                    additionalDividerMargin: additionalDividerMargin,
                    hasLeading: hasLeading,
                    separatorColor: separatorColor,
                    children: children,
                  ),
                ),
              ],
      );
}
