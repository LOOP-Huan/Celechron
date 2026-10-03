import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class AppBackgroundException implements Exception {
  final String message;

  const AppBackgroundException(this.message);

  @override
  String toString() => message;
}

/// A normalized first-frame PNG, with no retained codec or native image handle.
/// The settings page may drop a candidate without applying it or disposing it.
class BackgroundCandidate {
  final Uint8List _bytes;
  final int width;
  final int height;
  final int _sourceWidth;
  final int _sourceHeight;
  final MemoryImage image;

  BackgroundCandidate._(
    Uint8List bytes,
    this.width,
    this.height,
    this._sourceWidth,
    this._sourceHeight,
  ) : _bytes = bytes.asUnmodifiableView(),
      image = MemoryImage(bytes.asUnmodifiableView());

  static Future<BackgroundCandidate> fromBytes(Uint8List bytes) =>
      _normalizeBackground(bytes);

  /// Optional cache cleanup when abandoning/replacing a preview. This does not
  /// dispose a native resource or make the candidate invalid for a later apply.
  void evictPreview() => AppBackgroundService._evict(image);
}

/// Keeps background selection completely separate from account/Hive state.
/// A picker result is temporary: only apply() commits an app-private image.
class AppBackgroundService extends ChangeNotifier {
  static final AppBackgroundService instance = AppBackgroundService();
  static const int maxInputBytes = 32 * 1024 * 1024;
  static const int maxImageEdge = 2048;
  static const int maxSourcePixels = 26 * 1000 * 1000;
  static const String configName = 'background.json';

  final Future<Directory> Function() _rootDirectory;
  final Future<XFile?> Function() _picker;
  final Future<void> Function(File temporary, File destination) _commitConfig;
  final bool _usesPlatformPicker;
  Directory? _directory;
  Future<void>? _initializing;
  bool _initialized = false;
  bool _disposed = false;
  bool _busy = false;
  String? _error;
  ImageProvider<Object>? _image;

  /// [rootDirectory] is the dedicated background directory, not its parent.
  /// [commitConfig] is injectable to verify failures at the commit boundary.
  AppBackgroundService({
    Future<Directory> Function()? rootDirectory,
    Future<XFile?> Function()? picker,
    @visibleForTesting
    Future<void> Function(File temporary, File destination)? commitConfig,
  }) : _rootDirectory = rootDirectory ?? _defaultDirectory,
       _picker = picker ?? _pickFromGallery,
       _usesPlatformPicker = picker == null,
       _commitConfig = commitConfig ?? _renameConfig;

