import 'dart:async';
import 'dart:ui' as ui;

import 'package:celechron/database/database_helper.dart';
import 'package:celechron/design/app_background_scope.dart';
import 'package:celechron/design/liquid_glass.dart';
import 'package:celechron/model/option.dart';
import 'package:celechron/model/scholar.dart';
import 'package:celechron/page/option/background_settings_page.dart';
import 'package:celechron/page/option/option_view.dart';
import 'package:celechron/services/app_background_service.dart';
import 'package:celechron/worker/fuse.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

class _FakeBackgroundService extends AppBackgroundService {
  ImageProvider<Object>? current;
  BackgroundCandidate? next;
  Completer<BackgroundCandidate?>? pickGate;
  Completer<void>? applyGate;
  Object? pickError;
  Object? applyError;
  Object? resetError;
  String? startupMessage;
  int picks = 0;
  int applies = 0;
  int resets = 0;

  @override
  ImageProvider<Object>? get image => current;
  @override
  bool get hasImage => current != null;
  @override
  bool get busy => false;
  @override
  String? get error => startupMessage;

  @override
  Future<void> init() async {}

  @override
  Future<BackgroundCandidate?> pick() async {
    picks++;
    if (pickError != null) throw pickError!;
    if (pickGate != null) return pickGate!.future;
    return next;
  }

  @override
  Future<void> apply(BackgroundCandidate candidate) async {
    applies++;
    if (applyGate != null) await applyGate!.future;
    if (applyError != null) throw applyError!;
    current = candidate.image;
    notifyListeners();
  }

  @override
  Future<void> reset() async {
    resets++;
    if (resetError != null) throw resetError!;
    current = null;
    notifyListeners();
  }
}

Widget _app(
  _FakeBackgroundService service, {
  Brightness brightness = Brightness.light,
  bool highContrast = false,
  double scale = 1,
  Widget? home,
}) => AppBackgroundScope(
  service: service,
  child: CupertinoApp(
    theme: CupertinoThemeData(
      brightness: brightness,
      primaryColor: GlassPalette.accent,
      primaryContrastingColor: GlassPalette.onAccent,
    ),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        highContrast: highContrast,
        textScaler: TextScaler.linear(scale),
      ),
      child: child!,
    ),
    home: home ?? BackgroundSettingsPage(service: service),
  ),
);

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

