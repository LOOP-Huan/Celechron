import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import 'glass_geometry.dart';
import 'liquid_glass.dart';

/// Equal-width segments with a thumb concentric to their glass container.
/// Labels can wrap and grow with text scaling; there is no fixed control height.
class GlassSegmentedControl<T extends Object> extends StatefulWidget {
  const GlassSegmentedControl({
    super.key,
    required this.children,
    required this.groupValue,
    required this.onValueChanged,
    this.disabledChildren = const {},
  });

  final Map<T, Widget> children;
  final T groupValue;
  final ValueChanged<T>? onValueChanged;
  final Set<T> disabledChildren;

  @override
  State<GlassSegmentedControl<T>> createState() =>
      _GlassSegmentedControlState<T>();
}

class _GlassSegmentedControlState<T extends Object>
    extends State<GlassSegmentedControl<T>> {
  final _focusNodes = <T, FocusNode>{};
  final _segmentsKey = GlobalKey();
  T? _dragValue;

  bool _enabled(T value) =>
      widget.onValueChanged != null && !widget.disabledChildren.contains(value);

  @override
  void didUpdateWidget(covariant GlassSegmentedControl<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_dragValue != null &&
        (!widget.children.containsKey(_dragValue) || !_enabled(_dragValue!))) {
      _dragValue = null;
    }
    for (final value in _focusNodes.keys.toList()) {
      if (!widget.children.containsKey(value)) {
        _focusNodes.remove(value)!.dispose();
      }
    }
  }

  @override
  void dispose() {
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _select(T value) {
    if (_enabled(value) && value != widget.groupValue) {
      widget.onValueChanged!(value);
    }
  }

  void _previewDrag(Offset position) {
    final box = _segmentsKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || box.size.width <= 0) return;
    final values = widget.children.keys.toList();
    var index = (position.dx / box.size.width * values.length).floor().clamp(
      0,
      values.length - 1,
    );
    if (Directionality.of(context) == TextDirection.rtl) {
      index = values.length - 1 - index;
    }
    final value = values[index];
    if (_enabled(value) && _dragValue != value) {
      setState(() => _dragValue = value);
    }
  }

  void _finishDrag({bool commit = true}) {
    final value = _dragValue;
    if (value == null) return;
    setState(() => _dragValue = null);
    if (commit) _select(value);
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final values = widget.children.keys.where(_enabled).toList();
    if (values.isEmpty) return KeyEventResult.ignored;
    final key = event.logicalKey;
    var index = values.indexWhere(
      (value) => _focusNodes[value]?.hasFocus ?? false,
    );
    if (index < 0) index = values.indexOf(widget.groupValue);
    if (key == LogicalKeyboardKey.home) {
      index = 0;
    } else if (key == LogicalKeyboardKey.end) {
      index = values.length - 1;
    } else if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      final rtl = Directionality.of(context) == TextDirection.rtl;
      final forward = (key == LogicalKeyboardKey.arrowRight) != rtl;
      index = (index + (forward ? 1 : -1)) % values.length;
    } else {
      return KeyEventResult.ignored;
    }
    final value = values[index];
    _select(value);
    // A page may dismiss a text field in its change callback. Restore keyboard
    // focus to the chosen segment after that callback so arrow navigation stays
    // inside the control.
    _focusNodes[value]!.requestFocus();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    assert(widget.children.length >= 2);
    assert(widget.children.containsKey(widget.groupValue));
    final entries = widget.children.entries.toList();
    final selectedIndex = entries.indexWhere(
      (item) => item.key == (_dragValue ?? widget.groupValue),
    );
    final radius = GlassGeometry.insetRadius(GlassGeometry.segmentInset);
    final textStyle = CupertinoTheme.of(context).textTheme.textStyle.copyWith(
      fontSize: 15,
      height: 1.25,
      fontWeight: FontWeight.w600,
    );
    return GlassSurface(
      borderRadius: GlassGeometry.surfaceRadius,
      padding: const EdgeInsets.all(GlassGeometry.segmentInset),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKeyEvent,
        child: Listener(
          // A drag recognizer may report onEnd after an accepted pointer is
          // cancelled. Clear its preview before that end callback can commit.
          onPointerCancel: (_) => _finishDrag(commit: false),
          child: GestureDetector(
            key: _segmentsKey,
            excludeFromSemantics: true,
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: widget.onValueChanged == null
                ? null
                : (details) => _previewDrag(details.localPosition),
            onHorizontalDragUpdate: widget.onValueChanged == null
                ? null
                : (details) => _previewDrag(details.localPosition),
            onHorizontalDragEnd: widget.onValueChanged == null
                ? null
                : (_) => _finishDrag(),
            onHorizontalDragCancel: widget.onValueChanged == null
                ? null
                : () => _finishDrag(commit: false),
            child: Stack(
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedAlign(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      alignment: AlignmentDirectional(
                        -1 + 2 * selectedIndex / (entries.length - 1),
                        0,
                      ),
                      child: FractionallySizedBox(
                        widthFactor: 1 / entries.length,
                        heightFactor: 1,
                        child: DecoratedBox(
                          decoration: GlassPalette.decoration(
                            context,
                            radius: radius,
                            selected: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final entry in entries)
                        Expanded(
                          child: MergeSemantics(
                            child: Semantics(
                              selected: entry.key == widget.groupValue,
                              enabled: _enabled(entry.key),
                              inMutuallyExclusiveGroup: true,
                              child: CupertinoButton(
                                focusNode: _focusNodes.putIfAbsent(
                                  entry.key,
                                  () => FocusNode(),
                                ),
                                borderRadius: BorderRadius.circular(radius),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                minimumSize: const Size(44, 44),
                                onPressed: _enabled(entry.key)
                                    ? () => _select(entry.key)
                                    : null,
                                child: DefaultTextStyle(
                                  style: textStyle.copyWith(
                                    color: CupertinoDynamicColor.resolve(
                                      _enabled(entry.key)
                                          ? CupertinoColors.label
                                          : CupertinoColors.tertiaryLabel,
                                      context,
                                    ),
                                  ),
                                  textAlign: TextAlign.center,
                                  softWrap: true,
                                  child: entry.value,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
