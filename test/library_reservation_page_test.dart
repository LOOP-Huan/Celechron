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
  floorId: 'floor-2',
  floorName: '二层',
);
const _sameFloorRoom = LibraryRoom(
  id: 'room-202',
  name: '测试研讨间 202',
  buildingId: 'test-building',
  floorId: 'floor-2',
  floorName: '二层',
);
const _thirdFloorRoom = LibraryRoom(
  id: 'room-301',
  name: '测试研讨间 301',
  buildingId: 'test-building',
  floorId: 'floor-3',
  floorName: '三层',
);

LibraryRoom _catalogRoom(String id,
        {bool canReserve = true, bool known = true, bool thirdFloor = false}) =>
    LibraryRoom(
      id: id,
      name: id,
      buildingId: 'test-building',
      floorId: thirdFloor ? 'floor-3' : 'floor-2',
      floorName: thirdFloor ? '三层' : '二层',
      canReserve: canReserve,
      availabilityKnown: known,
    );

List<String> _displayedRoomIds(WidgetTester tester) => tester
    .widgetList<CupertinoButton>(find.byWidgetPredicate((widget) =>
        widget is CupertinoButton &&
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith('library-room-')))
    .map((button) => (button.key! as ValueKey<String>)
        .value
        .substring('library-room-'.length))
    .toList();

class _FakeLibraryBookingClient implements LibraryBookingClient {
  _FakeLibraryBookingClient() {
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    date = '${tomorrow.year}-'
        '${tomorrow.month.toString().padLeft(2, '0')}-'
        '${tomorrow.day.toString().padLeft(2, '0')}';
    final afterTomorrow = tomorrow.add(const Duration(days: 1));
    secondDate = '${afterTomorrow.year}-'
        '${afterTomorrow.month.toString().padLeft(2, '0')}-'
        '${afterTomorrow.day.toString().padLeft(2, '0')}';
  }

  late final String date;
  late final String secondDate;
  int catalogCalls = 0;
  int roomCalls = 0;
  int availabilityCalls = 0;
  int submitCalls = 0;
  int reservationCalls = 0;
  int cancelCalls = 0;
  int endCalls = 0;
  int disposeCalls = 0;
  Object? catalogError;
  Object? submitError;
  Object? cancelError;
  Object? endError;
  bool reservationCanCancel = true;
  bool reservationCanEnd = false;
  String reservationStatus = '预约成功';
  String cancellationWarning = '';
  String? endReason;
  List<LibraryRoom> rooms = const [_room];
  List<LibraryRoom>? secondDateRooms;
  final List<String?> catalogDates = [];
  final List<({String buildingId, String date})> roomQueries = [];
  final List<({LibraryRoom room, String date})> availabilityQueries = [];
  bool detailCanReserve = true;
  String? detailUnavailableReason;
  String rules = '';
  List<LibraryTitleChoice> titleChoices = const [];
  Completer<LibraryCatalog>? pendingCatalog;
  Completer<String>? pendingSubmission;
  Completer<String>? pendingEnd;
  LibraryBookingDraft? submittedDraft;

  LibraryRoomAvailability availability(LibraryRoom room, String date) =>
      LibraryRoomAvailability(
        room: room,
        date: date,
        startMinute: 8 * 60,
        endMinute: 22 * 60,
        minDurationMinutes: 30,
        maxDurationMinutes: 4 * 60,
        titleRequired: true,
        titleChoices: titleChoices,
        rules: rules,
        mobile: '13800000000',
        canReserve: detailCanReserve,
        unavailableReason: detailUnavailableReason,
      );

  LibraryCatalog get catalog => LibraryCatalog(
        dates: [date, secondDate],
        buildings: const [
          LibraryBuilding(id: 'test-building', name: '测试图书馆'),
        ],
      );

  LibraryReservation get reservation => LibraryReservation(
        id: 'test-reservation',
        roomName: _room.name,
        date: date,
        startTime: '08:00',
        endTime: '08:30',
        status: reservationStatus,
        canCancel: reservationCanCancel,
        canEnd: reservationCanEnd,
        endReason: endReason,
        cancellationWarning: cancellationWarning,
      );

