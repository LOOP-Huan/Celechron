import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:celechron/http/zjuServices/library_booking.dart';
import 'package:flutter_test/flutter_test.dart';

const _room = LibraryRoom(id: '9', name: '讨论室 9', buildingId: '3');

LibraryRoomAvailability _availability({
  List<LibraryTimeRange> unavailable = const [],
  int? earliestStartMinute,
  bool requireUntilClosing = false,
  bool requiresAttachment = false,
}) =>
    LibraryRoomAvailability(
      room: _room,
      date: '2026-10-03',
      startMinute: 480,
      endMinute: 720,
      stepMinutes: 15,
      minDurationMinutes: 60,
      maxDurationMinutes: 240,
      unavailable: unavailable,
      earliestStartMinute: earliestStartMinute,
      requireUntilClosing: requireUntilClosing,
      requiresAttachment: requiresAttachment,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _seatBookingTests();

  test('预约加密与独立 OpenSSL AES-CBC 向量一致，使用上海日期', () {
    // Independently generated with OpenSSL, not by the implementation under test.
    const encrypted =
        'ZIYerTLoswxNPLoVyj2brHjhu/0yJWtlJIvnHMRKsaT62lv8a9C/6M7lyHeREn4Z'
        '8COWZ6EPNz761BZsFfv5LRJ05w1vV/ftXwx4agsA/QI=';
    final payload = <String, dynamic>{
      'id': 2,
      'area': 9,
      'day': '2026-10-03',
      'title': '读书讨论',
      'user': '101,102',
    };
    final now = DateTime.utc(2026, 10, 1, 16, 10);
    expect(LibraryBookingCodec.encrypt(payload, now), encrypted);
    expect(LibraryBookingCodec.decrypt(encrypted, now), payload);
  });

  test('拒绝不完整的加密响应', () {
    expect(
      () => LibraryBookingCodec.decrypt(
          '%%%invalid%%%', DateTime.utc(2026, 10, 2)),
      throwsA(isA<Exception>()),
    );
  });

  test('已占用时段不能预约，相邻的空闲时段可以预约', () {
    final availability = _availability(unavailable: const [
      LibraryTimeRange(startMinute: 540, endMinute: 600),
    ]);
    expect(availability.isRangeAvailable(480, 540), isTrue);
    expect(availability.isRangeAvailable(600, 660), isTrue);
    expect(availability.isRangeAvailable(525, 585), isFalse);
    expect(availability.isRangeAvailable(480, 660), isFalse);
  });

  test('遵守时长、开放时间和当日最早开始时间', () {
    final availability = _availability(earliestStartMinute: 510);
    expect(availability.isRangeAvailable(480, 540), isFalse);
    expect(availability.isRangeAvailable(510, 570), isTrue);
    expect(availability.isRangeAvailable(510, 540), isFalse);
    expect(availability.isRangeAvailable(511, 571), isFalse);
    expect(availability.isRangeAvailable(660, 735), isFalse);
    expect(availability.isRangeAvailable(600, 540), isFalse);
  });

  test('闭馆结束限制与需要附件的房间不能被普通预约绕过', () {
    final availability = _availability(requireUntilClosing: true);
    expect(availability.isRangeAvailable(600, 660), isFalse);
    expect(availability.isRangeAvailable(600, 720), isTrue);
    expect(
      _availability(requiresAttachment: true).isRangeAvailable(480, 540),
      isFalse,
    );
  });

  test('图书馆保留 PHP 会话、通过 HTTPS 换票，认证 Cookie 不跨站泄露', () async {
    final client = _Client();
    _expectLogin(client);
    client.expectRequest('POST', '/api/Member/seminar', (request) {
      expect(request.headers.value('authorization'), 'bearerfake-token');
      expect(request.json['authorization'], 'bearerfake-token');
      expect(request.json['page'], 1);
      expect(request.json['limit'], 10);
      return _reservationResponse();
    });
    final service = _service(client);
    addTearDown(service.dispose);
    final reservations = await service.loadReservations();
    expect(reservations, hasLength(1));
    expect(reservations.single.roomName, '测试研讨间');
    expect(reservations.single.canCancel, isTrue);
    expect(client.steps, isEmpty);
  });

  test('index.html 的 CAS 交换码直接换取会话，无需请求 SPA 页面', () async {
    final client = _Client();
    _expectLogin(client,
        h5Callback: '/h5/index.html#/cas?cas=fake-exchange-code');
    client.expectRequest('POST', '/api/Member/seminar', (request) {
      expect(request.headers.value('authorization'), 'bearerfake-token');
      return _reservationResponse();
    });
    final service = _service(client);
    addTearDown(service.dispose);

    expect(await service.loadReservations(), hasLength(1));
    expect(
        client.requestedUris.any((uri) => uri.path.startsWith('/h5')), isFalse);
    expect(client.steps, isEmpty);
  });

  test('浏览器导航与 JSON API 使用各自的请求头', () async {
    final client = _Client();
    _expectLogin(client,
        h5Callback: '/h5/index.html#/cas?cas=fake-exchange-code');
    client.expectRequest(
        'POST', '/api/Member/seminar', (_) => _reservationResponse());
    final service = _service(client);
    addTearDown(service.dispose);
    await service.loadReservations();

    final navigations =
        client.requests.where((request) => request.method == 'GET');
    expect(navigations, hasLength(3));
    for (final request in navigations) {
      expect(request.headers.value('x-requested-with'), isNull,
          reason: '导航不能被服务器识别为 AJAX 请求');
      expect(request.headers.value('accept') ?? '',
          isNot(contains('application/json')));
      expect(request.headers.contentType, isNull);
    }
    final apiRequests =
        client.requests.where((request) => request.method == 'POST');
    expect(apiRequests, hasLength(2));
    for (final request in apiRequests) {
      expect(request.headers.value('x-requested-with'), 'XMLHttpRequest');
      expect(request.headers.value('accept'), 'application/json');
      expect(request.headers.contentType?.mimeType, 'application/json');
    }
    expect(client.steps, isEmpty);
  });

  test('去除 ticket 的额外跳转保留新 PHP 会话后解析 index.html', () async {
    final client = _Client();
    _expectLogin(client,
        h5Callback: '/h5/index.html#/cas?cas=fake-exchange-code',
        cleanTicketRedirect: true);
    client.expectRequest(
        'POST', '/api/Member/seminar', (_) => _reservationResponse());
    final service = _service(client);
    addTearDown(service.dispose);

    expect(await service.loadReservations(), hasLength(1));
    final exchange = client.requests
        .singleWhere((request) => request.uri.path == '/api/cas/user');
    expect(exchange.cookies.single.name, 'PHPSESSID');
    expect(exchange.cookies.single.value, 'updated-php-session');
    expect(
        client.requestedUris.any((uri) => uri.path.startsWith('/h5')), isFalse);
    expect(client.steps, isEmpty);
  });

  test('个人信息 SPA 路由不能代替认证交换码', () async {
    final client = _Client();
    _expectCasTicket(client);
    client.expectRequest(
        'GET',
        '/api/cas/cas',
        (_) => _Response(
              statusCode: 302,
              headers: {'location': '/h5/index.html#/my/info'},
            ));
    final service = _service(client);
    addTearDown(service.dispose);

    await expectLater(
        service.loadReservations(), throwsA(isA<LibraryBookingException>()));
    expect(client.requestedUris, hasLength(3));
    expect(
        client.requestedUris.any((uri) => uri.path.startsWith('/h5')), isFalse);
    expect(client.requests.any((request) => request.method == 'POST'), isFalse);
    expect(client.steps, isEmpty);
  });

  test('HTTP 200 的 CAS 失败 HTML 夹 JSON 显示票据拒绝而不泄露正文', () async {
    final client = _Client();
    _expectCasTicket(client);
    const body = '<html><body><h1>CAS Authentication failed!</h1>'
        '<pre>{"ticket":"FAKE-TICKET-SECRET","cas":"FAKE-CAS-SECRET",'
        '"password":"FAKE-PASSWORD-SECRET test-password"}</pre>'
        '</body></html>';
    client.expectRequest(
        'GET',
        '/api/cas/cas',
        (_) => _Response(
              statusCode: 200,
              headers: {'content-type': 'text/html'},
              body: body,
            ));
    final service = _service(client);
    addTearDown(service.dispose);

    await expectLater(
      service.loadReservations(),
      throwsA(isA<LibraryBookingException>().having(
          (error) => error.message,
          '安全票据拒绝提示',
          allOf([
            contains('未接受认证票据'),
            contains('HTTP 200'),
            contains('HTML'),
            isNot(contains('FAKE-TICKET-SECRET')),
            isNot(contains('FAKE-CAS-SECRET')),
            isNot(contains('FAKE-PASSWORD-SECRET')),
            isNot(contains('test-password')),
            isNot(contains(body)),
          ]))),
    );
    expect(client.requestedUris, hasLength(3));
    expect(client.steps, isEmpty);
  });

  for (final invalidCallback in {
    '外站': 'https://example.org/h5/index.html#/cas?cas=FAKE-CAS-SECRET',
    'HTTP':
        'http://booking.lib.zju.edu.cn/h5/index.html#/cas?cas=FAKE-CAS-SECRET',
    '错误承载路径':
        'https://booking.lib.zju.edu.cn/other/index.html#/cas?cas=FAKE-CAS-SECRET',
  }.entries) {
    test('带交换码的${invalidCallback.key}回调不能认证', () async {
      final client = _Client();
      _expectCasTicket(client);
      client.expectRequest(
          'GET',
          '/api/cas/cas',
          (_) => _Response(
                statusCode: 302,
                headers: {'location': invalidCallback.value},
              ));
      final service = _service(client);
      addTearDown(service.dispose);

      await expectLater(
          service.loadReservations(), throwsA(isA<LibraryBookingException>()));
      expect(client.requestedUris, hasLength(3));
      expect(
          client.requests.any((request) => request.method == 'POST'), isFalse);
      expect(client.steps, isEmpty);
    });
  }

  for (final response in [
    (
      status: 200,
      type: 'HTML',
      contentType: 'text/html',
      body: '<html><body>FAKE-TICKET-SECRET FAKE-CAS-SECRET '
          'FAKE-PASSWORD-SECRET test-password</body></html>',
    ),
    (
      status: 502,
      type: 'JSON',
      contentType: 'application/json',
      body: '{"ticket":"FAKE-TICKET-SECRET","cas":"FAKE-CAS-SECRET",'
          '"password":"FAKE-PASSWORD-SECRET test-password"}',
    ),
  ]) {
    test('登录失败诊断保留 HTTP ${response.status} 与类型，不泄露票据或密码', () async {
      final client = _Client();
      _expectCasTicket(client,
          ticketCallback: 'https://booking.lib.zju.edu.cn/api/cas/cas?'
              'ticket=FAKE-TICKET-SECRET&cas=FAKE-CAS-SECRET&'
              'password=FAKE-PASSWORD-SECRET');
      client.expectRequest(
          'GET',
          '/api/cas/cas',
          (_) => _Response(
                statusCode: response.status,
                headers: {'content-type': response.contentType},
                body: response.body,
              ));
      final service = _service(client);
      addTearDown(service.dispose);

      await expectLater(
        service.loadReservations(),
        throwsA(isA<LibraryBookingException>().having(
            (error) => error.message,
            '安全登录诊断',
            allOf([
              contains('阶段'),
              contains('HTTP ${response.status}'),
              contains(response.type),
              isNot(contains('FAKE-TICKET-SECRET')),
              isNot(contains('FAKE-CAS-SECRET')),
              isNot(contains('FAKE-PASSWORD-SECRET')),
              isNot(contains('test-password')),
              isNot(contains('booking.lib.zju.edu.cn')),
              isNot(contains(response.body)),
            ]))),
      );
      expect(client.requestedUris, hasLength(3));
      expect(client.steps, isEmpty);
    });
  }

  test('取消权限必须同时满足本人、成功状态和服务端取消标志', () async {
    final client = _Client();
    _expectLogin(client);
    client.expectRequest(
        'POST',
        '/api/Member/seminar',
        (_) => _Response.json({
              'code': 1,
              'data': {
                'data': [
                  _reservationJson(id: 'own'),
                  _reservationJson(id: 'other', booker: '999'),
                  _reservationJson(id: 'ended', status: 4),
                  _reservationJson(id: 'late', oksign: 0),
                ],
              },
            }));
    final service = _service(client);
    addTearDown(service.dispose);
    final reservations = await service.loadReservations();
    expect(reservations.map((item) => item.canCancel),
        [true, false, false, false]);
    await expectLater(service.cancel(reservations[1]),
        throwsA(isA<LibraryBookingException>()));
    expect(client.steps, isEmpty);
  });

  test('明确会话失效时只读查询重建一次会话', () async {
    final client = _Client();
    _expectLogin(client);
    client.expectRequest(
        'POST',
        '/api/Member/seminar',
        (_) => _Response.json({
              'code': 10001,
              'msg': '您尚未登录',
            }));
    _expectLogin(client, token: 'second-token');
    client.expectRequest('POST', '/api/Member/seminar', (request) {
      expect(request.headers.value('authorization'), 'bearersecond-token');
      return _reservationResponse();
    });
    var authentications = 0;
    final service = _service(client, onAuthenticate: () => authentications++);
    addTearDown(service.dispose);
    expect(await service.loadReservations(), hasLength(1));
    expect(authentications, 2);
    expect(client.steps, isEmpty);
  });

  test('CAS ticket 回调不允许跳到外站', () async {
    final client = _Client();
    client.expectRequest(
        'GET', '/api/cas/cas', (_) => _Response(statusCode: 302));
    client.expectRequest(
        'GET',
        '/cas/login',
        (_) => _Response(
              statusCode: 302,
              headers: {'location': 'https://example.org/?ticket=FAKE-TICKET'},
            ));
    final service = _service(client);
    addTearDown(service.dispose);
    await expectLater(
        service.loadReservations(), throwsA(isA<LibraryBookingException>()));
    expect(client.requests, hasLength(2));
    expect(client.steps, isEmpty);
  });

  test('取消超时只发送一次，并明确结果未知', () async {
    final client = _Client();
    _expectLogin(client);
    client.expectRequest(
        'POST', '/api/Member/seminar', (_) => _reservationResponse());
    client.expectRequest('POST', '/api/space/seminarCancel', (_) {
      throw TimeoutException('Fake transport timeout');
    });
    final service = _service(client);
    addTearDown(service.dispose);
    final reservation = (await service.loadReservations()).single;
    await expectLater(
      service.cancel(reservation),
      throwsA(isA<LibraryBookingException>()
          .having((error) => error.outcomeUnknown, 'outcomeUnknown', isTrue)),
    );
    expect(
        client.requests
            .where((request) => request.uri.path == '/api/space/seminarCancel'),
        hasLength(1));
    expect(client.steps, isEmpty);
  });

  test('写操作返回登录失效也不自动重发', () async {
    final client = _Client();
    _expectLogin(client);
    client.expectRequest(
        'POST', '/api/Member/seminar', (_) => _reservationResponse());
    client.expectRequest(
        'POST',
        '/api/space/seminarCancel',
        (_) => _Response.json({
              'code': 10001,
              'msg': '您尚未登录',
            }));
    var authentications = 0;
    final service = _service(client, onAuthenticate: () => authentications++);
    addTearDown(service.dispose);
    final reservation = (await service.loadReservations()).single;
    await expectLater(
        service.cancel(reservation),
        throwsA(isA<LibraryBookingException>().having(
            (error) => error.authenticationRequired,
            'authenticationRequired',
            isTrue)));
    expect(authentications, 1);
    expect(client.steps, isEmpty);
  });

  test('取消进行中拒绝第二次写操作', () async {
    final client = _Client();
    _expectLogin(client);
    client.expectRequest(
        'POST', '/api/Member/seminar', (_) => _reservationResponse());
    final pending = Completer<HttpClientResponse>();
    client.expectRequest(
        'POST', '/api/space/seminarCancel', (_) => pending.future);
    final service = _service(client);
    addTearDown(service.dispose);
    final reservation = (await service.loadReservations()).single;
    final first = service.cancel(reservation);
    await expectLater(
        service.cancel(reservation), throwsA(isA<LibraryBookingException>()));
    pending.complete(_Response.json({'code': 1, 'msg': '预约已取消'}));
    expect(await first, '预约已取消');
    expect(client.steps, isEmpty);
  });

  test('提交前重读时段和人数，以 AES 正文发送一次预约申请', () async {
    final client = _Client();
    _expectLogin(client);
    _expectAvailability(client);
    client.expectRequest('POST', '/reserve/index/confirm', (request) {
      expect(request.json.keys, unorderedEquals(['aesjson', 'authorization']));
      expect(request.json['authorization'], 'bearerfake-token');
      final payload = LibraryBookingCodec.decrypt(
          request.json['aesjson'] as String, DateTime.utc(2026, 10, 2));
      expect(payload, {
        'id': 2,
        'day': '2026-10-03',
        'start_time': '08:00',
        'end_time': '09:00',
        'room': '9',
        'title': '读书讨论',
        'content': '小组讨论',
        'mobile': '13800000000',
        'open': '0',
        'file_name': '',
        'file_url': '',
        'teamusers': '202',
      });
      return _Response.json({'code': 1, 'msg': '预约成功'});
    });
    final service = _service(client);
    addTearDown(service.dispose);
    expect(await service.submit(_draft()), '预约成功');
    expect(client.steps, isEmpty);
  });

  test('提交时发现所选时段被他人占用，不发送预约申请', () async {
    final client = _Client();
    _expectLogin(client);
    _expectAvailability(client, occupied: true);
    final service = _service(client);
    addTearDown(service.dispose);
    await expectLater(
        service.submit(_draft()), throwsA(isA<LibraryBookingException>()));
    expect(
        client.requests
            .any((request) => request.uri.path == '/reserve/index/confirm'),
        isFalse);
    expect(client.steps, isEmpty);
  });

  test('读取提交前最新规则期间也拒绝第二次提交', () async {
    final client = _Client();
    _expectLogin(client);
    final detail = Completer<HttpClientResponse>();
    final reading = Completer<void>();
    _expectAvailability(client, detail: (_) {
      reading.complete();
      return detail.future;
    });
    client.expectRequest('POST', '/reserve/index/confirm',
        (_) => _Response.json({'code': 1, 'msg': '预约成功'}));
    final service = _service(client);
    addTearDown(service.dispose);
    final first = service.submit(_draft());
    await reading.future;
    await expectLater(
        service.submit(_draft()), throwsA(isA<LibraryBookingException>()));
    detail.complete(_Response.json({
      'code': 1,
      'data': {'is_reducible': 1}
    }));
    expect(await first, '预约成功');
    expect(
        client.requests
            .where((request) => request.uri.path == '/reserve/index/confirm'),
        hasLength(1));
    expect(client.steps, isEmpty);
  });

  test('离开页面后，正在完成的认证不能恢复已关闭会话', () async {
    final client = _Client();
    client.expectRequest(
        'GET', '/api/cas/cas', (_) => _Response(statusCode: 302));
    final pending = Completer<Cookie?>();
    final started = Completer<void>();
    final service = LibraryBookingService(
      username: 'test-account',
      password: 'test-password',
      httpClient: client,
      ssoCookieProvider: (_, __, ___) {
        started.complete();
        return pending.future;
      },
    );
    final operation = service.loadReservations();
    final failure =
        expectLater(operation, throwsA(isA<LibraryBookingException>()));
    await started.future;
    service.dispose();
    pending.complete(Cookie('iPlanetDirectoryPro', 'fake-sso'));
    await failure;
    expect(client.closed, isTrue);
    expect(client.requests, hasLength(1));
    await expectLater(
        service.loadReservations(), throwsA(isA<LibraryBookingException>()));
  });
}

