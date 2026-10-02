import 'dart:async';

import 'package:celechron/http/zjuServices/library_booking.dart';
import 'package:celechron/model/scholar.dart';
import 'package:flutter/cupertino.dart';
import 'package:url_launcher/url_launcher.dart';

typedef LibrarySeatClientFactory = LibrarySeatBookingClient Function(
  String username,
  String password,
);

class LibrarySeatPage extends StatefulWidget {
  const LibrarySeatPage({
    super.key,
    required this.scholar,
    this.seatClientFactory,
  });

  final Scholar scholar;
  final LibrarySeatClientFactory? seatClientFactory;

  @override
  State<LibrarySeatPage> createState() => _LibrarySeatPageState();
}

class _LibrarySeatPageState extends State<LibrarySeatPage> {
  LibrarySeatBookingClient? _client;
  String? _username;
  String? _password;
  String? _accessMessage;
  String? _error;
  VoidCallback? _retry;
  LibraryCatalog? _catalog;
  LibraryBuilding? _building;
  String? _date;
  String _floor = '';
  List<LibrarySeatArea> _areas = [];
  LibrarySeatArea? _area;
  LibrarySeatAvailability? _availability;
  LibrarySeatSegment? _segment;
  List<LibrarySeat> _seats = [];
  LibrarySeat? _seat;
  List<LibrarySeatReservation> _reservations = [];
  final _search = TextEditingController();
  int _visibleSeatCount = 60;
  int _section = 0;
  int _reservationPage = 0;
  bool _hasMoreReservations = false;
  bool _busy = false;
  bool _submissionUncertain = false;
  final Set<String> _uncertainCancellations = {};

  @override
  void initState() {
    super.initState();
    final scholar = widget.scholar;
    if (!scholar.isLogan ||
        (scholar.username?.isEmpty ?? true) ||
        (scholar.password?.isEmpty ?? true)) {
      _accessMessage = '请先在设置中登录统一身份认证账号，再回来预约座位。';
      return;
    }
    if (scholar.username == '3200000000') {
      _accessMessage = '演示账号无法预约真实座位。请在设置中登录自己的账号。';
      return;
    }
    _username = scholar.username!;
    _password = scholar.password!;
    _client = widget.seatClientFactory?.call(_username!, _password!) ??
        LibraryBookingService(
          username: _username!,
          password: _password!,
          canUseSession: () => _accountMatches,
        );
    unawaited(_loadCatalog());
  }

  bool get _accountMatches =>
      mounted &&
      widget.scholar.isLogan &&
      widget.scholar.username == _username &&
      widget.scholar.password == _password;

  bool _checkAccount() {
    if (!mounted) return false;
    if (_accountMatches) return true;
    _client?.dispose();
    _client = null;
    setState(() {
      _accessMessage = '登录账号已变化，请返回后重新打开座位预约。';
      _reservations = [];
      _clearArea();
      _error = null;
    });
    return false;
  }

  @override
  void dispose() {
    _client?.dispose();
    _search.dispose();
    super.dispose();
  }

  String _errorText(Object error) =>
      error is LibraryBookingException ? error.message : '暂时无法连接图书馆，请检查网络后重试。';

