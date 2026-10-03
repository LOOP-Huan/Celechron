import 'package:celechron/design/glass_geometry.dart';
import 'package:celechron/design/liquid_glass.dart';
import 'package:celechron/model/todo.dart';
import 'package:celechron/utils/utils.dart';
import 'package:flutter/cupertino.dart';

class TodoCard extends StatelessWidget {
  final Todo todo;

  const TodoCard({super.key, required this.todo});

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      borderRadius: GlassGeometry.surfaceRadius,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        // add a colored edge
        children: [
          Text(
            todo.course,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            strutStyle: const StrutStyle(leading: 0.5, forceStrutHeight: true),
            style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                  color: CupertinoTheme.of(context)
                      .textTheme
                      .textStyle
                      .color!
                      .withValues(alpha: 0.5),
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            todo.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            strutStyle: const StrutStyle(leading: 0.5, forceStrutHeight: true),
            style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: CupertinoDynamicColor.resolve(
                      CupertinoColors.label, context),
                ),
          ),
          const SizedBox(height: 4),
          Text(
            todo.endTime != null ? toStringHumanReadable(todo.endTime!) : "无",
            style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: CupertinoDynamicColor.resolve(
                      CupertinoColors.label, context),
                ),
          ),
        ],
      ),
    );
  }
}
