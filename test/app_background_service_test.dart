import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:celechron/services/app_background_service.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

Future<Uint8List> _png({int width = 12, int height = 8}) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff336699), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
    }
  }
  return crc ^ 0xffffffff;
}

Uint8List _withTextMetadata(Uint8List png) {
  final payload = utf8.encode('Location\u0000private-photo-location');
  final body = [...ascii.encode('tEXt'), ...payload];
  final chunk = ByteData(payload.length + 12)..setUint32(0, payload.length);
  chunk.buffer.asUint8List().setRange(4, 4 + body.length, body);
  chunk.setUint32(8 + payload.length, _crc32(body));
  return Uint8List.fromList([
    ...png.sublist(0, png.length - 12),
    ...chunk.buffer.asUint8List(),
    ...png.sublist(png.length - 12),
  ]);
}

Uint8List _withHeaderSize(Uint8List png, int width, int height) {
  final bytes = Uint8List.fromList(png);
  final data = ByteData.sublistView(bytes);
  data.setUint32(16, width);
  data.setUint32(20, height);
  data.setUint32(29, _crc32(bytes.sublist(12, 29)));
  return bytes;
}

class _OversizedFile extends XFile {
  _OversizedFile() : super('unused');

  bool read = false;

  @override
  Future<int> length() async => AppBackgroundService.maxInputBytes + 1;

  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    read = true;
    yield Uint8List(1);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Uint8List png;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('celechron-background-');
    png = await _png();
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  AppBackgroundService service({
    Future<XFile?> Function()? picker,
    Future<void> Function(File, File)? commit,
  }) {
    final value = AppBackgroundService(
      rootDirectory: () async => directory,
      picker: picker ?? () async => null,
      commitConfig: commit,
    );
    addTearDown(value.dispose);
    return value;
  }

  Future<Map<String, dynamic>> config() async =>
      jsonDecode(
            await File(
              '${directory.path}/${AppBackgroundService.configName}',
            ).readAsString(),
          )
          as Map<String, dynamic>;

  test('初始化幂等，选择只生成降采样预览，未确认不保存或替换背景', () async {
    final big = await _png(width: 4096, height: 32);
    final value = service(picker: () async => XFile.fromData(big));
    await Future.wait([value.init(), value.init()]);
    final candidate = (await value.pick())!;
    expect(candidate.width, 2048);
    expect(candidate.height, 16);
    expect(value.hasImage, isFalse);
    expect(value.busy, isFalse);
    expect(await directory.list().toList(), isEmpty);
    expect(() => candidate.image.bytes[0] = 0, throwsUnsupportedError);
  });

  test('确认后保存私有PNG并剥离元数据，删除相册临时文件不影响重启恢复', () async {
    final temporary = File('${directory.path}/picker-source.png');
    await temporary.writeAsBytes(_withTextMetadata(png));
    final value = service(picker: () async => XFile(temporary.path));
    final candidate = (await value.pick())!;
    await value.apply(candidate);
    final stored = (value.image! as FileImage).file;
    expect(stored.path, isNot(temporary.path));
    expect(await stored.exists(), isTrue);
    expect(
      utf8.decode(await stored.readAsBytes(), allowMalformed: true),
      isNot(contains('private-photo-location')),
    );
    final pointer = await config();
    expect(pointer['file'], stored.uri.pathSegments.last);
    expect(pointer['width'], 12);
    expect(pointer['height'], 8);
    await temporary.delete();
    value.dispose();

    final restored = service();
    await restored.init();
    expect(restored.hasImage, isTrue);
    expect((restored.image! as FileImage).file.path, stored.path);
    expect(restored.error, isNull);
  });

  test('成功替换才清旧文件，恢复默认可持久化且不删除无关文件', () async {
    final value = service();
    final candidate = await BackgroundCandidate.fromBytes(png);
    await value.apply(candidate);
    final first = (value.image! as FileImage).file;
    final unrelated = await File(
      '${directory.path}/unrelated.txt',
    ).writeAsString('keep');
    await value.apply(candidate);
    final second = (value.image! as FileImage).file;
    expect(await first.exists(), isFalse);
    expect(await second.exists(), isTrue);
    expect(await unrelated.exists(), isTrue);
    await value.reset();
    expect(value.image, isNull);
    expect(await second.exists(), isFalse);
    expect((await config())['file'], isNull);
    final restored = service();
    await restored.init();
    expect(restored.hasImage, isFalse);
    expect(await unrelated.exists(), isTrue);
  });