  Future<void> _read(
    Future<void> Function(LibrarySeatBookingClient client) action,
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
      if (_checkAccount()) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _clearSeats() {
    _seats = [];
    _seat = null;
    _search.clear();
    _visibleSeatCount = 60;
    _submissionUncertain = false;
  }

  void _clearArea() {
    _area = null;
    _availability = null;
    _segment = null;
    _clearSeats();
  }

  Future<void> _loadCatalog({String? date, String? preferredBuildingId}) =>
      _read((client) async {
        final catalog = await client.loadSeatCatalog(date: date);
        if (!_checkAccount()) return;
        setState(() {
          _catalog = catalog;
          _building = catalog.buildings
                  .where((building) => building.id == preferredBuildingId)
                  .firstOrNull ??
              catalog.buildings.firstOrNull;
          _date =
              catalog.dates.contains(date) ? date : catalog.dates.firstOrNull;
          _areas = [];
          _floor = '';
          _clearArea();
        });
        if (_building == null || _date == null) return;
        final areas = await client.loadSeatAreas(
          buildingId: _building!.id,
          date: _date!,
        );
        if (_checkAccount()) setState(() => _areas = areas);
      },
          () => unawaited(_loadCatalog(
              date: date, preferredBuildingId: preferredBuildingId)));

  Future<void> _loadAreas() => _read((client) async {
        if (_building == null || _date == null) return;
        setState(() {
          _areas = [];
          _floor = '';
          _clearArea();
        });
        final areas = await client.loadSeatAreas(
          buildingId: _building!.id,
          date: _date!,
        );
        if (_checkAccount()) setState(() => _areas = areas);
      }, () => unawaited(_loadAreas()));

  Future<void> _loadAvailability(LibrarySeatArea area) => _read((client) async {
        setState(() {
          _clearArea();
          _area = area;
        });
        final availability = await client.loadSeatAvailability(area: area);
        if (!_checkAccount()) return;
        final day =
            availability.days.where((value) => value.date == _date).firstOrNull;
        final segment =
            availability.canReserve && availability.unsupportedReason == null
                ? day?.segments.where((value) => value.canReserve).firstOrNull
                : null;
        setState(() {
          _availability = availability;
          _segment = segment;
        });
        if (segment == null) return;
        final seats = await client.loadSeats(area: area, segment: segment);
        if (_checkAccount()) setState(() => _seats = seats);
      }, () => unawaited(_loadAvailability(area)));

  Future<void> _loadSeats(LibrarySeatSegment segment) => _read((client) async {
        final area = _area;
        if (area == null) return;
        setState(() {
          _segment = segment;
          _clearSeats();
        });
        final seats = await client.loadSeats(area: area, segment: segment);
        if (_checkAccount()) setState(() => _seats = seats);
      }, () => unawaited(_loadSeats(segment)));

  Future<void> _loadReservations({bool more = false}) => _read((client) async {
        final page = more ? _reservationPage + 1 : 1;
        final values = await client.loadSeatReservations(page: page);
        if (!_checkAccount()) return;
        setState(() {
          final existing =
              more ? [..._reservations] : <LibrarySeatReservation>[];
          final ids = existing.map((value) => value.id).toSet();
          final additional =
              values.where((value) => ids.add(value.id)).toList();
          _reservations = [...existing, ...additional];
          _reservationPage = page;
          _hasMoreReservations = values.length >= 10 && additional.isNotEmpty;
        });
      }, () => unawaited(_loadReservations(more: more)));

  Future<T?> _choose<T>(
          String title, List<T> values, String Function(T value) label) =>
      showCupertinoModalPopup<T>(
        context: context,
        builder: (context) => CupertinoActionSheet(
          title: Text(title),
          actions: values
              .map((value) => CupertinoActionSheetAction(
                    onPressed: () => Navigator.of(context).pop(value),
                    child: Text(label(value)),
                  ))
              .toList(),
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('返回'),
          ),
        ),
      );

  Future<void> _chooseDate() async {
    final value = await _choose('选择预约日期', _catalog!.dates, (date) => date);
    if (!mounted || value == null || value == _date) return;
    final buildingId = _building?.id;
    setState(() {
      _date = value;
      _areas = [];
      _floor = '';
      _clearArea();
    });
    await _loadCatalog(date: value, preferredBuildingId: buildingId);
  }

  Future<void> _chooseBuilding() async {
    final value =
        await _choose('选择馆区', _catalog!.buildings, (building) => building.name);
    if (!mounted || value == null || value.id == _building?.id) return;
    setState(() => _building = value);
    await _loadAreas();
  }

  Future<void> _chooseFloor() async {
    final values = [
      '',
      ..._areas
          .map((area) => area.floorName)
          .where((value) => value.isNotEmpty)
          .toSet(),
    ];
    final value = await _choose(
        '选择楼层', values, (floor) => floor.isEmpty ? '全部楼层' : floor);
    if (!mounted || value == null || value == _floor) return;
    setState(() {
      _floor = value;
      _clearArea();
    });
  }

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

