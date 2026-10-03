import 'package:flutter/cupertino.dart';

import 'liquid_glass.dart';

class AnimateButton extends StatefulWidget {
  final String text;
  final VoidCallback? onTap;
  final CupertinoDynamicColor backgroundColor;
  final bool selected;

  const AnimateButton({
    super.key,
    required this.text,
    this.onTap,
    this.backgroundColor = CupertinoColors.systemBackground,
    this.selected = false,
  });

  @override
  State<AnimateButton> createState() => _AnimateButtonState();
}

class _AnimateButtonState extends State<AnimateButton> {
  bool _pressed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _pressed = false;
  }

  void _setPressed(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final tint = CupertinoDynamicColor.resolve(widget.backgroundColor, context);

    return Semantics(
      button: true,
      selected: widget.selected,
      enabled: widget.onTap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: disableAnimations ? null : (_) => _setPressed(true),
        onTapUp: disableAnimations ? null : (_) => _setPressed(false),
        onTapCancel: disableAnimations ? null : () => _setPressed(false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: !disableAnimations && _pressed ? 0.97 : 1,
          duration: disableAnimations
              ? Duration.zero
              : Duration(milliseconds: _pressed ? 140 : 240),
          curve: Curves.easeOutCubic,
          child: GlassSurface(
            borderRadius: 14,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            tint: widget.backgroundColor == CupertinoColors.systemBackground
                ? null
                : tint,
            emphasized: widget.selected,
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.selected) ...[
                      Icon(CupertinoIcons.check_mark,
                          size: 12,
                          color: CupertinoDynamicColor.resolve(
                              CupertinoColors.label, context)),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      widget.text,
                      maxLines: 1,
                      style: CupertinoTheme.of(context)
                          .textTheme
                          .textStyle
                          .copyWith(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: GlassPalette.isDark(context) &&
                                    widget.backgroundColor !=
                                        CupertinoColors.systemBackground
                                ? tint
                                : CupertinoDynamicColor.resolve(
                                    CupertinoColors.label,
                                    context,
                                  ),
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
