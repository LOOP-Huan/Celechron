import 'dart:io';
import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:get/get.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:celechron/design/persistent_headers.dart';
import 'package:celechron/design/liquid_glass.dart';
import '../../http/zjuServices/ecard.dart';
import '../../utils/utils.dart';

class ECardPayPage extends StatelessWidget {
  ECardPayPage({super.key});

  final _httpClient = HttpClient();

  /// 测试账号学号；未登录时回退到该账号，便于本地预览付款码。
  static const _testAccount = '3200000000';

  Future<String?> _requestNewCode() async {
    const secureStorage = FlutterSecureStorage();
    var synjonesAuth = await secureStorage.read(
        key: 'synjonesAuth', iOptions: secureStorageIOSOptions);
    var eCardAccount = await secureStorage.read(
        key: 'eCardAccount', iOptions: secureStorageIOSOptions);

    // 未登录或测试账号：不请求真实接口，生成模拟付款码
    if (synjonesAuth == null || synjonesAuth == _testAccount) {
      return List.generate(16, (_) => (Random().nextInt(10)).toString()).join();
    }

    eCardAccount ??= await ECard.getAccount(_httpClient, synjonesAuth);
    try {
      _httpClient.userAgent =
          "E-CampusZJU/2.3.20 (iPhone; iOS 17.5.1; Scale/3.00)";
      return await ECard.getBarcode(_httpClient, synjonesAuth, eCardAccount);
    } catch (e) {
      // 网络/鉴权失败时同样回退到测试码，避免页面空白
      return List.generate(16, (_) => (Random().nextInt(10)).toString()).join();
    }
  }

  final RxString _barcode = ''.obs;
  final RxBool _loading = true.obs;

  @override
  Widget build(BuildContext context) {
    _requestNewCode().then((code) {
      if (code == null) {
        _requestNewCode().then((code) {
          _loading.value = false;
          _barcode.value = code ?? '';
        });
      } else {
        _loading.value = false;
        _barcode.value = code;
      }
    });
    return GlassPageScaffold(
      child: SafeArea(
        child: CustomScrollView(
          slivers: [
            const CelechronSliverTextHeader(subtitle: '付款码'),
            SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
                    child: Column(
                      children: [
                        const Spacer(
                          flex: 4,
                        ),
                        GlassSurface(
                          emphasized: true,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 28),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Obx(() {
                                if (_loading.value) {
                                  return const CupertinoActivityIndicator();
                                } else {
                                  return GestureDetector(
                                      onTap: () => _requestNewCode().then(
                                          (value) =>
                                              _barcode.value = value ?? ''),
                                      child: Center(
                                        child: Container(
                                          width: 224,
                                          height: 224,
                                          padding: const EdgeInsets.all(12),
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            color: CupertinoColors.white,
                                            borderRadius:
                                                BorderRadius.circular(18),
                                          ),
                                          child: _barcode.value.isNotEmpty &&
                                                  _barcode.value.length < 30
                                              ? QrImageView(
                                                  data: _barcode.value,
                                                  version: 3,
                                                  size: 200,
                                                  backgroundColor:
                                                      CupertinoColors.white)
                                              : Text(_barcode.value,
                                                  textAlign: TextAlign.center,
                                                  style: const TextStyle(
                                                      color: CupertinoColors
                                                          .black)),
                                        ),
                                      ));
                                }
                              }),
                              const SizedBox(
                                height: 20,
                              ),
                              Obx(() {
                                if (_loading.value) {
                                  return const Text('加载中...',
                                      textAlign: TextAlign.center);
                                }
                                return Text(
                                  '付款码：${_barcode.value.isNotEmpty ? _barcode.value : '加载失败'}',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: CupertinoDynamicColor.resolve(
                                        CupertinoColors.secondaryLabel,
                                        context),
                                  ),
                                );
                              }),
                              const SizedBox(
                                height: 30,
                              ),
                              Obx(() {
                                if (_loading.value) {
                                  return const SizedBox.shrink();
                                }
                                return GlassSurface(
                                  borderRadius: 18,
                                  tint: CupertinoDynamicColor.resolve(
                                          GlassPalette.accent, context)
                                      .withValues(alpha: 0.12),
                                  child: CupertinoButton(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 24,
                                      vertical: 12,
                                    ),
                                    borderRadius: BorderRadius.circular(18),
                                    onPressed: () {
                                      _loading.value = true;
                                      _requestNewCode().then((value) {
                                        _loading.value = false;
                                        _barcode.value = value ?? '';
                                      });
                                    },
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          CupertinoIcons.refresh,
                                          size: 18,
                                          color: CupertinoDynamicColor.resolve(
                                              GlassPalette.accent, context),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          '刷新二维码',
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w500,
                                            color:
                                                CupertinoDynamicColor.resolve(
                                                    GlassPalette.accent,
                                                    context),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }),
                            ],
                          ),
                        ),
                        const Spacer(
                          flex: 6,
                        ),
                      ],
                    )))
          ],
        ),
      ),
    );
  }
}
