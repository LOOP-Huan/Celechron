import 'package:flutter/cupertino.dart';

/// A compact heading shared by the seat and seminar booking flows.
class LibraryStepHeader extends StatelessWidget {
  const LibraryStepHeader({
    super.key,
    required this.steps,
    required this.currentStep,
    this.onBack,
    this.showBackButton = true,
  }) : assert(currentStep >= 0 && currentStep < steps.length);

  final List<String> steps;
  final int currentStep;
  final VoidCallback? onBack;
  final bool showBackButton;

  @override
  Widget build(BuildContext context) {
    final primary = CupertinoTheme.of(context).primaryColor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (showBackButton && currentStep > 0) ...[
                Semantics(
                  label: '返回${steps[currentStep - 1]}',
                  child: CupertinoButton(
                    key: const ValueKey('library-step-back'),
                    padding: EdgeInsets.zero,
                    onPressed: onBack,
                    child: const Icon(CupertinoIcons.chevron_back, size: 21),
                  ),
                ),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    steps[currentStep],
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Semantics(
                label: '第 ${currentStep + 1} 步，共 ${steps.length} 步',
                child: ExcludeSemantics(
                  child: Text(
                    '${currentStep + 1} / ${steps.length}',
                    style: TextStyle(
                      fontSize: 13,
                      color: CupertinoDynamicColor.resolve(
                        CupertinoColors.secondaryLabel,
                        context,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ExcludeSemantics(
            child: Row(
              children: [
                for (var index = 0; index < steps.length; index++) ...[
                  if (index > 0) const SizedBox(width: 5),
                  Expanded(
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: index <= currentStep
                            ? primary
                            : CupertinoDynamicColor.resolve(
                                CupertinoColors.systemFill,
                                context,
                              ),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class LibraryFloorOption {
  const LibraryFloorOption({
    required this.id,
    required this.label,
    required this.count,
  });

  final String id;
  final String label;
  final int count;
}

/// Horizontal floor pages keep long room/area directories out of the form.
class LibraryFloorTabs extends StatefulWidget {
  const LibraryFloorTabs({
    super.key,
    required this.floors,
    required this.selectedId,
    required this.onChanged,
  });

  final List<LibraryFloorOption> floors;
  final String selectedId;
  final ValueChanged<String>? onChanged;

  @override
  State<LibraryFloorTabs> createState() => _LibraryFloorTabsState();
}

class _LibraryFloorTabsState extends State<LibraryFloorTabs> {
  final _selectedKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _revealSelection();
  }

  void _revealSelection() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final selectedContext = _selectedKey.currentContext;
      if (mounted && selectedContext != null) {
        final target = selectedContext.findRenderObject();
        if (target != null) {
          Scrollable.of(selectedContext, axis: Axis.horizontal)
              .position
              .ensureVisible(
                target,
                alignment: 0.5,
                duration: const Duration(milliseconds: 180),
              );
        }
      }
    });
  }

  @override
  void didUpdateWidget(covariant LibraryFloorTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedId != widget.selectedId) {
      _revealSelection();
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = CupertinoTheme.of(context).primaryColor;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final floor in widget.floors)
            Padding(
              key: floor.id == widget.selectedId ? _selectedKey : null,
              padding: const EdgeInsets.only(right: 8),
              child: Semantics(
                selected: floor.id == widget.selectedId,
                child: CupertinoButton(
                  key: ValueKey('library-floor-${floor.id}'),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  borderRadius: BorderRadius.circular(22),
                  color: floor.id == widget.selectedId
                      ? primary.withValues(alpha: 0.12)
                      : CupertinoDynamicColor.resolve(
                          CupertinoColors.tertiarySystemFill,
                          context,
                        ),
                  onPressed: widget.onChanged == null
                      ? null
                      : () => widget.onChanged!(floor.id),
                  child: Text(
                    '${floor.label} · ${floor.count}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: floor.id == widget.selectedId
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: floor.id == widget.selectedId
                          ? primary
                          : CupertinoDynamicColor.resolve(
                              CupertinoColors.label,
                              context,
                            ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
