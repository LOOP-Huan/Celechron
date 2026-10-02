import 'dart:async';

import 'package:celechron/model/library_seat.dart';
import 'package:celechron/model/scholar.dart';
import 'package:celechron/page/library/library_seat_page.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

Scholar _scholar({String username = '3230000001', bool loggedIn = true}) =>
    Scholar()
      ..username = username
      ..password = 'test-password'
      ..isLogan = loggedIn;

const _firstDate = '2026-10-03';
const _secondDate = '2026-10-04';
const _unknownCancellation = '取消权限暂未确认，请刷新预约记录后重试。';
const _cancellationWarning = '请在预约开始前取消，逾期按违约处理。';
const _secondFloor = LibrarySeatArea(
  id: 'area-2',
  name: '二层阅览区',
  buildingId: 'library-1',
  floorName: '二层',
);
const _thirdFloor = LibrarySeatArea(
  id: 'area-3',
  name: '三层阅览区',
  buildingId: 'library-1',
  floorName: '三层',
);

class _FakeSeatClient implements LibrarySeatBookingClient {
  int catalogCalls = 0;
  int areaCalls = 0;
  int availabilityCalls = 0;
  int seatCalls = 0;
  int submitCalls = 0;
  int reservationCalls = 0;
  int cancelCalls = 0;
  int disposeCalls = 0;
  Object? catalogError;
  Object? seatError;
  Object? submitError;
  bool emptySeats = false;
  bool cancelled = false;
  bool cancellationPermissionKnown = true;
  String cancellationWarning = '';
  Completer<String>? pendingSubmit;
  LibrarySeatDraft? submittedDraft;
  final List<({String areaId, String date})> seatQueries = [];

  LibrarySeat seat(LibrarySeatArea area, String date) => LibrarySeat(
        id: '${area.id}-$date',
        name: '${area.floorName} 01',
        status: '空闲',
      );

  @override
  Future<LibraryCatalog> loadSeatCatalog({String? date}) async {
    catalogCalls++;
    final error = catalogError;
    if (error != null) throw error;
    return const LibraryCatalog(
      dates: [_firstDate, _secondDate],
      buildings: [LibraryBuilding(id: 'library-1', name: '测试图书馆')],
    );
  }

  @override
  Future<List<LibrarySeatArea>> loadSeatAreas({
    required String buildingId,
    required String date,
  }) async {
    areaCalls++;
    return const [_secondFloor, _thirdFloor];
  }

  @override
  Future<LibrarySeatAvailability> loadSeatAvailability({
    required LibrarySeatArea area,
  }) async {
    availabilityCalls++;
    return LibrarySeatAvailability(
      area: area,
      days: [
        for (final date in [_firstDate, _secondDate])
          LibrarySeatDay(date: date, segments: [
            LibrarySeatSegment(
              id: '${area.id}-$date-segment',
              areaId: area.id,
              date: date,
              startTime: '08:00',
              endTime: '10:00',
            ),
          ]),
      ],
    );
  }

  @override
  Future<List<LibrarySeat>> loadSeats({
    required LibrarySeatArea area,
    required LibrarySeatSegment segment,
  }) async {
    seatCalls++;
    seatQueries.add((areaId: area.id, date: segment.date));
    final error = seatError;
    if (error != null) throw error;
    return emptySeats
        ? []
        : [
            seat(area, segment.date),
            const LibrarySeat(
              id: 'occupied-seat',
              name: '占用的座位',
              status: '已占用',
              canReserve: false,
            ),
          ];
  }

  @override
  Future<String> submitSeat(LibrarySeatDraft draft) async {
    submitCalls++;
    submittedDraft = draft;
    final error = submitError;
    if (error != null) throw error;
    final pending = pendingSubmit;
    if (pending != null) return pending.future;
    return '预约成功';
  }