  ImageProvider<Object>? get image => _image;
  bool get hasImage => _image != null;
  bool get busy => _busy;
  String? get error => _error;

  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}${Platform.pathSeparator}app_background');
  }

  static Future<XFile?> _pickFromGallery() => ImagePicker().pickImage(
    source: ImageSource.gallery,
    requestFullMetadata: false,
  );

  static Future<void> _renameConfig(File temporary, File destination) async {
    // A same-directory rename replaces the pointer only after its contents have
    // been flushed. Never delete the previous config before this operation.
    await temporary.rename(destination.path);
  }

  void _checkActive() {
    if (_disposed) throw const AppBackgroundException('背景设置已关闭。');
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Idempotent and startup-safe: damaged or missing storage uses the default
  /// background and reports a friendly error, without blocking app startup.
  Future<void> init() {
    if (_initialized || _disposed) return Future<void>.value();
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      await _run(() async {
        final directory = await _getDirectory();
        final config = File(
          '${directory.path}${Platform.pathSeparator}$configName',
        );
        if (await config.exists()) {
          final decoded = jsonDecode(
            utf8.decode(
              await _readBounded(
                config.openRead(),
                await config.length(),
                limit: 4096,
              ),
            ),
          );
          if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
            throw const AppBackgroundException('背景配置无法读取，已使用默认背景。');
          }
          final name = decoded['file'];
          if (name != null) {
            if (name is! String || !_imageName.hasMatch(name)) {
              throw const AppBackgroundException('背景配置无法读取，已使用默认背景。');
            }
            final file = File(
              '${directory.path}${Platform.pathSeparator}$name',
            );
            if (await FileSystemEntity.type(file.path, followLinks: false) !=
                FileSystemEntityType.file) {
              throw const AppBackgroundException('背景图片已不可用，已使用默认背景。');
            }
            final bytes = await _readBounded(
              file.openRead(),
              await file.length(),
            );
            final candidate = await BackgroundCandidate.fromBytes(bytes);
            if (!_isPng(bytes) ||
                candidate._sourceWidth > maxImageEdge ||
                candidate._sourceHeight > maxImageEdge) {
              throw const AppBackgroundException('背景图片已不可用，已使用默认背景。');
            }
            _checkActive();
            _image = FileImage(file);
          }
          await _cleanUnused(directory, keep: name as String?);
        }
        // Android may kill an activity while its system picker is open. Drain
        // the plugin's recovery result, but never apply an unconfirmed photo.
        if (_usesPlatformPicker && Platform.isAndroid) {
          try {
            final lost = await ImagePicker().retrieveLostData().timeout(
              const Duration(seconds: 3),
            );
            if (!lost.isEmpty) _error = '上次照片选择已中断，请重新选择并确认。';
          } catch (_) {
            // Recovery is optional; the already committed background is safe.
          }
        }
      }, fallback: '背景文件无法读取，已使用默认背景。');
    } on AppBackgroundException {
      // init must not make startup depend on optional image storage.
    } finally {
      _initialized = true;
    }
  }

  Future<BackgroundCandidate?> pick() async {
    await init();
    return _run(() async {
      final file = await _picker();
      _checkActive();
      if (file == null) return null;
      final bytes = await _readBounded(file.openRead(), await file.length());
      _checkActive();
      final candidate = await BackgroundCandidate.fromBytes(bytes);
      _checkActive();
      return candidate;
    }, fallback: '无法打开这张照片，请重新选择。');
  }

  Future<void> apply(BackgroundCandidate candidate) async {
    await init();
    await _run(() async {
      final directory = await _getDirectory();
      final id = const Uuid().v4();
      final name = 'background-$id.png';
      final temporary = File(
        '${directory.path}${Platform.pathSeparator}$name.tmp',
      );
      final saved = File('${directory.path}${Platform.pathSeparator}$name');
      var committed = false;
      try {
        await temporary.writeAsBytes(candidate._bytes, flush: true);
        _checkActive();
        await temporary.rename(saved.path);
        _checkActive();
        await _savePointer(
          directory,
          name,
          width: candidate.width,
          height: candidate.height,
        );
        committed = true;
        final old = _image;
        _image = _disposed ? null : FileImage(saved);
        _notify();
        _evict(old);
        _evict(candidate.image);
        await _cleanUnused(directory, keep: name);
      } finally {
        await _deleteQuietly(temporary);
        if (!committed) await _deleteQuietly(saved);
      }
    }, fallback: '背景保存失败，原背景已保留，请重试。');
  }

  Future<void> reset() async {
    await init();
    await _run(() async {
      final directory = await _getDirectory();
      await _savePointer(directory, null);
      final old = _image;
      _image = null;
      _notify();
      _evict(old);
      await _cleanUnused(directory);
    }, fallback: '恢复默认背景失败，原背景已保留，请重试。');
  }

  Future<Directory> _getDirectory() async {
    final directory = _directory ?? await _rootDirectory();
    _checkActive();
    await directory.create(recursive: true);
    _checkActive();
    return _directory = directory;
  }

  Future<void> _savePointer(
    Directory directory,
    String? name, {
    int? width,
    int? height,
  }) async {
    final temporary = File(
      '${directory.path}${Platform.pathSeparator}'
      'config-${const Uuid().v4()}.tmp',
    );
    try {
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'file': name,
          if (name != null) 'width': width,
          if (name != null) 'height': height,
        }),
        flush: true,
      );
      _checkActive();
      await _commitConfig(
        temporary,
        File('${directory.path}${Platform.pathSeparator}$configName'),
      );
    } finally {
      await _deleteQuietly(temporary);
    }
  }

  Future<T> _run<T>(
    Future<T> Function() operation, {
    required String fallback,
  }) async {
    _checkActive();
    if (_busy) throw const AppBackgroundException('上一项背景操作尚未完成，请稍候。');
    _busy = true;
    _error = null;
    _notify();
    try {
      return await operation();
    } catch (error) {
      final safe = error is AppBackgroundException
          ? error
          : AppBackgroundException(fallback);
      if (!_disposed) _error = safe.message;
      throw safe;
    } finally {
      _busy = false;
      _notify();
    }
  }

  static final _imageName = RegExp(r'^background-[0-9a-f-]+\.png$');
  static final _temporaryName = RegExp(
    r'^(?:background-[0-9a-f-]+\.png|config-[0-9a-f-]+)\.tmp$',
  );

  static Future<void> _cleanUnused(Directory directory, {String? keep}) async {
    try {
      await for (final entry in directory.list(followLinks: false)) {
        final name = entry.path.split(Platform.pathSeparator).last;
        if (name != keep &&
            (_imageName.hasMatch(name) || _temporaryName.hasMatch(name))) {
          await _deleteQuietly(entry);
        }
      }
    } catch (_) {
      // Cleanup is best effort after commit, never a reason to roll back it.
    }
  }

  static Future<void> _deleteQuietly(FileSystemEntity file) async {
    try {
      await file.delete();
    } catch (_) {}
  }

  static void _evict(ImageProvider<Object>? image) {
    if (image == null) return;
    unawaited(() async {
      try {
        final key = await image.obtainKey(const ImageConfiguration());
        // Keep live image streams valid for the current frame while removing
        // the old keep-alive cache entry. Existing widgets release their handle.
        PaintingBinding.instance.imageCache.evict(key, includeLive: false);
      } catch (_) {}
    }());
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _evict(_image);
    _image = null;
    super.dispose();
  }
}