void _seatBookingTests() {
  group('普通座位预约', () {
    test('解析馆舍楼层区域与日期，单会话跨查询复用 token', () async {
      final client = _Client();
      _expectLogin(client);
      _expectSeatCatalog(client);
      _expectSeatCatalog(client);
      _expectSeatAvailability(client);
      _expectSeatList(client);
      client.expectRequest(
          'POST', '/api/Member/seat', (_) => _seatReservationsResponse());
      var authentications = 0;
      final service = _service(client, onAuthenticate: () => authentications++);
      addTearDown(service.dispose);

      final catalog = await service.loadSeatCatalog(date: '2026-10-03');
      expect(catalog.dates, ['2026-10-03']);
      expect(catalog.buildings.single.id, '3');
      expect(catalog.buildings.single.name, '测试图书馆');
      final areas =
          await service.loadSeatAreas(buildingId: '3', date: '2026-10-03');
      expect(areas.map((area) => area.id), ['31', '32', '33']);
      expect(areas.first.floorName, '二层');
      expect(areas.map((area) => area.canReserve), [true, false, false]);
      final availability =
          await service.loadSeatAvailability(area: areas.first);
      final segment = availability.days.single.segments.single;
      expect(segment.id, 'segment-1');
      expect(segment.areaId, '31');
      expect(segment.date, '2026-10-03');
      expect(segment.startTime, '08:00');
      expect(segment.endTime, '12:00');
      expect(segment.canReserve, isTrue);
      expect(availability.rules, contains('按时签到'));
      expect(await service.loadSeats(area: areas.first, segment: segment),
          hasLength(1));
      expect(await service.loadSeatReservations(), hasLength(1));
      expect(authentications, 1);
      for (final request in client.requests.where((request) =>
          request.method == 'POST' && request.uri.path != '/api/cas/user')) {
        expect(request.headers.value('authorization'), 'bearerfake-token');
        expect(request.json['authorization'], 'bearerfake-token');
      }
      expect(client.steps, isEmpty);
    });

    test('固定 segment 排除停用、倒置、缺失时间和过期日期', () async {
      final client = _Client();
      _expectLogin(client);
      _expectSeatAvailability(client, days: [
        {
          'day': '2026-10-03',
          'times': [
            _seatSegmentJson(),
            _seatSegmentJson(id: 'disabled', status: 0),
            _seatSegmentJson(id: 'reversed', start: '12:00', end: '08:00'),
            _seatSegmentJson(id: 'missing', start: ''),
            _seatSegmentJson(id: 'bad-minute', start: '08:60'),
            _seatSegmentJson(id: 'bad-hour', end: '25:00'),
          ],
        },
        {
          'day': '2026-10-01',
          'times': [_seatSegmentJson(id: 'expired')],
        },
      ]);
      final service = _service(client);
      addTearDown(service.dispose);
      final availability = await service.loadSeatAvailability(area: _seatArea);
      final reservable = availability.days
          .expand((day) => day.segments)
          .where((segment) => segment.canReserve);
      expect(reservable.map((segment) => segment.id), ['segment-1']);
      expect(client.steps, isEmpty);
    });

    test('座位必须同时空闲且符合资格，未知状态不能默认可约', () async {
      final client = _Client();
      _expectLogin(client);
      _expectSeatList(client, rows: [
        _seatJson(),
        _seatJson(id: 'occupied', status: 2),
        _seatJson(id: 'disabled', status: 0),
        _seatJson(id: 'restricted', inLabel: 0),
        {..._seatJson(id: 'missing-status')}..remove('status'),
        {..._seatJson(id: 'missing-label')}..remove('in_label'),
      ]);
      final service = _service(client);
      addTearDown(service.dispose);
      final seats =
          await service.loadSeats(area: _seatArea, segment: _seatSegment);
      expect(seats.map((seat) => seat.canReserve),
          [true, false, false, false, false, false]);
      expect(client.steps, isEmpty);
    });

    test('服务端日期溢出必须报错，不规范成其他日期继续预约', () async {
      final client = _Client();
      _expectLogin(client);
      _expectSeatAvailability(client, days: [
        {
          'day': '2026-02-30',
          'times': [_seatSegmentJson()]
        },
      ]);
      final service = _service(client);
      addTearDown(service.dispose);
      await expectLater(service.loadSeatAvailability(area: _seatArea),
          throwsA(isA<LibraryBookingException>()));
      expect(client.steps, isEmpty);
    });

    test('依据服务器上海时间执行最远日期开放限制', () async {
      final client = _Client();
      _expectLogin(client);
      _expectSeatAvailability(client,
          serverTime: DateTime.utc(2026, 10, 1, 22, 59),
          days: [
            {
              'day': '2026-10-02',
              'times': [_seatSegmentJson(id: 'today')]
            },
            {
              'day': '2026-10-03',
              'times': [_seatSegmentJson(id: 'tomorrow')]
            },
          ]);
      final service = _service(client);
      addTearDown(service.dispose);
      final availability = await service.loadSeatAvailability(area: _seatArea);
      expect(availability.days.first.segments.single.canReserve, isTrue);
      expect(availability.days.last.segments.single.canReserve, isFalse);
      expect(client.steps, isEmpty);
    });

    test('本机跨日偏差时确认 AES 使用服务器上海日期', () async {
      final client = _Client();
      _expectLogin(client);
      _expectSeatCatalog(client);
      final serverTime = DateTime.utc(2026, 10, 3);
      _expectSeatAvailability(client, serverTime: serverTime);
      _expectSeatList(client);
      _expectSeatConfirm(client, encryptedAt: serverTime);
      // _service 的本机时钟仍固定在 10 月 2 日，服务器已经进入次日。
      final service = _service(client);
      addTearDown(service.dispose);
      expect(await service.submitSeat(_seatDraft()), '座位预约成功');
      expect(client.steps, isEmpty);
    });

    for (final invalid in {
      '不可用时段': const LibrarySeatDraft(
        area: _seatArea,
        segment: LibrarySeatSegment(
            id: 'segment-1',
            areaId: '31',
            date: '2026-10-03',
            startTime: '08:00',
            endTime: '12:00',
            canReserve: false),
        seat: _seat,
      ),
      '跨区域时段': const LibrarySeatDraft(
        area: _seatArea,
        segment: LibrarySeatSegment(
            id: 'segment-1',
            areaId: '99',
            date: '2026-10-03',
            startTime: '08:00',
            endTime: '12:00'),
        seat: _seat,
      ),
      '溢出日期': const LibrarySeatDraft(
        area: _seatArea,
        segment: LibrarySeatSegment(
            id: 'segment-1',
            areaId: '31',
            date: '2026-02-30',
            startTime: '08:00',
            endTime: '12:00'),
        seat: _seat,
      ),
      '溢出时间': const LibrarySeatDraft(
        area: _seatArea,
        segment: LibrarySeatSegment(
            id: 'segment-1',
            areaId: '31',
            date: '2026-10-03',
            startTime: '08:00',
            endTime: '24:30'),
        seat: _seat,
      ),
    }.entries) {
      test('提交前拒绝${invalid.key}，不发网络写请求', () async {
        final client = _Client();
        final service = _service(client);
        addTearDown(service.dispose);
        await expectLater(service.submitSeat(invalid.value),
            throwsA(isA<LibraryBookingException>()));
        expect(client.requestedUris, isEmpty);
      });
    }

    test('提交前刷新日期与座位，确认加密正文只包含 seat_id 和 segment', () async {
      final client = _Client();
      _expectLogin(client);
      _expectSeatAvailability(client);
      _expectSeatList(client);
      _expectSeatCatalog(client);
      _expectSeatAvailability(client, includeRules: false);
      _expectSeatList(client);
      _expectSeatConfirm(client);
      final service = _service(client);
      addTearDown(service.dispose);
      final availability = await service.loadSeatAvailability(area: _seatArea);
      final segment = availability.days.single.segments.single;
      final seat =
          (await service.loadSeats(area: _seatArea, segment: segment)).single;
      expect(
          await service.submitSeat(
              LibrarySeatDraft(area: _seatArea, segment: segment, seat: seat)),
          '座位预约成功');
      expect(
          client.requests
              .where((request) => request.uri.path == '/api/Seat/seat'),
          hasLength(2));
      expect(
          client.requests
              .where((request) => request.uri.path == '/api/Seat/confirm'),
          hasLength(1));
      expect(client.steps, isEmpty);
    });

    test('提交时座位已被抢占，不发送确认写请求', () async {
      final client = _Client();
      _expectLogin(client);
      _expectSeatCatalog(client);
      _expectSeatAvailability(client);
      _expectSeatList(client, rows: [_seatJson(status: 2)]);
      final service = _service(client);
      addTearDown(service.dispose);
      await expectLater(service.submitSeat(_seatDraft()),
          throwsA(isA<LibraryBookingException>()));
      expect(
          client.requests
              .any((request) => request.uri.path == '/api/Seat/confirm'),
          isFalse);
      expect(client.steps, isEmpty);
    });

    for (final changed in {
      '区域已满': {'id': '31', 'free_num': 0, 'typeCategory': '1'},
      '区域已移除': {'id': '99', 'free_num': 10, 'typeCategory': '1'},
      '区域变为其他预约类型': {'id': '31', 'free_num': 10, 'typeCategory': '2'},
    }.entries) {
      test('新鲜目录显示${changed.key}时拒绝预约', () async {
        final client = _Client();
        _expectLogin(client);
        _expectSeatCatalog(client, areas: [
          {
            ...changed.value,
            'name': '更新后的区域',
            'topId': '3',
            'parentId': '30',
          }
        ]);
        final service = _service(client);
        addTearDown(service.dispose);
        await expectLater(service.submitSeat(_seatDraft()),
            throwsA(isA<LibraryBookingException>()));
        expect(
            client.requests
                .any((request) => request.uri.path == '/api/Seat/confirm'),
            isFalse);
        expect(client.steps, isEmpty);
      });
    }

    for (final changed in {
      '服务端移除所选 segment': [_seatSegmentJson(id: 'different-segment')],
      '同一 segment 时间发生变化': [_seatSegmentJson(start: '09:00')],
      '所选 segment 不再可预约': [_seatSegmentJson(status: 0)],
    }.entries) {
      test('${changed.key}时拒绝使用旧选择提交', () async {
        final client = _Client();
        _expectLogin(client);
        _expectSeatCatalog(client);
        _expectSeatAvailability(client, days: [
          {'day': '2026-10-03', 'times': changed.value},
        ]);
        final service = _service(client);
        addTearDown(service.dispose);
        await expectLater(service.submitSeat(_seatDraft()),
            throwsA(isA<LibraryBookingException>()));
        expect(
            client.requests
                .any((request) => request.uri.path == '/api/Seat/confirm'),
            isFalse);
        expect(client.steps, isEmpty);
      });
    }

    test('准备提交期间禁止第二次写操作', () async {
      final client = _Client();
      _expectLogin(client);
      _expectSeatCatalog(client);
      _expectSeatAvailability(client);
      final reading = Completer<void>();
      final seats = Completer<HttpClientResponse>();
      _expectSeatList(client, response: (_) {
        reading.complete();
        return seats.future;
      });
      _expectSeatConfirm(client);
      final service = _service(client);
      addTearDown(service.dispose);
      final first = service.submitSeat(_seatDraft());
      await reading.future;
      await expectLater(service.submitSeat(_seatDraft()),
          throwsA(isA<LibraryBookingException>()));
      seats.complete(_Response.json({
        'code': 1,
        'data': [_seatJson()]
      }));
      expect(await first, '座位预约成功');
      expect(client.steps, isEmpty);
    });

    test('等待预检时退出或更换账号，不得随后提交预约', () async {
      final client = _Client();
      _expectLogin(client);
      _expectSeatCatalog(client);
      _expectSeatAvailability(client);
      final reading = Completer<void>();
      final seats = Completer<HttpClientResponse>();
      _expectSeatList(client, response: (_) {
        reading.complete();
        return seats.future;
      });
      var active = true;
      final service = _service(client, canUseSession: () => active);
      addTearDown(service.dispose);
      final submission = service.submitSeat(_seatDraft());
      final failure =
          expectLater(submission, throwsA(isA<LibraryBookingException>()));
      await reading.future;
      active = false;
      seats.complete(_Response.json({
        'code': 1,
        'data': [_seatJson()]
      }));
      await failure;
      expect(
          client.requests
              .any((request) => request.uri.path == '/api/Seat/confirm'),
          isFalse);
      expect(client.steps, isEmpty);
    });

    _seatMutationTests();
  });
}

