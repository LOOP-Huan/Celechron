import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:celechron/model/library_reservation.dart';
import 'package:pointycastle/export.dart';

import 'zjuam.dart';

export 'package:celechron/model/library_reservation.dart';

typedef SsoCookieProvider = Future<Cookie?> Function(
  HttpClient client,
  String username,
  String password,
);

/// Matches the public booking site's CryptoJS AES-CBC/PKCS7 protocol.
/// Its date-derived key is protocol obfuscation, not a credential or secret.
class LibraryBookingCodec {
  static DateTime shanghaiTime(DateTime time) =>
      time.toUtc().add(const Duration(hours: 8));

  static String dateLabel(DateTime time) {
    final day = shanghaiTime(time);
    return '${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
  }

  static PaddedBlockCipher _cipher(bool encrypting, DateTime time) {
    final day = dateLabel(time).replaceAll('-', '');
    final key = '$day${day.split('').reversed.join()}';
    return PaddedBlockCipher('AES/CBC/PKCS7')
      ..init(
        encrypting,
        PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
          ParametersWithIV(
            KeyParameter(Uint8List.fromList(utf8.encode(key))),
            Uint8List.fromList(utf8.encode('ZZWBKJ_ZHIHUAWEI')),
          ),
          null,
        ),
      );
  }

  static String encrypt(Map<String, dynamic> data, DateTime time) =>
      base64Encode(_cipher(true, time).process(
        Uint8List.fromList(utf8.encode(jsonEncode(data))),
      ));

  static dynamic decrypt(String value, DateTime time) => jsonDecode(
        utf8.decode(_cipher(false, time).process(base64Decode(value))),
      );
}

class _StoredCookie {
  final Cookie cookie;
  final String path;
  final DateTime? expires;

  _StoredCookie(this.cookie, this.path, this.expires);
}

class _LibraryResponse {
  final int status;
  final String body;
  final String? location;

  const _LibraryResponse(this.status, this.body, this.location);
}

/// An account-scoped session for booking.lib.zju.edu.cn, deliberately separate
/// from the academic clients. Tokens, cookies and member data are never saved.
/// Only read operations may retry after explicit authentication expiry.
class LibraryBookingService implements LibraryBookingClient {
  static final Uri serviceUri =
      Uri.https('booking.lib.zju.edu.cn', '/api/cas/cas');
  static final Uri _casLoginUri = Uri.https(
    'zjuam.zju.edu.cn',
    '/cas/login',
    {'service': serviceUri.toString()},
  );
  static const _host = 'booking.lib.zju.edu.cn';
  static const _unknownOutcome = '操作结果尚未确认，请先刷新“我的预约”核实，避免重复提交。';

  final String _username;
  String _password;
  final HttpClient _httpClient;
  final SsoCookieProvider _ssoCookieProvider;
  final DateTime Function() _now;
  final Duration requestTimeout;
  final List<_StoredCookie> _cookies = [];
  Future<void>? _loginFuture;
  String? _token;
  String _memberId = '';
  String _mobile = '';
  String _rules = '';
  bool _disposed = false;
  bool _writing = false;
  bool _preparingSubmission = false;
  bool _unresolvedMutation = false;
  int _generation = 0;

  LibraryBookingService({
    required String username,
    required String password,
    HttpClient? httpClient,
    SsoCookieProvider? ssoCookieProvider,
    DateTime Function()? now,
    this.requestTimeout = const Duration(seconds: 15),
  })  : _username = username,
        _password = password,
        _httpClient = httpClient ?? HttpClient(),
        _ssoCookieProvider = ssoCookieProvider ?? ZjuAm.getSsoCookie,
        _now = now ?? DateTime.now {
    _httpClient.connectionTimeout = requestTimeout;
    _httpClient.userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/110.0.0.0 Safari/537.36';
  }

