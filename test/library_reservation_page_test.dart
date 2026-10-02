import 'dart:async';

import 'package:celechron/model/library_reservation.dart';
import 'package:celechron/model/scholar.dart';
import 'package:celechron/page/library/library_reservation_page.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

Scholar _scholar({String username = '3230000001', bool loggedIn = true}) =>
    Scholar()
      ..username = username
      ..password = 'test-password'
      ..isLogan = loggedIn;

const _room = LibraryRoom(
  id: 'test-room',
  name: '测试研讨间 201',
  buildingId: 'test-building',
);

class _FakeLibraryBookingClient implements LibraryBookingClient {
  _FakeLibraryBookingClient() {
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    date = '${tomorrow.year}-'
        '${tomorrow.month.toString().padLeft(2, '0')}-'
        '${tomorrow.day.toString().padLeft(2, '0')}';
  }

  late final String date;
  int catalogCalls = 0;
  int roomCalls = 0;
  int availabilityCalls = 0;
  int submitCalls = 0;
  int reservationCalls = 0;
  int cancelCalls = 0;
  int disposeCalls = 0;
  Object? catalogError;
  Object? submitError;
  Completer<String>? pendingSubmission;
  LibraryBookingDraft? submittedDraft;

  LibraryRoomAvailability get availability => LibraryRoomAvailability(
        room: _room,
        date: date,
        startMinute: 8 * 60,
        endMinute: 22 * 60,
        minDurationMinutes: 30,
        maxDurationMinutes: 4 * 60,
        titleRequired: true,
        mobile: '13800000000',
      );

  LibraryReservation get reservation => LibraryReservation(
        id: 'test-reservation',
        roomName: _room.name,
        date: date,
        startTime: '08:00',
        endTime: '08:30',
        status: '预约成功',
        canCancel: true,
      );

  @override
  Future<LibraryCatalog> loadCatalog() async {
    catalogCalls++;
    final error = catalogError;
    if (error != null) throw error;
    return LibraryCatalog(
      dates: [date],
      buildings: const [
        LibraryBuilding(id: 'test-building', name: '测试图书馆'),
      ],
    );
  }

  @override
  Future<List<LibraryRoom>> loadRooms({
    required String buildingId,
    required String date,
  }) async {
    roomCalls++;
    return const [_room];
  }

  @override
  Future<LibraryRoomAvailability> loadAvailability({
    required LibraryRoom room,
    required String date,
  }) async {
    availabilityCalls++;
    return availability;
  }

  @override
  Future<LibraryParticipant> lookupParticipant({
    required String studentId,
    required LibraryRoom room,
    required String date,
    required int startMinute,
    required int endMinute,
  }) async =>
      LibraryParticipant(id: studentId, name: '测试参与人');

  @override
  Future<String> submit(LibraryBookingDraft draft) async {
    submitCalls++;
    submittedDraft = draft;
    final error = submitError;
    if (error != null) throw error;
    final pending = pendingSubmission;
    if (pending != null) return pending.future;
    return '预约成功';
  }

  @override
  Future<List<LibraryReservation>> loadReservations({int page = 1}) async {
    reservationCalls++;
    return [reservation];
  }

  @override
  Future<String> cancel(LibraryReservation reservation) async {
    cancelCalls++;
    return '取消成功';
  }

  @override
  void dispose() => disposeCalls++;
}

Future<void> _openPage(
  WidgetTester tester,
  _FakeLibraryBookingClient client,
) async {
  await tester.pumpWidget(CupertinoApp(
    home: LibraryReservationPage(
      scholar: _scholar(),
      clientFactory: (username, password) {
        expect(username, '3230000001');
        expect(password, 'test-password');
        return client;
      },
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _prepareDraft(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('library-room-test-room')));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('library-title')),
    300,
  );
  await tester.enterText(
    find.byKey(const ValueKey('library-title')),
    '课程研讨',
  );
  await tester.enterText(
    find.byKey(const ValueKey('library-content')),
    '课程项目小组讨论',
  );
  await tester.ensureVisible(find.byKey(const ValueKey('library-submit')));
  await tester.pumpAndSettle();
}

