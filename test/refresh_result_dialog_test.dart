import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'package:celechron/model/option.dart';
import 'package:celechron/model/scholar.dart';
import 'package:celechron/page/scholar/scholar_controller.dart';
import 'package:celechron/page/scholar/scholar_view.dart';

void main() {
  testWidgets('构造学业页不改写全局错误页面构造器', (tester) async {
    final originalBuilder = ErrorWidget.builder;
    Get.put<Rx<Scholar>>(Scholar().obs, tag: 'scholar');
    Get.put<Option>(
      Option(
        workTime: const Duration(minutes: 45).obs,
        restTime: const Duration(minutes: 15).obs,
        allowTime: <DateTime, DateTime>{}.obs,
        gpaStrategy: GpaStrategy.best.obs,
        pushOnGradeChange: false.obs,
        pushOnDdlReminder: false.obs,
        brightnessMode: BrightnessMode.system.obs,
        courseIdMappingList: <CourseIdMap>[].obs,
        hideHomeGpa: false.obs,
        asyncRefresh: false.obs,
      ),
      tag: 'option',
    );
    try {
      ScholarPage();
      expect(ErrorWidget.builder, same(originalBuilder));
      await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    } finally {
      ErrorWidget.builder = originalBuilder;
      if (Get.isRegistered<ScholarController>()) {
        Get.find<ScholarController>().onClose();
      }
      Get.reset();
    }
  });

  Widget testApp(List<String?> results) {
    return CupertinoApp(
      home: Builder(
        builder: (context) => CupertinoButton(
          onPressed: () => showRefreshResultDialog(context, results),
          child: const Text('刷新'),
        ),
      ),
    );
  }

  testWidgets('完整刷新成功后不显示结果弹窗', (tester) async {
    await tester.pumpWidget(testApp([null, null, null]));

    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();

    expect(find.byType(CupertinoAlertDialog), findsNothing);
  });

  testWidgets('刷新失败仍显示必要错误且不展示诊断标识', (tester) async {
    await tester.pumpWidget(testApp(['作业查询出错：请求超时']));

    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();

    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    expect(find.textContaining('请求超时'), findsOneWidget);
    expect(find.textContaining('refreshId'), findsNothing);
    expect(find.textContaining('总耗时'), findsNothing);
  });
}
