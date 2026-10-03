import 'package:flutter/cupertino.dart';

import 'liquid_glass.dart';

class TwoLineCard extends StatefulWidget {
  final String title;
  final String content;
  final String? extraContent;
  final bool withColoredFont;
  final bool animate;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final CupertinoDynamicColor backgroundColor;
  final bool transparent;
  final double? height;
  final double? width;

  const TwoLineCard({
    super.key,
    required this.title,
    required this.content,
    this.extraContent,
    this.animate = false,
    this.withColoredFont = false,
    this.onTap,
    this.onLongPress,
    this.backgroundColor = CupertinoColors.systemBackground,
    this.transparent = false,
    this.height,
    this.width,
  });

  static Widget dummy(String title, String content) =>
      const TwoLineCard(title: 'title', content: 'content');

  @override
  State<TwoLineCard> createState() => _TwoLineCardState();
}

class _TwoLineCardState extends State<TwoLineCard> {
  bool _pressed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _pressed = false;
  }

  @override
  void didUpdateWidget(covariant TwoLineCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.animate || widget.transparent) _pressed = false;
  }

  void _setPressed(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final tint = CupertinoDynamicColor.resolve(widget.backgroundColor, context);
    final textStyle = CupertinoTheme.of(context).textTheme.textStyle;
    final valueColor = widget.withColoredFont && GlassPalette.isDark(context)
        ? tint
        : CupertinoDynamicColor.resolve(CupertinoColors.label, context);

    final body = LayoutBuilder(
      builder: (context, constraints) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: constraints.hasBoundedWidth ? constraints.maxWidth : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  widget.title,
                  maxLines: 1,
                  style: textStyle.copyWith(
                    color: CupertinoDynamicColor.resolve(
                      CupertinoColors.secondaryLabel,
                      context,
                    ),
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              widget.withColoredFont
                  ? const SizedBox(height: 4)
                  : Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: tint,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      widget.content,
                      maxLines: 1,
                      style: textStyle.copyWith(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: valueColor,
                      ),
                    ),
                    if (widget.extraContent != null)
                      Text(
                        ' / ${widget.extraContent}',
                        maxLines: 1,
                        style: textStyle.copyWith(
                          fontSize: 12,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: valueColor,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (widget.transparent) {
      return SizedBox(
        height: widget.height,
        width: widget.width,
        child: IgnorePointer(
          child: ExcludeSemantics(
            child: Opacity(
              opacity: 0,
              child: Padding(padding: const EdgeInsets.all(16), child: body),
            ),
          ),
        ),
      );
    }

    final core = SizedBox(
      height: widget.height,
      width: widget.width,
      child: GlassSurface(
        borderRadius: 20,
        padding: const EdgeInsets.all(16),
        tint: widget.backgroundColor == CupertinoColors.systemBackground
            ? null
            : tint,
        child: body,
      ),
    );

    if (!widget.animate && widget.onTap == null && widget.onLongPress == null) {
      return core;
    }

    final animate = widget.animate && !disableAnimations;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: animate ? (_) => _setPressed(true) : null,
      onTapUp: animate ? (_) => _setPressed(false) : null,
      onTapCancel: animate ? () => _setPressed(false) : null,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: animate && _pressed ? 0.97 : 1,
        duration: animate
            ? Duration(milliseconds: _pressed ? 140 : 240)
            : Duration.zero,
        curve: Curves.easeOutCubic,
        child: core,
      ),
    );
  }
}
