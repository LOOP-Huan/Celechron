import 'package:celechron/design/glass_geometry.dart';
import 'package:flutter/cupertino.dart';

import 'liquid_glass.dart';

class CelechronSliverTextHeader extends StatelessWidget {
  final String subtitle;
  final Widget? right;
  final Widget? bottom;
  final double fontSize;
  final bool firstPage;

  const CelechronSliverTextHeader({
    super.key,
    required this.subtitle,
    this.right,
    this.bottom,
    this.fontSize = 20,
    this.firstPage = false,
  });

  @override
  Widget build(BuildContext context) {
    return SliverPersistentHeader(
      pinned: true,
      delegate: CelechronHeader(
        fontSize: fontSize,
        firstPage: firstPage,
        subtitle: subtitle,
        right: right,
        bottom: bottom,
        padding: MediaQuery.of(context).padding.top,
        toolbarHeight: (MediaQuery.textScalerOf(context).scale(fontSize) + 24)
            .clamp(52, 88),
      ),
    );
  }
}

class CelechronHeader extends SliverPersistentHeaderDelegate {
  final String subtitle;
  final Widget? bottom;
  final Widget? right;
  final double padding;
  final double fontSize;
  final bool firstPage;
  final double toolbarHeight;

  CelechronHeader({
    required this.subtitle,
    this.right,
    this.bottom,
    required this.padding,
    this.fontSize = 20,
    this.firstPage = false,
    this.toolbarHeight = 52,
  });

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return GlassSurface(
      borderRadius: GlassGeometry.flushRadius,
      tint: CupertinoDynamicColor.resolve(GlassPalette.barColor, context),
      blur: overlapsContent || shrinkOffset > 0,
      padding: EdgeInsets.only(top: padding),
      child: Column(
        children: [
          SizedBox(
            height: toolbarHeight,
            child: NavigationToolbar(
              centerMiddle: true,
              middleSpacing: 8,
              leading: firstPage
                  ? null
                  : CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: Icon(
                        CupertinoIcons.back,
                        semanticLabel: '返回',
                        color: GlassPalette.accentColor(context),
                      ),
                    ),
              middle: Hero(
                tag: subtitle,
                child: Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CupertinoTheme.of(context)
                      .textTheme
                      .navTitleTextStyle
                      .copyWith(fontSize: fontSize - (bottom == null ? 0 : 2)),
                ),
              ),
              trailing: right,
            ),
          ),
          if (bottom != null)
            SizedBox(height: 48, child: Center(child: bottom)),
        ],
      ),
    );
  }

  @override
  double get minExtent => toolbarHeight + padding + (bottom == null ? 0 : 48);

  @override
  double get maxExtent => minExtent;

  @override
  bool shouldRebuild(covariant CelechronHeader oldDelegate) =>
      oldDelegate.subtitle != subtitle ||
      oldDelegate.bottom != bottom ||
      oldDelegate.right != right ||
      oldDelegate.padding != padding ||
      oldDelegate.fontSize != fontSize ||
      oldDelegate.firstPage != firstPage ||
      oldDelegate.toolbarHeight != toolbarHeight;
}
