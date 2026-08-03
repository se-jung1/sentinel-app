import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// 앱의 단일 데이터 소스. 클라우드 연결 상태와 무관하게 동작한다.
///
/// (device_id, seq) 를 PRIMARY KEY 로 두고 INSERT OR IGNORE 로 넣는다.
/// 서버의 `$setOnInsert` + 유니크 인덱스 업서트와 같은 의미 —
/// 노드가 원본이므로 먼저 도착한 값이 정본이고, 같은 배치를 몇 번
/// 재전송해도 결과가 같다.
class SentinelDb {
  SentinelDb._(this._db);

  final Database _db;
  Database get raw => _db;

  static SentinelDb? _instance;
  static SentinelDb get instance {
    final db = _instance;
    if (db == null) {
      throw StateError('SentinelDb.open() 을 먼저 호출해야 합니다');
    }
    return db;
  }

  /// [path] 를 주면 그 경로를 그대로 쓴다 (테스트의 인메모리 DB 용).
  static Future<SentinelDb> open({
    String fileName = 'sentinel.db',
    String? path,
  }) async {
    if (_instance != null) return _instance!;
    final db = await openDatabase(
      path ?? p.join(await getDatabasesPath(), fileName),
      version: 1,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE devices(
            device_id    TEXT PRIMARY KEY,
            site_name    TEXT,
            ble_id       TEXT,
            last_sync_at INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE readings(
            device_id TEXT    NOT NULL,
            seq       INTEGER NOT NULL,
            ts        INTEGER NOT NULL,
            pm25      INTEGER NOT NULL,
            pm10      INTEGER NOT NULL,
            flags     INTEGER NOT NULL DEFAULT 0,
            quality   TEXT    NOT NULL DEFAULT '',
            battery   INTEGER,
            uploaded  INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(device_id, seq)
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_readings_ts ON readings(device_id, ts)',
        );
        await db.execute(
          'CREATE INDEX idx_readings_pending ON readings(uploaded, device_id)',
        );
      },
    );
    return _instance = SentinelDb._(db);
  }

  Future<void> upsertDevice(DeviceInfo device) async {
    await _db.insert(
      'devices',
      device.toRow()..removeWhere((_, v) => v == null),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> touchLastSync(String deviceId, DateTime at) async {
    await _db.update(
      'devices',
      {'last_sync_at': at.millisecondsSinceEpoch ~/ 1000},
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
  }

  Future<DeviceInfo?> device(String deviceId) async {
    final rows = await _db.query(
      'devices',
      where: 'device_id = ?',
      whereArgs: [deviceId],
      limit: 1,
    );
    return rows.isEmpty ? null : DeviceInfo.fromRow(rows.first);
  }

  Future<List<DeviceInfo>> devices() async {
    final rows = await _db.query('devices', orderBy: 'device_id');
    return rows.map(DeviceInfo.fromRow).toList();
  }

  /// 멱등 저장. 같은 (device_id, seq) 는 무시된다.
  /// 반환값은 신규 저장 건수 / 중복 건수 — 서버 업로드 응답과 같은 형태.
  Future<InsertResult> insertReadings(List<Reading> readings) async {
    if (readings.isEmpty) return const InsertResult(inserted: 0, duplicated: 0);

    final batch = _db.batch();
    for (final r in readings) {
      batch.insert(
        'readings',
        r.toRow(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    // OR IGNORE 로 걸러진 행은 rowid 0 을 돌려준다.
    final results = await batch.commit(noResult: false);
    final inserted = results.where((e) => e is int && e != 0).length;
    return InsertResult(
      inserted: inserted,
      duplicated: readings.length - inserted,
    );
  }

  /// 아직 서버로 못 올린 측정값. 오래된 것부터 배치 단위로 꺼낸다.
  Future<List<Reading>> pendingUploads({int limit = 1000}) async {
    final rows = await _db.query(
      'readings',
      where: 'uploaded = 0',
      orderBy: 'device_id, seq',
      limit: limit,
    );
    return rows.map(Reading.fromRow).toList();
  }

  /// 업로드에 성공한 구간을 표시한다.
  /// 서버가 멱등이라 중복으로 처리된 건도 올라간 것으로 본다.
  Future<void> markUploaded(String deviceId, List<int> seqs) async {
    if (seqs.isEmpty) return;
    final placeholders = List.filled(seqs.length, '?').join(',');
    await _db.rawUpdate(
      'UPDATE readings SET uploaded = 1 '
      'WHERE device_id = ? AND seq IN ($placeholders)',
      [deviceId, ...seqs],
    );
  }

  Future<int> pendingCount() async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM readings WHERE uploaded = 0',
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  /// 마지막으로 받은 seq. 다음 BLE 다운로드의 시작점으로 쓴다.
  Future<int> lastSeq(String deviceId) async {
    final rows = await _db.rawQuery(
      'SELECT MAX(seq) AS s FROM readings WHERE device_id = ?',
      [deviceId],
    );
    return (rows.first['s'] as int?) ?? -1;
  }

  Future<void> close() async {
    await _db.close();
    _instance = null;
  }
}

class InsertResult {
  const InsertResult({required this.inserted, required this.duplicated});
  final int inserted;
  final int duplicated;
  int get total => inserted + duplicated;
}