Future<Uint8List> _readBounded(
  Stream<List<int>> stream,
  int length, {
  int limit = AppBackgroundService.maxInputBytes,
}) async {
  if (length <= 0 || length > limit) {
    throw const AppBackgroundException('请选择不超过 32 MB 的有效图片。');
  }
  final result = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (result.length + chunk.length > limit) {
      throw const AppBackgroundException('请选择不超过 32 MB 的有效图片。');
    }
    result.add(chunk);
  }
  return result.takeBytes();
}

bool _isPng(Uint8List bytes) =>
    bytes.length >= 8 &&
    listEquals(bytes.sublist(0, 8), const [137, 80, 78, 71, 13, 10, 26, 10]);

Future<BackgroundCandidate> _normalizeBackground(Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > AppBackgroundService.maxInputBytes) {
    throw const AppBackgroundException('请选择不超过 32 MB 的有效图片。');
  }
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width;
    final height = descriptor.height;
    // Check header dimensions before creating any full-size pixel buffer.
    if (width <= 0 ||
        height <= 0 ||
        width > 32768 ||
        height > 32768 ||
        // Nominal 24 MP phone photos can be 5712 x 4284 (24.47 MP).
        width * height > AppBackgroundService.maxSourcePixels) {
      throw const AppBackgroundException('图片尺寸过大，请先裁剪或缩小后再选择。');
    }
    final scale = math.min(
      1.0,
      AppBackgroundService.maxImageEdge / math.max(width, height),
    );
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (width * scale).round()),
      targetHeight: math.max(1, (height * scale).round()),
    );
    image = (await codec.getNextFrame()).image;
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null || png.lengthInBytes > AppBackgroundService.maxInputBytes) {
      throw const AppBackgroundException('图片处理失败，请选择另一张照片。');
    }
    return BackgroundCandidate._(
      png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      image.width,
      image.height,
      width,
      height,
    );
  } on AppBackgroundException {
    rethrow;
  } catch (_) {
    throw const AppBackgroundException('图片损坏或格式不受支持，请选择另一张照片。');
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}
