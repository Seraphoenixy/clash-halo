/// Versioned, cross-platform backup export and restore.
///
/// The backup contains nodes, subscriptions and common settings only. Logs,
/// temp files and device-specific runtime state are excluded by construction:
/// the export functions only ever read those three tables.
///
/// Encryption is optional and only applied to the payload. The header stays
/// readable so a wrong password is reported as "wrong password" rather than
/// "corrupt file". Algorithms are the standard ones from `package:cryptography`
/// (PBKDF2-HMAC-SHA256 + AES-256-GCM); no custom construction is used.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:halo_domain/halo_domain.dart';

import 'repositories.dart';
import 'schema.dart';
import 'store.dart';

/// Backup format version. Independent from the IPC protocol version so either
/// side can evolve without invalidating the other.
const int kBackupFormatVersion = 1;

const String kBackupMagic = 'clash-halo-backup';

/// PBKDF2 iterations. 100k keeps export under a second on this machine
/// (measured 0.81 s) while remaining slow enough for a password at rest.
const int kBackupKdfIterations = 100000;

/// Settings that are device-specific and must not travel between platforms.
const _deviceSpecificSettingPrefixes = [
  'system.proxy',
  'app.path',
  'native.',
  'ui.window',
];

/// Backup body before encryption.
class BackupPayload {
  const BackupPayload({
    required this.nodes,
    required this.subscriptions,
    required this.settings,
    required this.exportedAtMs,
    required this.appVersion,
    this.groups = const [],
    this.platform,
  });

  final List<ProxyNode> nodes;
  final List<SubscriptionProfile> subscriptions;

  /// Subscription groups. Defaulted so a backup written before v6 still loads;
  /// such a file simply has no groups, and its subscriptions land ungrouped.
  final List<SubscriptionGroup> groups;
  final Map<String, String> settings;
  final int exportedAtMs;
  final String appVersion;

  /// Informational only: restore never applies platform-specific behaviour.
  final String? platform;

  Map<String, Object?> toJson() => {
        'nodes': nodes.map((n) => n.toJson()).toList(),
        'subscriptions': subscriptions.map((s) => s.toJson()).toList(),
        if (groups.isNotEmpty) 'groups': groups.map((g) => g.toJson()).toList(),
        'settings': settings,
        'exportedAtMs': exportedAtMs,
        'appVersion': appVersion,
        if (platform != null) 'platform': platform,
      };

