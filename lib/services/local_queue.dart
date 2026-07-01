import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

class LocalQueue {
  static final LocalQueue _instance = LocalQueue._internal();
  factory LocalQueue() => _instance;
  LocalQueue._internal();

  Database? _db;

  Future<void> init() async {
    if (_db != null) return;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'wayrouter_queue.db'),
      version: 1,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE pending (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          payload TEXT NOT NULL,
          created_at INTEGER NOT NULL
        )
      '''),
    );
  }

  Future<void> enqueue(Map<String, dynamic> data) async {
    await init();
    await _db!.insert('pending', {
      'payload': jsonEncode(data),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<Map<String, dynamic>>> peekAll() async {
    await init();
    final rows = await _db!.query('pending', orderBy: 'id ASC');
    return rows
        .map((r) => jsonDecode(r['payload'] as String) as Map<String, dynamic>)
        .toList();
  }

  Future<int> count() async {
    await init();
    final result = await _db!.rawQuery('SELECT COUNT(*) AS c FROM pending');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> flush(int count) async {
    await init();
    await _db!.delete('pending', where: 'id IN (SELECT id FROM pending ORDER BY id ASC LIMIT ?)', whereArgs: [count]);
  }

  Future<void> clear() async {
    await init();
    await _db!.delete('pending');
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