void _seatMutationTests() {
  test('没有普通座位历史时 data.data 为 null 视为空列表', () async {
    final client = _Client();
    _expectLogin(client);
    client.expectRequest(
        'POST',
        '/api/Member/seat',
        (_) => _Response.json({
              'code': 1,
              'data': {'data': null, 'total': 0}
            }));
    final service = _service(client);
    addTearDown(service.dispose);
    expect(await service.loadSeatReservations(), isEmpty);
    expect(client.steps, isEmpty);
  });

  test('普通座位记录分页、取消资格及取消接口参数与研讨间不同', () async {
    final client = _Client();
    _expectLogin(client);
    client.expectRequest('POST', '/api/Member/seat', (request) {
      expect(request.json,
          {'page': 2, 'limit': 10, 'authorization': 'bearerfake-token'});
      return _seatReservationsResponse(rows: [
        _seatReservationJson(id: 'status-1', status: 1),
        _seatReservationJson(id: 'status-2', status: 2),
        _seatReservationJson(id: 'status-9', status: 9),
        _seatReservationJson(id: 'checked-in', status: 3),
        _seatReservationJson(id: 'late', oksign: 0),
        _seatReservationJson(id: 'ended', status: 4),
      ]);
    });
    client.expectRequest('POST', '/api/Space/cancel', (request) {
      expect(request.json,
          {'id': 'status-2', 'authorization': 'bearerfake-token'});
      return _Response.json({'code': 1, 'msg': '座位预约已取消'});
    });
    final service = _service(client);
    addTearDown(service.dispose);
    final reservations = await service.loadSeatReservations(page: 2);
    expect(reservations.first.seatName, 'A001');
    expect(reservations.first.areaName, '测试图书馆 二层 自习区');
    expect(reservations.map((record) => record.canCancel),
        [true, true, true, false, false, false]);
    await expectLater(service.cancelSeat(reservations[3]),
        throwsA(isA<LibraryBookingException>()));
    expect(await service.cancelSeat(reservations[1]), '座位预约已取消');
    expect(
        client.requests.any((request) =>
            request.uri.path.toLowerCase().contains('leave') ||
            request.uri.path.toLowerCase().contains('checkout')),
        isFalse);
    expect(client.steps, isEmpty);
  });

  test('普通座位确认超时只发一次，结果未知时阻止再次提交', () async {
    final client = _Client();
    _expectLogin(client);
    _expectSeatCatalog(client);
    _expectSeatAvailability(client);
    _expectSeatList(client);
    client.expectRequest('POST', '/api/Seat/confirm', (_) {
      throw TimeoutException('Fake seat confirm timeout');
    });
    final service = _service(client);
    addTearDown(service.dispose);
    await expectLater(service.submitSeat(_seatDraft()), _unknownBookingOutcome);
    await expectLater(service.submitSeat(_seatDraft()), _unknownBookingOutcome);
    expect(
        client.requests
            .where((request) => request.uri.path == '/api/Seat/confirm'),
        hasLength(1));
    expect(client.steps, isEmpty);
  });

  test('普通座位确认登录失效也不自动重发写请求', () async {
    final client = _Client();
    _expectLogin(client);
    _expectSeatCatalog(client);
    _expectSeatAvailability(client);
    _expectSeatList(client);
    client.expectRequest('POST', '/api/Seat/confirm',
        (_) => _Response.json({'code': 10001, 'msg': '您尚未登录'}));
    var authentications = 0;
    final service = _service(client, onAuthenticate: () => authentications++);
    addTearDown(service.dispose);
    await expectLater(
        service.submitSeat(_seatDraft()),
        throwsA(isA<LibraryBookingException>().having(
            (error) => error.authenticationRequired,
            'authenticationRequired',
            isTrue)));
    expect(authentications, 1);
    expect(
        client.requests
            .where((request) => request.uri.path == '/api/Seat/confirm'),
        hasLength(1));
    expect(client.steps, isEmpty);
  });

  test('只有未知写结果之后重新读取座位记录第一页才能解除锁', () async {
    final client = _Client();
    _expectLogin(client);
    client.expectRequest(
        'POST', '/api/Member/seat', (_) => _seatReservationsResponse());
    client.expectRequest('POST', '/api/Space/cancel', (_) {
      throw TimeoutException('Fake cancellation timeout');
    });
    client.expectRequest('POST', '/api/Member/seat', (request) {
      expect(request.json['page'], 2);
      return _seatReservationsResponse();
    });
    client.expectRequest('POST', '/api/Member/seat', (request) {
      expect(request.json['page'], 1);
      return _seatReservationsResponse();
    });
    client.expectRequest('POST', '/api/Space/cancel',
        (_) => _Response.json({'code': 1, 'msg': '已取消'}));
    final service = _service(client);
    addTearDown(service.dispose);
    final record = (await service.loadSeatReservations()).single;
    await expectLater(service.cancelSeat(record), _unknownBookingOutcome);
    await service.loadSeatReservations(page: 2);
    await expectLater(service.cancelSeat(record), _unknownBookingOutcome);
    final refreshed = (await service.loadSeatReservations()).single;
    expect(await service.cancelSeat(refreshed), '已取消');
    expect(
        client.requests
            .where((request) => request.uri.path == '/api/Space/cancel'),
        hasLength(2));
    expect(client.steps, isEmpty);
  });

  test('未知结果前已经发起的第一页查询晚到不能解除写锁', () async {
    final client = _Client();
    _expectLogin(client);
    client.expectRequest(
        'POST', '/api/Member/seat', (_) => _seatReservationsResponse());
    final readStarted = Completer<void>();
    final pendingRead = Completer<HttpClientResponse>();
    client.expectRequest('POST', '/api/Member/seat', (_) {
      readStarted.complete();
      return pendingRead.future;
    });
    client.expectRequest('POST', '/api/Space/cancel', (_) {
      throw TimeoutException('Fake cancellation timeout');
    });
    final service = _service(client);
    addTearDown(service.dispose);
    final record = (await service.loadSeatReservations()).single;
    final staleRead = service.loadSeatReservations();
    await readStarted.future;
    await expectLater(service.cancelSeat(record), _unknownBookingOutcome);
    pendingRead.complete(_seatReservationsResponse());
    await staleRead;
    await expectLater(service.cancelSeat(record), _unknownBookingOutcome);
    expect(
        client.requests
            .where((request) => request.uri.path == '/api/Space/cancel'),
        hasLength(1));
    expect(client.steps, isEmpty);
  });

  test('研讨间记录不能解除普通座位的未知结果锁', () async {
    final client = _Client();
    _expectLogin(client);
    client.expectRequest(
        'POST', '/api/Member/seat', (_) => _seatReservationsResponse());
    client.expectRequest('POST', '/api/Space/cancel', (_) {
      throw TimeoutException('Fake seat cancellation timeout');
    });
    client.expectRequest(
        'POST', '/api/Member/seminar', (_) => _reservationResponse());
    final service = _service(client);
    addTearDown(service.dispose);
    final record = (await service.loadSeatReservations()).single;
    await expectLater(service.cancelSeat(record), _unknownBookingOutcome);
    await service.loadReservations();
    await expectLater(service.cancelSeat(record), _unknownBookingOutcome);
    expect(client.steps, isEmpty);
  });

  test('普通座位记录不能解除研讨间的未知结果锁', () async {
    final client = _Client();
    _expectLogin(client);
    client.expectRequest(
        'POST', '/api/Member/seminar', (_) => _reservationResponse());
    client.expectRequest('POST', '/api/space/seminarCancel', (_) {
      throw TimeoutException('Fake room cancellation timeout');
    });
    client.expectRequest(
        'POST', '/api/Member/seat', (_) => _seatReservationsResponse());
    final service = _service(client);
    addTearDown(service.dispose);
    final record = (await service.loadReservations()).single;
    await expectLater(service.cancel(record), _unknownBookingOutcome);
    await service.loadSeatReservations();
    await expectLater(service.cancel(record), _unknownBookingOutcome);
    expect(client.steps, isEmpty);
  });
}

