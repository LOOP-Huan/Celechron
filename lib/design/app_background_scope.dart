import 'package:celechron/services/app_background_service.dart';
import 'package:flutter/widgets.dart';

/// Keeps wallpaper updates local to the widgets that display the material.
class AppBackgroundScope extends InheritedNotifier<AppBackgroundService> {
  const AppBackgroundScope({
    super.key,
    required AppBackgroundService service,
    required super.child,
  }) : super(notifier: service);

  static AppBackgroundService? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AppBackgroundScope>()
      ?.notifier;
}
