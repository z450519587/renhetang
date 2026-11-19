import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../models/platform_model.dart';
import 'package:flutter_hbb/common.dart';

/// 仁和堂门店配置与同步服务。
///
/// 设计要点：
/// - 店名与备注以本地 option 持久化（LocalConfig，自由 key，无需改 Rust key 表）。
/// - 设备唯一标识 = 本机 RustDesk ID（bind.mainGetMyId()）。
/// - 服务端 = lejianwen/rustdesk-api（Go/Gin）。对接其【后台管理 API】
///   /api/admin/address_book/*，认证头 api-token，通过 user_id + collection_id
///   直接定位共享通讯录集合，用 id（设备ID）匹配记录、alias 字段写入店名。
/// - 所有可变 API 参数集中在 [RhStoreConfig]，构建时用 --dart-define 注入。
/// - adminToken 不写入源码：构建时通过 --dart-define=RH_ADMIN_TOKEN=xxx 注入。
class RhStoreConfig {
  // API 服务器：默认沿用客户端已内置的 rd.renhetang.cn:21114。
  // 传空时回退到 bind.mainGetApiServer()。
  static const String apiServerOverride = String.fromEnvironment(
    'RH_API_SERVER',
    defaultValue: 'http://rd.renhetang.cn:21114',
  );

  // 共享通讯录归属用户与集合 ID。
  // 在 rustdesk-api 后台模型中即 address_book 表的 user_id / collection_id。
  static const String addressBookUserId =
      String.fromEnvironment('RH_AB_USER_ID', defaultValue: '1');
  static const String addressBookCollectionId =
      String.fromEnvironment('RH_AB_COLLECTION_ID', defaultValue: '3');

  // 管理员令牌：构建时注入，源码中永不出现明文。
  // rustdesk-api 后台接口用 api-token 头传递（见 http/middleware/admin.go）。
  static const String adminToken =
      String.fromEnvironment('RH_ADMIN_TOKEN', defaultValue: '');

  // 本地 option key（持久化店名 / 备注 / 首次配置标记 / 记录缓存）。
  static const String keyStoreName = 'rh-store-name';
  static const String keyStoreNote = 'rh-store-note';
  static const String keySetupDone = 'rh-store-setup-done';
  static const String keyStoreCache = 'rh-store-cache';

  // 店名输入占位示例。
  static const String storeNamePlaceholder = '例如：仁和堂临沂解放路店';
}

class RhStoreRecord {
  final String deviceId;
  final String name;
  final String note;