  test('取消或损坏图片保留原背景，不泄露本地路径到错误信息', () async {
    XFile? next;
    final value = service(picker: () async => next);
    await value.apply(await BackgroundCandidate.fromBytes(png));
    final previous = value.image;
    final pointer = await config();
    expect(await value.pick(), isNull);
    expect(value.image, same(previous));
    next = XFile.fromData(Uint8List.fromList([1, 2, 3]));
    await expectLater(value.pick(), throwsA(isA<AppBackgroundException>()));
    expect(value.image, same(previous));
    expect(await config(), pointer);
    expect(value.error, isNot(contains(directory.path)));
  });

  test('配置提交失败时旧指针和图片不变，临时图片被清理，恢复失败同样保留', () async {
    var fail = false;
    File? oldFile;
    final value = service(
      commit: (temporary, destination) async {
        if (oldFile != null) expect(await oldFile.exists(), isTrue);
        if (fail) throw const FileSystemException('sensitive local path');
        await temporary.rename(destination.path);
      },
    );
    final candidate = await BackgroundCandidate.fromBytes(png);
    await value.apply(candidate);
    final oldImage = value.image;
    oldFile = (oldImage! as FileImage).file;
    final pointer = await config();
    fail = true;
    await expectLater(
      value.apply(candidate),
      throwsA(isA<AppBackgroundException>()),
    );
    await expectLater(value.reset(), throwsA(isA<AppBackgroundException>()));
    expect(value.image, same(oldImage));
    expect(await config(), pointer);
    expect(await oldFile.exists(), isTrue);
    expect(await directory.list().length, 2);
    expect(value.error, isNot(contains('sensitive')));
  });

  for (final state in [
    'missing-image',
    'damaged-image',
    'traversal',
    'broken-json',
  ]) {
    test('重启遇到$state时安全回退默认，初始化不阻断应用', () async {
      final file = File('${directory.path}/${AppBackgroundService.configName}');
      if (state == 'broken-json') {
        await file.writeAsString('{');
      } else {
        await file.writeAsString(
          jsonEncode({
            'version': 1,
            'file': state == 'traversal'
                ? '../outside.png'
                : 'background-abcd.png',
          }),
        );
        if (state == 'damaged-image') {
          await File(
            '${directory.path}/background-abcd.png',
          ).writeAsString('bad');
        }
      }
      final value = service();
      await value.init();
      expect(value.hasImage, isFalse);
      expect(value.error, isNotNull);
      expect(value.busy, isFalse);
    });
  }

  test('超出字节或原图像素限制在完整解码前拒绝，当前图片保持不变', () async {
    final oversized = _OversizedFile();
    final value = service(picker: () async => oversized);
    await value.apply(await BackgroundCandidate.fromBytes(png));
    final previous = value.image;
    await expectLater(value.pick(), throwsA(isA<AppBackgroundException>()));
    expect(oversized.read, isFalse);
    expect(value.image, same(previous));
    await expectLater(
      BackgroundCandidate.fromBytes(_withHeaderSize(png, 6000, 5000)),
      throwsA(
        isA<AppBackgroundException>().having(
          (error) => error.message,
          'message',
          contains('尺寸过大'),
        ),
      ),
    );
  });

  test('选择期间拒绝并发保存或恢复，完成取消后可继续操作', () async {
    final picked = Completer<XFile?>();
    final started = Completer<void>();
    final value = service(
      picker: () {
        started.complete();
        return picked.future;
      },
    );
    await value.init();
    final pending = value.pick();
    await started.future;
    expect(value.busy, isTrue);
    await expectLater(value.reset(), throwsA(isA<AppBackgroundException>()));
    picked.complete(null);
    expect(await pending, isNull);
    expect(value.busy, isFalse);
    await value.reset();
  });

  test('服务关闭后未完成的选择不能恢复状态或通知旧订阅者', () async {
    final picked = Completer<XFile?>();
    final started = Completer<void>();
    final value = service(
      picker: () {
        started.complete();
        return picked.future;
      },
    );
    await value.init();
    var notifications = 0;
    value.addListener(() => notifications++);
    final pending = value.pick();
    await started.future;
    value.dispose();
    final before = notifications;
    picked.complete(XFile.fromData(png));
    await expectLater(pending, throwsA(isA<AppBackgroundException>()));
    expect(value.image, isNull);
    expect(notifications, before);
  });
}