Matcher get _unknownBookingOutcome => throwsA(isA<LibraryBookingException>()
    .having((error) => error.outcomeUnknown, 'outcomeUnknown', isTrue));

const _seatArea =
    LibrarySeatArea(id: '31', name: '自习区', buildingId: '3', floorName: '二层');
const _seatSegment = LibrarySeatSegment(
    id: 'segment-1',
    areaId: '31',
    date: '2026-10-03',
    startTime: '08:00',
    endTime: '12:00');
const _seat = LibrarySeat(id: 'seat-1', name: 'A001');

LibrarySeatDraft _seatDraft() =>
    const LibrarySeatDraft(area: _seatArea, segment: _seatSegment, seat: _seat);

Map<String, dynamic> _seatSegmentJson(
        {String id = 'segment-1',
        int status = 1,
        String start = '08:00',
        String end = '12:00'}) =>
    {'id': id, 'start': start, 'end': end, 'status': status};

_Response _seatDatesResponse({List<Map<String, dynamic>>? days}) =>
    _Response.json({
      'code': 1,
      'data': days ??
          [
            {
              'day': '2026-10-03',
              'times': [_seatSegmentJson()]
            },
          ]
    });

void _expectSeatCatalog(_Client client, {List<Map<String, dynamic>>? areas}) {
  client.expectRequest('POST', '/reserve/index/quickSelect', (request) {
    expect(request.json, {
      'id': '1',
      'date': '2026-10-03',
      'authorization': 'bearerfake-token',
    });
    return _Response.json({
      'code': 0,
      'data': {
        'date': ['2026-10-03'],
        'premises': [
          {'id': '3', 'name': '测试图书馆'}
        ],
        'storey': [
          {'id': '30', 'name': '二层', 'topId': '3'}
        ],
        'area': areas ??
            [
              {
                'id': '31',
                'name': '自习区',
                'topId': '3',
                'parentId': '30',
                'free_num': 10,
                'typeCategory': '1'
              },
              {
                'id': '32',
                'name': '已约满区域',
                'topId': '3',
                'parentId': '30',
                'free_num': 0,
                'typeCategory': '1'
              },
              {
                'id': '33',
                'name': '专用区域',
                'topId': '3',
                'parentId': '30',
                'free_num': 10,
                'typeCategory': '2'
              },
              {
                'id': '91',
                'name': '其他馆区域',
                'topId': '9',
                'parentId': '90',
                'free_num': 10,
                'typeCategory': '1'
              },
            ],
      }
    });
  });
}

