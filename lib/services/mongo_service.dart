import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'local_queue.dart';
import 'location_tracker.dart';

class MongoService {
  static final MongoService _instance = MongoService._internal();
  factory MongoService() => _instance;
  MongoService._internal();

  Db? _db;
  DbCollection? _collection;

  final String _connectionString =
      "mongodb+srv://aswinharidas0_db_user:MhjUydcZIoHmhnmY@singularity.b6oshdq.mongodb.net/singularity?appName=singularity";

  // Position stream subscription (from LocationTracker)
  StreamSubscription<Position>? _positionSub;

  // Periodic queue-flush timer — independent of location events
  Timer? _flushTimer;
  static const Duration _flushInterval = Duration(seconds: 30);

  Position? _lastPosition;

  // Minimum distance in metres to record a new point (secondary dedup guard
  // alongside the Fused Provider's own distanceFilter)
  static const double _minRecordDistance = 20.0;

  final LocalQueue _queue = LocalQueue();
  final LocationTracker _tracker = LocationTracker();

  int _totalSynced = 0;
  int _totalQueued = 0;
  int _pendingCount = 0;

  void Function(String)? onLog;
  void Function(MotionState)? onMotionStateChanged;

  void _log(String message) {
    debugPrint(message);
    onLog?.call(message);
  }

  int get totalSynced => _totalSynced;
  int get totalQueued => _totalQueued;
  int get pendingCount => _pendingCount;
  bool get isConnected => _db != null && _db!.isConnected;
  MotionState get motionState => _tracker.currentMotionState;
  LocationTracker get tracker => _tracker;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> connect() async {
    try {
      await _queue.init();
      _pendingCount = await _queue.count();
      _log('Local queue initialized');
    } catch (e) {
      _log('Error initializing local queue: $e');
    }

    try {
      _log('Connecting to MongoDB...');
      _db = await Db.create(_connectionString);
      await _db!.open().timeout(const Duration(seconds: 8));
      _collection = _db!.collection('sensor_data');
      _log('Connected to MongoDB');
    } catch (e) {
      _log('Error connecting to MongoDB: $e');
      rethrow;
    }
  }

  void startTracking() {
    // Wire up tracker logging → our log callback
    _tracker.onLog = _log;
    _tracker.onMotionStateChanged = (state) {
      _log('Motion state → ${state.name.toUpperCase()}');
      onMotionStateChanged?.call(state);
    };

    // Subscribe to position events from the tracker's stream
    _positionSub = _tracker.positionStream.listen(_onNewPosition);

    // Start the motion-gated GPS engine
    _tracker.startTracking();

    // Start periodic queue flush (handles DB reconnects + offline catchup)
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(_flushInterval, (_) => _flushQueue());

    _log('Tracking started — Fused Location stream, motion-gated');
  }

  void stopTracking() {
    _tracker.stopTracking();
    _positionSub?.cancel();
    _positionSub = null;
    _flushTimer?.cancel();
    _flushTimer = null;
    _log('Tracking stopped');
  }

  Future<void> close() async {
    await _flushQueue();
    stopTracking();
    _tracker.dispose();
    await _queue.close();
    await _db?.close();
  }

  // ---------------------------------------------------------------------------
  // Position handler — called by Fused Location stream
  // ---------------------------------------------------------------------------

  Future<void> _onNewPosition(Position position) async {
    // Secondary dedup: skip if the Fused Provider fires a point too close
    if (_lastPosition != null) {
      final dist = Geolocator.distanceBetween(
        _lastPosition!.latitude,
        _lastPosition!.longitude,
        position.latitude,
        position.longitude,
      );
      if (dist < _minRecordDistance) {
        _log('Position dedup: ${dist.toStringAsFixed(1)}m — skipped');
        return;
      }
    }

    await _flushQueue();

    final motionLabel = _tracker.currentMotionState.name;

    final data = {
      'timestamp': DateTime.now().toIso8601String(),
      'location': {
        'type': 'Point',
        'coordinates': [position.longitude, position.latitude],
        'accuracy': position.accuracy,
        'altitude': position.altitude,
        'speed': position.speed,
      },
      'motion': motionLabel,
    };

    // Always enqueue locally first for resilience
    await _queue.enqueue(data);
    _totalQueued++;

    if (_db != null && _db!.isConnected && _collection != null) {
      try {
        await _collection!.insert(data);
        _totalSynced++;
        await _queue.flush(1);
        _log(
          'Sent | motion: $motionLabel | acc: ${position.accuracy.toStringAsFixed(0)}m | '
          'speed: ${position.speed.toStringAsFixed(1)}m/s',
        );
      } catch (e) {
        _log('MongoDB write failed (queued locally): $e');
      }
    } else {
      final pending = await _queue.count();
      _log(
        'Queued locally (offline) | motion: $motionLabel | pending: $pending',
      );
    }

    _pendingCount = await _queue.count();
    _lastPosition = position;
  }

  Future<void> saveSharedContent(String content) async {
    if (_db == null || !_db!.isConnected) await connect();
    await _db!.collection('shared_data').insert({
      'content': content,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  // ---------------------------------------------------------------------------
  // Queue flush — called periodically and before every write
  // ---------------------------------------------------------------------------

  Future<void> _flushQueue() async {
    if (_db == null || !_db!.isConnected || _collection == null) return;

    try {
      final items = await _queue.peekAll();
      if (items.isEmpty) return;

      _log('Flushing ${items.length} queued items to MongoDB...');
      int sent = 0;
      for (final item in items) {
        try {
          await _collection!.insert(item);
          sent++;
        } catch (e) {
          _log('Failed to send queued item: $e');
          break;
        }
      }

      if (sent > 0) {
        await _queue.flush(sent);
        _totalSynced += sent;
        _log('Flushed $sent items. $_totalSynced synced total.');
      }
      _pendingCount = await _queue.count();
    } catch (e) {
      _log('Error flushing queue: $e');
      _pendingCount = await _queue.count();
    }
  }
}