  Future<void> _write({
    required String title,
    required String detail,
    required String confirmLabel,
    required Future<String> Function() action,
    LibrarySeatReservation? cancellation,
  }) async {
    if (_busy || !_checkAccount()) return;
    var refresh = false;
    setState(() => _busy = true);
    try {
      final confirmed = await showCupertinoDialog<bool>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(title),
          content: Text(detail),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('返回'),
            ),
            CupertinoDialogAction(
              isDestructiveAction: cancellation != null,
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      );
      if (confirmed != true || !_checkAccount()) return;
      final message = await action();
      if (!_checkAccount()) return;
      setState(() {
        _section = 1;
        _seat = null;
      });
      refresh = true;
      await _message(cancellation == null ? '预约已提交' : '预约已取消',
          message.isEmpty ? '请在「我的座位」查看最新状态。' : message);
    } on Object catch (error) {
      if (!_checkAccount()) return;
      if (error is LibraryBookingException && error.outcomeUnknown) {
        setState(() {
          _section = 1;
          if (cancellation == null) {
            _submissionUncertain = true;
          } else {
            _uncertainCancellations.add(cancellation.id);
          }
        });
        refresh = true;
        await _message(
          cancellation == null ? '预约结果待确认' : '取消结果待确认',
          '未能确认本次操作结果。请先查看「我的座位」确认结果，不要重复提交。',
        );
      } else {
        await _message(
            cancellation == null ? '预约未完成' : '取消未完成', _errorText(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (refresh && mounted) await _loadReservations();
  }

  Future<void> _submit() async {
    final area = _area;
    final segment = _segment;
    final seat = _seat;
    if (_busy ||
        _submissionUncertain ||
        area == null ||
        segment == null ||
        seat == null ||
        !seat.canReserve ||
        !segment.canReserve) {
      return;
    }
    await _write(
      title: '确认座位预约',
      detail: '${_building?.name ?? ''} · ${area.floorName} · ${area.name}\n'
          '座位：${seat.name}\n${segment.date} ${segment.startTime}–${segment.endTime}\n'
          '请确认已阅读预约须知，到馆后按图书馆要求签到。',
      confirmLabel: '提交预约',
      action: () => _client!.submitSeat(
          LibrarySeatDraft(area: area, segment: segment, seat: seat)),
    );
  }

  Future<void> _cancel(LibrarySeatReservation reservation) async {
    if (!reservation.canCancel ||
        _uncertainCancellations.contains(reservation.id)) {
      return;
    }
    await _write(
      title: '取消这条预约？',
      detail: '${reservation.areaName} · ${reservation.seatName}\n'
          '${reservation.date} ${reservation.startTime}–${reservation.endTime}',
      confirmLabel: '确认取消',
      cancellation: reservation,
      action: () => _client!.cancelSeat(reservation),
    );
  }

  Future<void> _openOfficialSite() async {
    try {
      final opened = await launchUrl(
          Uri.https('booking.lib.zju.edu.cn', '/h5/'),
          mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        await _message('无法打开官网', '请在浏览器访问 m.lib.zju.edu.cn。');
      }
    } on Object {
      if (mounted) await _message('无法打开官网', '请在浏览器访问 m.lib.zju.edu.cn。');
    }
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          middle: const Text('座位预约'),
          trailing: _busy
              ? const CupertinoActivityIndicator()
              : CupertinoButton(
                  key: const ValueKey('seat-refresh'),
                  padding: EdgeInsets.zero,
                  onPressed: _accessMessage != null
                      ? null
                      : () => _section == 1
                          ? unawaited(_loadReservations())
                          : _area != null
                              ? unawaited(_loadAvailability(_area!))
                              : unawaited(_loadCatalog(
                                  date: _date,
                                  preferredBuildingId: _building?.id)),
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
              : Column(children: [
                  Expanded(
                      child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 36),
                    children: [
                      CupertinoSlidingSegmentedControl<int>(
                        key: const ValueKey('seat-section-tabs'),
                        groupValue: _section,
                        children: const {0: Text('预约座位'), 1: Text('我的座位')},
                        onValueChanged: (value) {
                          if (_busy || value == null || value == _section) {
                            return;
                          }
                          setState(() {
                            _section = value;
                            _error = null;
                          });
                          if (value == 1) unawaited(_loadReservations());
                        },
                      ),
                      const SizedBox(height: 16),
                      if (_busy)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('正在处理，请稍候…', textAlign: TextAlign.center),
                        ),
                      if (_error != null)
                        _panel([
                          Text(_error!,
                              style: const TextStyle(
                                  color: CupertinoColors.systemRed)),
                          CupertinoButton(
                            key: const ValueKey('seat-retry'),
                            onPressed: _busy ? null : _retry,
                            child: const Text('重试'),
                          ),
                        ]),
                      if (_section == 0)
                        ..._bookingWidgets()
                      else
                        ..._mineWidgets(),
                      _note('请按图书馆要求到场签到。扫码签到、暂离和签退请使用官方渠道，官网可能需要重新登录。'),
                      CupertinoButton(
                        onPressed: _busy ? null : _openOfficialSite,
                        child: const Text('打开图书馆官网'),
                      ),
                    ],
                  )),
                  if (_section == 0 && _segment != null) _submissionBar(),
                ]),
        ),
      );

