import 'package:flutter/cupertino.dart';

import 'liquid_glass.dart';

class RoundRectangleCard extends StatefulWidget {
  final Widget child;
  final Function()? onTap;
  final bool animate;
  final List<BoxShadow> boxShadow;
  final EdgeInsets padding;

  const RoundRectangleCard({
    super.key,
    required this.child,
    this.onTap,
    this.animate = true,
    this.padding = const EdgeInsets.all(12),
    this.boxShadow = const [
      BoxShadow(
        color: CupertinoColors.systemGrey5,
        spreadRadius: 0,
        blurRadius: 12,
        offset: Offset(0, 6),
      ),
    ],
  });

  @override
  State<RoundRectangleCard> createState() => _RoundRectangleCardState();
}

class _RoundRectangleCardState extends State<RoundRectangleCard> {
  bool _pressed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _pressed = false;
  }

  @override
  void didUpdateWidget(covariant RoundRectangleCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.animate || widget.onTap == null) _pressed = false;
  }

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final animate = widget.animate &&
        widget.onTap != null &&
        !MediaQuery.disableAnimationsOf(context);
    final core = GlassSurface(
      padding: widget.padding,
      child: widget.child,
    );
    if (widget.onTap == null) return core;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: animate ? (_) => _setPressed(true) : null,
      onTapUp: animate ? (_) => _setPressed(false) : null,
      onTapCancel: () => _setPressed(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: animate && _pressed ? 0.98 : 1,
        duration: animate ? const Duration(milliseconds: 140) : Duration.zero,
        curve: Curves.easeOutCubic,
        child: core,
      ),
    );
  }
}

class RoundRectangleCardWithForehead extends StatelessWidget {
  final Widget child;
  final Widget forehead;
  final Color foreheadColor;
  final Function()? onTap;
  final bool animate;

  const RoundRectangleCardWithForehead({
    super.key,
    required this.child,
    required this.forehead,
    this.foreheadColor = CupertinoColors.systemFill,
    this.onTap,
    this.animate = true,
  });

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      tint: CupertinoDynamicColor.resolve(foreheadColor, context),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            forehead,
            RoundRectangleCard(
              onTap: onTap,
              animate: animate,
              boxShadow: const [],
              child: child,
            ),
          ],
        ),
      ),
    );
  }
}
