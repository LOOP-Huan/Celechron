import 'dart:async';

import 'package:celechron/design/liquid_glass.dart';
import 'package:celechron/http/zjuServices/library_booking.dart';
import 'package:celechron/model/scholar.dart';
import 'package:flutter/cupertino.dart';
import 'package:url_launcher/url_launcher.dart';

import 'library_booking_widgets.dart';

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
  final _scroll = ScrollController();
  static const _seatsPerPage = 12;
  int _seatPage = 0;
  int _bookingStep = 0;
  bool _hasLoadedSeats = false;
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
    _scroll.dispose();
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
    _seatPage = 0;
    _hasLoadedSeats = false;
  }

  void _clearArea() {
    _area = null;
    _bookingStep = 0;
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
        if (_checkAccount()) {
          setState(() {
            _areas = areas;
            _floor = areas.firstOrNull?.floorName ?? '';
          });
        }
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
        if (_checkAccount()) {
          setState(() {
            _areas = areas;
            _floor = areas.firstOrNull?.floorName ?? '';
          });
        }
      }, () => unawaited(_loadAreas()));

  Future<void> _loadAvailability(LibrarySeatArea area,
      {bool preserveSelection = false}) {
    final previousSegment = preserveSelection ? _segment : null;
    final previousSeat = preserveSelection ? _seat : null;
    final previousSearch = preserveSelection ? _search.text : '';
    final previousPage = preserveSelection ? _seatPage : 0;
    return _read((client) async {
      setState(() {
        _clearArea();
        _area = area;
        _bookingStep = 1;
      });
      final availability = await client.loadSeatAvailability(area: area);
      if (!_checkAccount()) return;
      final day =
          availability.days.where((value) => value.date == _date).firstOrNull;
      final segment = availability.canReserve &&
              availability.unsupportedReason == null
          ? day?.segments
              .where((value) =>
                  value.canReserve &&
                  (previousSegment == null || value.id == previousSegment.id))
              .firstOrNull
          : null;
      setState(() {
        _availability = availability;
        _segment = segment;
      });
      if (segment == null) return;
      final seats = await client.loadSeats(area: area, segment: segment);
      if (_checkAccount()) {
        setState(() {
          _seats = seats;
          _hasLoadedSeats = true;
          _seat = seats
              .where(
                  (value) => value.canReserve && value.id == previousSeat?.id)
              .firstOrNull;
          _search.text = previousSearch;
          _seatPage = previousPage;
        });
      }
    },
        () => unawaited(
            _loadAvailability(area, preserveSelection: preserveSelection)));
  }

  Future<void> _loadSeats(LibrarySeatSegment segment) => _read((client) async {
        final area = _area;
        if (area == null) return;
        setState(() {
          _segment = segment;
          _clearSeats();
        });
        final seats = await client.loadSeats(area: area, segment: segment);
        if (_checkAccount()) {
          setState(() {
            _seats = seats;
            _hasLoadedSeats = true;
          });
        }
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

  void _changeFloor(String value) {
    if (_busy || value == _floor) return;
    setState(() {
      _floor = value;
      _clearArea();
    });
  }

  void _resetScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  void _openArea(LibrarySeatArea area) {
    if (_busy) return;
    if (_area?.id == area.id &&
        _availability != null &&
        (_segment == null || _hasLoadedSeats)) {
      setState(() => _bookingStep = 1);
    } else {
      unawaited(_loadAvailability(area));
    }
    _resetScroll();
  }

  void _backToAreas() {
    if (_busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _bookingStep = 0;
      _error = null;
    });
    _resetScroll();
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
        _bookingStep = 0;
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
          '${reservation.date} ${reservation.startTime}–${reservation.endTime}'
          '${reservation.cancellationWarning.isEmpty ? '' : '\n\n${reservation.cancellationWarning}'}',
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

  void _refresh() {
    if (_busy || _accessMessage != null) return;
    if (_section == 1) {
      unawaited(_loadReservations());
    } else if (_bookingStep == 1 && _area != null) {
      unawaited(_loadAvailability(_area!, preserveSelection: true));
    } else {
      unawaited(_loadCatalog(date: _date, preferredBuildingId: _building?.id));
    }
  }

  void _showRules() {
    if (_busy) return;
    final rules = _availability?.rules.trim() ?? '';
    Navigator.of(context).push(CupertinoPageRoute<void>(
      builder: (context) => GlassPageScaffold(
        navigationBar: CupertinoNavigationBar(
          backgroundColor:
              CupertinoDynamicColor.resolve(GlassPalette.barColor, context),
          border: null,
          middle: const Text('座位预约须知'),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Text(rules.isEmpty
                ? '请选择图书馆提供的预约时段。预约完成后，请在「我的座位」核对结果，并按图书馆要求到场签到。'
                : rules),
          ),
        ),
      ),
    ));
  }

  Future<void> _showMore() async {
    if (_busy) return;
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: const Text('图书馆服务'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop('official'),
            child: const Text('打开图书馆官网'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop('instructions'),
            child: const Text('签到与使用说明'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('返回'),
        ),
      ),
    );
    if (!mounted || _busy || action == null) return;
    if (action == 'official') {
      await _openOfficialSite();
    } else {
      await _message('签到与使用说明', '请按图书馆要求到场签到。扫码签到、暂离和签退请使用官方渠道，官网可能需要重新登录。');
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_busy &&
            !(_accessMessage == null && _section == 0 && _bookingStep == 1),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop &&
              !_busy &&
              _accessMessage == null &&
              _section == 0 &&
              _bookingStep == 1) {
            _backToAreas();
          }
        },
        child: GlassPageScaffold(
          navigationBar: CupertinoNavigationBar(
            backgroundColor:
                CupertinoDynamicColor.resolve(GlassPalette.barColor, context),
            border: null,
            automaticallyImplyLeading: false,
            leading: (_accessMessage == null &&
                        _section == 0 &&
                        _bookingStep == 1) ||
                    Navigator.of(context).canPop()
                ? CupertinoButton(
                    key: const ValueKey('seat-navigation-back'),
                    padding: EdgeInsets.zero,
                    onPressed: _busy
                        ? null
                        : () {
                            if (_accessMessage == null &&
                                _section == 0 &&
                                _bookingStep == 1) {
                              _backToAreas();
                            } else {
                              Navigator.of(context).maybePop();
                            }
                          },
                    child: Semantics(
                        label: '返回',
                        child:
                            const Icon(CupertinoIcons.chevron_back, size: 22)),
                  )
                : null,
            middle: const Text('座位预约'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (_busy)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: CupertinoActivityIndicator(),
                )
              else
                CupertinoButton(
                  key: const ValueKey('seat-refresh'),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  onPressed: _accessMessage != null ? null : _refresh,
                  child: Semantics(
                      label: '刷新',
                      child: const Icon(CupertinoIcons.refresh, size: 21)),
                ),
              CupertinoButton(
                key: const ValueKey('seat-more'),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                onPressed: _busy ? null : _showMore,
                child: Semantics(
                    label: '更多',
                    child: const Icon(CupertinoIcons.ellipsis, size: 22)),
              ),
            ]),
          ),
          child: SafeArea(
            child: _accessMessage != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(_accessMessage!, textAlign: TextAlign.center),
                    ),
                  )
                : Column(children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                      child: SizedBox(
                        width: double.infinity,
                        child: GlassSurface(
                          borderRadius: 22,
                          padding: const EdgeInsets.all(3),
                          child: CupertinoSlidingSegmentedControl<int>(
                            backgroundColor: CupertinoColors.transparent,
                            thumbColor: GlassPalette.surfaceColor(context),
                            key: const ValueKey('seat-section-tabs'),
                            groupValue: _section,
                            children: const {
                              0: Text('预约座位'),
                              1: Text('我的座位'),
                            },
                            onValueChanged: (value) {
                              if (_busy || value == null || value == _section) {
                                return;
                              }
                              FocusManager.instance.primaryFocus?.unfocus();
                              setState(() {
                                _section = value;
                                _error = null;
                              });
                              _resetScroll();
                              if (value == 1) unawaited(_loadReservations());
                            },
                          ),
                        ),
                      ),
                    ),
                    if (_section == 0 &&
                        MediaQuery.viewInsetsOf(context).bottom == 0)
                      LibraryStepHeader(
                        key: const ValueKey('seat-step-header'),
                        steps: const ['选择阅览区', '选择时段和座位'],
                        currentStep: _bookingStep,
                        showBackButton: false,
                        onBack:
                            _bookingStep == 1 && !_busy ? _backToAreas : null,
                      ),
                    Expanded(
                      child: ListView(
                        key: const ValueKey('seat-content'),
                        controller: _scroll,
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        children: [
                          if (_busy)
                            const Padding(
                              padding: EdgeInsets.all(12),
                              child: Text('正在处理，请稍候…',
                                  textAlign: TextAlign.center),
                            ),
                          if (_error != null)
                            _panel([
                              Text(_error!,
                                  style: TextStyle(
                                      color: CupertinoDynamicColor.resolve(
                                          CupertinoColors.systemRed, context))),
                              CupertinoButton(
                                key: const ValueKey('seat-retry'),
                                onPressed: _busy ? null : _retry,
                                child: const Text('重试'),
                              ),
                            ]),
                          if (_section == 0)
                            ...(_bookingStep == 0
                                ? _directoryWidgets()
                                : _selectionWidgets())
                          else
                            ..._mineWidgets(),
                        ],
                      ),
                    ),
                    if (_section == 0 &&
                        _bookingStep == 1 &&
                        _segment != null &&
                        MediaQuery.viewInsetsOf(context).bottom == 0)
                      _submissionBar(),
                  ]),
          ),
        ),
      );

  Widget _panel(List<Widget> children) => GlassSurface(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
      );

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 13,
                color: CupertinoDynamicColor.resolve(
                    CupertinoColors.secondaryLabel, context))),
      );

  Widget _selection(
          String key, String label, String value, VoidCallback action) =>
      CupertinoButton(
        key: ValueKey(key),
        padding: const EdgeInsets.symmetric(vertical: 10),
        onPressed: _busy ? null : action,
        child: Row(children: [
          Text(label, style: CupertinoTheme.of(context).textTheme.textStyle),
          const SizedBox(width: 12),
          Expanded(child: Text(value, textAlign: TextAlign.right)),
          const SizedBox(width: 6),
          const Icon(CupertinoIcons.chevron_down, size: 14),
        ]),
      );

  // Partition into fresh lists so each group keeps the server's order.
  List<T> _availableFirst<T>(Iterable<T> values, bool Function(T) available) =>
      [
        ...values.where(available),
        ...values.where((value) => !available(value)),
      ];

  String _seatCountsLabel(int? free, int? total) =>
      '${free ?? '—'}/${total ?? '—'}';

  ({int? free, int? total}) _floorSeatCounts(List<LibrarySeatArea> areas) {
    final actualFloors = <String, Map<String, LibrarySeatArea>>{};
    for (final area in areas.where((area) => area.typeCategory == '1')) {
      actualFloors
          .putIfAbsent(area.floorId, () => {})
          .putIfAbsent(area.id, () => area);
    }
    int? sumComplete(Iterable<int?> values) {
      if (values.isEmpty || values.any((value) => value == null)) return null;
      return values.fold<int>(0, (sum, value) => sum + value!);
    }

    ({int? free, int? total}) consistent(int? free, int? total) =>
        free != null && total != null && free > total
            ? (free: null, total: null)
            : (free: free, total: total);

    final counts = actualFloors.entries.map((entry) {
      int? count(bool free) {
        // Official storey counts are repeated on areas: use once per ID.
        final official = entry.key.isEmpty
            ? null
            : entry.value.values
                .map(
                    (area) => free ? area.floorFreeSeats : area.floorTotalSeats)
                .whereType<int>()
                .firstOrNull;
        return official ??
            sumComplete(entry.value.values
                .map((area) => free ? area.freeSeats : area.totalSeats));
      }

      return consistent(count(true), count(false));
    }).toList();
    return consistent(
      sumComplete(counts.map((count) => count.free)),
      sumComplete(counts.map((count) => count.total)),
    );
  }

  List<Widget> _directoryWidgets() {
    final catalog = _catalog;
    if (catalog == null) return [];
    if (catalog.dates.isEmpty || catalog.buildings.isEmpty) {
      return [
        _panel([const Text('图书馆目前没有开放可预约的馆区或日期。')])
      ];
    }
    final floors = <String, List<LibrarySeatArea>>{};
    for (final area in _areas) {
      floors.putIfAbsent(area.floorName, () => []).add(area);
    }
    final areas = _availableFirst(
      floors[_floor] ?? <LibrarySeatArea>[],
      (area) => area.canReserve && area.unsupportedReason == null,
    );
    return [
      _panel([
        _selection(
            'seat-building', '馆区', _building?.name ?? '请选择', _chooseBuilding),
        _selection('seat-date', '日期', _date ?? '请选择', _chooseDate),
      ]),
      if (floors.isNotEmpty) ...[
        LibraryFloorTabs(
          key: const ValueKey('seat-floor-tabs'),
          floors: floors.entries.map((entry) {
            final counts = _floorSeatCounts(entry.value);
            return LibraryFloorOption(
              id: entry.key,
              label: entry.key.isEmpty ? '未标注楼层' : entry.key,
              availableCount: counts.free,
              count: counts.total,
            );
          }).toList(),
          selectedId: _floor,
          onChanged: _busy ? null : _changeFloor,
        ),
        _note('可用/总数 · 按所选日期统计，具体时段以选座结果为准'),
        const SizedBox(height: 4),
      ],
      _panel([
        if (areas.isEmpty && !_busy && _error == null)
          const Text('所选馆区和日期暂无可预约区域。'),
        for (final area in areas)
          CupertinoButton(
            key: ValueKey('seat-area-${area.id}'),
            padding: const EdgeInsets.symmetric(vertical: 12),
            onPressed:
                _busy || !area.canReserve || area.unsupportedReason != null
                    ? null
                    : () => _openArea(area),
            child: Row(children: [
              Expanded(
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(area.name),
                  if (area.typeCategory == '1')
                    _note(
                        '可用/总数 · ${_seatCountsLabel(area.freeSeats, area.totalSeats)}'),
                  if (area.unsupportedReason != null)
                    _note(area.unsupportedReason!)
                  else if (!area.canReserve)
                    _note('暂不可预约'),
                ],
              )),
              const SizedBox(width: 8),
              Icon(
                  _area?.id == area.id
                      ? CupertinoIcons.check_mark_circled_solid
                      : CupertinoIcons.chevron_forward,
                  size: 20),
            ]),
          ),
      ]),
    ];
  }

  List<Widget> _selectionWidgets() {
    final area = _area;
    if (area == null) return [];
    final availability = _availability;
    final segments = availability?.days
            .where((day) => day.date == _date)
            .firstOrNull
            ?.segments ??
        <LibrarySeatSegment>[];
    return [
      _panel([
        Row(children: [
          Expanded(
              child: Text(area.name,
                  style: const TextStyle(fontWeight: FontWeight.w600))),
          CupertinoButton(
            key: const ValueKey('seat-rules'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            onPressed: _busy ? null : _showRules,
            child: Semantics(
                label: '查看预约须知',
                child: const Text('须知', style: TextStyle(fontSize: 14))),
          ),
        ]),
        _note([_building?.name, area.floorName, _date]
            .whereType<String>()
            .where((text) => text.isNotEmpty)
            .join(' · ')),
        if (availability != null) ...[
          const SizedBox(height: 4),
          if (availability.unsupportedReason != null)
            Text(availability.unsupportedReason!)
          else if (!availability.canReserve)
            const Text('当前账号无法预约此区域。')
          else if (segments.isEmpty)
            const Text('所选日期暂无预约时段，请返回选择其他日期或阅览区。')
          else
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final segment in segments)
                Semantics(
                  selected: _segment?.id == segment.id,
                  child: DecoratedBox(
                    decoration: GlassPalette.decoration(
                      context,
                      radius: 16,
                      selected: _segment?.id == segment.id,
                    ),
                    child: CupertinoButton(
                      key: ValueKey('seat-segment-${segment.id}'),
                      borderRadius: BorderRadius.circular(16),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 9),
                      onPressed: _busy || !segment.canReserve
                          ? null
                          : () {
                              if (_segment?.id != segment.id) {
                                unawaited(_loadSeats(segment));
                              }
                            },
                      child: Text('${segment.startTime}–${segment.endTime}',
                          style: TextStyle(
                              fontSize: 14,
                              color: CupertinoDynamicColor.resolve(
                                  _busy || !segment.canReserve
                                      ? CupertinoColors.secondaryLabel
                                      : _segment?.id == segment.id
                                          ? GlassPalette.accent
                                          : CupertinoColors.label,
                                  context))),
                    ),
                  ),
                ),
            ]),
          ...segments
              .where((segment) => !segment.canReserve)
              .map((segment) => segment.unavailableReason ?? '此时段暂不可预约。')
              .where((reason) => reason.isNotEmpty)
              .toSet()
              .map(_note),
        ],
      ]),
      if (_segment != null) _seatPanel(),
    ];
  }

  Widget _seatPanel() {
    final query = _search.text.trim().toLowerCase();
    final matches = _availableFirst(_seats, (seat) => seat.canReserve)
        .where((seat) =>
            query.isEmpty ||
            seat.name.toLowerCase().contains(query) ||
            seat.labels.any((label) => label.toLowerCase().contains(query)))
        .toList();
    final pageCount = (matches.length / _seatsPerPage).ceil().clamp(1, 1000000);
    final page = _seatPage.clamp(0, pageCount - 1);
    final visible =
        matches.skip(page * _seatsPerPage).take(_seatsPerPage).toList();
    return _panel([
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        spacing: 12,
        runSpacing: 4,
        children: [
          const Text('选择座位', style: TextStyle(fontWeight: FontWeight.w600)),
          Text(
            '可用/总数 · ${_hasLoadedSeats ? _seatCountsLabel(matches.where((seat) => seat.canReserve).length, matches.length) : '—/—'}',
            key: const ValueKey('seat-result-count'),
            style: TextStyle(
                fontSize: 13,
                color: CupertinoDynamicColor.resolve(
                    CupertinoColors.secondaryLabel, context)),
          ),
        ],
      ),
      const SizedBox(height: 10),
      CupertinoSearchTextField(
        key: const ValueKey('seat-search'),
        backgroundColor: GlassPalette.fieldColor(context),
        borderRadius: BorderRadius.circular(16),
        controller: _search,
        enabled: !_busy,
        placeholder: '座位号或设施',
        onChanged: (_) => setState(() => _seatPage = 0),
      ),
      const SizedBox(height: 12),
      if (matches.isEmpty && !_busy && _error == null) const Text('没有符合条件的座位。'),
      LayoutBuilder(builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final columns = (constraints.maxWidth / (106 * scale.clamp(1, 1.2)))
            .floor()
            .clamp(1, 6);
        final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
        return Wrap(spacing: 8, runSpacing: 8, children: [
          for (final seat in visible)
            SizedBox(
                width: width,
                height: 106 * scale.clamp(1, 4),
                child: _seatTile(seat)),
        ]);
      }),
      if (matches.isNotEmpty) ...[
        const SizedBox(height: 12),
        Row(children: [
          CupertinoButton(
            key: const ValueKey('seat-page-previous'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            onPressed: _busy || page == 0
                ? null
                : () {
                    setState(() => _seatPage = page - 1);
                    FocusManager.instance.primaryFocus?.unfocus();
                  },
            child: const Text('上一页', style: TextStyle(fontSize: 14)),
          ),
          Expanded(
              child: Text('${page + 1} / $pageCount',
                  key: const ValueKey('seat-page-count'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13))),
          CupertinoButton(
            key: const ValueKey('seat-page-next'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            onPressed: _busy || page + 1 >= pageCount
                ? null
                : () {
                    setState(() => _seatPage = page + 1);
                    FocusManager.instance.primaryFocus?.unfocus();
                  },
            child: const Text('下一页', style: TextStyle(fontSize: 14)),
          ),
        ]),
      ],
    ]);
  }

  Widget _seatTile(LibrarySeat seat) {
    final selected = _seat?.id == seat.id;
    final status =
        seat.status.isEmpty ? (seat.canReserve ? '可预约' : '暂不可预约') : seat.status;
    return Semantics(
      selected: selected,
      label:
          '${seat.name}，$status${seat.labels.isEmpty ? '' : '，${seat.labels.join('、')}'}',
      child: DecoratedBox(
        decoration:
            GlassPalette.decoration(context, radius: 16, selected: selected),
        child: CupertinoButton(
          key: ValueKey('seat-item-${seat.id}'),
          padding: const EdgeInsets.all(8),
          borderRadius: BorderRadius.circular(16),
          onPressed: _busy || !seat.canReserve
              ? null
              : () => setState(() {
                    _seat = seat;
                  }),
          child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Expanded(
                      child: Text(seat.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight:
                                  selected ? FontWeight.w600 : FontWeight.w400,
                              color: CupertinoDynamicColor.resolve(
                                  _busy || !seat.canReserve
                                      ? CupertinoColors.secondaryLabel
                                      : selected
                                          ? GlassPalette.accent
                                          : CupertinoColors.label,
                                  context)))),
                  if (selected)
                    const Padding(
                        padding: EdgeInsets.only(left: 3),
                        child: Icon(CupertinoIcons.check_mark_circled_solid,
                            size: 16)),
                ]),
                const SizedBox(height: 4),
                Text(status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: CupertinoDynamicColor.resolve(
                            CupertinoColors.secondaryLabel, context))),
                if (seat.labels.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(seat.labels.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11,
                          color: CupertinoDynamicColor.resolve(
                              CupertinoColors.secondaryLabel, context))),
                ],
              ]),
        ),
      ),
    );
  }

  Widget _submissionBar() => GlassSurface(
        key: const ValueKey('seat-submission-bar'),
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        blur: true,
        child: LayoutBuilder(builder: (context, constraints) {
          final summary = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_seat == null ? '请选择座位' : '已选座位：${_seat!.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 3),
              Text(
                  '${_segment!.date} ${_segment!.startTime}–${_segment!.endTime}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12,
                      color: CupertinoDynamicColor.resolve(
                          CupertinoColors.secondaryLabel, context))),
              if (_submissionUncertain)
                Text('结果待确认，请先查看「我的座位」。',
                    style: TextStyle(
                        fontSize: 12,
                        color: CupertinoDynamicColor.resolve(
                            CupertinoColors.secondaryLabel, context))),
            ],
          );
          final button = CupertinoButton.filled(
            key: const ValueKey('seat-submit'),
            borderRadius: BorderRadius.circular(18),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            onPressed:
                _busy || _seat == null || _submissionUncertain ? null : _submit,
            child: const Text('确认预约'),
          );
          if (constraints.maxWidth < 330 ||
              MediaQuery.textScalerOf(context).scale(14) > 20) {
            return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [summary, const SizedBox(height: 8), button]);
          }
          return Row(children: [
            Expanded(child: summary),
            const SizedBox(width: 12),
            button
          ]);
        }),
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
                child: Text('取消预约',
                    style: TextStyle(
                        color: CupertinoDynamicColor.resolve(
                            CupertinoColors.systemRed, context))),
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