  @override
  Future<LibraryCatalog> loadCatalog({String? date}) async {
    catalogCalls++;
    catalogDates.add(date);
    final error = catalogError;
    if (error != null) throw error;
    final pending = pendingCatalog;
    if (pending != null) return pending.future;
    return catalog;
  }

  @override
  Future<List<LibraryRoom>> loadRooms({
    required String buildingId,
    required String date,
  }) async {
    roomCalls++;
    roomQueries.add((buildingId: buildingId, date: date));
    return date == secondDate ? secondDateRooms ?? rooms : rooms;
  }

  @override
  Future<LibraryRoomAvailability> loadAvailability({
    required LibraryRoom room,
    required String date,
  }) async {
    availabilityCalls++;
    availabilityQueries.add((room: room, date: date));
    return availability(room, date);
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
    final error = cancelError;
    if (error != null) throw error;
    return '取消成功';
  }

  @override
  Future<String> endUse(LibraryReservation reservation) async {
    endCalls++;
    final error = endError;
    if (error != null) throw error;
    final message = await (pendingEnd?.future ?? Future.value('结束成功'));
    reservationCanCancel = false;
    reservationCanEnd = false;
    reservationStatus = '已结束使用';
    return message;
  }

  @override
  void dispose() => disposeCalls++;
}

