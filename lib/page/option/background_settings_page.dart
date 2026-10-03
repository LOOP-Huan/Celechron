import 'dart:math' as math;

import 'package:celechron/design/app_background_scope.dart';
import 'package:celechron/design/glass_geometry.dart';
import 'package:celechron/design/liquid_glass.dart';
import 'package:celechron/services/app_background_service.dart';
import 'package:flutter/cupertino.dart';

class BackgroundSettingsPage extends StatefulWidget {
  const BackgroundSettingsPage({super.key, this.service});

  final AppBackgroundService? service;

  @override
  State<BackgroundSettingsPage> createState() => _BackgroundSettingsPageState();
}

enum _BackgroundActivity {
  loading,
  idle,
  picking,
  applying,
  resetting,
  confirming,
}

class _BackgroundSettingsPageState extends State<BackgroundSettingsPage> {
  late final AppBackgroundService _service;
  bool _initialized = false;
  BackgroundCandidate? _candidate;
  _BackgroundActivity _activity = _BackgroundActivity.loading;
  String? _error;
  String? _message;

  bool get _busy => _activity != _BackgroundActivity.idle || _service.busy;
  bool get _saving =>
      _activity == _BackgroundActivity.applying ||
      _activity == _BackgroundActivity.resetting;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _service =
        widget.service ??
        AppBackgroundScope.maybeOf(context) ??
        AppBackgroundService.instance;
    _initialize();
  }

  @override
  void dispose() {
    _candidate?.evictPreview();
    super.dispose();
  }

  void _replaceCandidate(BackgroundCandidate? candidate) {
    final previous = _candidate;
    _candidate = candidate;
    if (!identical(previous, candidate)) previous?.evictPreview();
  }

  Future<void> _initialize() async {
    try {
      await _service.init();
    } on Object catch (error) {
      if (mounted) _error = _errorMessage(error, '暂时无法读取背景，请稍后重试。');
    } finally {
      if (mounted) setState(() => _activity = _BackgroundActivity.idle);
    }
  }

  String _errorMessage(Object error, String fallback) =>
      error is AppBackgroundException ? error.message : fallback;

  void _start(_BackgroundActivity activity) {
    setState(() {
      _activity = activity;
      _error = null;
      _message = null;
    });
  }

  Future<void> _pick() async {
    if (_busy) return;
    _start(_BackgroundActivity.picking);
    try {
      final candidate = await _service.pick();
      if (!mounted) {
        candidate?.evictPreview();
        return;
      }
      if (candidate != null) setState(() => _replaceCandidate(candidate));
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = _errorMessage(error, '无法打开这张图片，请重新选择。'));
      }
    } finally {
      if (mounted) setState(() => _activity = _BackgroundActivity.idle);
    }
  }

  Future<void> _apply() async {
    final candidate = _candidate;
    if (_busy || candidate == null) return;
    _start(_BackgroundActivity.applying);
    try {
      await _service.apply(candidate);
      if (!mounted) return;
      setState(() {
        _replaceCandidate(null);
        _message = '已更新应用背景';
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = _errorMessage(error, '背景保存失败，请重试。'));
      }
    } finally {
      if (mounted) setState(() => _activity = _BackgroundActivity.idle);
    }
  }

  Future<void> _reset() async {
    if (_busy || !_service.hasImage) return;
    _start(_BackgroundActivity.confirming);
    try {
      final confirmed = await showCupertinoDialog<bool>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: const Text('恢复默认背景？'),
          content: const Text('应用将不再使用当前图片作为背景。'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            CupertinoDialogAction(
              key: const ValueKey('background-confirm-reset'),
              isDestructiveAction: true,
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('恢复默认'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      setState(() => _activity = _BackgroundActivity.resetting);
      await _service.reset();
      if (!mounted) return;
      setState(() {
        _replaceCandidate(null);
        _message = '已恢复默认背景';
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = _errorMessage(error, '暂时无法恢复默认背景，请重试。'));
      }
    } finally {
      if (mounted) setState(() => _activity = _BackgroundActivity.idle);
    }
  }

  String? get _progress => switch (_activity) {
    _BackgroundActivity.loading => '正在读取背景…',
    _BackgroundActivity.picking => '正在选择和处理图片…',
    _BackgroundActivity.applying => '正在保存背景…',
    _BackgroundActivity.resetting => '正在恢复默认背景…',
    _ => null,
  };

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _service,
    builder: (context, _) {
      final error = _error ?? _service.error;
      final secondary = GlassPalette.secondaryLabel(context);
      return PopScope(
        canPop: !_saving,
        child: GlassPageScaffold(
          navigationBar: CupertinoNavigationBar(
            middle: const Text('应用背景'),
            backgroundColor: GlassPalette.barColor,
            border: null,
            leading: _saving ? const SizedBox.shrink() : null,
          ),
          child: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  _candidate != null ? '新图片预览' : '当前背景',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _candidate != null
                      ? '点击“使用这张图片”后，全应用背景才会更新。'
                      : '选择喜欢的图片，预览它与玻璃卡片搭配的效果。',
                  style: TextStyle(fontSize: 14, color: secondary),
                ),
                const SizedBox(height: 16),
                _preview(context),
                const SizedBox(height: 16),
                if (_progress != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Semantics(
                      liveRegion: true,
                      child: Row(
                        children: [
                          const CupertinoActivityIndicator(),
                          const SizedBox(width: 10),
                          Expanded(child: Text(_progress!)),
                        ],
                      ),
                    ),
                  ),
                if (error != null || _message != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        error ?? _message!,
                        key: const ValueKey('background-feedback'),
                        style: TextStyle(
                          color: error == null
                              ? secondary
                              : CupertinoDynamicColor.resolve(
                                  CupertinoColors.systemRed,
                                  context,
                                ),
                        ),
                      ),
                    ),
                  ),
                if (_candidate != null) ...[
                  CupertinoButton.filled(
                    key: const ValueKey('background-apply'),
                    borderRadius: BorderRadius.circular(
                      GlassGeometry.compactRadius,
                    ),
                    onPressed: _busy ? null : _apply,
                    child: const Text('使用这张图片', textAlign: TextAlign.center),
                  ),
                  const SizedBox(height: 8),
                ],
                CupertinoButton(
                  key: const ValueKey('background-pick'),
                  borderRadius: BorderRadius.circular(
                    GlassGeometry.compactRadius,
                  ),
                  color: _candidate == null
                      ? GlassPalette.accentColor(context)
                      : null,
                  onPressed: _busy ? null : _pick,
                  child: Text(
                    _candidate == null ? '从相册选择图片' : '重新选择图片',
                    textAlign: TextAlign.center,
                    style: _candidate == null
                        ? TextStyle(
                            color: CupertinoDynamicColor.resolve(
                              GlassPalette.onAccent,
                              context,
                            ),
                          )
                        : null,
                  ),
                ),
                if (_candidate != null)
                  CupertinoButton(
                    key: const ValueKey('background-discard'),
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _replaceCandidate(null);
                            _error = null;
                            _message = null;
                          }),
                    child: const Text('取消预览'),
                  ),
                CupertinoButton(
                  key: const ValueKey('background-reset'),
                  onPressed: _busy || !_service.hasImage ? null : _reset,
                  child: const Text('恢复默认背景', textAlign: TextAlign.center),
                ),
                const SizedBox(height: 8),
                if (MediaQuery.highContrastOf(context)) ...[
                  Text(
                    '高对比度模式下会使用纯色背景，便于阅读。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: secondary),
                  ),
                  const SizedBox(height: 8),
                ],
                Text(
                  '图片仅保存在本机，不会上传至服务器。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: secondary),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _preview(BuildContext context) {
    final scaled = MediaQuery.textScalerOf(context).scale(18) / 18;
    return ClipRRect(
      borderRadius: BorderRadius.circular(GlassGeometry.surfaceRadius),
      child: SizedBox(
        height: math.max(280, 210 * scaled),
        child: GlassBackgroundPreview(
          key: const ValueKey('background-preview'),
          image: _candidate?.image ?? _service.image,
          child: Builder(
            builder: (previewContext) => Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    '背景效果预览',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 20),
                  GlassSurface(
                    blur: true,
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '接下来',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '14:00 小组讨论',
                          style: TextStyle(
                            fontSize: 15,
                            color: GlassPalette.secondaryLabel(previewContext),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