  RhStoreRecord({
    required this.deviceId,
    required this.name,
    required this.note,
  });

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'name': name,
        'note': note,
      };

  factory RhStoreRecord.fromJson(Map<String, dynamic> json) => RhStoreRecord(
        deviceId: (json['deviceId'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        note: (json['note'] ?? '').toString(),
      );
}

class SyncResult {
  final bool ok;
  final String error;
  SyncResult._(this.ok, this.error);
  factory SyncResult.success() => SyncResult._(true, '');
  factory SyncResult.failure(String e) => SyncResult._(false, e);
}

class RhStoreService {
  RhStoreService._();
  static final RhStoreService instance = RhStoreService._();

  /// 当前店名（响应式）：主界面右上角展示、提交成功后刷新。
  static final RxString currentStoreName = ''.obs;

  /// 启动时载入本地店名到响应式变量。
  Future<void> loadCurrentStoreName() async {
    currentStoreName.value = await getStoreName();
  }

  Future<String> get apiServer async {
    final override = RhStoreConfig.apiServerOverride;
    if (override.isNotEmpty) return override;
    return await bind.mainGetApiServer();
  }

  /// rustdesk-api 后台接口认证：api-token 头（不是 Authorization Bearer）。
  /// 见服务端 http/middleware/admin.go 的 BackendUserAuth()。
  Map<String, String> _headers() {
    return {
      'api-token': RhStoreConfig.adminToken,
      // jsonEncode 产生 UTF-8 字节；显式声明 charset 保证服务端按 UTF-8 解析。
      'Content-Type': 'application/json; charset=utf-8',
    };
  }

  /// 后台接口统一响应体：{"code":0,"message":"...","data":...}
  /// code==0 为成功（见服务端 http/response/response.go）。
  dynamic _checkAdminResponse(http.Response resp, String action) {
    if (resp.statusCode != 200) {
      throw '$action失败（HTTP ${resp.statusCode}）';
    }
    final json = jsonDecode(utf8.decode(resp.bodyBytes));
    if (json is Map<String, dynamic>) {
      final code = json['code'];
      if (code is int && code != 0) {
        throw '$action失败：${json['message'] ?? code}';
      }
    }
    return json;
  }

  /// 所有后台请求都带硬超时，避免服务端无响应时界面永久“没反应”。
  static const Duration _requestTimeout = Duration(seconds: 15);

  Future<http.Response> _get(Uri url) async {
    try {
      return await http.get(url, headers: _headers()).timeout(_requestTimeout);
    } on TimeoutException catch (_) {
      throw '请求服务器超时，请检查网络后重试';
    }
  }

  Future<http.Response> _post(Uri url, Map<String, dynamic> body) async {
    try {
      return await http
          .post(url, headers: _headers(), body: jsonEncode(body))
          .timeout(_requestTimeout);
    } on TimeoutException catch (_) {
      throw '请求服务器超时，请检查网络后重试';
    }
  }

  /// 后台列表接口 data 形态兼容：{"list":[...]}、{"data":[...]}、[...]。
  List<dynamic> _rowsFromAdminJson(dynamic json) {
    final data = json is Map<String, dynamic> ? json['data'] : null;
    if (data is Map<String, dynamic>) {
      return (data['list'] as List?) ?? (data['data'] as List?) ?? const [];
    }
    if (data is List) return data;
    return const [];
  }

  /// 首次启动时 Rust 后端可能还没生成设备 ID，轮询等待，避免拿到空 ID。
  Future<String> _waitForMyId() async {
    for (var i = 0; i < 30; i++) {
      final id = (await bind.mainGetMyId()).trim();
      if (id.isNotEmpty) return id;
      await Future.delayed(const Duration(milliseconds: 500));
    }
    throw '未获取到本机设备 ID，请稍后重试';
  }

  // ---------- 本地持久化 ----------

  Future<String> getStoreName() async =>
      await bind.mainGetLocalOption(key: RhStoreConfig.keyStoreName);

  Future<void> setStoreName(String v) async =>
      await bind.mainSetLocalOption(key: RhStoreConfig.keyStoreName, value: v);

  Future<String> getStoreNote() async =>
      await bind.mainGetLocalOption(key: RhStoreConfig.keyStoreNote);

  Future<void> setStoreNote(String v) async =>
      await bind.mainSetLocalOption(key: RhStoreConfig.keyStoreNote, value: v);

  Future<bool> isSetupDone() async =>
      await bind.mainGetLocalOption(key: RhStoreConfig.keySetupDone) == 'Y';

  Future<void> markSetupDone() async =>
      await bind.mainSetLocalOption(key: RhStoreConfig.keySetupDone, value: 'Y');

  /// 本地记录缓存：用于「共享通讯录中被删除的门店，再次同步时恢复」。
  Future<List<RhStoreRecord>> loadCache() async {
    final raw = await bind.mainGetLocalOption(key: RhStoreConfig.keyStoreCache);
    if (raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => RhStoreRecord.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('rh_store loadCache: $e');
      return [];
    }
  }

  Future<void> saveCache(List<RhStoreRecord> records) async {
    final raw = jsonEncode(records.map((e) => e.toJson()).toList());
    await bind.mainSetLocalOption(key: RhStoreConfig.keyStoreCache, value: raw);
  }

  Future<void> upsertCache(RhStoreRecord rec) async {
    final records = await loadCache();
    final idx = records.indexWhere((e) => e.deviceId == rec.deviceId);
    if (idx < 0) {
      records.add(rec);
    } else {
      records[idx] = rec;
    }
    await saveCache(records);
  }

  // ---------- 地址簿记录查询 / 写入（后台管理 API） ----------
  //
  // 服务端：lejianwen/rustdesk-api
  // 列表：GET  /api/admin/address_book/list?user_id=&collection_id=&id=
  // 新增：POST /api/admin/address_book/create   body=AddressBookForm
  // 更新：POST /api/admin/address_book/update   body=AddressBookForm（须含 row_id）
  // 认证：api-token 头；成功判定 code==0。
  // 见 http/router/admin.go + http/controller/admin/addressBook.go。

  /// 按设备 ID 在指定 user_id/collection_id 集合里查询记录。
  /// 返回 null 表示不存在（可能被删除）。
  Future<Map<String, dynamic>?> _findAbRow(String deviceId) async {
    final base = await apiServer;
    final url = Uri.parse('$base/api/admin/address_book/list').replace(
        queryParameters: {
      'user_id': RhStoreConfig.addressBookUserId,
      'collection_id': RhStoreConfig.addressBookCollectionId,
      'id': deviceId,
      'page': '1',
      'pageSize': '10',
    });
    final resp = await _get(url);
    final json = _checkAdminResponse(resp, '查询通讯录');
    for (final item in _rowsFromAdminJson(json)) {
      if (item is! Map<String, dynamic>) continue;
      if ((item['id'] ?? '').toString() == deviceId) return item;
    }
    return null;
  }

  /// 读取通讯录中该设备记录的备注。
  /// 注意：rustdesk-api 的 address_book 模型没有 note 字段，备注信息统一以
  /// alias（显示名）承载；这里读 alias 作为"备注"内容，供恢复逻辑使用。
  Future<String> fetchNoteFromAb(String deviceId) async {
    final row = await _findAbRow(deviceId);
    return row == null ? '' : (row['alias'] ?? '').toString();
  }

  /// 新增或更新地址簿记录（按设备 ID 去重：存在则 update，不存在则 create）。
  /// 写入字段 alias = 店名（UTF-8 由 jsonEncode + charset 头保证）。
  Future<void> upsertPeer(RhStoreRecord rec) async {
    final base = await apiServer;
    final existing = await _findAbRow(rec.deviceId);
    final bodyMap = <String, dynamic>{
      'id': rec.deviceId,
      'alias': rec.name,
      'user_id': int.tryParse(RhStoreConfig.addressBookUserId) ?? 1,
      'collection_id': int.tryParse(RhStoreConfig.addressBookCollectionId) ?? 0,
    };
    if (existing != null) {
      // 更新必须带 row_id（服务端按 row_id 定位，见 admin/addressBook.go Update）。
      bodyMap['row_id'] = existing['row_id'];
    }
    final url = Uri.parse(existing == null
        ? '$base/api/admin/address_book/create'
        : '$base/api/admin/address_book/update');
    final resp = await _post(url, bodyMap);
    _checkAdminResponse(resp, '写入通讯录');

    // 回读校验：确保店名确实以 UTF-8 写进了 alias，而不是只返回成功码。
    final verify = await _findAbRow(rec.deviceId);
    if (verify == null || (verify['alias'] ?? '').toString() != rec.name) {
      throw '通讯录写入后校验未通过，请重试';
    }
  }

  // ---------- 设备管理写入（后台管理 API） ----------
  //
  // 列表：GET  /api/admin/peer/list?id=<deviceId>
  // 更新：POST /api/admin/peer/update   body=PeerForm（含 row_id + alias）
  // 见 http/controller/admin/peer.go。写入 alias = 店名，与通讯录保持一致。

  /// 把店名写入设备管理（按设备 ID 匹配，更新其 alias 字段）。
  /// 返回 null 表示成功；返回字符串表示失败原因，由弹窗直接展示，
  /// 不再静默跳过，确保用户能明确知道别名没有写进去。
  Future<String?> writeDeviceInfo(String deviceId, RhStoreRecord rec) async {
    try {
      final base = await apiServer;
      final listUrl =
          Uri.parse('$base/api/admin/peer/list').replace(queryParameters: {
        'id': deviceId,
        'page': '1',
        'pageSize': '10',
      });
      final listResp = await _get(listUrl);
      final listJson = _checkAdminResponse(listResp, '查询设备管理');

      Map<String, dynamic>? deviceRow;
      for (final item in _rowsFromAdminJson(listJson)) {
        if (item is Map<String, dynamic> &&
            (item['id'] ?? '').toString() == deviceId) {
          deviceRow = item;
          break;
        }
      }
      if (deviceRow == null) {
        return '设备管理未找到设备 $deviceId，请确认设备已连接专属服务器后重试';
      }

      final body = <String, dynamic>{
        'row_id': deviceRow['row_id'],
        'id': deviceId,
        'alias': rec.name,
      };
      final updateUrl = Uri.parse('$base/api/admin/peer/update');
      final resp = await _post(updateUrl, body);
      _checkAdminResponse(resp, '写入设备管理');

      // 回读校验：确认 alias 真的写进去了。
      final verifyResp = await _get(listUrl);
      final verifyJson = _checkAdminResponse(verifyResp, '校验设备管理');
      for (final item in _rowsFromAdminJson(verifyJson)) {
        if (item is Map<String, dynamic> &&
            (item['id'] ?? '').toString() == deviceId) {
          if ((item['alias'] ?? '').toString() == rec.name) return null;
          return '设备管理别名校验未通过，请重试';
        }
      }
      return '设备管理别名校验未通过，请重试';
    } catch (e) {
      return '写入设备管理失败：$e';
    }
  }

  // ---------- 统一同步入口 ----------

  /// 首次配置提交：校验 -> 网络同步（地址簿 + 设备管理）-> 本地持久化。
  Future<SyncResult> submitStoreName(String rawName) async {
    final name = rawName.trim();
    if (name.isEmpty) return SyncResult.failure('店名不能为空');

    try {
      final deviceId = await _waitForMyId();

      // 恢复逻辑：若本地已有该设备记录（含备注），优先沿用本地备注；
      // 否则尝试从通讯录取回备注，实现「被删除门店再次同步时恢复展示」。
      final cached = await loadCache();
      final local = cached.firstWhere(
        (e) => e.deviceId == deviceId,
        orElse: () => RhStoreRecord(deviceId: deviceId, name: name, note: ''),
      );
      String note = local.note;
      if (note.isEmpty) {
        final remoteNote = await fetchNoteFromAb(deviceId);
        if (remoteNote.isNotEmpty) note = remoteNote;
      }

      final rec = RhStoreRecord(deviceId: deviceId, name: name, note: note);

      // 双向同步：共享通讯录（address_book）+ 设备管理（peer）。
      await upsertPeer(rec);
      final deviceError = await writeDeviceInfo(deviceId, rec);
      if (deviceError != null) return SyncResult.failure(deviceError);

      // 成功后持久化到本地，后续不再弹窗。
      await setStoreName(name);
      await setStoreNote(note);
      await upsertCache(rec);
      await markSetupDone();
      currentStoreName.value = name;
      return SyncResult.success();
    } catch (e) {
      return SyncResult.failure(e.toString());
    }
  }

  /// 启动时的后台双向同步：刷新通讯录备注展示，并在记录被删除时恢复。
  Future<void> syncOnStart() async {
    if (!await isSetupDone()) return;
    try {
      final deviceId = await _waitForMyId();
      final name = await getStoreName();
      if (name.isEmpty) return;

      final remoteRow = await _findAbRow(deviceId);
      final cached = await loadCache();
      final local = cached.firstWhere(
        (e) => e.deviceId == deviceId,
        orElse: () => RhStoreRecord(deviceId: deviceId, name: name, note: ''),
      );

      // 远程记录被删除 -> 用本地缓存重新写入，恢复展示。
      if (remoteRow == null) {
        final rec = RhStoreRecord(
            deviceId: deviceId, name: local.name, note: local.note);
        await upsertPeer(rec);
        final err = await writeDeviceInfo(deviceId, rec);
        if (err != null) debugPrint('rh_store syncOnStart: $err');
      } else {
        // 远程存在：以远程 alias 为准确认门店名，并回填本地（双向同步另一方向）。
        final remoteAlias = (remoteRow['alias'] ?? '').toString();
        if (remoteAlias.isNotEmpty && remoteAlias != local.name) {
          await setStoreName(remoteAlias);
          currentStoreName.value = remoteAlias;
          await upsertCache(RhStoreRecord(
              deviceId: deviceId, name: remoteAlias, note: remoteAlias));
        }
      }
    } catch (e) {
      debugPrint('rh_store syncOnStart: $e');
    }
  }
}

/// 首页右侧品牌区：上方 logo、下方店名。
/// 使用原有文字颜色来源，店名字号放大并限制单行省略。
class StoreNameHomeBadge extends StatelessWidget {
  const StoreNameHomeBadge({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final name = RhStoreService.currentStoreName.value.trim();
      if (name.isEmpty) return const SizedBox.shrink();

      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Image.asset(
                'assets/rh_store_logo.png',
                width: 72,
                height: 72,
                fit: BoxFit.contain,
              ),
              const SizedBox(height: 16),
              Tooltip(
                message: name,
                child: Text(
                  name,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                    color: Theme.of(context).textTheme.bodyMedium?.color,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}