Future<void> _openPage(WidgetTester tester, _FakeLibraryBookingClient client,
    {double textScale = 1,
    Scholar? scholar,
    Brightness brightness = Brightness.light}) async {
  await tester.pumpWidget(CupertinoApp(
    theme: CupertinoThemeData(brightness: brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: LibraryReservationPage(
      scholar: scholar ?? _scholar(),
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
  await _scrollTo(tester, find.byKey(const ValueKey('library-room-test-room')));
  await tester.tap(find.byKey(const ValueKey('library-room-test-room')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('library-next')));
  await tester.pumpAndSettle();
  await _scrollTo(tester, find.byKey(const ValueKey('library-title')));
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

Future<void> _scrollTo(WidgetTester tester, Finder target,
    {double delta = 250}) async {
  await tester.scrollUntilVisible(
    target,
    delta,
    scrollable: find
        .byWidgetPredicate((widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down)
        .first,
  );
  await tester.pump();
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

  testWidgets('目录默认首层，仅显示选中楼层且合并未标注楼层', (tester) async {
    final client = _FakeLibraryBookingClient()
      ..rooms = const [
        _room,
        _sameFloorRoom,
        _thirdFloorRoom,
        LibraryRoom(
            id: 'unknown-1',
            name: '未知楼层 A',
            buildingId: 'test-building',
            floorId: 'internal-1'),
        LibraryRoom(
            id: 'unknown-2',
            name: '未知楼层 B',
            buildingId: 'test-building',
            floorId: 'internal-2'),
      ];
    await _openPage(tester, client);
    expect(
        find.byKey(const ValueKey('library-room-test-room')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-room-room-202')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-room-room-301')), findsNothing);
    expect(find.text('全部楼层'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('library-floor-floor-3')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-room-room-301')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-room-test-room')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('library-floor-unassigned')));
    await tester.pumpAndSettle();
    expect(find.text('未标注楼层 · 2/2'), findsOneWidget);
    expect(find.text('未知楼层 A'), findsOneWidget);
    expect(find.text('未知楼层 B'), findsOneWidget);
    expect(find.textContaining('internal-'), findsNothing);
  });

  testWidgets('同楼层按可用、待确认、不可用稳定排列且不更改权限和官网数据', (tester) async {
    final source = List<LibraryRoom>.unmodifiable([
      _catalogRoom('closed-a', canReserve: false),
      _catalogRoom('unknown-a', known: false),
      _catalogRoom('available-a'),
      _catalogRoom('closed-b', canReserve: false),
      _catalogRoom('available-b'),
      _catalogRoom('unknown-b', canReserve: false, known: false),
    ]);
    final originalIds = source.map((room) => room.id).toList();
    final client = _FakeLibraryBookingClient()..rooms = source;
    await _openPage(tester, client);

    expect(_displayedRoomIds(tester), [
      'available-a',
      'available-b',
      'unknown-a',
      'unknown-b',
      'closed-a',
      'closed-b',
    ]);
    expect(client.rooms.map((room) => room.id), originalIds);
    expect(find.text('二层 · 2/6 · 2待确认'), findsOneWidget);
    expect(find.text('可用/总数，待确认的研讨间可进入详情查询'), findsOneWidget);
    for (final id in ['unknown-a', 'unknown-b']) {
      expect(
          tester
              .widget<CupertinoButton>(find.byKey(ValueKey('library-room-$id')))
              .onPressed,
          isNotNull);
    }
    for (final id in ['closed-a', 'closed-b']) {
      expect(
          tester
              .widget<CupertinoButton>(find.byKey(ValueKey('library-room-$id')))
              .onPressed,
          isNull);
    }
    expect(client.availabilityCalls, 0);
  });

  testWidgets('各楼层独立统计可用和待确认数量，楼层保留官网出现顺序', (tester) async {
    final client = _FakeLibraryBookingClient()
      ..rooms = [
        _catalogRoom('third-closed', canReserve: false, thirdFloor: true),
        _catalogRoom('second-available'),
        _catalogRoom('third-unknown', known: false, thirdFloor: true),
        _catalogRoom('second-closed', canReserve: false),
      ];
    await _openPage(tester, client);
    final floorIds = tester
        .widgetList<CupertinoButton>(find.byWidgetPredicate((widget) =>
            widget is CupertinoButton &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>)
                .value
                .startsWith('library-floor-')))
        .map((button) => (button.key! as ValueKey<String>).value)
        .toList();
    expect(floorIds, ['library-floor-floor-3', 'library-floor-floor-2']);
    expect(find.text('三层 · 0/2 · 1待确认'), findsOneWidget);
    expect(find.text('二层 · 1/2'), findsOneWidget);
    expect(_displayedRoomIds(tester), ['third-unknown', 'third-closed']);

    await tester.tap(find.byKey(const ValueKey('library-floor-floor-2')));
    await tester.pumpAndSettle();
    expect(_displayedRoomIds(tester), ['second-available', 'second-closed']);
  });

  testWidgets('刷新重新统计并排序，未知状态确认后移除待确认说明', (tester) async {
    final client = _FakeLibraryBookingClient()
      ..rooms = [
        _catalogRoom('closed', canReserve: false),
        _catalogRoom('available'),
        _catalogRoom('pending', known: false),
      ];
    await _openPage(tester, client);
    expect(find.text('二层 · 1/3 · 1待确认'), findsOneWidget);
    expect(_displayedRoomIds(tester), ['available', 'pending', 'closed']);

    client.rooms = [
      _catalogRoom('closed', canReserve: false),
      _catalogRoom('available', canReserve: false),
      _catalogRoom('pending'),
    ];
    await tester.tap(find.byKey(const ValueKey('library-refresh')));
    await tester.pumpAndSettle();
    expect(client.catalogCalls, 2);
    expect(client.roomCalls, 2);
    expect(_displayedRoomIds(tester), ['pending', 'closed', 'available']);
    expect(find.text('二层 · 1/3'), findsOneWidget);
    expect(find.textContaining('待确认'), findsNothing);
    expect(find.text('可用/总数'), findsOneWidget);
  });

  testWidgets('界面与系统返回保留时段和申请内容，重新进入同房间不丢草稿', (tester) async {
    final client = _FakeLibraryBookingClient();
    await _openPage(tester, client);
    await _prepareDraft(tester);
    final tabs = find.byKey(const ValueKey('library-section-tabs'));
    final tabPosition = tester.getTopLeft(tabs);
    await _scrollTo(tester, find.byKey(const ValueKey('library-mobile')));
    expect(tester.getTopLeft(tabs), tabPosition);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-start')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-title')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('library-navigation-back')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('library-room-test-room')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('library-room-test-room')));
    await tester.pumpAndSettle();
    expect(client.availabilityCalls, 1);
    await tester.tap(find.byKey(const ValueKey('library-next')));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.byKey(const ValueKey('library-title')));
    expect(
        tester
            .widget<CupertinoTextField>(
                find.byKey(const ValueKey('library-title')))
            .controller!
            .text,
        '课程研讨');
    expect(
        tester
            .widget<CupertinoTextField>(
                find.byKey(const ValueKey('library-content')))
            .controller!
            .text,
        '课程项目小组讨论');
  });

  for (final destination in [_sameFloorRoom, _thirdFloorRoom]) {
    testWidgets('换到${destination.name}清除旧房间申请内容', (tester) async {
      final client = _FakeLibraryBookingClient()
        ..rooms = const [_room, _sameFloorRoom, _thirdFloorRoom];
      await _openPage(tester, client);
      await _prepareDraft(tester);
      for (var step = 0; step < 2; step++) {
        await tester.tap(find.byKey(const ValueKey('library-navigation-back')));
        await tester.pumpAndSettle();
      }
      if (destination.floorId != _room.floorId) {
        await tester
            .tap(find.byKey(ValueKey('library-floor-${destination.floorId}')));
        await tester.pumpAndSettle();
      }
      final room = find.byKey(ValueKey('library-room-${destination.id}'));
      await _scrollTo(tester, room);
      await tester.tap(room);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-next')));
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.byKey(const ValueKey('library-title')));
      expect(
          tester
              .widget<CupertinoTextField>(
                  find.byKey(const ValueKey('library-title')))
              .controller!
              .text,
          isEmpty);
      expect(
          tester
              .widget<CupertinoTextField>(
                  find.byKey(const ValueKey('library-content')))
              .controller!
              .text,
          isEmpty);
      expect(client.availabilityQueries.last.room.id, destination.id);
      expect(client.submitCalls, 0);
    });
  }

  testWidgets('须知全文只在独立页面显示，返回后仍保留所选时段', (tester) async {
    const rules = '预约使用规则\n请按时到馆签到\n离开时请保持安静并带走物品';
    final client = _FakeLibraryBookingClient()..rules = rules;
    await _openPage(tester, client);
    await tester.tap(find.byKey(const ValueKey('library-room-test-room')));
    await tester.pumpAndSettle();
    expect(find.text(rules), findsNothing);
    await tester.tap(find.byKey(const ValueKey('library-rules')));
    await tester.pumpAndSettle();
    expect(find.text(rules), findsOneWidget);
    Navigator.of(tester.element(find.text(rules))).pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-start')), findsOneWidget);
    expect(
        tester
            .widget<CupertinoButton>(find.byKey(const ValueKey('library-next')))
            .onPressed,
        isNotNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('小屏放大文字时三步可操作且顶部预约切换保持可见（${brightness.name}）', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = _FakeLibraryBookingClient();
      await _openPage(tester, client, textScale: 1.5, brightness: brightness);
      expect(tester.takeException(), isNull);
      final tabs = find.byKey(const ValueKey('library-section-tabs'));
      final position = tester.getTopLeft(tabs);
      await _prepareDraft(tester);
      expect(tester.takeException(), isNull);
      expect(tester.getTopLeft(tabs), position);
      expect(find.byKey(const ValueKey('library-submit')).hitTestable(),
          findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('library-navigation-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-next')).hitTestable(),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('刷新后取消的固定主题不会覆盖新填写的自由主题', (tester) async {
    const choice = LibraryTitleChoice(id: 'old-topic', title: '旧固定主题');
    final client = _FakeLibraryBookingClient()..titleChoices = [choice];
    await _openPage(tester, client);
    await tester.tap(find.byKey(const ValueKey('library-room-test-room')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-next')));
    await tester.pumpAndSettle();
    final title = find.byKey(const ValueKey('library-title'));
    await _scrollTo(tester, title);
    await tester.tap(title);
    await tester.pumpAndSettle();
    await tester.tap(find.text('旧固定主题').last);
    await tester.pumpAndSettle();
    client.titleChoices = [];
    await tester.tap(find.byKey(const ValueKey('library-refresh')));
    await tester.pumpAndSettle();
    expect(client.catalogCalls, 1);
    expect(client.availabilityCalls, 2);
    await _scrollTo(tester, title);
    await tester.enterText(title, '刷新后填写的主题');
    await tester.enterText(
        find.byKey(const ValueKey('library-content')), '课程项目小组讨论');
    await tester.tap(find.byKey(const ValueKey('library-submit')));
    await _pumpDialog(tester);
    await tester.tap(find.text('提交预约'));
    await _pumpDialog(tester);
    expect(client.submittedDraft?.title, '刷新后填写的主题');
    expect(client.submittedDraft?.titleChoice, isNull);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
  });

  testWidgets('目录未提供预约状态时仍可查看真实可用时段', (tester) async {
    const unknownRoom = LibraryRoom(
      id: 'unknown-room',
      name: '状态待查询的研讨间',
      buildingId: 'test-building',
      canReserve: false,
      availabilityKnown: false,
    );
    final client = _FakeLibraryBookingClient()..rooms = [unknownRoom];
    await _openPage(tester, client);
    final room = find.byKey(const ValueKey('library-room-unknown-room'));
    expect(tester.widget<CupertinoButton>(room).onPressed, isNotNull);
    expect(find.text('查看可用时段'), findsOneWidget);
    expect(find.text('暂不可预约'), findsNothing);

    await tester.tap(room);
    await tester.pumpAndSettle();
    expect(client.availabilityCalls, 1);
    expect(client.availabilityQueries.single.room.id, unknownRoom.id);
    expect(client.availabilityQueries.single.date, client.date);
    final start = find.byKey(const ValueKey('library-start'));
    await _scrollTo(tester, start);
    expect(start, findsOneWidget);
    expect(client.submitCalls, 0);
  });

  for (final reason in ['该日期已约满，请选择其他日期。', '此研讨间暂未开放预约，请查看开放安排。']) {
    testWidgets('目录明确不可预约时保留具体原因：$reason', (tester) async {
      final client = _FakeLibraryBookingClient()
        ..rooms = [
          LibraryRoom(
            id: 'unavailable-room',
            name: '暂不可预约研讨间',
            buildingId: 'test-building',
            canReserve: false,
            availabilityKnown: true,
            unavailableReason: reason,
          ),
        ];
      await _openPage(tester, client);
      final room = find.byKey(const ValueKey('library-room-unavailable-room'));
      expect(find.text(reason), findsOneWidget);
      expect(tester.widget<CupertinoButton>(room).onPressed, isNull);
      expect(find.text('当前账号无法预约此研讨间。'), findsNothing);
      expect(client.availabilityCalls, 0);
      expect(client.submitCalls, 0);
    });
  }

  testWidgets('详情不可预约时展示返回的开放限制，不误报账号无权限', (tester) async {
    const reason = '所选日期已超过此研讨间开放范围。';
    final client = _FakeLibraryBookingClient()
      ..detailCanReserve = false
      ..detailUnavailableReason = reason;
    await _openPage(tester, client);
    await tester.tap(find.byKey(const ValueKey('library-room-test-room')));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text(reason));

    expect(find.text(reason), findsOneWidget);
    expect(find.text('当前账号无法预约此研讨间。'), findsNothing);
    expect(find.byKey(const ValueKey('library-submit')), findsNothing);
    expect(
        tester
            .widget<CupertinoButton>(find.byKey(const ValueKey('library-next')))
            .onPressed,
        isNull);
    expect(client.submitCalls, 0);
  });

  testWidgets('切换日期按新日期重新获取目录并在等待期间清除旧房间', (tester) async {
    const nextRoom = LibraryRoom(
      id: 'next-date-room',
      name: '次日开放的研讨间',
      buildingId: 'test-building',
    );
    final client = _FakeLibraryBookingClient()..secondDateRooms = [nextRoom];
    await _openPage(tester, client);
    await _prepareDraft(tester);
    await tester.tap(find.byKey(const ValueKey('library-navigation-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-navigation-back')));
    await tester.pumpAndSettle();
    final pending = Completer<LibraryCatalog>();
    client.pendingCatalog = pending;
    addTearDown(() {
      if (!pending.isCompleted) pending.complete(client.catalog);
    });

    final date = find.byKey(const ValueKey('library-date'));
    await _scrollTo(tester, date, delta: -250);
    await tester.tap(date);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(CupertinoActionSheet),
      matching: find.text(client.secondDate),
    ));
    await _pumpDialog(tester);

    expect(client.catalogCalls, 2);
    expect(client.catalogDates.last, client.secondDate);
    expect(find.byKey(const ValueKey('library-room-test-room')), findsNothing);
    expect(find.byKey(const ValueKey('library-submit')), findsNothing);
    expect(client.submitCalls, 0);

    pending.complete(client.catalog);
    await tester.pumpAndSettle();
    expect(client.roomQueries.last,
        (buildingId: 'test-building', date: client.secondDate));
    final room = find.byKey(const ValueKey('library-room-next-date-room'));
    expect(room, findsOneWidget);
    await tester.tap(room);
    await tester.pumpAndSettle();
    expect(client.availabilityQueries.last.room.id, nextRoom.id);
    expect(client.availabilityQueries.last.date, client.secondDate);
  });

  testWidgets('取消预约必须先确认，关闭确认框不会发送请求', (tester) async {
    const warning = '距离预约开始不足 30 分钟，取消可能记为违约。';
    final client = _FakeLibraryBookingClient()..cancellationWarning = warning;
    await _openPage(tester, client);
    await tester.tap(find.text('我的预约'));
    await tester.pumpAndSettle();

    final cancel =
        find.byKey(const ValueKey('library-cancel-test-reservation'));
    await tester.tap(cancel);
    await _pumpDialog(tester);
    expect(find.text('取消这条预约？'), findsOneWidget);
    expect(find.textContaining(warning), findsOneWidget);
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

  testWidgets('原预约记录按权限提供结束使用，二次确认后只执行一次', (tester) async {
    final pending = Completer<String>();
    final client = _FakeLibraryBookingClient()
      ..reservationCanEnd = true
      ..reservationCanCancel = true
      ..reservationStatus = '使用中'
      ..pendingEnd = pending;
    await _openPage(tester, client);
    await tester.tap(find.text('我的预约'));
    await tester.pumpAndSettle();
    final end = find.byKey(const ValueKey('library-end-test-reservation'));
    expect(end, findsOneWidget);
    expect(find.byKey(const ValueKey('library-cancel-test-reservation')),
        findsNothing);
    expect(find.text('当前预约'), findsNothing);
    expect(find.text('预约记录'), findsNothing);

    await tester.tap(end);
    await _pumpDialog(tester);
    expect(find.text('结束使用这个研讨间？'), findsOneWidget);
    expect(find.textContaining('确认后将结束本次研讨间使用。'), findsOneWidget);
    expect(client.endCalls, 0);
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(client.endCalls, 0);

    await tester.tap(end);
    await _pumpDialog(tester);
    await tester.tap(find.text('确认结束'));
    await _pumpDialog(tester);
    expect(client.endCalls, 1);
    expect(tester.widget<CupertinoButton>(end).onPressed, isNull);
    await tester.tap(end);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(client.endCalls, 1);
    expect(end, findsOneWidget);
    expect(client.cancelCalls, 0);

    pending.complete('结束成功');
    await _pumpDialog(tester);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(client.reservationCalls, 2);
    expect(find.text('已结束使用'), findsOneWidget);
    expect(end, findsNothing);
  });

  for (final ending in [false, true]) {
    final action = ending ? '结束' : '取消';
    testWidgets('$action结果未知时刷新原列表并锁住同一预约的所有操作', (tester) async {
      const unknown = LibraryBookingException('响应中断', outcomeUnknown: true);
      final client = _FakeLibraryBookingClient()
        ..reservationCanEnd = ending
        ..reservationCanCancel = !ending
        ..endError = ending ? unknown : null
        ..cancelError = ending ? null : unknown;
      await _openPage(tester, client);
      await tester.tap(find.text('我的预约'));
      await tester.pumpAndSettle();
      final actionKey = ending
          ? 'library-end-test-reservation'
          : 'library-cancel-test-reservation';
      await tester.tap(find.byKey(ValueKey(actionKey)));
      await _pumpDialog(tester);
      await tester.tap(find.text(ending ? '确认结束' : '确认取消'));
      await _pumpDialog(tester);
      expect(find.text('$action结果待确认'), findsOneWidget);

      // The next read exposes the other action for the same id. It must still
      // be locked because this page cannot establish the earlier write result.
      client.reservationCanEnd = !ending;
      client.reservationCanCancel = ending;
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(client.reservationCalls, 2);
      expect(find.textContaining('$action结果待确认'), findsOneWidget);
      expect(find.byKey(const ValueKey('library-end-test-reservation')),
          findsNothing);
      expect(find.byKey(const ValueKey('library-cancel-test-reservation')),
          findsNothing);
      await tester.tap(find.byKey(const ValueKey('library-refresh')));
      await tester.pumpAndSettle();
      expect(client.reservationCalls, 3);
      expect(client.endCalls, ending ? 1 : 0);
      expect(client.cancelCalls, ending ? 0 : 1);
      expect(find.byKey(const ValueKey('library-end-test-reservation')),
          findsNothing);
      expect(find.byKey(const ValueKey('library-cancel-test-reservation')),
          findsNothing);
    });
  }

  testWidgets('结束确认期间账号改变不会发送结束请求', (tester) async {
    final scholar = _scholar();
    final client = _FakeLibraryBookingClient()..reservationCanEnd = true;
    await _openPage(tester, client, scholar: scholar);
    await tester.tap(find.text('我的预约'));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('library-end-test-reservation')));
    await _pumpDialog(tester);
    scholar.username = '3230000002';
    await tester.tap(find.text('确认结束'));
    await tester.pumpAndSettle();
    expect(client.endCalls, 0);
    expect(client.cancelCalls, 0);
    expect(client.disposeCalls, 1);
    expect(find.textContaining('登录账号已变化'), findsOneWidget);
  });

  testWidgets('使用中状态本身不授予结束权限，展示服务端不可用原因', (tester) async {
    const reason = '结束权限暂未确认，请刷新预约记录后重试。';
    final client = _FakeLibraryBookingClient()
      ..reservationCanEnd = false
      ..reservationCanCancel = false
      ..reservationStatus = '使用中'
      ..endReason = reason;
    await _openPage(tester, client);
    await tester.tap(find.text('我的预约'));
    await tester.pumpAndSettle();
    expect(find.text('使用中'), findsOneWidget);
    expect(find.text(reason), findsOneWidget);
    expect(find.byKey(const ValueKey('library-end-test-reservation')),
        findsNothing);
    expect(find.byKey(const ValueKey('library-cancel-test-reservation')),
        findsNothing);
    expect(client.endCalls, 0);
    expect(client.cancelCalls, 0);
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
    expect(
        tester
            .widget<CupertinoButton>(
                find.byKey(const ValueKey('library-navigation-back')))
            .onPressed,
        isNull);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(submit, findsOneWidget);
    await tester.tap(find.text('我的预约'));
    await tester.pump();
    expect(client.reservationCalls, 0);
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
    await tester.tap(find.text('预约研讨间'));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('library-room-test-room')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-submit')), findsNothing);
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
    await _scrollTo(tester, submit);
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
