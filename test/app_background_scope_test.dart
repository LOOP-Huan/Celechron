import 'dart:ui' as ui;

import 'package:celechron/design/app_background_scope.dart';
import 'package:celechron/design/liquid_glass.dart';
import 'package:celechron/design/refractive_glass.dart';
import 'package:celechron/services/app_background_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

class _Background extends AppBackgroundService {
  ImageProvider<Object>? _image;

  @override
  ImageProvider<Object>? get image => _image;

  void replace(ImageProvider<Object>? value) {
    _image = value;
    notifyListeners();
  }
}

Future<MemoryImage> _image() async {
  final image = await createTestImage(width: 4, height: 4, cache: false);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return MemoryImage(bytes!.buffer.asUint8List());
  } finally {
    image.dispose();
  }
}

Widget _app(_Background service, Widget home, {bool highContrast = false}) =>
    CupertinoApp(
      builder: (context, child) => AppBackgroundScope(
        service: service,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(highContrast: highContrast),
          child: child!,
        ),
      ),
      home: home,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryImage wallpaper;
  setUpAll(() async => wallpaper = await _image());

  testWidgets('嵌套页面只绘制一次背景，键盘避让不改变壁纸尺寸', (tester) async {
    final service = _Background()..replace(wallpaper);
    addTearDown(service.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    var taps = 0;
    Widget page() => _app(
          service,
          GlassBackdrop(
            child: Padding(
              padding: EdgeInsets.only(bottom: tester.view.viewInsets.bottom),
              child: GlassPageScaffold(
                child: Center(
                  child: CupertinoButton(
                    onPressed: () => taps++,
                    child: const Text('选择'),
                  ),
                ),
              ),
            ),
          ),
        );
    await tester.pumpWidget(page());
    expect(find.byType(Image), findsOneWidget);
    final before = tester.getRect(find.byType(Image));
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pumpWidget(page());
    expect(find.byType(Image), findsOneWidget);
    expect(tester.getRect(find.byType(Image)), before);
    await tester.tap(find.text('选择'));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('背景切换覆盖新路由且保留输入状态，恢复默认立即生效', (tester) async {
    final service = _Background();
    final controller = TextEditingController();
    addTearDown(service.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(
      service,
      Builder(builder: (context) {
        return GlassPageScaffold(
          child: Center(
            child: CupertinoButton(
              onPressed: () => Navigator.of(context).push(CupertinoPageRoute(
                builder: (_) => GlassPageScaffold(
                  child: Center(
                    child: GlassSurface(
                      child: CupertinoTextField(controller: controller),
                    ),
                  ),
                ),
              )),
              child: const Text('打开'),
            ),
          ),
        );
      }),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField), '尚未提交的预约');
    service.replace(wallpaper);
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(controller.text, '尚未提交的预约');
    expect(tester.testTextInput.isVisible, isTrue);
    service.replace(null);
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(controller.text, '尚未提交的预约');
    expect(tester.takeException(), isNull);
  });

  testWidgets('预览默认背景不继承当前图片也不会改变全局选择', (tester) async {
    final service = _Background()..replace(wallpaper);
    addTearDown(service.dispose);
    await tester.pumpWidget(_app(
      service,
      const GlassPageScaffold(
        child: Center(
          child: SizedBox(
            width: 250,
            height: 280,
            child: GlassBackgroundPreview(
              image: null,
              child: GlassPageScaffold(child: Text('预览')),
            ),
          ),
        ),
      ),
    ));
    expect(find.byType(Image), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(GlassBackgroundPreview),
            matching: find.byType(Image)),
        findsNothing);
    expect(service.image, same(wallpaper));
  });

  testWidgets('高对比度隐藏自定义图片并关闭玻璃过滤', (tester) async {
    final service = _Background()..replace(wallpaper);
    addTearDown(service.dispose);
    await tester.pumpWidget(_app(
      service,
      const GlassPageScaffold(
        child: Center(child: GlassSurface(child: Text('可读的文字'))),
      ),
      highContrast: true,
    ));
    expect(find.byType(Image), findsNothing);
    expect(tester.widget<RefractiveGlass>(find.byType(RefractiveGlass)).enabled,
        isFalse);
    final decoration =
        GlassPalette.decoration(tester.element(find.byType(GlassSurface)));
    expect(decoration.color!.a, 1);
    expect(tester.takeException(), isNull);
  });
}