void _expectSeatAvailability(
  _Client client, {
  List<Map<String, dynamic>>? days,
  bool includeRules = true,
  DateTime? serverTime,
}) {
  client.expectRequest('POST', '/api/Seat/date', (request) {
    expect(
        request.json, {'build_id': '31', 'authorization': 'bearerfake-token'});
    return _seatDatesResponse(days: days);
  });
  client.expectRequest('POST', '/reserve/index/detail', (request) {
    expect(request.json,
        {'id': '1', 'areaId': '31', 'authorization': 'bearerfake-token'});
    return _Response.json({
      'code': 0,
      'data': {
        'name': '自习区',
        'is_reducible': 1,
        'type_id': 1,
        'typeCategory': '1',
        'contents': '请保持安静。',
      }
    });
  });
  final responseTime = serverTime ?? DateTime.utc(2026, 10, 2);
  client.expectRequest(
      'POST',
      '/api/index/time',
      (_) => _Response.json({
            'code': 1,
            'data': {
              'time': (responseTime.millisecondsSinceEpoch ~/ 1000 + 509) * 29,
            },
          }));
  client.expectRequest(
      'POST',
      '/api/index/config',
      (_) => _Response.json({
            'code': 1,
            'data': LibraryBookingCodec.encrypt({
              'config': {'new': '07:00', 'close': '23:00', 'end': '23:59'},
            }, responseTime),
          }));
  if (includeRules) {
    client.expectRequest(
        'POST',
        '/api/seminar/should',
        (_) => _Response.json({
              'code': 1,
              'data': {
                'seat_rule': '<p>请按时签到。</p>',
              }
            }));
  }
}

