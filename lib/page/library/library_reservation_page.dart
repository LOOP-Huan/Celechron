import 'dart:async';

import 'package:celechron/http/zjuServices/library_booking.dart';
import 'package:celechron/model/scholar.dart';
import 'package:flutter/cupertino.dart';
import 'package:url_launcher/url_launcher.dart';

import 'library_seat_page.dart';

typedef LibraryBookingClientFactory = LibraryBookingClient Function(
  String username,
  String password,
);

class LibraryReservationPage extends StatefulWidget {
  const LibraryReservationPage({
    super.key,
    required this.scholar,
    this.clientFactory,
    this.seatClientFactory,
  });

  final Scholar scholar;
  final LibraryBookingClientFactory? clientFactory;
  final LibrarySeatClientFactory? seatClientFactory;

  @override
  State<LibraryReservationPage> createState() => _LibraryReservationPageState();
}

class _LibraryReservationPageState extends State<LibraryReservationPage> {
  final _title = TextEditingController();
  final _content = TextEditingController();
  final _mobile = TextEditingController();
  final _participantId = TextEditingController();
  LibraryBookingClient? _client;
  String? _username;
  String? _password;
  String? _accessMessage;
  String? _error;
  VoidCallback? _retry;
  LibraryCatalog? _catalog;
  LibraryBuilding? _building;
  String? _date;
  List<LibraryRoom> _rooms = [];
  LibraryRoom? _room;
  LibraryRoomAvailability? _availability;
  LibraryTitleChoice? _titleChoice;
  final List<LibraryParticipant> _participants = [];
  List<LibraryReservation> _reservations = [];
  int? _start;
  int? _end;
  int _section = 0;
  int _reservationPage = 0;
  bool _hasMore = true;
  bool _busy = false;
  bool _isPublic = true;
  bool _submissionUncertain = false;
  final Set<String> _uncertainCancellations = {};

  @override
  void initState() {
    super.initState();
    _connect();
  }

  void _connect() {
    final scholar = widget.scholar;
    if (!scholar.isLogan ||
        (scholar.username?.isEmpty ?? true) ||
        (scholar.password?.isEmpty ?? true)) {
      _accessMessage = '请先在设置中登录统一身份认证账号，再回来预约研讨间。';
      return;
    }
    if (scholar.username == '3200000000') {
      _accessMessage = '演示账号无法预约真实研讨间。请在设置中登录自己的账号。';
      return;
    }
    _username = scholar.username!;
    _password = scholar.password!;
    _client = widget.clientFactory?.call(_username!, _password!) ??
        LibraryBookingService(
          username: _username!,
          password: _password!,
          canUseSession: () =>
              mounted &&
              widget.scholar.isLogan &&
              widget.scholar.username == _username &&
              widget.scholar.password == _password,
        );
    unawaited(_loadCatalog());
  }

  bool _checkAccount() {
    if (!mounted) return false;
    if (widget.scholar.isLogan &&
        widget.scholar.username == _username &&
        widget.scholar.password == _password) {
      return true;
    }
    _client?.dispose();
    _client = null;
    setState(() {
      _accessMessage = '登录账号已变化，请返回后重新打开研讨间预约。';
      _reservations = [];
      _participants.clear();
      _availability = null;
      _error = null;
    });
    return false;
  }

  @override
  void dispose() {
    _client?.dispose();
    _title.dispose();
    _content.dispose();
    _mobile.dispose();
    _participantId.dispose();
    super.dispose();
  }

  String _errorMessage(Object error) {
    if (error is LibraryBookingException) return error.message;
    return '暂时无法连接图书馆，请检查网络后重试。';
  }