  factory BackupPayload.fromJson(Map<String, Object?> json) => BackupPayload(
        nodes: [
          for (final raw in (json['nodes'] as List? ?? const []))
            ProxyNode.fromJson((raw as Map).cast<String, Object?>()),
        ],
        subscriptions: [
          for (final raw in (json['subscriptions'] as List? ?? const []))
            SubscriptionProfile.fromJson((raw as Map).cast<String, Object?>()),
        ],
        groups: [
          for (final raw in (json['groups'] as List? ?? const []))
            SubscriptionGroup.fromJson((raw as Map).cast<String, Object?>()),
        ],
        settings: (json['settings'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ??
            const {},
        exportedAtMs: (json['exportedAtMs'] as num?)?.toInt() ?? 0,
        appVersion: json['appVersion'] as String? ?? '0.0.0',
        platform: json['platform'] as String?,
      );
}

/// Why an export or import failed, with a message suitable for the UI.
class BackupError implements Exception {
  const BackupError(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'BackupError($code): $message';
}

/// Result of building a backup file.
class BackupResult {
  const BackupResult({this.text, this.encrypted = false, this.error});

  final String? text;
  final bool encrypted;
  final BackupError? error;

  bool get ok => text != null;
}

/// Restore preview: what would change, shown before applying anything.
class RestorePreview {
  const RestorePreview({
    required this.payload,
    required this.encrypted,
    required this.nodeDelta,
    required this.subscriptionDelta,
    required this.settingCount,
    required this.conflicts,
    required this.exportedAtMs,
    required this.appVersion,
    this.platform,
  });

  final BackupPayload payload;
  final bool encrypted;
  final int nodeDelta;
  final int subscriptionDelta;
  final int settingCount;

  /// Nodes in the backup whose fingerprint already exists locally.
  final int conflicts;
  final int exportedAtMs;
  final String appVersion;
  final String? platform;

  String get summary =>
      '备份包含 ${payload.nodes.length} 个节点、${payload.subscriptions.length} 个订阅、'
      '${payload.settings.length} 项设置；'
      '导入后节点 ${nodeDelta >= 0 ? '+' : ''}$nodeDelta，订阅 ${subscriptionDelta >= 0 ? '+' : ''}$subscriptionDelta'
      '${conflicts > 0 ? '，$conflicts 个节点与现有数据相同' : ''}';
}

/// Result of applying a restore.
class RestoreResult {
  const RestoreResult({
    this.applied = false,
    this.nodesImported = 0,
    this.subscriptionsImported = 0,
    this.settingsImported = 0,
    this.rollbackBackup,
    this.error,
  });

  final bool applied;
  final int nodesImported;
  final int subscriptionsImported;
  final int settingsImported;

  /// A backup of the pre-restore state, taken automatically so the user can
  /// undo a restore that turned out to be wrong.
  final String? rollbackBackup;
  final BackupError? error;
}

abstract final class Backup {
  /// Collects the current state. [platform] is recorded but never re-applied.
  static BackupPayload collect(
    HaloStore store, {
    required int nowMs,
    required String appVersion,
    String? platform,
    SettingsRepository? settings,
  }) {
    final nodes = NodeRepository(store);
    final subs = SubscriptionRepository(store);
    final set = SettingsRepository(store);
    final allSettings = set.all();
    return BackupPayload(
      nodes: nodes.allNodes(),
      subscriptions: subs.allProfiles(),
      groups: SubscriptionGroupRepository(store).allGroups(),
      settings: {
        for (final e in allSettings.entries)
          if (!_isDeviceSpecific(e.key)) e.key: e.value,
      },
      exportedAtMs: nowMs,
      appVersion: appVersion,
      platform: platform,
    );
  }

  static bool _isDeviceSpecific(String key) =>
      _deviceSpecificSettingPrefixes.any((p) => key.startsWith(p));

  /// Serialises [payload] to a **plaintext** backup document.
  ///
  /// There is deliberately no synchronous encrypted variant: PBKDF2 costs
  /// real time, so encryption is async-only (see [exportSafe]). Callers that
  /// might have a password must call [exportSafe] instead.
  static BackupResult exportPlain(BackupPayload payload) {
    // The payload map goes into the document as-is: the old encode → decode →
    // encode chain walked the whole node list three times, which on a restore
    // backup (taken automatically before every apply) was pure double work.
    return BackupResult(
      text: jsonEncode({
        'magic': kBackupMagic,
        'formatVersion': kBackupFormatVersion,
        'encrypted': false,
        'exportedAtMs': payload.exportedAtMs,
        'appVersion': payload.appVersion,
        'platform': payload.platform,
        'payload': payload.toJson(),
      }),
    );
  }

  /// Serialises [payload], encrypting it when [password] is non-empty.
  ///
  /// Returns a [BackupResult] rather than throwing so callers can show the
  /// real reason in the UI.
  static Future<BackupResult> exportSafe(
    BackupPayload payload, {
    String? password,
  }) async {
    if (password == null || password.isEmpty) return exportPlain(payload);
    return _exportEncrypted(payload, password);
  }

  static Future<BackupResult> _exportEncrypted(
      BackupPayload payload, String password) async {
    final payloadJson = jsonEncode(payload.toJson());
    try {
      final salt = _randomBytes(16);
      final nonce = _randomBytes(12);
      final key = await _deriveKey(password, salt);
      final box = await AesGcm.with256bits().encrypt(
        utf8.encode(payloadJson),
        secretKey: key,
        nonce: nonce,
      );
      final body = <String, Object?>{
        'magic': kBackupMagic,
        'formatVersion': kBackupFormatVersion,
        'encrypted': true,
        'kdf': 'pbkdf2-hmac-sha256',
        'iterations': kBackupKdfIterations,
        'cipher': 'aes-256-gcm',
        'salt': base64.encode(salt),
        'nonce': base64.encode(nonce),
        'tag': base64.encode(box.mac.bytes),
        'ciphertext': base64.encode(box.cipherText),
        'exportedAtMs': payload.exportedAtMs,
        'appVersion': payload.appVersion,
        'payloadSummary': {
          'nodes': payload.nodes.length,
          'subscriptions': payload.subscriptions.length,
          'settings': payload.settings.length,
        },
      };
      return BackupResult(text: jsonEncode(body), encrypted: true);
    } catch (e) {
      return BackupResult(error: BackupError('encrypt_failed', '加密导出失败: $e'));
    }
  }

  /// Parses a backup document into a preview without touching the database.
  ///
  /// This is the only inspection entry point: decrypting needs PBKDF2, which
  /// cannot run synchronously on the UI isolate.
  static Future<({RestorePreview? preview, BackupError? error})> inspectAsync(
    String text, {
    required Map<String, int> existingNodeCountsByFingerprint,
    required int existingSubscriptionCount,
    String? password,
  }) async {
    Map<String, Object?> doc;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        return (
          preview: null,
          error: const BackupError('bad_format', '备份文件不是 JSON 对象'),
        );
      }
      doc = decoded.cast<String, Object?>();
    } catch (e) {
      return (preview: null, error: BackupError('bad_format', '备份文件无法解析: $e'));
    }
    if ('${doc['magic'] ?? ''}' != kBackupMagic) {
      return (
        preview: null,
        error: const BackupError('bad_magic', '不是 clash-halo 备份文件'),
      );
    }
    final version = (doc['formatVersion'] as num?)?.toInt() ?? 0;
    if (version > kBackupFormatVersion) {
      return (
        preview: null,
        error: BackupError('too_new',
            '备份格式版本 $version 高于当前支持的 $kBackupFormatVersion，请升级应用'),
      );
    }
    final encrypted = doc['encrypted'] == true;
    if (!encrypted && (password != null && password.isNotEmpty)) {
      return (
        preview: null,
        error: const BackupError('not_encrypted', '该备份未加密，请勿输入密码'),
      );
    }
    BackupPayload? payload;
    if (encrypted) {
      if (password == null || password.isEmpty) {
        return (
          preview: null,
          error: const BackupError('password_required', '该备份已加密，需要输入密码'),
        );
      }
      try {
        final salt = base64.decode('${doc['salt']}');
        final nonce = base64.decode('${doc['nonce']}');
        final tag = base64.decode('${doc['tag']}');
        final cipher = base64.decode('${doc['ciphertext']}');
        final iterations = (doc['iterations'] as num?)?.toInt() ?? kBackupKdfIterations;
        final key = await _deriveKey(password, Uint8List.fromList(salt),
            iterations: iterations);
        final plain = await AesGcm.with256bits().decrypt(
          SecretBox(cipher, nonce: nonce, mac: Mac(tag)),
          secretKey: key,
        );
        payload = BackupPayload.fromJson(
            (jsonDecode(utf8.decode(plain)) as Map).cast<String, Object?>());
      } on SecretBoxAuthenticationError {
        return (
          preview: null,
          error: const BackupError('wrong_password', '密码错误或备份已损坏'),
        );
      } catch (e) {
        return (preview: null, error: BackupError('bad_encrypted', '加密备份无法读取: $e'));
      }
    } else {
      final raw = doc['payload'];
      if (raw is! Map) {
        return (preview: null, error: const BackupError('bad_payload', '备份缺少 payload'));
      }
      try {
        payload = BackupPayload.fromJson(raw.cast<String, Object?>());
      } catch (e) {
        return (preview: null, error: BackupError('bad_payload', '备份内容无法解析: $e'));
      }
    }
    final conflicts = payload.nodes
        .where((n) => existingNodeCountsByFingerprint.containsKey(n.fingerprint))
        .length;
    final incomingSubIds = payload.subscriptions.map((s) => s.id).toSet();
    final subscriptionDelta =
        incomingSubIds.length - existingSubscriptionCount;
    return (
      preview: RestorePreview(
        payload: payload,
        encrypted: encrypted,
        nodeDelta: payload.nodes.length - conflicts,
        subscriptionDelta: subscriptionDelta,
        settingCount: payload.settings.length,
        conflicts: conflicts,
        exportedAtMs: payload.exportedAtMs,
        appVersion: payload.appVersion,
        platform: payload.platform,
      ),
      error: null,
    );
  }

  /// Applies a previewed restore. Always writes a rollback backup first.
  ///
  /// Merge policy: subscriptions are upserted by id, nodes are inserted by
  /// fingerprint (existing ones win on name, incoming ones win on connection
  /// parameters only when the fingerprint matches, which by definition it
  /// cannot), settings are merged with incoming values taking precedence.
  static RestoreResult apply(
    HaloStore store,
    RestorePreview preview, {
    required int nowMs,
    required String appVersion,
    String? platform,
  }) {
    final before = collect(store,
        nowMs: nowMs, appVersion: appVersion, platform: platform);
    // The rollback snapshot is written in plaintext so that undoing a restore
    // never depends on a password the user may have mistyped.
    final rollback = exportPlain(before);
    if (!rollback.ok) {
      return RestoreResult(
        error: BackupError('rollback_failed', '无法生成回退备份，已取消导入: ${rollback.error?.message}'),
      );
    }
    try {
      final subs = SubscriptionRepository(store);
      final groups = SubscriptionGroupRepository(store);
      final nodes = NodeRepository(store);
      final settings = SettingsRepository(store);
      var subsImported = 0;
      var nodesImported = 0;
      var settingsImported = 0;
      store.transaction((db) {
        // Groups first: a subscribed profile may carry `groupId`, and restoring
        // the memberships before the names would leave them unresolvable.
        for (final group in preview.payload.groups) {
          groups.upsert(group);
        }
        for (final profile in preview.payload.subscriptions) {
          subs.upsert(profile);
          subsImported++;
        }
        // One batched write: per-node insert used to mean one SELECT plus one
        // implicit commit per row, and a restore of a large backup ran on the
        // UI isolate.
        final written = nodes.insertAll(preview.payload.nodes, nowMs: nowMs);
        // Count what the restore actually stored: identity is global, so a
        // backup that carried the same connection under two profiles now
        // restores it once and the second copy is reported as a skip.
        nodesImported += written.stored.length;
        for (final e in preview.payload.settings.entries) {
          if (_isDeviceSpecific(e.key)) continue;
          settings.setRaw(e.key, e.value);
          settingsImported++;
        }
        setMeta(db, 'last_restore_at', '$nowMs');
        setMeta(db, 'last_restore_app_version', preview.appVersion);
      });
      return RestoreResult(
        applied: true,
        nodesImported: nodesImported,
        subscriptionsImported: subsImported,
        settingsImported: settingsImported,
        rollbackBackup: rollback.text,
      );
    } catch (e) {
      return RestoreResult(error: BackupError('apply_failed', '导入失败: $e'));
    }
  }

  /// Convenience for the UI: number of existing nodes grouped by fingerprint.
  static Map<String, int> fingerprintIndex(NodeRepository repo) {
    final index = <String, int>{};
    for (final node in repo.allNodes()) {
      index[node.fingerprint] = (index[node.fingerprint] ?? 0) + 1;
    }
    return index;
  }

  static Future<SecretKey> _deriveKey(String password, Uint8List salt,
      {int iterations = kBackupKdfIterations}) {
    return Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256)
        .deriveKeyFromPassword(password: password, nonce: salt);
  }

  static Uint8List _randomBytes(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rng.nextInt(256)));
  }
}