Map<String, dynamic> _seatJson(
        {String id = 'seat-1', int status = 1, int inLabel = 1}) =>
    {
      'id': id,
      'name': 'A001',
      'status': status,
      'in_label': inLabel,
    };

void _expectSeatList(
  _Client client, {
  List<Map<String, dynamic>>? rows,
  _ResponseFactory? response,
}) {
  client.expectRequest('POST', '/api/Seat/seat', (request) {
    expect(request.json, {
      'area': '31',
      'segment': 'segment-1',
      'day': '2026-10-03',
      'startTime': '08:00',
      'endTime': '12:00',
      'authorization': 'bearerfake-token'
    });
    return response?.call(request) ??
        _Response.json({
          'code': 1,
          'data': rows ?? [_seatJson()]
        });
  });
}

void _expectSeatConfirm(_Client client, {DateTime? encryptedAt}) {
  client.expectRequest('POST', '/api/Seat/confirm', (request) {
    expect(request.json.keys, unorderedEquals(['aesjson', 'authorization']));
    expect(
        LibraryBookingCodec.decrypt(request.json['aesjson'] as String,
            encryptedAt ?? DateTime.utc(2026, 10, 2)),
        {'seat_id': 'seat-1', 'segment': 'segment-1'});
    return _Response.json({'code': 1, 'msg': '座位预约成功'});
  });
}