  Future<void> _read(
    Future<void> Function(LibraryBookingClient client) action,
    VoidCallback retry,
  ) async {
    if (_busy || !_checkAccount() || _client == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _retry = retry;
    });
    try {
      await action(_client!);
    } on Object catch (error) {
      if (_checkAccount()) setState(() => _error = _errorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadCatalog() => _read((client) async {
        final catalog = await client.loadCatalog();
        if (!_checkAccount()) return;
        setState(() {
          _catalog = catalog;
          _building = catalog.buildings.firstOrNull;
          _date = catalog.dates.firstOrNull;
          _resetRoom();
        });
        if (_building != null && _date != null) {
          final rooms = await client.loadRooms(
            buildingId: _building!.id,
            date: _date!,
          );
          if (_checkAccount()) setState(() => _rooms = rooms);
        }
      }, () => unawaited(_loadCatalog()));

  void _resetRoom() {
    _rooms = [];
    _room = null;
    _availability = null;
    _resetDraft();
  }

  void _resetDraft() {
    _start = null;
    _end = null;
    _participants.clear();
    _participantId.clear();
    _titleChoice = null;
    _title.clear();
    _content.clear();
    _submissionUncertain = false;
  }

  Future<void> _loadRooms() => _read((client) async {
        if (_building == null || _date == null) return;
        setState(_resetRoom);
        final rooms = await client.loadRooms(
          buildingId: _building!.id,
          date: _date!,
        );
        if (_checkAccount()) setState(() => _rooms = rooms);
      }, () => unawaited(_loadRooms()));

  Future<void> _loadAvailability(LibraryRoom room) => _read((client) async {
        if (_date == null) return;
        setState(() {
          _room = room;
          _availability = null;
          _resetDraft();
        });
        final availability = await client.loadAvailability(
          room: room,
          date: _date!,
        );
        if (!_checkAccount()) return;
        setState(() {
          _availability = availability;
          if (_mobile.text.isEmpty) _mobile.text = availability.mobile;
          final starts = _startOptions(availability);
          _start = starts.firstOrNull;
          if (_start != null) {
            _end = _endOptions(availability, _start!).firstOrNull;
          }
        });
      }, () => unawaited(_loadAvailability(room)));

  List<int> _startOptions(LibraryRoomAvailability availability) {
    if (!availability.canReserve || availability.unsupportedReason != null) {
      return [];
    }
    final result = <int>[];
    final step = availability.stepMinutes;
    if (step <= 0) return result;
    for (var value = ((availability.startMinute + step - 1) ~/ step) * step;
        value < availability.endMinute;
        value += step) {
      if (_endOptions(availability, value).isNotEmpty) result.add(value);
    }
    return result;
  }

  List<int> _endOptions(LibraryRoomAvailability availability, int start) {
    final result = <int>[];
    final step = availability.stepMinutes;
    if (step <= 0) return result;
    for (var value = start + step;
        value <= availability.endMinute;
        value += step) {
      if (availability.isRangeAvailable(start, value)) result.add(value);
    }
    return result;
  }

  String _time(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

  Future<T?> _choose<T>(
    String title,
    List<T> options,
    String Function(T value) label,
  ) =>
      showCupertinoModalPopup<T>(
        context: context,
        builder: (context) => CupertinoActionSheet(
          title: Text(title),
          actions: options
              .map((value) => CupertinoActionSheetAction(
                    onPressed: () => Navigator.of(context).pop(value),
                    child: Text(label(value)),
                  ))
              .toList(),
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ),
      );

  Future<void> _chooseBuilding() async {
    final value = await _choose(
      '选择馆区',
      _catalog!.buildings,
      (building) => building.name,
    );
    if (!mounted || value == null || value.id == _building?.id) return;
    setState(() => _building = value);
    await _loadRooms();
  }

  Future<void> _chooseDate() async {
    final value = await _choose('选择预约日期', _catalog!.dates, (date) => date);
    if (!mounted || value == null || value == _date) return;
    setState(() => _date = value);
    await _loadRooms();
  }

  Future<void> _chooseStart() async {
    final value = await _choose(
      '选择开始时间',
      _startOptions(_availability!),
      _time,
    );
    if (!mounted || value == null || value == _start) return;
    setState(() {
      _start = value;
      _end = _endOptions(_availability!, value).firstOrNull;
      _participants.clear();
      _submissionUncertain = false;
    });
  }

  Future<void> _chooseEnd() async {
    final value = await _choose(
      '选择结束时间',
      _endOptions(_availability!, _start!),
      _time,
    );
    if (!mounted || value == null || value == _end) return;
    setState(() {
      _end = value;
      _participants.clear();
      _submissionUncertain = false;
    });
  }

  Future<void> _addParticipant() async {
    if (_busy || _room == null || _start == null || _end == null) return;
    final studentId = _participantId.text.trim();
    if (studentId.isEmpty) {
      await _message('请填写成员学工号', '添加参与人后会核验该成员能否参与所选时段。');
      return;
    }
    if (studentId == _username) {
      await _message('已包含本人', '预约人数已包含你自己，请添加其他参与成员。');
      return;
    }
    await _read((client) async {
      final participant = await client.lookupParticipant(
        studentId: studentId,
        room: _room!,
        date: _date!,
        startMinute: _start!,
        endMinute: _end!,
      );
      if (!_checkAccount()) return;
      if (_participants.any((value) => value.id == participant.id)) {
        await _message('成员已添加', '请勿重复添加同一成员。');
        return;
      }
      setState(() {
        _participants.add(participant);
        _participantId.clear();
      });
    }, () => unawaited(_addParticipant()));
  }

  Future<void> _loadReservations({bool more = false}) => _read((client) async {
        final page = more ? _reservationPage + 1 : 1;
        final values = await client.loadReservations(page: page);
        if (!_checkAccount()) return;
        setState(() {
          final existing = more ? [..._reservations] : <LibraryReservation>[];
          final seen = existing.map((value) => value.id).toSet();
          final additional =
              values.where((value) => seen.add(value.id)).toList();
          _reservations = [...existing, ...additional];
          _reservationPage = page;
          _hasMore = values.length >= 10 && additional.isNotEmpty;
        });
      }, () => unawaited(_loadReservations(more: more)));

  Future<void> _message(String title, String message) =>
      showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );

  Future<void> _openOfficialSite() async {
    try {
      final opened = await launchUrl(
        Uri.parse('https://booking.lib.zju.edu.cn/h5/'),
        mode: LaunchMode.inAppBrowserView,
      );
      if (!opened && mounted) {
        await _message('暂时无法打开官网', '请在浏览器中访问 booking.lib.zju.edu.cn。');
      }
    } on Object {
      if (mounted) {
        await _message('暂时无法打开官网', '请在浏览器中访问 booking.lib.zju.edu.cn。');
      }
    }
  }

  Future<bool> _confirm(String title, String message, String action,
          {bool destructive = false}) async =>
      await showCupertinoDialog<bool>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('返回'),
            ),
            CupertinoDialogAction(
              isDestructiveAction: destructive,
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  String? _validateDraft() {
    final availability = _availability;
    if (availability == null || _start == null || _end == null) {
      return '请先选择可预约的研讨间和时段。';
    }
    if (availability.unsupportedReason != null) {
      return availability.unsupportedReason;
    }
    if (availability.requiresAttachment) return '此研讨间需要提交附件，暂不支持预约。';
    if (!availability.isRangeAvailable(_start!, _end!)) {
      return '所选时段不可预约，请重新选择。';
    }
    if (availability.titleChoices.isNotEmpty && _titleChoice == null) {
      return '请选择申请主题。';
    }
    if (availability.titleRequired &&
        _titleChoice == null &&
        _title.text.trim().isEmpty) {
      return '请填写申请主题。';
    }
    if (_content.text.trim().isEmpty) return '请填写申请内容。';
    if (_mobile.text.trim().isEmpty) return '请填写联系电话。';
    final count = _participants.length + 1;
    if (count < availability.minParticipants ||
        (availability.maxParticipants > 0 &&
            count > availability.maxParticipants)) {
      return '参与人数不符合此研讨间要求，请按页面提示添加成员。';
    }
    return null;
  }

  Future<void> _submit() async {
    if (_busy || _submissionUncertain || !_checkAccount()) return;
    final error = _validateDraft();
    if (error != null) {
      await _message('请完善预约信息', error);
      return;
    }
    var refreshReservations = false;
    setState(() => _busy = true);
    try {
      final confirmed = await _confirm(
        '确认预约',
        '${_room!.name}\n$_date ${_time(_start!)}–${_time(_end!)}\n'
            '共 ${_participants.length + 1} 人（含本人）\n'
            '请确认已阅读预约须知，并按图书馆规定签到和使用。',
        '提交预约',
      );
      if (!confirmed || !_checkAccount()) return;
      final message = await _client!.submit(LibraryBookingDraft(
        room: _room!,
        availability: _availability!,
        startMinute: _start!,
        endMinute: _end!,
        title: _titleChoice?.title ?? _title.text.trim(),
        titleChoice: _titleChoice,
        content: _content.text.trim(),
        mobile: _mobile.text.trim(),
        participants: List.unmodifiable(_participants),
        isPublic: _isPublic,
      ));
      if (!_checkAccount()) return;
      setState(() {
        _section = 1;
        _availability = null;
        _resetDraft();
      });
      refreshReservations = true;
      await _message('预约已提交', message.isEmpty ? '请在「我的预约」查看当前状态。' : message);
    } on Object catch (error) {
      if (!_checkAccount()) return;
      if (error is LibraryBookingException && error.outcomeUnknown) {
        setState(() {
          _submissionUncertain = true;
          _section = 1;
        });
        refreshReservations = true;
        await _message('预约结果待确认', '未能确认本次提交结果。请先查看「我的预约」确认结果，避免重复预约。');
      } else {
        await _message('预约未完成', _errorMessage(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (refreshReservations && mounted) await _loadReservations();
  }

  Future<void> _cancel(LibraryReservation reservation) async {
    if (_busy || !_checkAccount()) return;
    var refreshReservations = false;
    setState(() => _busy = true);
    try {
      final confirmed = await _confirm(
        '取消这条预约？',
        '${reservation.roomName}\n${reservation.date} '
            '${reservation.startTime}–${reservation.endTime}',
        '确认取消',
        destructive: true,
      );
      if (!confirmed || !_checkAccount()) return;
      final message = await _client!.cancel(reservation);
      if (!_checkAccount()) return;
      refreshReservations = true;
      await _message('预约已取消', message.isEmpty ? '预约状态将自动更新。' : message);
    } on Object catch (error) {
      if (!_checkAccount()) return;
      if (error is LibraryBookingException && error.outcomeUnknown) {
        setState(() => _uncertainCancellations.add(reservation.id));
        refreshReservations = true;
        await _message('取消结果待确认', '未能确认本次取消结果。请刷新「我的预约」查看最新状态，不要重复提交。');
      } else {
        await _message('取消未完成', _errorMessage(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (refreshReservations && mounted) await _loadReservations();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('研讨间预约'),
        trailing: _busy
            ? const CupertinoActivityIndicator()
            : CupertinoButton(
                key: const ValueKey('library-refresh'),
                padding: EdgeInsets.zero,
                onPressed: _accessMessage != null
                    ? null
                    : () => _section == 1
                        ? unawaited(_loadReservations())
                        : _room != null
                            ? unawaited(_loadAvailability(_room!))
                            : unawaited(_loadCatalog()),
                child: const Icon(CupertinoIcons.refresh, size: 22),
              ),
      ),
      backgroundColor: CupertinoColors.systemGroupedBackground,
      child: SafeArea(
        child: _accessMessage != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(_accessMessage!, textAlign: TextAlign.center),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 36),
                children: [
                  CupertinoSlidingSegmentedControl<int>(
                    key: const ValueKey('library-section-tabs'),
                    groupValue: _section,
                    children: const {
                      0: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text('预约研讨间'),
                      ),
                      1: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text('我的预约'),
                      ),
                    },
                    onValueChanged: (value) {
                      if (_busy || value == null || value == _section) return;
                      setState(() {
                        _section = value;
                        _error = null;
                      });
                      if (value == 1) unawaited(_loadReservations());
                    },
                  ),
                  const SizedBox(height: 16),
                  if (_error != null) _errorCard(),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('正在处理，请稍候…', textAlign: TextAlign.center),
                    ),
                  if (_section == 0)
                    ..._bookingWidgets()
                  else
                    ..._mineWidgets(),
                  CupertinoButton(
                    key: const ValueKey('library-seat-entry'),
                    onPressed: _busy
                        ? null
                        : () => Navigator.of(context).push(
                              CupertinoPageRoute<void>(
                                builder: (_) => LibrarySeatPage(
                                  scholar: widget.scholar,
                                  seatClientFactory: widget.seatClientFactory,
                                ),
                              ),
                            ),
                    child: const Text('切换到座位预约'),
                  ),
                  _note('需要附件的特殊申请和成员邀请可在图书馆官网处理，官网可能需要重新登录。'),
                  CupertinoButton(
                    onPressed: _busy ? null : _openOfficialSite,
                    child: const Text('打开图书馆官网'),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _panel(List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: CupertinoDynamicColor.resolve(
              CupertinoColors.secondarySystemGroupedBackground,
              context,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      );

  Widget _heading(String value) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      );

  Widget _note(String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          value,
          style: const TextStyle(
            color: CupertinoColors.secondaryLabel,
            fontSize: 13,
          ),
        ),
      );

  Widget _errorCard() => _panel([
        Text(_error!, style: const TextStyle(color: CupertinoColors.systemRed)),
        CupertinoButton(
          key: const ValueKey('library-retry'),
          onPressed: _busy ? null : _retry,
          child: const Text('重试'),
        ),
      ]);

  Widget _selection(
          String key, String label, String value, VoidCallback? onPressed) =>
      CupertinoButton(
        key: ValueKey(key),
        padding: const EdgeInsets.symmetric(vertical: 12),
        onPressed: _busy ? null : onPressed,
        child: Row(
          children: [
            Text(label, style: CupertinoTheme.of(context).textTheme.textStyle),
            const SizedBox(width: 12),
            Expanded(child: Text(value, textAlign: TextAlign.right)),
            const SizedBox(width: 6),
            const Icon(CupertinoIcons.chevron_down, size: 14),
          ],
        ),
      );

  List<Widget> _bookingWidgets() {
    final catalog = _catalog;
    if (catalog == null) return [];
    if (catalog.buildings.isEmpty || catalog.dates.isEmpty) {
      return [
        _panel([const Text('图书馆目前没有开放可预约的馆区或日期。')])
      ];
    }
    final availability = _availability;
    return [
      _panel([
        _selection('library-building', '馆区', _building?.name ?? '请选择',
            _chooseBuilding),
        _selection('library-date', '日期', _date ?? '请选择', _chooseDate),
        _note('可选日期与空闲情况由图书馆实时提供。'),
      ]),
      _panel([
        _heading('选择研讨间'),
        if (_rooms.isEmpty && !_busy) const Text('此馆区在所选日期暂无可预约研讨间。'),
        for (final room in _rooms)
          CupertinoButton(
            key: ValueKey('library-room-${room.id}'),
            padding: const EdgeInsets.symmetric(vertical: 12),
            onPressed: _busy || !room.canReserve
                ? null
                : () => unawaited(_loadAvailability(room)),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(room.name),
                      if (!room.canReserve) _note('暂不可预约'),
                    ],
                  ),
                ),
                Icon(
                  _room?.id == room.id
                      ? CupertinoIcons.check_mark_circled_solid
                      : CupertinoIcons.chevron_forward,
                  size: 20,
                ),
              ],
            ),
          ),
      ]),
      if (availability != null) ..._availabilityWidgets(availability),
    ];
  }

  List<Widget> _availabilityWidgets(LibraryRoomAvailability availability) {
    final unsupported = availability.unsupportedReason ??
        (availability.requiresAttachment ? '此研讨间要求上传附件，当前暂不支持预约。' : null);
    final count = _participants.length + 1;
    final maxParticipants = availability.maxParticipants;
    return [
      _panel([
        _heading(_room!.name),
        if (_room!.description.isNotEmpty) _note(_room!.description),
        if (availability.rules.isNotEmpty) ...[
          Text(
            availability.rules,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              color: CupertinoColors.secondaryLabel,
            ),
          ),
          CupertinoButton(
            key: const ValueKey('library-rules'),
            padding: const EdgeInsets.symmetric(vertical: 12),
            onPressed: () => Navigator.of(context).push(
              CupertinoPageRoute<void>(
                builder: (context) => CupertinoPageScaffold(
                  navigationBar: const CupertinoNavigationBar(
                    middle: Text('预约须知'),
                  ),
                  child: SafeArea(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Text(availability.rules),
                    ),
                  ),
                ),
              ),
            ),
            child: const Text('查看完整预约须知'),
          ),
        ],
        if (unsupported != null)
          Text(unsupported)
        else if (!availability.canReserve)
          const Text('当前账号无法预约此研讨间。')
        else if (_start == null || _end == null)
          const Text('此日期暂无符合要求的空闲时段，请换一天或选择其他房间。')
        else ...[
          _selection('library-start', '开始时间', _time(_start!), _chooseStart),
          _selection('library-end', '结束时间', _time(_end!), _chooseEnd),
          _note('预约时长：${_end! - _start!} 分钟。调整时段后需重新添加参与成员。'),
        ],
      ]),
      if (unsupported == null &&
          availability.canReserve &&
          _start != null &&
          _end != null) ...[
        _panel([
          _heading('参与成员'),
          Text('共 $count 人（含本人）'),
          _note(maxParticipants > 0
              ? '人数要求：${availability.minParticipants}–$maxParticipants 人，包含预约人。'
              : '至少 ${availability.minParticipants} 人，包含预约人。'),
          for (final participant in _participants)
            Row(
              children: [
                Expanded(child: Text(participant.name)),
                CupertinoButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _participants.remove(participant)),
                  child: const Text('移除'),
                ),
              ],
            ),
          if (maxParticipants <= 0 || count < maxParticipants) ...[
            CupertinoTextField(
              key: const ValueKey('library-participant-id'),
              controller: _participantId,
              enabled: !_busy,
              placeholder: '成员学工号',
              keyboardType: TextInputType.text,
              padding: const EdgeInsets.all(12),
              onSubmitted: (_) => unawaited(_addParticipant()),
            ),
            CupertinoButton(
              key: const ValueKey('library-add-participant'),
              onPressed: _busy ? null : _addParticipant,
              child: const Text('添加成员'),
            ),
          ],
        ]),
        _panel([
          _heading('预约信息'),
          if (availability.titleChoices.isNotEmpty)
            _selection('library-title', '申请主题', _titleChoice?.title ?? '请选择',
                () async {
              final value = await _choose('选择申请主题', availability.titleChoices,
                  (choice) => choice.title);
              if (mounted && value != null) {
                setState(() => _titleChoice = value);
              }
            })
          else if (availability.titleRequired)
            _field('library-title', '申请主题', _title),
          _field('library-content', '申请内容', _content, maxLines: 3),
          _field('library-mobile', '联系电话', _mobile,
              keyboardType: TextInputType.phone),
          Row(
            children: [
              const Expanded(child: Text('公开预约')),
              CupertinoSwitch(
                key: const ValueKey('library-public'),
                value: _isPublic,
                onChanged:
                    _busy ? null : (value) => setState(() => _isPublic = value),
              ),
            ],
          ),
          if (_submissionUncertain) _note('上一条预约结果尚未确认，请先查看「我的预约」，不要重复提交。'),
          const SizedBox(height: 12),
          CupertinoButton.filled(
            key: const ValueKey('library-submit'),
            onPressed: _busy || _submissionUncertain ? null : _submit,
            child: const Text('确认预约信息'),
          ),
        ]),
      ],
    ];
  }

  Widget _field(String key, String label, TextEditingController controller,
          {int maxLines = 1, TextInputType? keyboardType}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label),
            const SizedBox(height: 8),
            CupertinoTextField(
              key: ValueKey(key),
              controller: controller,
              enabled: !_busy,
              placeholder: '请填写$label',
              keyboardType: keyboardType,
              maxLines: maxLines,
              padding: const EdgeInsets.all(12),
            ),
          ],
        ),
      );

  List<Widget> _mineWidgets() => [
        if (_submissionUncertain)
          _panel([
            const Text('上次预约的提交结果尚未确认，请核对下方记录。若暂未出现，可稍后刷新查看。'),
          ]),
        if (_reservations.isEmpty && !_busy && _error == null)
          _panel([const Text('暂无研讨间预约。')]),
        for (final reservation in _reservations)
          _panel([
            _heading(reservation.roomName),
            Text('${reservation.date} '
                '${reservation.startTime}–${reservation.endTime}'),
            const SizedBox(height: 8),
            Text(reservation.status),
            if (_uncertainCancellations.contains(reservation.id))
              _note('取消结果待确认，请刷新查看最新状态。')
            else if (reservation.canCancel)
              CupertinoButton(
                key: ValueKey('library-cancel-${reservation.id}'),
                onPressed: _busy ? null : () => _cancel(reservation),
                child: const Text('取消预约',
                    style: TextStyle(color: CupertinoColors.systemRed)),
              )
            else if (reservation.cancellationReason?.isNotEmpty ?? false)
              _note(reservation.cancellationReason!),
          ]),
        if (_reservations.isNotEmpty && _hasMore)
          CupertinoButton(
            key: const ValueKey('library-load-more'),
            onPressed:
                _busy ? null : () => unawaited(_loadReservations(more: true)),
            child: const Text('加载更多'),
          ),
      ];
}
