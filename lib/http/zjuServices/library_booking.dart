import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:celechron/model/library_reservation.dart';
import 'package:celechron/model/library_seat.dart';
import 'package:pointycastle/export.dart';

import 'zjuam.dart';

export 'package:celechron/model/library_reservation.dart';
export 'package:celechron/model/library_seat.dart';

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
  final String? contentType;

  const _LibraryResponse(
      this.status, this.body, this.location, this.contentType);
}

enum _LibraryWriteDomain { seminar, seat }

class _SeatCancellationPermission {
  final bool? allowed;
  final String warning;

  const _SeatCancellationPermission(this.allowed, this.warning);
}

/// An account-scoped session for booking.lib.zju.edu.cn, deliberately separate
/// from the academic clients. Tokens, cookies and member data are never saved.
/// Only read operations may retry after explicit authentication expiry.
class LibraryBookingService
    implements LibraryBookingClient, LibrarySeatBookingClient {
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
  final bool Function()? _canUseSession;
  final Duration requestTimeout;
  final List<_StoredCookie> _cookies = [];
  final Map<String, int> _seatReservationPages = {};
  Future<void>? _loginFuture;
  String? _token;
  String _memberId = '';
  String _mobile = '';
  String _rules = '';
  String _seatRules = '';
  Duration? _serverClockOffset;
  bool _disposed = false;
  bool _writing = false;
  bool _preparingSubmission = false;
  bool _unresolvedMutation = false;
  _LibraryWriteDomain? _unresolvedMutationDomain;
  int _unresolvedMutationVersion = 0;
  int _generation = 0;

  LibraryBookingService({
    required String username,
    required String password,
    HttpClient? httpClient,
    SsoCookieProvider? ssoCookieProvider,
    DateTime Function()? now,
    bool Function()? canUseSession,
    this.requestTimeout = const Duration(seconds: 15),
  })  : _username = username,
        _password = password,
        _httpClient = httpClient ?? HttpClient(),
        _ssoCookieProvider = ssoCookieProvider ?? ZjuAm.getSsoCookie,
        _canUseSession = canUseSession,
        _now = now ?? DateTime.now {
    _httpClient.connectionTimeout = requestTimeout;
    _httpClient.userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/110.0.0.0 Safari/537.36';
  }

  void _checkActive([int? generation]) {
    if (_disposed ||
        (generation != null && generation != _generation) ||
        (_canUseSession != null && !_canUseSession!())) {
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
    _seatReservationPages.clear();
    _serverClockOffset = null;
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
      late _LibraryResponse callbackResponse;
      var redirectCount = 0;
      for (var redirects = 0; redirects < 5; redirects++) {
        final response = await _request(callback);
        callbackResponse = response;
        if (!_isRedirect(response.status) || response.location == null) break;
        callback = callback.resolve(response.location!);
        if (!_isBookingUri(callback)) {
          throw const LibraryBookingException('图书馆登录跳转地址无效。');
        }
        redirectCount++;
        if (_isSpaPath(callback.path)) {
          // The fragment belongs to Vue and is not an HTTP resource. Extract
          // the exchange code before requesting index.html (which only returns
          // the SPA shell). A normal /my/info route is not a login credential.
          exchangeCode = _casExchangeCode(callback);
          break;
        }
        if (callback.hasFragment) {
          throw const LibraryBookingException('图书馆登录回调页面无效。');
        }
      }
      if (exchangeCode == null || exchangeCode.isEmpty) {
        throw _callbackFailure(callbackResponse, redirectCount);
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

  static bool _isSpaPath(String path) =>
      const ['/h5', '/h5/', '/h5/index.html'].contains(path);

  static String? _casExchangeCode(Uri callback) {
    if (!_isBookingUri(callback) || !_isSpaPath(callback.path)) return null;
    final route = Uri.tryParse(callback.fragment);
    if (route == null ||
        route.hasScheme ||
        route.hasAuthority ||
        route.hasFragment ||
        !RegExp(r'^/cas/?$', caseSensitive: false).hasMatch(route.path)) {
      return null;
    }
    final values = route.queryParametersAll['cas'];
    if (values == null || values.length != 1 || values.single.trim().isEmpty) {
      return null;
    }
    return values.single;
  }

  static LibraryBookingException _callbackFailure(
      _LibraryResponse response, int redirectCount) {
    // phpCAS may return its failure HTML as HTTP 200 when a framework treats
    // navigation as AJAX. Report only a fixed classification, never the body,
    // Location, CAS ticket, exchange code or arbitrary Content-Type header.
    final ticketRejected =
        RegExp(r'CAS\s+Authentication\s+failed', caseSensitive: false)
            .hasMatch(response.body);
    final reason = ticketRejected ? '图书馆未接受认证票据' : '图书馆登录未返回有效的认证结果';
    final body = response.body.trimLeft();
    final contentType = response.contentType?.toLowerCase() ?? '';
    final String responseType;
    if (body.isEmpty) {
      responseType = '空';
    } else if (body.startsWith('<') || contentType.startsWith('text/html')) {
      responseType = 'HTML';
    } else if (body.startsWith('{') ||
        body.startsWith('[') ||
        contentType.startsWith('application/json')) {
      responseType = 'JSON';
    } else {
      responseType = '其他';
    }
    return LibraryBookingException('$reason（阶段：图书馆回调；'
        'HTTP ${response.status}；响应类型：$responseType；跳转次数：$redirectCount）。');
  }

  Future<_LibraryResponse> _request(
    Uri uri, {
    Map<String, dynamic>? body,
    bool authenticated = false,
    bool mutation = false,
    Cookie? ssoCookie,
  }) async {
    _checkActive();
    uri = uri.removeFragment();
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
      if (body == null) {
        request.headers
            .set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml');
      }
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
        if (body != null) {
          request.headers.set('X-Requested-With', 'XMLHttpRequest');
          request.headers.set('lang', 'zh');
          request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        }
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
      return _LibraryResponse(
        response.statusCode,
        content,
        response.headers.value(HttpHeaders.locationHeader),
        response.headers.value(HttpHeaders.contentTypeHeader),
      );
    } on LibraryBookingException {
      request?.abort();
      if (mutation && mayHaveBeenSent) {
        throw const LibraryBookingException(_unknownOutcome,
            outcomeUnknown: true);
      }
      rethrow;
    } catch (_) {
      request?.abort();
      if (mutation && mayHaveBeenSent) {
        throw const LibraryBookingException(_unknownOutcome,
            outcomeUnknown: true);
      }
      _checkActive(generation);
      throw const LibraryBookingException('图书馆网络请求失败，请稍后重试。');
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
            'aesjson': LibraryBookingCodec.encrypt(data, _protocolNow())
          }
        : Map<String, dynamic>.from(data);
    if (authenticated && _token != null) {
      body['authorization'] = 'bearer$_token';
    }
    final response = await _request(Uri.https(_host, path),
        body: body, authenticated: authenticated, mutation: mutation);
    if (mutation && _isRedirect(response.status)) {
      throw const LibraryBookingException(_unknownOutcome,
          outcomeUnknown: true);
    }
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
      if (int.tryParse(_string(decoded['code'])) == null) {
        throw const FormatException();
      }
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
  Future<LibraryCatalog> loadCatalog({String? date}) async {
    final data = await _seminarDirectory(
        date ?? LibraryBookingCodec.dateLabel(_protocolNow()));
    return LibraryCatalog(
      dates: _list(data['date'] ?? const []).map((value) {
        final day = _requiredString(value);
        _requireSeatDate(day);
        return day;
      }).toList(),
      buildings: _list(data['premises'] ?? const []).map((value) {
        final item = _map(value);
        return LibraryBuilding(
            id: _requiredString(item['id']),
            name: _requiredString(item['name']));
      }).toList(),
    );
  }

  Future<Map<String, dynamic>> _seminarDirectory(String date) async {
    _requireSeatDate(date);
    // The current SeatScreening/2 -> QuickChoose route uses this flat directory,
    // not the status flags from the retired Seminar/tree selector.
    return _map((await _read(
        '/reserve/index/quickSelect', {'id': '2', 'date': date},
        successCode: 0))['data']);
  }

  @override
  Future<List<LibraryRoom>> loadRooms({
    required String buildingId,
    required String date,
  }) async {
    final data = await _seminarDirectory(date);
    final floors = <String, String>{};
    for (final value in _list(data['storey'] ?? const [])) {
      final floor = _map(value);
      if (_string(floor['topId']) == buildingId) {
        floors[_requiredString(floor['id'])] = _requiredString(floor['name']);
      }
    }
    final result = <LibraryRoom>[];
    for (final value in _list(data['area'] ?? const [])) {
      final room = _map(value);
      if (_string(room['topId']) != buildingId) continue;
      final full = _binaryFlag(room['Fully_Booked']);
      final permission = _binaryFlag(room['is_reducible']);
      final type = _string(room['typeCategory']);
      final earlierPeriods = int.tryParse(_string(room['earlierPeriods'])) ?? 0;
      final special = type == '5' || earlierPeriods > 0;
      final reason = special
          ? '此空间使用特殊预约流程，请前往图书馆官网办理。'
          : permission == false
              ? '当前账号没有此空间的预约权限。'
              : full == true
                  ? '所选日期已约满。'
                  : null;
      result.add(LibraryRoom(
        id: _requiredString(room['id']),
        name: _requiredString(room['name']),
        buildingId: buildingId,
        description: floors[_string(room['parentId'])] ?? '',
        canReserve: reason == null,
        availabilityKnown: special || full != null || permission != null,
        unavailableReason: reason,
        typeCategory: type,
        earlierPeriods: earlierPeriods,
      ));
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
        '/reserve/index/detail', {'areaId': room.id, 'id': '2', 'date': date},
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
    final today = LibraryBookingCodec.dateLabel(_protocolNow());
    final current = LibraryBookingCodec.shanghaiTime(_protocolNow());
    final minute = current.hour * 60 + current.minute;
    final earliest = date == today ? ((minute ~/ 15) + 1) * 15 : start;
    final requiresAttachment = _string(rule['isMouldShow']) == '1';
    final specialSpace = _string(form['type_id']) == '5' ||
        room.typeCategory == '5' ||
        room.earlierPeriods > 0 ||
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
    // Both official detail screens use is_reducible == 0 to deny a booking.
    // Accept an explicit grant from either current detail response, but never
    // turn missing permission fields into authorization to submit.
    final permissionFlags = [
      _binaryFlag(detail['is_reducible']),
      _binaryFlag(form['is_reducible']),
    ];
    final permission =
        !permissionFlags.contains(false) && permissionFlags.contains(true);
    final full = [info, detail, form]
        .any((value) => _binaryFlag(value['Fully_Booked']) == true);
    final String? unavailableReason;
    if (permissionFlags.contains(false)) {
      unavailableReason = '当前账号没有此空间的预约权限。';
    } else if (!permission) {
      unavailableReason = '无法确认当前预约权限，请刷新或前往图书馆官网核实。';
    } else if (date.compareTo(today) < 0) {
      unavailableReason = '所选预约日期已经过期。';
    } else if (full) {
      unavailableReason = '所选日期已约满，请选择其他日期或空间。';
    } else {
      unavailableReason = null;
    }
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
      canReserve: unavailableReason == null,
      unavailableReason: unavailableReason,
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
      throw LibraryBookingException(availability.unsupportedReason ??
          availability.unavailableReason ??
          '请选择符合规则的可用预约时段。');
    }
    final day = LibraryBookingCodec.dateLabel(_protocolNow());
    final current = LibraryBookingCodec.shanghaiTime(_protocolNow());
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
      {bool encrypted = false,
      _LibraryWriteDomain domain = _LibraryWriteDomain.seminar,
      required String fallbackMessage}) async {
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
      if (error.outcomeUnknown) {
        _unresolvedMutation = true;
        _unresolvedMutationDomain = domain;
        _unresolvedMutationVersion++;
      }
      rethrow;
    } finally {
      _writing = false;
    }
  }

  @override
  Future<List<LibraryReservation>> loadReservations({int page = 1}) async {
    final uncertaintyVersion = _unresolvedMutationVersion;
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
    _completeReservationRefresh(
        _LibraryWriteDomain.seminar, uncertaintyVersion, page);
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

  void _completeReservationRefresh(
      _LibraryWriteDomain domain, int version, int page) {
    _checkActive();
    if (page == 1 &&
        _unresolvedMutationDomain == domain &&
        _unresolvedMutationVersion == version) {
      _unresolvedMutation = false;
      _unresolvedMutationDomain = null;
    }
  }

  Future<Map<String, dynamic>> _seatDirectory(String date) async {
    _requireSeatDate(date);
    // Current SeatScreening/1 -> QuickChoose uses this flat directory. The old
    // Seat/tree module has a different schema and is not used as a fallback.
    return _map((await _read(
        '/reserve/index/quickSelect', {'id': '1', 'date': date},
        successCode: 0))['data']);
  }

  DateTime _protocolNow() =>
      _now().toUtc().add(_serverClockOffset ?? Duration.zero);

  @override
  Future<LibraryCatalog> loadSeatCatalog({String? date}) async {
    final data =
        await _seatDirectory(date ?? LibraryBookingCodec.dateLabel(_now()));
    final dates = _list(data['date']).map((value) {
      final day = _requiredString(value);
      _requireSeatDate(day);
      return day;
    }).toList();
    return LibraryCatalog(
      dates: dates,
      buildings: _list(data['premises']).map((value) {
        final building = _map(value);
        return LibraryBuilding(
          id: _requiredString(building['id']),
          name: _requiredString(building['name']),
        );
      }).toList(),
    );
  }

  @override
  Future<List<LibrarySeatArea>> loadSeatAreas({
    required String buildingId,
    required String date,
  }) async {
    final data = await _seatDirectory(date);
    final floors = <String, String>{};
    for (final value in _list(data['storey'])) {
      final floor = _map(value);
      if (_string(floor['topId']) == buildingId) {
        floors[_requiredString(floor['id'])] = _requiredString(floor['name']);
      }
    }
    final result = <LibrarySeatArea>[];
    for (final value in _list(data['area'])) {
      final area = _map(value);
      if (_string(area['topId']) != buildingId) continue;
      final type = _string(area['typeCategory']);
      final supported = type == '1';
      final freeSeats = num.tryParse(_string(area['free_num']));
      result.add(LibrarySeatArea(
        id: _requiredString(area['id']),
        name: _requiredString(area['name']),
        buildingId: buildingId,
        floorName: floors[_string(area['parentId'])] ?? '',
        typeCategory: type,
        canReserve: supported && freeSeats != null && freeSeats > 0,
        unsupportedReason: supported ? null : '此区域使用其他空间预约流程，请前往图书馆官网办理。',
      ));
    }
    return result;
  }

  @override
  Future<LibrarySeatAvailability> loadSeatAvailability({
    required LibrarySeatArea area,
  }) async {
    if (area.typeCategory != '1' || area.unsupportedReason != null) {
      return LibrarySeatAvailability(
        area: area,
        days: const [],
        canReserve: false,
        unsupportedReason:
            area.unsupportedReason ?? '此区域使用其他空间预约流程，请前往图书馆官网办理。',
      );
    }
    final dateRows =
        _list((await _read('/api/Seat/date', {'build_id': area.id}))['data']);
    final detail = _map((await _read(
        '/reserve/index/detail', {'id': '1', 'areaId': area.id},
        successCode: 0))['data']);
    final clock = _map((await _read('/api/index/time', {}))['data']);
    _checkActive();
    final encodedTime = num.tryParse(_string(clock['time']));
    if (encodedTime == null || !encodedTime.isFinite) {
      throw const LibraryBookingException('无法确认图书馆服务器时间，请稍后重试。');
    }
    final seconds = encodedTime / 29 - 509;
    if (!seconds.isFinite || seconds < 0 || seconds > 253402300799) {
      throw const LibraryBookingException('图书馆服务器时间格式异常，请稍后重试。');
    }
    final serverTime = DateTime.fromMillisecondsSinceEpoch(
        (seconds * 1000).round(),
        isUtc: true);
    // Keep protocol dates aligned with the server, including when a device's
    // date differs or a long selection crosses midnight in China.
    _serverClockOffset = serverTime.difference(_now().toUtc());
    final configResponse = await _read('/api/index/config', {});
    late Map<String, dynamic> config;
    try {
      final decoded = _map(LibraryBookingCodec.decrypt(
          _requiredString(configResponse['data']), _protocolNow()));
      config = _map(decoded['config']);
    } catch (_) {
      throw const LibraryBookingException('座位预约开放规则读取失败，请稍后重试。');
    }
    final opensAt = _seatMinute(_string(config['new']));
    final closesAt = _seatMinute(_string(config['close']));
    final systemEndsAt = _seatMinute(_string(config['end']));
    if (opensAt == null || closesAt == null || systemEndsAt == null) {
      throw const LibraryBookingException('座位预约开放规则格式异常，请前往图书馆官网核实。');
    }
    if (_seatRules.isEmpty) {
      final rules = _map((await _read('/api/seminar/should', {}))['data']);
      _seatRules = _plainText(_string(rules['seat_rule']));
    }
    _checkActive();
    final checkedAt = _protocolNow();
    final current = LibraryBookingCodec.shanghaiTime(checkedAt);
    final today = LibraryBookingCodec.dateLabel(checkedAt);
    final minute = current.hour * 60 + current.minute;
    final second = minute * 60 + current.second;
    final permission = _string(detail['is_reducible']) == '1';
    final days = <LibrarySeatDay>[];
    for (var index = 0; index < dateRows.length; index++) {
      final dayRow = _map(dateRows[index]);
      final date = _requiredString(dayRow['day']);
      _requireSeatDate(date);
      String? dayReason;
      if (!permission) {
        dayReason = '当前账号没有此区域的座位预约权限。';
      } else if (!area.canReserve) {
        dayReason = '此区域当前不可预约，请重新查询。';
      } else if (date.compareTo(today) < 0) {
        dayReason = '此预约日期已过期。';
      } else if (minute > systemEndsAt ||
          (date == today && minute > closesAt)) {
        dayReason = '已超过图书馆公布的预约截止时间。';
      } else if (dateRows.length > 1 &&
          index == dateRows.length - 1 &&
          second < opensAt * 60) {
        dayReason = '此日期将在北京时间 ${config['new']} 开放预约。';
      }
      final segments = _list(dayRow['times'] ?? const []).map((value) {
        final item = _map(value);
        final start = _string(item['start']);
        final end = _string(item['end']);
        final startMinute = _seatMinute(start);
        final endMinute = _seatMinute(end);
        String? reason = dayReason;
        if (startMinute == null ||
            endMinute == null ||
            startMinute >= endMinute) {
          reason ??= '此时段已暂停预约。';
        } else if (_string(item['status']) != '1') {
          reason ??= '此时段当前不可预约。';
        } else if (date == today && second >= endMinute * 60) {
          reason ??= '此预约时段已经结束。';
        }
        return LibrarySeatSegment(
          id: _requiredString(item['id']),
          areaId: area.id,
          date: date,
          startTime: start,
          endTime: end,
          canReserve: reason == null,
          unavailableReason: reason,
        );
      }).toList();
      days.add(LibrarySeatDay(date: date, segments: segments));
    }
    return LibrarySeatAvailability(
      area: area,
      days: days,
      canReserve: permission && area.canReserve,
      rules: [_seatRules, _plainText(_string(detail['contents']))]
          .where((value) => value.isNotEmpty)
          .join('\n\n'),
      unsupportedReason: permission ? null : '当前账号没有此区域的座位预约权限。',
    );
  }

  @override
  Future<List<LibrarySeat>> loadSeats({
    required LibrarySeatArea area,
    required LibrarySeatSegment segment,
  }) async {
    _validateSeatSelection(area, segment);
    final response = await _read('/api/Seat/seat', {
      'area': area.id,
      'segment': segment.id,
      'day': segment.date,
      'startTime': segment.startTime,
      'endTime': segment.endTime,
    });
    return _list(response['data']).map((value) {
      final seat = _map(value);
      final status = _string(seat['status']);
      return LibrarySeat(
        id: _requiredString(seat['id']),
        name: _requiredString(seat['name']),
        status: _seatStatusLabel(status),
        canReserve: status == '1' && _string(seat['in_label']) == '1',
        labels: _list(seat['labels'] ?? const [])
            .map((label) {
              final value = _map(label);
              return _string(value['zhname']);
            })
            .where((label) => label.isNotEmpty)
            .toList(),
      );
    }).toList();
  }

  @override
  Future<String> submitSeat(LibrarySeatDraft draft) async {
    _checkActive();
    if (_preparingSubmission || _writing) {
      throw const LibraryBookingException('上一项操作尚未完成，请稍候。');
    }
    if (_unresolvedMutation) {
      throw const LibraryBookingException(_unknownOutcome,
          outcomeUnknown: true);
    }
    _validateSeatSelection(draft.area, draft.segment);
    if (draft.seat.id.trim().isEmpty || !draft.seat.canReserve) {
      throw const LibraryBookingException('请选择可预约的座位。');
    }
    _preparingSubmission = true;
    try {
      final areas = await loadSeatAreas(
          buildingId: draft.area.buildingId, date: draft.segment.date);
      _checkActive();
      LibrarySeatArea? area;
      for (final value in areas) {
        if (value.id == draft.area.id) area = value;
      }
      if (area == null || !area.canReserve || area.typeCategory != '1') {
        throw const LibraryBookingException('所选区域当前不可预约，请重新查询。');
      }
      final availability = await loadSeatAvailability(area: area);
      _checkActive();
      LibrarySeatSegment? segment;
      for (final day in availability.days) {
        if (day.date != draft.segment.date) continue;
        for (final value in day.segments) {
          if (value.id == draft.segment.id) segment = value;
        }
      }
      if (!availability.canReserve || segment == null || !segment.canReserve) {
        throw LibraryBookingException(availability.unsupportedReason ??
            segment?.unavailableReason ??
            '所选预约时段已不可用，请重新选择。');
      }
      if (segment.startTime != draft.segment.startTime ||
          segment.endTime != draft.segment.endTime) {
        throw const LibraryBookingException('预约时段已发生变化，请重新确认。');
      }
      final seats = await loadSeats(area: area, segment: segment);
      _checkActive();
      if (!seats.any((seat) => seat.id == draft.seat.id && seat.canReserve)) {
        throw const LibraryBookingException('所选座位已不可预约，请重新选择。');
      }
      return await _write(
          '/api/Seat/confirm',
          {
            'seat_id': draft.seat.id,
            'segment': segment.id,
          },
          encrypted: true,
          domain: _LibraryWriteDomain.seat,
          fallbackMessage: '座位预约已提交，请在“我的座位预约”确认状态并按要求到场签到。');
    } finally {
      _preparingSubmission = false;
    }
  }

  @override
  Future<List<LibrarySeatReservation>> loadSeatReservations(
      {int page = 1}) async {
    final uncertaintyVersion = _unresolvedMutationVersion;
    final history = await _readSeatHistory(page);
    List<Map<String, dynamic>>? current;
    try {
      current = await _readCurrentSeatReservations();
    } on LibraryBookingException {
      // A missing home response must not hide successfully loaded history or
      // imply permission to cancel. Account invalidation still aborts the read.
      _checkActive();
    }
    _checkActive();
    final result = history.map((record) {
      final id = _requiredString(record['id']).trim();
      if (id.isEmpty) {
        throw const LibraryBookingException('图书馆响应缺少预约编号，请在官网核实。');
      }
      _seatReservationPages[id] = page;
      final home = _seatHomePermission(current ?? const [], id);
      final canCancel =
          current != null && (home.allowed ?? _seatHistoryAllowsCancel(record));
      final label = _string(record['statusName']);
      return LibrarySeatReservation(
        id: id,
        seatName: _string(record['name']),
        areaName: _string(record['nameMerge']),
        date: _string(record['day']),
        startTime: _string(record['start']),
        endTime: _string(record['end']),
        status: label.isEmpty ? '状态待确认' : label,
        canCancel: canCancel,
        cancellationReason: current == null
            ? '当前取消权限无法核实，请刷新后重试。'
            : canCancel
                ? null
                : '此预约当前不可取消，请按图书馆规定处理。',
        cancellationWarning: home.warning,
      );
    }).toList();
    if (current != null) {
      _completeReservationRefresh(
          _LibraryWriteDomain.seat, uncertaintyVersion, page);
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> _readSeatHistory(int page) async {
    final data = _map(
        (await _read('/api/Member/seat', {'page': page, 'limit': 10}))['data']);
    return _list(data['data'] ?? const []).map(_map).toList();
  }

  Future<List<Map<String, dynamic>>> _readCurrentSeatReservations() async {
    final response = await _read('/api/index/subscribe', {});
    return _list(response['data']).map(_map).toList();
  }

  static bool _seatHistoryAllowsCancel(Map<String, dynamic> record) =>
      const ['1', '2', '9'].contains(_string(record['status']).trim()) &&
      _binaryFlag(record['oksign']) == true;

  static _SeatCancellationPermission _seatHomePermission(
      List<Map<String, dynamic>> records, String reservationId) {
    bool? allowed;
    final warnings = <String>{};
    for (final record in records) {
      // id is the booking ID. space_id identifies the physical seat instead.
      if (_string(record['type']).trim() != '1' ||
          _string(record['id']).trim() != reservationId) {
        continue;
      }
      final flag = _binaryFlag(record['oksign']);
      if (flag == false || (allowed == null && flag == true)) allowed = flag;
      if (_binaryFlag(record['only_cancel']) == true) {
        final warning = _plainText(_string(record['only_cancel_text']));
        if (warning.isNotEmpty) warnings.add(warning);
      }
    }
    return _SeatCancellationPermission(allowed, warnings.join('\n'));
  }

  @override
  Future<String> cancelSeat(LibrarySeatReservation reservation) async {
    _checkActive();
    if (_preparingSubmission || _writing) {
      throw const LibraryBookingException('上一项操作尚未完成，请稍候。');
    }
    if (_unresolvedMutation) {
      throw const LibraryBookingException(_unknownOutcome,
          outcomeUnknown: true);
    }
    if (!reservation.canCancel || reservation.id.isEmpty) {
      throw LibraryBookingException(
          reservation.cancellationReason ?? '此座位预约当前不可取消。');
    }
    _preparingSubmission = true;
    try {
      final current = await _readCurrentSeatReservations();
      _checkActive();
      final permission = _seatHomePermission(current, reservation.id);
      var allowed = permission.allowed;
      if (allowed == null) {
        // Use private reads: a cancellation preflight must never clear an
        // unresolved mutation, unlike an explicit refresh of "my bookings".
        final history =
            await _readSeatHistory(_seatReservationPages[reservation.id] ?? 1);
        _checkActive();
        allowed = history.any((record) =>
            _string(record['id']).trim() == reservation.id &&
            _seatHistoryAllowsCancel(record));
      }
      if (!allowed) {
        throw const LibraryBookingException('此预约当前已不可取消，请刷新预约状态后核实。');
      }
      if (permission.warning.isNotEmpty &&
          permission.warning != reservation.cancellationWarning) {
        throw const LibraryBookingException('取消预约的提示已更新，请刷新后阅读并重新确认。');
      }
      return await _write('/api/Space/cancel', {'id': reservation.id},
          domain: _LibraryWriteDomain.seat, fallbackMessage: '座位预约已取消。');
    } finally {
      _preparingSubmission = false;
    }
  }

  static void _validateSeatSelection(
      LibrarySeatArea area, LibrarySeatSegment segment) {
    final start = _seatMinute(segment.startTime);
    final end = _seatMinute(segment.endTime);
    _requireSeatDate(segment.date);
    if (!area.canReserve ||
        area.typeCategory != '1' ||
        area.unsupportedReason != null ||
        area.id != segment.areaId ||
        area.id.isEmpty ||
        segment.id.isEmpty ||
        !segment.canReserve ||
        start == null ||
        end == null ||
        start >= end) {
      throw LibraryBookingException(area.unsupportedReason ??
          segment.unavailableReason ??
          '请选择有效的普通座位区域和预约时段。');
    }
  }

  static void _requireSeatDate(String date) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(date);
    if (match != null) {
      final year = int.parse(match[1]!);
      final month = int.parse(match[2]!);
      final day = int.parse(match[3]!);
      final parsed = DateTime.utc(year, month, day);
      if (year > 0 &&
          parsed.year == year &&
          parsed.month == month &&
          parsed.day == day) {
        return;
      }
    }
    throw const LibraryBookingException('座位预约日期格式无效，请重新选择。');
  }

  static int? _seatMinute(String value) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})(?::00)?$').firstMatch(value);
    if (match == null) return null;
    final hour = int.parse(match[1]!);
    final minute = int.parse(match[2]!);
    if (minute >= 60 || hour > 24 || (hour == 24 && minute != 0)) return null;
    return hour * 60 + minute;
  }

  static String _seatStatusLabel(String status) {
    if (status == '1') return '空闲';
    if (status == '7') return '暂离';
    if (const ['2', '10', '11'].contains(status)) return '已预约';
    if (const ['6', '8', '9'].contains(status)) return '使用中';
    if (const ['3', '4', '5'].contains(status)) return '关闭';
    return '不可预约';
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

  /// Missing or unfamiliar fields are unknown, never an implicit permission.
  static bool? _binaryFlag(dynamic value) {
    if (value == true || value == 1 || value == '1') return true;
    if (value == false || value == 0 || value == '0') return false;
    if (value is String) {
      if (value.trim() == '1') return true;
      if (value.trim() == '0') return false;
    }
    return null;
  }

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