Map<String, dynamic> _seatReservationJson(
        {String id = 'seat-booking-1', int status = 2, int oksign = 1}) =>
    {
      'id': id,
      'name': 'A001',
      'nameMerge': '测试图书馆 二层 自习区',
      'day': '2026-10-03',
      'start': '08:00',
      'end': '12:00',
      'status': status,
      'statusName': '预约成功',
      'oksign': oksign,
    };

_Response _seatReservationsResponse({List<Map<String, dynamic>>? rows}) =>
    _Response.json({
      'code': 1,
      'data': {
        'data': rows ?? [_seatReservationJson()],
        'total': rows?.length ?? 1,
      }
    });

LibraryBookingService _service(_Client client,
        {void Function()? onAuthenticate, bool Function()? canUseSession}) =>
    LibraryBookingService(
      username: 'test-account',
      password: 'test-password',
      httpClient: client,
      now: () => DateTime.utc(2026, 10, 2),
      canUseSession: canUseSession,
      ssoCookieProvider: (_, __, ___) async {
        onAuthenticate?.call();
        return Cookie('iPlanetDirectoryPro', 'fake-sso');
      },
    );

void _expectCasTicket(_Client client,
    {String ticketCallback =
        'https://booking.lib.zju.edu.cn/api/cas/cas?ticket=FAKE-TICKET'}) {
  client.expectRequest(
      'GET',
      '/api/cas/cas',
      (_) => _Response(
            statusCode: 302,
            headers: {
              'location': 'http://zjuam.zju.edu.cn:80/cas/login?service='
                  'https%3A%2F%2Fbooking.lib.zju.edu.cn%2Fapi%2Fcas%2Fcas',
            },
            cookies: [Cookie('PHPSESSID', 'fake-php-session')..path = '/'],
          ));
  client.expectRequest('GET', '/cas/login', (request) {
    expect(request.uri.scheme, 'https');
    expect(request.uri.host, 'zjuam.zju.edu.cn');
    expect(request.uri.queryParameters['service'],
        'https://booking.lib.zju.edu.cn/api/cas/cas');
    expect(request.followRedirects, isFalse);
    expect(
        request.cookies.map((cookie) => cookie.name), ['iPlanetDirectoryPro']);
    return _Response(statusCode: 302, headers: {'location': ticketCallback});
  });
}