  @override
  Future<List<LibrarySeatReservation>> loadSeatReservations(
      {int page = 1}) async {
    reservationCalls++;
    return [
      LibrarySeatReservation(
        id: 'booking-1',
        seatName: '二层 01',
        areaName: '二层阅览区',
        date: _firstDate,
        startTime: '08:00',
        endTime: '10:00',
        status: cancelled ? '已取消' : '预约成功',
        canCancel: !cancelled && cancellationPermissionKnown,
        cancellationReason:
            cancellationPermissionKnown ? null : _unknownCancellation,
        cancellationWarning: cancellationWarning,
      ),
    ];
  }

  @override
  Future<String> cancelSeat(LibrarySeatReservation reservation) async {
    cancelCalls++;
    cancelled = true;
    return '取消成功';
  }

  @override
  void dispose() => disposeCalls++;
}

Future<void> _openPage(WidgetTester tester, _FakeSeatClient client,
    {Scholar? scholar}) async {
  await tester.pumpWidget(CupertinoApp(
    home: LibrarySeatPage(
      scholar: scholar ?? _scholar(),
      seatClientFactory: (username, password) {
        expect(username, '3230000001');
        expect(password, 'test-password');
        return client;
      },
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _selectArea(WidgetTester tester,
    {LibrarySeatArea area = _secondFloor}) async {
  final button = find.byKey(ValueKey('seat-area-${area.id}'));
  await _scrollTo(tester, button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _selectSeat(WidgetTester tester,
    {LibrarySeatArea area = _secondFloor, String date = _firstDate}) async {
  await _selectArea(tester, area: area);
  final seat = find.byKey(ValueKey('seat-item-${area.id}-$date'));
  await _scrollTo(tester, seat);
  await tester.tap(seat);
  await tester.pumpAndSettle();
}

Future<void> _openConfirmation(WidgetTester tester) async {
  final submit = find.byKey(const ValueKey('seat-submit'));
  await _scrollTo(tester, submit);
  await tester.tap(submit);
  await _pumpDialog(tester);
}

void _expectNoSubmitAction(WidgetTester tester) {
  final submit = find.byKey(const ValueKey('seat-submit'));
  if (submit.evaluate().isNotEmpty) {
    expect(tester.widget<CupertinoButton>(submit).onPressed, isNull);
  }
}

Future<void> _scrollTo(WidgetTester tester, Finder target,
    {double delta = 250}) async {
  await tester.scrollUntilVisible(
    target,
    delta,
    scrollable: find.byWidgetPredicate((widget) =>
        widget is Scrollable && widget.axisDirection == AxisDirection.down),
  );
  await tester.pump();
}

Future<void> _pumpDialog(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets('未登录不能创建真实座位客户端', (tester) async {
    var clientCreations = 0;
    await tester.pumpWidget(CupertinoApp(
      home: LibrarySeatPage(
        scholar: _scholar(loggedIn: false),
        seatClientFactory: (_, __) {
          clientCreations++;
          throw StateError('未登录不应发送座位系统请求');
        },
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('请先在设置中登录'), findsOneWidget);
    expect(clientCreations, 0);
    expect(find.byKey(const ValueKey('seat-submit')), findsNothing);
  });

  testWidgets('演示账号不能创建真实座位客户端', (tester) async {
    var clientCreations = 0;
    await tester.pumpWidget(CupertinoApp(
      home: LibrarySeatPage(
        scholar: _scholar(username: '3200000000'),
        seatClientFactory: (_, __) {
          clientCreations++;
          throw StateError('演示账号不应发送座位系统请求');
        },
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('演示账号无法预约真实座位'), findsOneWidget);
    expect(clientCreations, 0);
    expect(find.byKey(const ValueKey('seat-submit')), findsNothing);
  });

  testWidgets('座位目录读取失败可重试，不会误报为空列表', (tester) async {
    final client = _FakeSeatClient()
      ..catalogError = const LibraryBookingException('座位服务暂时不可用');
    await _openPage(tester, client);

    expect(find.textContaining('座位服务暂时不可用'), findsOneWidget);
    expect(client.catalogCalls, 1);
    expect(client.areaCalls, 0);

    client.catalogError = null;
    await tester.tap(find.byKey(const ValueKey('seat-retry')));
    await tester.pumpAndSettle();

    expect(client.catalogCalls, 2);
    expect(client.areaCalls, 1);
    expect(find.byKey(const ValueKey('seat-area-area-2')), findsOneWidget);
    expect(find.textContaining('座位服务暂时不可用'), findsNothing);
  });

  testWidgets('具体时段座位查询失败可重试同一时段', (tester) async {
    final client = _FakeSeatClient()
      ..seatError = const LibraryBookingException('座位空闲情况获取失败');
    await _openPage(tester, client);
    await _selectArea(tester);
    expect(find.textContaining('座位空闲情况获取失败'), findsOneWidget);
    expect(client.seatCalls, 1);
    _expectNoSubmitAction(tester);

    client.seatError = null;
    final retry = find.byKey(const ValueKey('seat-retry'));
    await _scrollTo(tester, retry, delta: -250);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    final seat = find.byKey(const ValueKey('seat-item-area-2-$_firstDate'));
    await _scrollTo(tester, seat);
    expect(seat, findsOneWidget);
    expect(client.seatQueries, [
      (areaId: 'area-2', date: _firstDate),
      (areaId: 'area-2', date: _firstDate)
    ]);
  });

  testWidgets('无座位时显示空状态且不能提交', (tester) async {
    final client = _FakeSeatClient()..emptySeats = true;
    await _openPage(tester, client);
    await _selectArea(tester);
    await tester.drag(find.byType(ListView).first, const Offset(0, -600));
    await tester.pumpAndSettle();

    expect(find.text('没有符合条件的座位。'), findsOneWidget);
    expect(find.byKey(const ValueKey('seat-item-area-2-$_firstDate')),
        findsNothing);
    _expectNoSubmitAction(tester);
    expect(client.submitCalls, 0);
  });

  for (final change in [
    (
      key: 'seat-date',
      label: _secondDate,
      area: _secondFloor,
      date: _secondDate
    ),
    (key: 'seat-floor', label: '三层', area: _thirdFloor, date: _firstDate),
  ]) {
    testWidgets('${change.key}变更清除旧座位，新选择使用当前筛选条件', (tester) async {
      final client = _FakeSeatClient();
      await _openPage(tester, client);
      await _selectSeat(tester);
      final filter = find.byKey(ValueKey(change.key));
      await _scrollTo(tester, filter, delta: -250);
      await tester.tap(filter);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(CupertinoActionSheet),
        matching: find.text(change.label),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('seat-item-area-2-$_firstDate')),
          findsNothing);
      _expectNoSubmitAction(tester);
      expect(client.submitCalls, 0);

      await _selectSeat(tester, area: change.area, date: change.date);
      await _openConfirmation(tester);
      await tester.tap(find.text('提交预约'));
      await _pumpDialog(tester);
      expect(client.submitCalls, 1);
      expect(client.submittedDraft?.area.id, change.area.id);
      expect(client.submittedDraft?.segment.date, change.date);
      expect(
          client.submittedDraft?.seat.id, '${change.area.id}-${change.date}');
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('选座后先确认，返回不会提交预约', (tester) async {
    final client = _FakeSeatClient();
    await _openPage(tester, client);
    await _selectSeat(tester);
    await _openConfirmation(tester);

    expect(find.text('确认座位预约'), findsOneWidget);
    expect(client.submitCalls, 0);
    final dialog = find.byType(CupertinoAlertDialog);
    expect(find.descendant(of: dialog, matching: find.textContaining('二层 01')),
        findsOneWidget);
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(client.submitCalls, 0);
  });

  testWidgets('已占用座位不能被选择或提交', (tester) async {
    final client = _FakeSeatClient();
    await _openPage(tester, client);
    await _selectArea(tester);
    final occupied = find.byKey(const ValueKey('seat-item-occupied-seat'));
    await _scrollTo(tester, occupied);
    expect(tester.widget<CupertinoButton>(occupied).onPressed, isNull);
    await tester.tap(occupied);
    await tester.pumpAndSettle();
    _expectNoSubmitAction(tester);
    expect(client.submitCalls, 0);
  });

  testWidgets('座位提交进行中禁止再次提交', (tester) async {
    final pending = Completer<String>();
    final client = _FakeSeatClient()..pendingSubmit = pending;
    await _openPage(tester, client);
    await _selectSeat(tester);
    await _openConfirmation(tester);
    await tester.tap(find.text('提交预约'));
    await _pumpDialog(tester);
    expect(client.submitCalls, 1);

    final submit = find.byKey(const ValueKey('seat-submit'));
    await _scrollTo(tester, submit);
    expect(tester.widget<CupertinoButton>(submit).onPressed, isNull);
    await tester.tap(submit);
    await tester.pump();
    expect(client.submitCalls, 1);
    expect(find.text('确认座位预约'), findsNothing);

    pending.complete('预约成功');
    await _pumpDialog(tester);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(client.reservationCalls, 1);
  });

  testWidgets('提交结果未知时仅查询记录，不自动重发', (tester) async {
    final client = _FakeSeatClient()
      ..submitError = const LibraryBookingException(
        '提交后连接中断',
        outcomeUnknown: true,
      );
    await _openPage(tester, client);
    await _selectSeat(tester);
    await _openConfirmation(tester);
    await tester.tap(find.text('提交预约'));
    await _pumpDialog(tester);
    expect(find.text('预约结果待确认'), findsOneWidget);
    expect(client.submitCalls, 1);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    expect(client.reservationCalls, 1);
    expect(client.submitCalls, 1);
    await tester.tap(find.byKey(const ValueKey('seat-refresh')));
    await tester.pumpAndSettle();
    expect(client.reservationCalls, 2);
    expect(client.submitCalls, 1);
    await tester.tap(find.text('预约座位'));
    await tester.pumpAndSettle();
    _expectNoSubmitAction(tester);
    expect(client.submitCalls, 1);
  });

  testWidgets('取消权限未知提示刷新，确认时显示服务端警告并更新取消状态', (tester) async {
    final client = _FakeSeatClient()
      ..cancellationPermissionKnown = false
      ..cancellationWarning = _cancellationWarning;
    await _openPage(tester, client);
    await tester.tap(find.text('我的座位'));
    await tester.pumpAndSettle();
    final cancel = find.byKey(const ValueKey('seat-cancel-booking-1'));
    expect(find.text(_unknownCancellation), findsOneWidget);
    expect(find.textContaining('永久不可取消'), findsNothing);
    expect(cancel, findsNothing);
    expect(client.cancelCalls, 0);

    client.cancellationPermissionKnown = true;
    await tester.tap(find.byKey(const ValueKey('seat-refresh')));
    await tester.pumpAndSettle();
    expect(find.text(_unknownCancellation), findsNothing);
    expect(cancel, findsOneWidget);
    await tester.tap(cancel);
    await _pumpDialog(tester);
    expect(find.text('取消这条预约？'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(CupertinoAlertDialog),
        matching: find.textContaining(_cancellationWarning),
      ),
      findsOneWidget,
    );
    expect(client.cancelCalls, 0);
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(client.cancelCalls, 0);

    await tester.tap(cancel);
    await _pumpDialog(tester);
    await tester.tap(find.text('确认取消'));
    await _pumpDialog(tester);
    expect(client.cancelCalls, 1);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('已取消'), findsOneWidget);
    expect(cancel, findsNothing);
    expect(client.reservationCalls, 3);
    expect(
      find.descendant(
        of: find.byType(CupertinoButton),
        matching: find.textContaining('签到'),
      ),
      findsNothing,
    );
  });

  testWidgets('确认期间退出账号不会向座位系统提交', (tester) async {
    final scholar = _scholar();
    final client = _FakeSeatClient();
    await _openPage(tester, client, scholar: scholar);
    await _selectSeat(tester);
    await _openConfirmation(tester);
    scholar.isLogan = false;
    await tester.tap(find.text('提交预约'));
    await tester.pumpAndSettle();

    expect(client.submitCalls, 0);
    expect(client.disposeCalls, 1);
    expect(find.textContaining('账号已变化'), findsOneWidget);
  });

  testWidgets('离开座位页面释放内存会话', (tester) async {
    final client = _FakeSeatClient();
    await _openPage(tester, client);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
    expect(client.disposeCalls, 1);
  });
}