GlassBackgroundPreview _preview(WidgetTester tester) =>
    tester.widget(find.byKey(const ValueKey('background-preview')));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackgroundCandidate oldImage;
  late BackgroundCandidate newImage;

  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const Color(0xFFB7D4E9), BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(32, 48);
    final bytes = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    image.dispose();
    picture.dispose();
    oldImage = await BackgroundCandidate.fromBytes(bytes);
    newImage = await BackgroundCandidate.fromBytes(bytes);
  });

  setUp(() => Get.testMode = true);
  tearDown(Get.reset);

  testWidgets('已保存图片不可用时展示恢复提示并允许重新选择', (tester) async {
    final service = _FakeBackgroundService()
      ..startupMessage = '背景图片已不可用，已使用默认背景。';
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();
    expect(find.text(service.startupMessage!), findsOneWidget);
    expect(_preview(tester).image, isNull);
    expect(
      tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('background-pick')),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('选图仅更新预览，取消系统选择保留当前预览与原背景', (tester) async {
    final service = _FakeBackgroundService()
      ..current = oldImage.image
      ..next = newImage;
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();
    expect(_preview(tester).image, same(oldImage.image));
    expect(find.text('图片仅保存在本机，不会上传至服务器。'), findsOneWidget);

    await _tap(tester, 'background-pick');
    await tester.pumpAndSettle();
    expect(find.text('新图片预览'), findsOneWidget);
    expect(_preview(tester).image, same(newImage.image));
    expect(service.current, same(oldImage.image));
    expect(service.applies, 0);

    service.next = null;
    await _tap(tester, 'background-pick');
    await tester.pumpAndSettle();
    expect(_preview(tester).image, same(newImage.image));
    expect(service.current, same(oldImage.image));

    await _tap(tester, 'background-discard');
    await tester.pumpAndSettle();
    expect(_preview(tester).image, same(oldImage.image));
    expect(find.byKey(const ValueKey('background-apply')), findsNothing);
    expect(service.applies, 0);
  });

  testWidgets('只有确认使用才保存，保存中阻止重复操作与返回', (tester) async {
    final service = _FakeBackgroundService()
      ..current = oldImage.image
      ..next = newImage
      ..applyGate = Completer<void>();
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();
    await _tap(tester, 'background-pick');
    await tester.pumpAndSettle();
    await _tap(tester, 'background-apply');
    expect(service.applies, 1);
    expect(service.current, same(oldImage.image));
    expect(find.text('正在保存背景…'), findsOneWidget);
    for (final key in [
      'background-apply',
      'background-pick',
      'background-reset',
      'background-discard',
    ]) {
      expect(
        tester.widget<CupertinoButton>(find.byKey(ValueKey(key))).onPressed,
        isNull,
      );
    }
    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isFalse);

    service.applyGate!.complete();
    await tester.pumpAndSettle();
    expect(service.current, same(newImage.image));
    expect(service.applies, 1);
    expect(find.text('已更新应用背景'), findsOneWidget);
    expect(find.byKey(const ValueKey('background-apply')), findsNothing);
  });

  testWidgets('未应用的照片预览独立使用照片文字对比度', (tester) async {
    final service = _FakeBackgroundService()..next = newImage;
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();
    await _tap(tester, 'background-pick');
    await tester.pumpAndSettle();
    final sample = tester.widget<Text>(find.text('14:00 小组讨论'));
    expect(sample.style!.color, const Color(0xFF24303F));
    expect(service.current, isNull);
    expect(service.applies, 0);
  });

  testWidgets('选择处理中不重复打开相册，页面释放后忽略返回的候选', (tester) async {
    final service = _FakeBackgroundService()
      ..current = oldImage.image
      ..pickGate = Completer<BackgroundCandidate?>();
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();
    await _tap(tester, 'background-pick');
    expect(service.picks, 1);
    expect(
      tester
          .widget<CupertinoButton>(
            find.byKey(const ValueKey('background-pick')),
          )
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    service.pickGate!.complete(newImage);
    await tester.pumpAndSettle();
    expect(service.applies, 0);
    expect(service.current, same(oldImage.image));
    expect(tester.takeException(), isNull);
  });

  testWidgets('返回设置不自动应用尚未确认的图片', (tester) async {
    final service = _FakeBackgroundService()
      ..current = oldImage.image
      ..next = newImage;
    await tester.pumpWidget(
      _app(
        service,
        home: Builder(
          builder: (context) => CupertinoPageScaffold(
            child: CupertinoButton(
              onPressed: () => Navigator.of(context).push(
                CupertinoPageRoute(
                  builder: (_) => BackgroundSettingsPage(service: service),
                ),
              ),
              child: const Text('打开背景'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开背景'));
    await tester.pumpAndSettle();
    await _tap(tester, 'background-pick');
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(BackgroundSettingsPage), findsNothing);
    expect(service.current, same(oldImage.image));
    expect(service.applies, 0);
  });

  testWidgets('选图和保存失败保留原图，保存失败的候选可重试', (tester) async {
    final service = _FakeBackgroundService()
      ..current = oldImage.image
      ..pickError = StateError('private local file path');
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();
    await _tap(tester, 'background-pick');
    await tester.pumpAndSettle();
    expect(find.text('无法打开这张图片，请重新选择。'), findsOneWidget);
    expect(find.textContaining('private local'), findsNothing);
    expect(service.current, same(oldImage.image));

    service
      ..pickError = null
      ..next = newImage
      ..applyError = StateError('write failed');
    await _tap(tester, 'background-pick');
    await tester.pumpAndSettle();
    await _tap(tester, 'background-apply');
    await tester.pumpAndSettle();
    expect(find.text('背景保存失败，请重试。'), findsOneWidget);
    expect(_preview(tester).image, same(newImage.image));
    expect(service.current, same(oldImage.image));

    service.applyError = null;
    await _tap(tester, 'background-apply');
    await tester.pumpAndSettle();
    expect(service.current, same(newImage.image));
  });

  testWidgets('恢复默认必须确认，取消和恢复失败均保留原背景', (tester) async {
    final service = _FakeBackgroundService()..current = oldImage.image;
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();
    await _tap(tester, 'background-reset');
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.resets, 0);
    expect(service.current, same(oldImage.image));

    service.resetError = StateError('write failed');
    await _tap(tester, 'background-reset');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('background-confirm-reset')));
    await tester.pumpAndSettle();
    expect(find.text('暂时无法恢复默认背景，请重试。'), findsOneWidget);
    expect(service.current, same(oldImage.image));

    service.resetError = null;
    await _tap(tester, 'background-reset');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('background-confirm-reset')));
    await tester.pumpAndSettle();
    expect(service.current, isNull);
    expect(_preview(tester).image, isNull);
    expect(find.text('已恢复默认背景'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets('窄屏大字、${brightness.name}高对比预览与操作不溢出', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _FakeBackgroundService()..next = newImage;
      await tester.pumpWidget(
        _app(service, brightness: brightness, highContrast: true, scale: 1.8),
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'background-pick');
      await tester.pumpAndSettle();
      expect(_preview(tester).image, same(newImage.image));
      await _tap(tester, 'background-apply');
      await tester.pumpAndSettle();
      expect(service.current, same(newImage.image));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('设置中的应用背景入口使用共享服务并打开预览页', (tester) async {
    final service = _FakeBackgroundService()..current = oldImage.image;
    Get.put<DatabaseHelper>(DatabaseHelper(), tag: 'db');
    Get.put<Rx<Scholar>>(Scholar().obs, tag: 'scholar');
    Get.put<Rx<Fuse>>(
      (Fuse()..lastUpdateTime = DateTime.now()).obs,
      tag: 'fuse',
    );
    Get.put<Option>(
      Option(
        workTime: const Duration(minutes: 45).obs,
        restTime: const Duration(minutes: 15).obs,
        allowTime: <DateTime, DateTime>{}.obs,
        gpaStrategy: GpaStrategy.first.obs,
        pushOnGradeChange: false.obs,
        pushOnDdlReminder: false.obs,
        brightnessMode: BrightnessMode.system.obs,
        courseIdMappingList: <CourseIdMap>[].obs,
        hideHomeGpa: false.obs,
        asyncRefresh: true.obs,
      ),
      tag: 'option',
    );
    const channel = MethodChannel('plugins.builttoroam.com/device_calendar');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => false,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(_app(service, home: OptionPage()));
    await tester.pumpAndSettle();
    await _tap(tester, 'background-settings-entry');
    await tester.pumpAndSettle();
    expect(find.byType(BackgroundSettingsPage), findsOneWidget);
    expect(_preview(tester).image, same(oldImage.image));
    expect(tester.takeException(), isNull);
  });
}