void _expectLogin(_Client client,
    {String token = 'fake-token',
    String h5Callback = '/h5/#/cas?cas=fake-exchange-code',
    bool cleanTicketRedirect = false}) {
  _expectCasTicket(client);
  client.expectRequest('GET', '/api/cas/cas', (request) {
    expect(request.uri.queryParameters['ticket'], 'FAKE-TICKET');
    expect(request.cookies.map((cookie) => cookie.name), ['PHPSESSID']);
    expect(request.cookies.single.value, 'fake-php-session');
    return _Response(
      statusCode: 302,
      headers: {
        'location': cleanTicketRedirect ? '/api/cas/cas' : h5Callback,
      },
      cookies: cleanTicketRedirect
          ? [Cookie('PHPSESSID', 'updated-php-session')..path = '/']
          : [],
    );
  });
  if (cleanTicketRedirect) {
    client.expectRequest('GET', '/api/cas/cas', (request) {
      expect(request.uri.queryParameters.containsKey('ticket'), isFalse);
      expect(request.cookies.single.name, 'PHPSESSID');
      expect(request.cookies.single.value, 'updated-php-session');
      return _Response(statusCode: 302, headers: {'location': h5Callback});
    });
  }
  client.expectRequest('POST', '/api/cas/user', (request) {
    expect(request.json, {'cas': 'fake-exchange-code'});
    expect(request.headers.value('authorization'), isNull);
    return _Response.json({
      'code': 1,
      'member': {'id': '101', 'token': token, 'mobile': ''},
    });
  });
}

Map<String, dynamic> _reservationJson({
  String id = 'booking-1',
  String booker = '101',
  int status = 2,
  int oksign = 1,
}) =>
    {
      'id': id,
      'nameMerge': '测试研讨间',
      'day': '2026-10-03',
      'start': '08:00',
      'end': '09:00',
      'status': status,
      'statusname': '预约成功',
      'booker': booker,
      'oksign': oksign,
    };

_Response _reservationResponse() => _Response.json({
      'code': 1,
      'data': {
        'data': [_reservationJson()],
        'total': 1
      },
    });

LibraryBookingDraft _draft() => LibraryBookingDraft(
      room: _room,
      availability: _availability(),
      startMinute: 480,
      endMinute: 540,
      title: '读书讨论',
      content: '小组讨论',
      mobile: '13800000000',
      isPublic: false,
      participants: const [LibraryParticipant(id: '202', name: '虚构成员')],
    );

void _expectAvailability(_Client client,
    {bool occupied = false, _ResponseFactory? detail}) {
  client.expectRequest(
      'POST',
      '/api/Seminar/detail',
      detail ??
          (request) {
            expect(request.json['id'], '9');
            expect(request.json['day'], '2026-10-03');
            return _Response.json({
              'code': 1,
              'data': {'is_reducible': 1}
            });
          });
  client.expectRequest('POST', '/api/Seminar/v1seminar', (request) {
    expect(request.json['room'], '9');
    expect(request.json['area'], '3');
    return _Response.json({
      'code': 1,
      'data': {
        'list': [
          {
            'date': '2026-10-03',
            'info': {
              'startTime': 480,
              'endTime': 720,
              'minTime': 60,
              'maxTime': 240,
              'Fully_Booked': 0,
              'isRemainder': 0,
              if (occupied)
                'list': [
                  {'beginNum': 480, 'endNum': 540}
                ],
            },
          }
        ],
      },
    });
  });
  client.expectRequest(
      'POST',
      '/api/Seminar/seminar',
      (_) => _Response.json({
            'code': 1,
            'data': {'minPerson': 2, 'maxPerson': 4, 'isMouldShow': 0},
          }));
  client.expectRequest(
      'POST',
      '/reserve/index/detail',
      (_) => _Response.json({
            'code': 0,
            'data': {
              'name': _room.name,
              'type_id': 2,
              'readonlyTitle': 2,
              'contents': '按时签到。'
            },
          }));
  client.expectRequest(
      'POST',
      '/api/seminar/should',
      (_) => _Response.json({
            'code': 1,
            'data': {'isShowRoomText': 1, 'seminar_rule': '<p>请遵守图书馆规定。</p>'},
          }));
}

typedef _ResponseFactory = FutureOr<HttpClientResponse> Function(_Request);

class _Step {
  final String method;
  final String path;
  final _ResponseFactory response;

  _Step(this.method, this.path, this.response);
}

class _Client implements HttpClient {
  final Queue<_Step> steps = Queue<_Step>();
  final List<_Request> requests = [];
  final List<Uri> requestedUris = [];
  bool closed = false;

  @override
  String? userAgent;
  @override
  Duration? connectionTimeout;

  void expectRequest(String method, String path, _ResponseFactory response) =>
      steps.add(_Step(method, path, response));

  Future<HttpClientRequest> _open(String method, Uri uri) async {
    if (closed) throw StateError('Client closed');
    requestedUris.add(uri);
    expect(steps, isNotEmpty, reason: 'Unexpected request: $method $uri');
    final step = steps.removeFirst();
    expect(method, step.method);
    expect(uri.path, step.path);
    final request = _Request(method, uri, step.response);
    requests.add(request);
    return request;
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _open('GET', url);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => _open('POST', url);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _open(method, url);
  @override
  void close({bool force = false}) => closed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  @override
  final String method;
  @override
  final Uri uri;
  final _ResponseFactory response;
  @override
  final _Headers headers = _Headers();
  @override
  final List<Cookie> cookies = [];
  @override
  bool followRedirects = true;
  final List<int> body = [];

  _Request(this.method, this.uri, this.response);

  Map<String, dynamic> get json =>
      (jsonDecode(utf8.decode(body)) as Map).cast<String, dynamic>();
  @override
  void add(List<int> data) => body.addAll(data);
  @override
  void write(Object? object) => body.addAll(utf8.encode('$object'));
  @override
  Future<HttpClientResponse> close() async => response(this);
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends StreamView<List<int>> implements HttpClientResponse {
  @override
  final int statusCode;
  @override
  final _Headers headers;
  @override
  final List<Cookie> cookies;
  @override
  final int contentLength;

  _Response({
    this.statusCode = 200,
    Map<String, String> headers = const {},
    this.cookies = const [],
    String body = '',
  })  : headers = _Headers(headers),
        contentLength = utf8.encode(body).length,
        super(Stream.value(utf8.encode(body)));

  factory _Response.json(Map<String, dynamic> data) => _Response(
        headers: {'content-type': 'application/json'},
        body: jsonEncode(data),
      );

  @override
  bool get isRedirect => const [301, 302, 303, 307, 308].contains(statusCode);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  final Map<String, List<String>> values = {};

  _Headers([Map<String, String> initial = const {}]) {
    initial.forEach(set);
  }

  @override
  ContentType? get contentType {
    final raw = value('content-type');
    return raw == null ? null : ContentType.parse(raw);
  }

  @override
  set contentType(ContentType? type) {
    if (type != null) set('content-type', type.toString());
  }

  @override
  String? value(String name) => values[name.toLowerCase()]?.join(', ');
  @override
  List<String>? operator [](String name) => values[name.toLowerCase()];
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = [value.toString()];
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) =>
      values.putIfAbsent(name.toLowerCase(), () => []).add(value.toString());
  @override
  void forEach(void Function(String, List<String>) action) =>
      values.forEach(action);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