Future<void> _pumpDialog(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets('未登录时解释登录要求，不创建预约客户端', (tester) async {
    var clientCreations = 0;
    await tester.pumpWidget(CupertinoApp(
      home: LibraryReservationPage(
        scholar: _scholar(loggedIn: false),
        clientFactory: (_, __) {
          clientCreations++;
          throw StateError('未登录不应开始图书馆认证');
        },
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('请先在设置中登录'), findsOneWidget);
    expect(clientCreations, 0);
    expect(find.byKey(const ValueKey('library-submit')), findsNothing);
  });

  testWidgets('演示账号不能创建真实预约客户端', (tester) async {
    var clientCreations = 0;
    await tester.pumpWidget(CupertinoApp(
      home: LibraryReservationPage(
        scholar: _scholar(username: '3200000000'),
        clientFactory: (_, __) {
          clientCreations++;
          throw StateError('演示账号不应开始图书馆认证');
        },
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('演示账号无法预约'), findsOneWidget);
    expect(clientCreations, 0);
    expect(find.byKey(const ValueKey('library-submit')), findsNothing);
  });

  testWidgets('查询失败后可以重试并恢复房间列表', (tester) async {
    final client = _FakeLibraryBookingClient()
      ..catalogError = const LibraryBookingException('图书馆服务暂时不可用');
    await _openPage(tester, client);

    expect(find.textContaining('图书馆服务暂时不可用'), findsOneWidget);
    expect(client.catalogCalls, 1);
    expect(client.roomCalls, 0);

    client.catalogError = null;
    await tester.tap(find.byKey(const ValueKey('library-retry')));
    await tester.pumpAndSettle();

    expect(client.catalogCalls, 2);
    expect(client.roomCalls, 1);
    expect(
        find.byKey(const ValueKey('library-room-test-room')), findsOneWidget);
    expect(find.textContaining('图书馆服务暂时不可用'), findsNothing);
  });

  testWidgets('取消预约必须先确认，关闭确认框不会发送请求', (tester) async {
    final client = _FakeLibraryBookingClient();
    await _openPage(tester, client);
    await tester.tap(find.text('我的预约'));
    await tester.pumpAndSettle();

    final cancel =
        find.byKey(const ValueKey('library-cancel-test-reservation'));
    await tester.tap(cancel);
    await _pumpDialog(tester);
    expect(find.text('取消这条预约？'), findsOneWidget);
    expect(client.cancelCalls, 0);

    final context = tester.element(find.byType(CupertinoAlertDialog));
    Navigator.of(context).pop(false);
    await tester.pumpAndSettle();
    expect(client.cancelCalls, 0);

    await tester.tap(cancel);
    await _pumpDialog(tester);
    await tester.tap(find.text('确认取消'));
    await _pumpDialog(tester);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(client.cancelCalls, 1);
  });

  testWidgets('预约表单先展示确认内容，取消确认不会提交', (tester) async {
    final client = _FakeLibraryBookingClient();
    await _openPage(tester, client);
    await _prepareDraft(tester);

    await tester.tap(find.byKey(const ValueKey('library-submit')));
    await _pumpDialog(tester);

    expect(find.text('确认预约'), findsOneWidget);
    expect(client.submitCalls, 0);
    final dialog = find.byType(CupertinoAlertDialog);
    expect(
      find.descendant(of: dialog, matching: find.textContaining(_room.name)),
      findsOneWidget,
    );
    Navigator.of(tester.element(dialog)).pop(false);
    await tester.pumpAndSettle();
    expect(client.submitCalls, 0);
  });

  testWidgets('提交处理中不能重复预约，完成后显示预约记录', (tester) async {
    final pending = Completer<String>();
    final client = _FakeLibraryBookingClient()..pendingSubmission = pending;
    await _openPage(tester, client);
    await _prepareDraft(tester);
    await tester.tap(find.byKey(const ValueKey('library-submit')));
    await _pumpDialog(tester);
    await tester.tap(find.text('提交预约'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(client.submitCalls, 1);
    final submit = find.byKey(const ValueKey('library-submit'));
    expect(tester.widget<CupertinoButton>(submit).onPressed, isNull);
    await tester.ensureVisible(submit);
    await tester.pump();
    await tester.tap(submit);
    await tester.pump();
    expect(client.submitCalls, 1);
    expect(find.text('确认预约'), findsNothing);

    pending.complete('预约成功');
    await _pumpDialog(tester);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(client.submittedDraft?.room.id, _room.id);
    expect(client.submittedDraft?.content, '课程项目小组讨论');
    expect(client.reservationCalls, greaterThanOrEqualTo(1));
  });

  testWidgets('提交结果未知时引导查询记录，且不会自动重发预约', (tester) async {
    final client = _FakeLibraryBookingClient()
      ..submitError = const LibraryBookingException(
        '提交后连接中断',
        outcomeUnknown: true,
      );
    await _openPage(tester, client);
    await _prepareDraft(tester);
    await tester.tap(find.byKey(const ValueKey('library-submit')));
    await _pumpDialog(tester);
    await tester.tap(find.text('提交预约'));
    await _pumpDialog(tester);

    expect(client.submitCalls, 1);
    expect(find.text('预约结果待确认'), findsOneWidget);
    expect(find.textContaining('避免重复预约'), findsOneWidget);

    Navigator.of(tester.element(find.byType(CupertinoAlertDialog))).pop();
    await tester.pumpAndSettle();
    expect(client.reservationCalls, greaterThanOrEqualTo(1));
    expect(client.submitCalls, 1);
    expect(
      find.byKey(const ValueKey('library-cancel-test-reservation')),
      findsOneWidget,
    );

    await tester.tap(find.text('预约研讨间'));
    await tester.pumpAndSettle();
    final submit = find.byKey(const ValueKey('library-submit'));
    await tester.scrollUntilVisible(submit, 300);
    expect(tester.widget<CupertinoButton>(submit).onPressed, isNull);
    expect(client.submitCalls, 1);
  });

  testWidgets('退出页面释放内存中的预约会话', (tester) async {
    final client = _FakeLibraryBookingClient();
    await _openPage(tester, client);
    expect(client.catalogCalls, 1);
    expect(client.disposeCalls, 0);

    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();

    expect(client.disposeCalls, 1);
  });
}