  void _checkActive([int? generation]) {
    if (_disposed || (generation != null && generation != _generation)) {
      throw const LibraryBookingException('图书馆会话已关闭，请重新打开预约页面。');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _token = null;
    _memberId = '';
    _mobile = '';
    _password = '';
    _cookies.clear();
    ZjuAm.clearClientSsoCookie(_httpClient, _username);
    _httpClient.close(force: true);
  }

  Future<void> _ensureAuthenticated() async {
    _checkActive();
    if (_token != null) return;
    final pending = _loginFuture;
    if (pending != null) return pending;
    final login = _login();
    _loginFuture = login;
    try {
      await login;
    } finally {
      if (identical(_loginFuture, login)) _loginFuture = null;
    }
  }

  Future<void> _login() async {
    final generation = _generation;
    try {
      // Establish PHPSESSID before obtaining the one-use ticket. The website's
      // initial redirect currently advertises HTTP CAS; construct HTTPS instead.
      await _request(serviceUri);
      final cookie =
          await _ssoCookieProvider(_httpClient, _username, _password);
      if (_disposed || generation != _generation) {
        ZjuAm.clearClientSsoCookie(_httpClient, _username);
      }
      _checkActive(generation);
      if (cookie == null) {
        throw const LibraryBookingException('统一身份认证失败，请检查当前账号登录状态。',
            authenticationRequired: true);
      }
      final cas = await _request(
        _casLoginUri,
        ssoCookie: cookie,
      );
      if (!_isRedirect(cas.status) || cas.location == null) {
        if (const [200, 401, 403].contains(cas.status)) {
          ZjuAm.clearClientSsoCookie(_httpClient, _username);
        }
        throw const LibraryBookingException('未获得图书馆登录凭据，请重新登录后重试。',
            authenticationRequired: true);
      }
      var callback = _casLoginUri.resolve(cas.location!);
      if (!_isBookingUri(callback) ||
          callback.path != serviceUri.path ||
          (callback.queryParameters['ticket'] ?? '').isEmpty) {
        throw const LibraryBookingException('图书馆统一认证回调地址无效。');
      }
      String? exchangeCode;
      for (var redirects = 0; redirects < 5; redirects++) {
        final response = await _request(callback);
        if (!_isRedirect(response.status) || response.location == null) break;
        callback = callback.resolve(response.location!);
        if (!_isBookingUri(callback)) {
          throw const LibraryBookingException('图书馆登录跳转地址无效。');
        }
        final route = Uri.tryParse(callback.fragment);
        if (callback.path == '/h5/' && route?.path == '/cas') {
          exchangeCode = route?.queryParameters['cas'];
          break;
        }
      }
      if (exchangeCode == null || exchangeCode.isEmpty) {
        throw const LibraryBookingException('图书馆登录未返回有效的认证结果。');
      }
      final response = await _postOnce('/api/cas/user', {'cas': exchangeCode},
          authenticated: false);
      final member = _map(response['member']);
      final token = _string(member['token']);
      final memberId = _string(member['id']);
      if (token.isEmpty || memberId.isEmpty) {
        throw const LibraryBookingException('图书馆登录响应缺少用户信息。');
      }
      _checkActive(generation);
      _token = token;
      _memberId = memberId;
      _mobile = _string(member['mobile']);
    } on LibraryBookingException {
      rethrow;
    } catch (_) {
      // Never include password, CAS tickets or callback bodies in diagnostics.
      _checkActive(generation);
      throw const LibraryBookingException('图书馆认证暂未完成，请稍后重试。');
    }
  }

  static bool _isBookingUri(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == _host &&
      uri.port == 443 &&
      uri.userInfo.isEmpty;

  static bool _isRedirect(int status) =>
      const [301, 302, 303, 307, 308].contains(status);

  Future<_LibraryResponse> _request(
    Uri uri, {
    Map<String, dynamic>? body,
    bool authenticated = false,
    bool mutation = false,
    Cookie? ssoCookie,
  }) async {
    _checkActive();
    final generation = _generation;
    final isCas = uri.scheme == 'https' &&
        uri.host == 'zjuam.zju.edu.cn' &&
        uri.port == 443 &&
        uri.path == '/cas/login' &&
        uri.userInfo.isEmpty &&
        body == null;
    if (!_isBookingUri(uri) && !isCas) {
      throw const LibraryBookingException('图书馆请求地址无效。');
    }
    HttpClientRequest? request;
    var mayHaveBeenSent = false;
    try {
      request = await (body == null
              ? _httpClient.getUrl(uri)
              : _httpClient.postUrl(uri))
          .timeout(requestTimeout);
      _checkActive(generation);
      request.followRedirects = false;
      if (isCas) {
        if (ssoCookie != null) {
          request.cookies.add(Cookie(ssoCookie.name, ssoCookie.value));
        }
      } else {
        final now = _now().toUtc();
        _cookies.removeWhere(
            (item) => item.expires != null && !now.isBefore(item.expires!));
        request.cookies.addAll(_cookies
            .where((item) =>
                uri.path == item.path ||
                uri.path.startsWith(
                    item.path.endsWith('/') ? item.path : '${item.path}/'))
            .map((item) => Cookie(item.cookie.name, item.cookie.value)));
        request.headers.set('X-Requested-With', 'XMLHttpRequest');
        request.headers.set('lang', 'zh');
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        if (authenticated && _token != null) {
          request.headers.set(HttpHeaders.authorizationHeader, 'bearer$_token');
        }
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        mayHaveBeenSent = true;
        request.write(jsonEncode(body));
      }
      mayHaveBeenSent = true;
      final response = await request.close().timeout(requestTimeout);
      final content =
          await utf8.decoder.bind(response).join().timeout(requestTimeout);
      _checkActive(generation);
      if (!isCas) _rememberCookies(uri, response.cookies);
      return _LibraryResponse(response.statusCode, content,
          response.headers.value(HttpHeaders.locationHeader));
    } on LibraryBookingException {
      rethrow;
    } catch (_) {
      request?.abort();
      _checkActive(generation);
      throw LibraryBookingException(
        mutation && mayHaveBeenSent ? _unknownOutcome : '图书馆网络请求失败，请稍后重试。',
        outcomeUnknown: mutation && mayHaveBeenSent,
      );
    }
  }

  void _rememberCookies(Uri uri, List<Cookie> cookies) {
    for (final cookie in cookies) {
      // Bind cookies to the booking origin, even if the server advertises a
      // broader Domain attribute. No library cookie is ever sent to CAS.
      final domain = cookie.domain?.replaceFirst(RegExp(r'^\.'), '');
      if (domain != null &&
          domain.isNotEmpty &&
          uri.host != domain &&
          !uri.host.endsWith('.$domain')) {
        continue;
      }
      final path = cookie.path?.startsWith('/') == true
          ? cookie.path!
          : uri.path.substring(0, uri.path.lastIndexOf('/') + 1);
      _cookies.removeWhere(
          (item) => item.cookie.name == cookie.name && item.path == path);
      final expires = cookie.maxAge != null
          ? _now().toUtc().add(Duration(seconds: cookie.maxAge!))
          : cookie.expires?.toUtc();
      if (cookie.value.isEmpty ||
          (expires != null && !expires.isAfter(_now().toUtc()))) {
        continue;
      }
      _cookies.add(_StoredCookie(cookie, path, expires));
    }
  }

  Future<Map<String, dynamic>> _postOnce(
    String path,
    Map<String, dynamic> data, {
    bool authenticated = true,
    bool mutation = false,
    int successCode = 1,
    bool encrypted = false,
  }) async {
    final body = encrypted
        ? <String, dynamic>{
            'aesjson': LibraryBookingCodec.encrypt(data, _now())
          }
        : Map<String, dynamic>.from(data);
    if (authenticated && _token != null) {
      body['authorization'] = 'bearer$_token';
    }
    final response = await _request(Uri.https(_host, path),
        body: body, authenticated: authenticated, mutation: mutation);
    if (response.status == 401 ||
        response.status == 403 ||
        _isRedirect(response.status)) {
      throw const LibraryBookingException('图书馆登录已过期，请重新加载后重试。',
          authenticationRequired: true);
    }
    if (response.status != 200) {
      throw LibraryBookingException(
        mutation ? _unknownOutcome : '图书馆服务暂时不可用（HTTP ${response.status}）。',
        outcomeUnknown: mutation,
      );
    }
    Map<String, dynamic> decoded;
    try {
      decoded = _map(jsonDecode(response.body));
      if (!decoded.containsKey('code')) throw const FormatException();
    } catch (_) {
      throw LibraryBookingException(
        mutation ? _unknownOutcome : '图书馆响应格式发生变化，请稍后重试。',
        outcomeUnknown: mutation,
      );
    }
    if (_string(decoded['code']) == '10001') {
      throw const LibraryBookingException('图书馆登录已过期，请重新加载后重试。',
          authenticationRequired: true);
    }
    if (_string(decoded['code']) != '$successCode') {
      throw LibraryBookingException(_message(decoded, '图书馆未接受本次请求。'));
    }
    return decoded;
  }

  Future<Map<String, dynamic>> _read(String path, Map<String, dynamic> body,
      {int successCode = 1}) async {
    await _ensureAuthenticated();
    final previousToken = _token;
    try {
      return await _postOnce(path, body, successCode: successCode);
    } on LibraryBookingException catch (error) {
      if (!error.authenticationRequired) rethrow;
      if (_token == previousToken) _token = null;
      await _ensureAuthenticated();
      return _postOnce(path, body, successCode: successCode);
    }
  }

  @override
  Future<LibraryCatalog> loadCatalog() async {
    final datesResponse = await _read('/api/Seminar/date', {});
    final dates = _list(datesResponse['data'])
        .map(_string)
        .where((date) => RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date))
        .toList();
    if (dates.isEmpty) return const LibraryCatalog(dates: [], buildings: []);
    final tree = await _tree(dates.first);
    return LibraryCatalog(
      dates: dates,
      buildings: tree
          .map((item) => LibraryBuilding(
              id: _requiredString(item['id']),
              name: _requiredString(item['name'])))
          .toList(),
    );
  }

  Future<List<Map<String, dynamic>>> _tree(String date) async =>
      _list((await _read('/api/Seminar/tree', {'date': date}))['data'])
          .map(_map)
          .toList();

  @override
  Future<List<LibraryRoom>> loadRooms({
    required String buildingId,
    required String date,
  }) async {
    final tree = await _tree(date);
    final result = <LibraryRoom>[];
    for (final building
        in tree.where((item) => _string(item['id']) == buildingId)) {
      for (final floorValue in _list(building['children'])) {
        final floor = _map(floorValue);
        for (final roomValue in _list(floor['children'])) {
          final room = _map(roomValue);
          result.add(LibraryRoom(
            id: _requiredString(room['id']),
            name: _requiredString(room['name']),
            buildingId: buildingId,
            description: _string(floor['name']),
            canReserve: _string(room['status']) == '1' &&
                _string(floor['status']) != '0',
          ));
        }
      }
    }
    return result;
  }

  @override
  Future<LibraryRoomAvailability> loadAvailability({
    required LibraryRoom room,
    required String date,
  }) async {
    final detail = _map((await _read(
        '/api/Seminar/detail', {'id': room.id, 'day': date}))['data']);
    final days = _map((await _read('/api/Seminar/v1seminar',
        {'room': room.id, 'area': room.buildingId}))['data']);
    final rule = _map((await _read('/api/Seminar/seminar',
        {'room': room.id, 'area': room.buildingId, 'day': date}))['data']);
    final form = _map((await _read(
        '/reserve/index/detail', {'areaId': room.id, 'id': '2'},
        successCode: 0))['data']);
    if (_rules.isEmpty) {
      final rules = _map((await _read('/api/seminar/should', {}))['data']);
      _rules = _plainText(_string(rules['seminar_rule']));
    }
    Map<String, dynamic>? selectedDay;
    for (final value in _list(days['list'])) {
      final item = _map(value);
      if (_string(item['date']) == date) selectedDay = item;
    }
    if (selectedDay == null) {
      throw const LibraryBookingException('所选日期当前不可预约，请重新选择日期。');
    }
    final info = _map(selectedDay['info']);
    final start = _requiredInt(info['startTime']);
    final end = _requiredInt(info['endTime']);
    final min = _requiredInt(info['minTime']);
    final max = _requiredInt(info['maxTime']);
    if (start < 0 || end > 1440 || start >= end || min <= 0 || max < min) {
      throw const LibraryBookingException('图书馆时段规则格式异常，请在官网核实。');
    }
    final unavailable = _list(info['list'] ?? const []).map((value) {
      final interval = _map(value);
      return LibraryTimeRange(
          startMinute: _requiredInt(interval['beginNum']),
          endMinute: _requiredInt(interval['endNum']));
    }).toList();
    final today = LibraryBookingCodec.dateLabel(_now());
    final current = LibraryBookingCodec.shanghaiTime(_now());
    final minute = current.hour * 60 + current.minute;
    final earliest = date == today ? ((minute ~/ 15) + 1) * 15 : start;
    final requiresAttachment = _string(rule['isMouldShow']) == '1';
    final specialSpace = _string(form['type_id']) == '5' ||
        (int.tryParse(_string(form['earlierPeriods'])) ?? 0) > 0;
    final titleChoices = _string(form['readonlyTitle']) == '1'
        ? _list(form['title']).map((value) {
            final title = _map(value);
            return LibraryTitleChoice(
                id: _requiredString(title['id']),
                title: _requiredString(title['title']));
          }).toList()
        : <LibraryTitleChoice>[];
    final minParticipants = _requiredInt(rule['minPerson']);
    final maxParticipants = _requiredInt(rule['maxPerson']);
    return LibraryRoomAvailability(
      room: room,
      date: date,
      startMinute: ((start + 14) ~/ 15) * 15,
      endMinute: (end ~/ 15) * 15,
      minDurationMinutes: min,
      maxDurationMinutes: max,
      minParticipants: minParticipants < 1 ? 1 : minParticipants,
      maxParticipants: maxParticipants,
      unavailable: unavailable,
      requiresAttachment: requiresAttachment,
      titleRequired:
          _string(form['readonlyTitle']) == '2' || titleChoices.isNotEmpty,
      titleChoices: titleChoices,
      canReserve: room.canReserve &&
          _string(detail['is_reducible']) == '1' &&
          _string(info['Fully_Booked']) == '0' &&
          date.compareTo(today) >= 0,
      mobile: _mobile,
      rules: [_rules, _plainText(_string(form['contents']))]
          .where((value) => value.isNotEmpty)
          .join('\n\n'),
      unsupportedReason: requiresAttachment
          ? '此空间要求上传附件，请使用图书馆官网完成预约。'
          : specialSpace || maxParticipants < 1
              ? '此空间使用特殊预约规则，请使用图书馆官网完成预约。'
              : null,
      requireUntilClosing: _string(info['isRemainder']) == '1',
      earliestStartMinute: earliest,
    );
  }

  @override
  Future<LibraryParticipant> lookupParticipant({
    required String studentId,
    required LibraryRoom room,
    required String date,
    required int startMinute,
    required int endMinute,
  }) async {
    if (studentId.trim().isEmpty) {
      throw const LibraryBookingException('请输入参与成员的学工号。');
    }
    final result = _map((await _read('/api/Seminar/group', {
      'card': studentId.trim(),
      'area': room.id,
      'beginTime': '$date ${libraryTimeLabel(startMinute)}',
      'endTime': '$date ${libraryTimeLabel(endMinute)}',
    }))['data']);
    return LibraryParticipant(
        id: _requiredString(result['id']),
        name: _requiredString(result['name']));
  }

  @override
  Future<String> submit(LibraryBookingDraft draft) async {
    if (_preparingSubmission || _writing) {
      throw const LibraryBookingException('上一项操作尚未完成，请稍候。');
    }
    _preparingSubmission = true;
    try {
      return await _submitValidated(draft);
    } finally {
      _preparingSubmission = false;
    }
  }

  Future<String> _submitValidated(LibraryBookingDraft draft) async {
    _checkActive();
    if (_unresolvedMutation) {
      throw const LibraryBookingException(_unknownOutcome,
          outcomeUnknown: true);
    }
    if (_writing) throw const LibraryBookingException('上一项操作尚未完成，请稍候。');
    // Availability and participant limits can change while the form is open.
    // Refresh reads before sending the single non-retriable write.
    final availability = await loadAvailability(
      room: draft.room,
      date: draft.availability.date,
    );
    if (draft.room.id != availability.room.id ||
        !availability.isRangeAvailable(draft.startMinute, draft.endMinute)) {
      throw LibraryBookingException(
          availability.unsupportedReason ?? '请选择符合规则的可用预约时段。');
    }
    final day = LibraryBookingCodec.dateLabel(_now());
    final current = LibraryBookingCodec.shanghaiTime(_now());
    if (availability.date.compareTo(day) < 0 ||
        (availability.date == day &&
            draft.startMinute <= current.hour * 60 + current.minute)) {
      throw const LibraryBookingException('预约开始时间已过，请重新选择时段。');
    }
    final ids = draft.participants.map((item) => item.id).toSet();
    final count = ids.length + 1;
    if (ids.length != draft.participants.length ||
        ids.contains('') ||
        ids.contains(_memberId) ||
        count < availability.minParticipants ||
        count > availability.maxParticipants) {
      throw const LibraryBookingException('参与人数不符合房间要求，请检查成员名单。');
    }
    if (draft.content.trim().isEmpty || draft.mobile.trim().isEmpty) {
      throw const LibraryBookingException('请填写申请内容和联系电话。');
    }
    final title = draft.titleChoice?.title ?? draft.title.trim();
    if ((availability.titleRequired && title.isEmpty) ||
        (availability.titleChoices.isNotEmpty &&
            !availability.titleChoices.any((item) =>
                item.id == draft.titleChoice?.id && item.title == title))) {
      throw const LibraryBookingException('请填写或选择有效的申请主题。');
    }
    return _write(
        '/reserve/index/confirm',
        {
          'id': 2,
          'day': availability.date,
          'start_time': libraryTimeLabel(draft.startMinute),
          'end_time': libraryTimeLabel(draft.endMinute),
          'title': title,
          'content': draft.content.trim(),
          'mobile': draft.mobile.trim(),
          'room': draft.room.id,
          'open': draft.isPublic ? '1' : '0',
          'file_name': '',
          'file_url': '',
          if (ids.isNotEmpty) 'teamusers': ids.join(','),
          if (draft.titleChoice != null) 'titleId': draft.titleChoice!.id,
        },
        encrypted: true,
        fallbackMessage: '预约申请已提交，请在“我的预约”确认状态。');
  }

  Future<String> _write(String path, Map<String, dynamic> body,
      {bool encrypted = false, required String fallbackMessage}) async {
    _checkActive();
    if (_writing) throw const LibraryBookingException('上一项操作尚未完成，请稍候。');
    if (_unresolvedMutation) {
      throw const LibraryBookingException(_unknownOutcome,
          outcomeUnknown: true);
    }
    _writing = true;
    try {
      await _ensureAuthenticated();
      final result =
          await _postOnce(path, body, encrypted: encrypted, mutation: true);
      return _message(result, fallbackMessage);
    } on LibraryBookingException catch (error) {
      if (error.authenticationRequired) _token = null;
      if (error.outcomeUnknown) _unresolvedMutation = true;
      rethrow;
    } finally {
      _writing = false;
    }
  }

  @override
  Future<List<LibraryReservation>> loadReservations({int page = 1}) async {
    final response =
        await _read('/api/Member/seminar', {'page': page, 'limit': 10});
    final data = _map(response['data']);
    final reservations = _list(data['data']).map((value) {
      final item = _map(value);
      final own = _string(item['booker']) == _memberId;
      final canCancel = _string(item['status']) == '2' &&
          own &&
          _string(item['oksign']) == '1';
      return LibraryReservation(
        id: _requiredString(item['id']),
        roomName: _string(item['nameMerge']),
        date: _string(item['day']),
        startTime: _string(item['start']),
        endTime: _string(item['end']),
        status: _reservationStatus(item, own),
        canCancel: canCancel,
        cancellationReason: canCancel
            ? null
            : own
                ? '此预约当前不可取消；请以图书馆规定和预约状态为准。'
                : '仅预约发起人可以取消。',
      );
    }).toList();
    if (page == 1) _unresolvedMutation = false;
    return reservations;
  }

  @override
  Future<String> cancel(LibraryReservation reservation) async {
    if (_preparingSubmission) {
      throw const LibraryBookingException('上一项操作尚未完成，请稍候。');
    }
    if (!reservation.canCancel || reservation.id.isEmpty) {
      throw LibraryBookingException(
          reservation.cancellationReason ?? '此预约当前不可取消。');
    }
    return _write('/api/space/seminarCancel', {'id': reservation.id},
        fallbackMessage: '预约已取消。');
  }

  String _message(Map<String, dynamic> response, String fallback) {
    var message = _plainText(_string(response['msg']));
    if (message.isEmpty) return fallback;
    for (final secret in [_token, _password, _username]) {
      if (secret != null && secret.isNotEmpty) {
        message = message.replaceAll(secret, '***');
      }
    }
    return message.length > 300 ? message.substring(0, 300) : message;
  }

  static String _plainText(String value) => value
      .replaceAll(RegExp(r'<(?:br\s*/?|/p|/div)>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .trim();

  static Map<String, dynamic> _map(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    throw const LibraryBookingException('图书馆响应字段格式异常，请在官网核实。');
  }

  static List<dynamic> _list(dynamic value) {
    if (value is List) return value;
    throw const LibraryBookingException('图书馆响应列表格式异常，请在官网核实。');
  }

  static String _string(dynamic value) => value == null ? '' : value.toString();

  static String _reservationStatus(Map<String, dynamic> item, bool own) {
    final status = _string(item['status']);
    if (status == '2') return '预约成功';
    if (status == '21') {
      if (own) return '等待成员确认';
      switch (_string(item['isAuthorized'])) {
        case '1':
          return '已同意邀请';
        case '2':
          return '已拒绝邀请';
        default:
          return '待确认邀请（请前往图书馆官网处理）';
      }
    }
    final label = _string(item['statusname']);
    return label.isEmpty ? '状态待确认' : label;
  }

  static String _requiredString(dynamic value) {
    final text = _string(value);
    if (text.isEmpty) {
      throw const LibraryBookingException('图书馆响应缺少必要字段，请在官网核实。');
    }
    return text;
  }

  static int _requiredInt(dynamic value) {
    final number = int.tryParse(_string(value));
    if (number == null) {
      throw const LibraryBookingException('图书馆响应数值格式异常，请在官网核实。');
    }
    return number;
  }
}