  Widget _panel(List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: CupertinoDynamicColor.resolve(
                CupertinoColors.secondarySystemGroupedBackground, context),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children),
        ),
      );

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
      );

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(text,
            style: const TextStyle(
                fontSize: 13, color: CupertinoColors.secondaryLabel)),
      );

  Widget _selection(
          String key, String label, String value, VoidCallback action) =>
      CupertinoButton(
        key: ValueKey(key),
        padding: const EdgeInsets.symmetric(vertical: 12),
        onPressed: _busy ? null : action,
        child: Row(children: [
          Text(label, style: CupertinoTheme.of(context).textTheme.textStyle),
          const SizedBox(width: 12),
          Expanded(child: Text(value, textAlign: TextAlign.right)),
          const SizedBox(width: 6),
          const Icon(CupertinoIcons.chevron_down, size: 14),
        ]),
      );

  List<Widget> _bookingWidgets() {
    final catalog = _catalog;
    if (catalog == null) return [];
    if (catalog.dates.isEmpty || catalog.buildings.isEmpty) {
      return [
        _panel([const Text('图书馆目前没有开放可预约的馆区或日期。')])
      ];
    }
    final areas = _areas
        .where((area) => _floor.isEmpty || area.floorName == _floor)
        .toList();
    return [
      _panel([
        _selection('seat-date', '日期', _date ?? '请选择', _chooseDate),
        _selection(
            'seat-building', '馆区', _building?.name ?? '请选择', _chooseBuilding),
        if (_areas.isNotEmpty)
          _selection('seat-floor', '楼层', _floor.isEmpty ? '全部楼层' : _floor,
              _chooseFloor),
      ]),
      _panel([
        _heading('选择阅览区域'),
        if (areas.isEmpty && !_busy && _error == null)
          const Text('所选馆区和日期暂无可预约区域。'),
        for (final area in areas)
          CupertinoButton(
            key: ValueKey('seat-area-${area.id}'),
            padding: const EdgeInsets.symmetric(vertical: 12),
            onPressed:
                _busy || !area.canReserve || area.unsupportedReason != null
                    ? null
                    : () => unawaited(_loadAvailability(area)),
            child: Row(children: [
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(area.name),
                    if (area.floorName.isNotEmpty) _note(area.floorName),
                    if (area.unsupportedReason != null)
                      _note(area.unsupportedReason!)
                    else if (!area.canReserve)
                      _note('暂不可预约'),
                  ])),
              Icon(
                  _area?.id == area.id
                      ? CupertinoIcons.check_mark_circled_solid
                      : CupertinoIcons.chevron_forward,
                  size: 20),
            ]),
          ),
      ]),
      if (_availability != null) ..._availabilityWidgets(_availability!),
    ];
  }

  List<Widget> _availabilityWidgets(LibrarySeatAvailability availability) {
    final segments = availability.days
            .where((day) => day.date == _date)
            .firstOrNull
            ?.segments ??
        <LibrarySeatSegment>[];
    return [
      _panel([
        _heading('选择预约时段'),
        if (availability.unsupportedReason != null)
          Text(availability.unsupportedReason!)
        else if (!availability.canReserve)
          const Text('当前账号无法预约此区域。')
        else if (segments.isEmpty)
          const Text('此区域在所选日期暂无预约时段，请选择其他日期或区域。')
        else ...[
          _note('请选择图书馆提供的固定时段。座位状态随所选时段更新。'),
          for (final segment in segments)
            CupertinoButton(
              key: ValueKey('seat-segment-${segment.id}'),
              onPressed: _busy || !segment.canReserve
                  ? null
                  : () => unawaited(_loadSeats(segment)),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${segment.startTime}–${segment.endTime}'),
                      if (segment.unavailableReason?.isNotEmpty ?? false)
                        _note(segment.unavailableReason!)
                      else if (!segment.canReserve)
                        _note('暂不可预约'),
                    ],
                  ),
                ),
                if (_segment?.id == segment.id)
                  const Icon(CupertinoIcons.check_mark_circled_solid, size: 20),
              ]),
            ),
        ],
        if (availability.rules.isNotEmpty) ...[
          Text(availability.rules,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 13, color: CupertinoColors.secondaryLabel)),
          CupertinoButton(
            key: const ValueKey('seat-rules'),
            onPressed: () =>
                Navigator.of(context).push(CupertinoPageRoute<void>(
              builder: (context) => CupertinoPageScaffold(
                navigationBar:
                    const CupertinoNavigationBar(middle: Text('座位预约须知')),
                child: SafeArea(
                    child: SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: Text(availability.rules))),
              ),
            )),
            child: const Text('查看完整预约须知'),
          ),
        ],
      ]),
      if (_segment != null) _seatPanel(),
    ];
  }

  Widget _seatPanel() {
    final query = _search.text.trim().toLowerCase();
    final matches = _seats
        .where((seat) =>
            query.isEmpty ||
            seat.name.toLowerCase().contains(query) ||
            seat.labels.any((label) => label.toLowerCase().contains(query)))
        .toList();
    return _panel([
      _heading('选择座位'),
      if (!_busy && _error == null)
        _note('当前时段 ${_seats.where((seat) => seat.canReserve).length} 个座位可预约'),
      CupertinoSearchTextField(
        key: const ValueKey('seat-search'),
        controller: _search,
        enabled: !_busy,
        placeholder: '搜索座位号或设施',
        onChanged: (_) => setState(() => _visibleSeatCount = 60),
      ),
      const SizedBox(height: 12),
      if (matches.isEmpty && !_busy && _error == null) const Text('没有符合条件的座位。'),
      for (final seat in matches.take(_visibleSeatCount))
        CupertinoButton(
          key: ValueKey('seat-item-${seat.id}'),
          padding: const EdgeInsets.symmetric(vertical: 10),
          onPressed: _busy || !seat.canReserve
              ? null
              : () => setState(() {
                    if (_seat?.id != seat.id) _submissionUncertain = false;
                    _seat = seat;
                  }),
          child: Row(children: [
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(seat.name),
                  _note(seat.status.isEmpty
                      ? (seat.canReserve ? '可预约' : '暂不可预约')
                      : seat.status),
                  if (seat.labels.isNotEmpty) _note(seat.labels.join(' · ')),
                ])),
            if (_seat?.id == seat.id)
              const Icon(CupertinoIcons.check_mark_circled_solid, size: 20),
          ]),
        ),
      if (matches.length > _visibleSeatCount)
        CupertinoButton(
          onPressed:
              _busy ? null : () => setState(() => _visibleSeatCount += 60),
          child: const Text('显示更多座位'),
        ),
    ]);
  }

  Widget _submissionBar() => Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: CupertinoDynamicColor.resolve(
              CupertinoColors.secondarySystemGroupedBackground, context),
          border: const Border(
              top: BorderSide(color: CupertinoColors.separator, width: 0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_seat == null ? '请选择座位' : '已选座位：${_seat!.name}'),
            _note(
                '${_segment!.date} ${_segment!.startTime}–${_segment!.endTime}'),
            if (_submissionUncertain) _note('上一条预约结果尚未确认，请先查看「我的座位」，不要重复提交。'),
            CupertinoButton.filled(
              key: const ValueKey('seat-submit'),
              onPressed: _busy || _seat == null || _submissionUncertain
                  ? null
                  : _submit,
              child: const Text('确认座位预约信息'),
            ),
          ],
        ),
      );

  List<Widget> _mineWidgets() => [
        if (_submissionUncertain)
          _panel([const Text('上次预约的提交结果尚未确认，请核对下方记录。若暂未出现，可稍后刷新查看。')]),
        if (_reservations.isEmpty && !_busy && _error == null)
          _panel([const Text('暂无座位预约。')]),
        for (final reservation in _reservations)
          _panel([
            _heading('${reservation.areaName} · ${reservation.seatName}'),
            Text(
                '${reservation.date} ${reservation.startTime}–${reservation.endTime}'),
            const SizedBox(height: 8),
            Text(reservation.status),
            if (_uncertainCancellations.contains(reservation.id))
              _note('取消结果待确认，请刷新查看最新状态。')
            else if (reservation.canCancel)
              CupertinoButton(
                key: ValueKey('seat-cancel-${reservation.id}'),
                onPressed: _busy ? null : () => unawaited(_cancel(reservation)),
                child: const Text('取消预约',
                    style: TextStyle(color: CupertinoColors.systemRed)),
              )
            else if (reservation.cancellationReason?.isNotEmpty ?? false)
              _note(reservation.cancellationReason!),
          ]),
        if (_hasMoreReservations)
          CupertinoButton(
            key: const ValueKey('seat-load-more'),
            onPressed:
                _busy ? null : () => unawaited(_loadReservations(more: true)),
            child: const Text('加载更多'),
          ),
      ];
}
