import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

// ---------------------------------------------------------------------------
// Motion state — drives GPS accuracy and distance filter decisions
// ---------------------------------------------------------------------------
enum MotionState { stationary, walking, driving }

// ---------------------------------------------------------------------------
// LocationTracker
//
// 3-layer battery-efficient GPS:
//   1. Motion Gate   — accelerometer samples at 2 Hz (near-zero battery cost)
//                      GPS stream is paused entirely when stationary.
//   2. Fused Stream  — Geolocator.getPositionStream() with OS-level distanceFilter
//                      so the Fused Location Provider does the batching.
//   3. Adaptive Acc  — balanced (cell+WiFi) normally, high (GPS) when driving.
// ---------------------------------------------------------------------------
class LocationTracker {
  // --- Thresholds ---
  static const double _accelMovingThreshold = 0.6;   // m/s² deviation from gravity
  static const double _accelDrivingThreshold = 1.8;  // m/s² — fast movement
  static const double _gyroMovingThreshold = 0.12;   // rad/s

  // How many consecutive stationary samples before we call it "stationary"
  static const int _stationaryHysteresis = 4;  // ~2 s at 2 Hz
  static const int _drivingHysteresis = 3;      // ~1.5 s at 2 Hz

  // Distance filters (OS-level, in metres)
  static const int _distanceFilterWalking = 50;
  static const int _distanceFilterDriving = 100;

  // Stationary timeouts before GPS stream is killed
  static const Duration _reduceAccuracyAfter = Duration(minutes: 2);
  static const Duration _pauseGpsAfter = Duration(minutes: 5);

  // Motion-sample interval
  static const Duration _motionSampleInterval = Duration(milliseconds: 500);

  // --- State ---
  MotionState _motionState = MotionState.stationary;
  int _stationaryCount = 0;
  int _drivingCount = 0;
  DateTime? _lastMotionTime;

  AccelerometerEvent? _latestAccel;
  GyroscopeEvent? _latestGyro;

  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<Position>? _positionSub;
  Timer? _motionCheckTimer;
  Timer? _stationaryTimeoutTimer;

  bool _gpsStreamActive = false;
  bool _isRunning = false;

  // --- Public surface ---
  final StreamController<Position> _positionController =
      StreamController<Position>.broadcast();
  Stream<Position> get positionStream => _positionController.stream;

  MotionState get currentMotionState => _motionState;

  void Function(String)? onLog;
  void Function(MotionState)? onMotionStateChanged;

  void _log(String msg) {
    debugPrint('[LocationTracker] $msg');
    onLog?.call(msg);
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  void startTracking() {
    if (_isRunning) return;
    _isRunning = true;
    _lastMotionTime = DateTime.now();
    _startSensorSubscriptions();
    _startMotionCheckLoop();
    _log('Location tracker started (motion-gated)');
  }

  void stopTracking() {
    _isRunning = false;
    _stopGpsStream();
    _stopMotionCheck();
    _accelSub?.cancel();
    _gyroSub?.cancel();
    _accelSub = null;
    _gyroSub = null;
    _log('Location tracker stopped');
  }

  void dispose() {
    stopTracking();
    _positionController.close();
  }

  // ---------------------------------------------------------------------------
  // Layer 1: Motion Gate — accelerometer at 2 Hz
  // ---------------------------------------------------------------------------

  void _startSensorSubscriptions() {
    // Use GAME sampling rate for responsive detection without hammering battery
    _accelSub = accelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen((e) => _latestAccel = e);

    _gyroSub = gyroscopeEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen((e) => _latestGyro = e);
  }

  void _startMotionCheckLoop() {
    _motionCheckTimer?.cancel();
    _motionCheckTimer = Timer.periodic(_motionSampleInterval, (_) {
      _evaluateMotion();
    });
  }

  void _stopMotionCheck() {
    _motionCheckTimer?.cancel();
    _motionCheckTimer = null;
    _stationaryTimeoutTimer?.cancel();
    _stationaryTimeoutTimer = null;
  }

  void _evaluateMotion() {
    if (!_isRunning) return;

    final moving = _isMoving();
    final driving = _isDriving();

    if (!moving) {
      // Phone not moving — increment stationary counter
      _stationaryCount++;
      _drivingCount = 0;

      if (_stationaryCount >= _stationaryHysteresis && _motionState != MotionState.stationary) {
        _transitionTo(MotionState.stationary);
      }
    } else {
      // Phone is moving — reset stationary counter
      _lastMotionTime = DateTime.now();
      _stationaryCount = 0;

      if (driving) {
        _drivingCount++;
        if (_drivingCount >= _drivingHysteresis && _motionState != MotionState.driving) {
          _transitionTo(MotionState.driving);
        }
      } else {
        _drivingCount = 0;
        if (_motionState != MotionState.walking) {
          _transitionTo(MotionState.walking);
        }
      }
    }
  }

  void _transitionTo(MotionState newState) {
    final prev = _motionState;
    _motionState = newState;
    onMotionStateChanged?.call(newState);

    switch (newState) {
      case MotionState.stationary:
        _log('Motion: STATIONARY — GPS stream will pause after timeout');
        _scheduleStationaryTimeout();
        // Don't kill GPS immediately; give it time in case user starts moving
        break;

      case MotionState.walking:
        if (prev == MotionState.stationary) {
          _stationaryTimeoutTimer?.cancel();
          _log('Motion: WALKING — starting GPS stream (50m filter, balanced)');
          _startGpsStream(
            accuracy: LocationAccuracy.medium,
            distanceFilter: _distanceFilterWalking,
          );
        } else if (prev == MotionState.driving) {
          _log('Motion: WALKING — reducing GPS filter to 50m, balanced');
          _restartGpsStream(
            accuracy: LocationAccuracy.medium,
            distanceFilter: _distanceFilterWalking,
          );
        }
        break;

      case MotionState.driving:
        _stationaryTimeoutTimer?.cancel();
        _log('Motion: DRIVING — GPS stream 100m filter, high accuracy');
        _restartGpsStream(
          accuracy: LocationAccuracy.high,
          distanceFilter: _distanceFilterDriving,
        );
        break;
    }
  }

  void _scheduleStationaryTimeout() {
    _stationaryTimeoutTimer?.cancel();

    // After 2 min stationary → reduce to low accuracy
    _stationaryTimeoutTimer = Timer(_reduceAccuracyAfter, () {
      if (_motionState == MotionState.stationary) {
        final idleSecs = _lastMotionTime != null
            ? DateTime.now().difference(_lastMotionTime!).inSeconds
            : 0;
        _log('Stationary ${idleSecs}s — reducing to low accuracy stream');
        _restartGpsStream(
          accuracy: LocationAccuracy.low,
          distanceFilter: 200,
        );
      }

      // After 5 min stationary → kill GPS entirely
      _stationaryTimeoutTimer = Timer(_pauseGpsAfter - _reduceAccuracyAfter, () {
        if (_motionState == MotionState.stationary) {
          _log('Stationary 5min — GPS stream paused entirely');
          _stopGpsStream();
        }
      });
    });
  }

  // ---------------------------------------------------------------------------
  // Layer 2: Fused Location Stream
  // ---------------------------------------------------------------------------

  void _startGpsStream({
    required LocationAccuracy accuracy,
    required int distanceFilter,
  }) {
    if (_gpsStreamActive) return;
    _launchGpsStream(accuracy: accuracy, distanceFilter: distanceFilter);
  }

  void _restartGpsStream({
    required LocationAccuracy accuracy,
    required int distanceFilter,
  }) {
    _stopGpsStream();
    _launchGpsStream(accuracy: accuracy, distanceFilter: distanceFilter);
  }

  void _launchGpsStream({
    required LocationAccuracy accuracy,
    required int distanceFilter,
  }) {
    final settings = AndroidSettings(
      accuracy: accuracy,
      distanceFilter: distanceFilter,
      // intervalDuration: minimum interval between updates (extra guard)
      intervalDuration: const Duration(seconds: 10),
      // Use Fused Location Provider (not legacy LocationManager)
      forceLocationManager: false,
    );

    _positionSub = Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen(
      (position) {
        if (!_positionController.isClosed) {
          _positionController.add(position);
        }
      },
      onError: (e) {
        _log('GPS stream error: $e');
        _gpsStreamActive = false;
      },
    );

    _gpsStreamActive = true;
    _log(
      'GPS stream ON | acc: ${_accuracyLabel(accuracy)} | filter: ${distanceFilter}m',
    );
  }

  void _stopGpsStream() {
    _positionSub?.cancel();
    _positionSub = null;
    if (_gpsStreamActive) {
      _gpsStreamActive = false;
      _log('GPS stream OFF');
    }
  }

  // ---------------------------------------------------------------------------
  // Layer 3: Motion Detection Helpers
  // ---------------------------------------------------------------------------

  double _accelDeviation() {
    if (_latestAccel == null) return 0.0;
    final mag = sqrt(
      _latestAccel!.x * _latestAccel!.x +
          _latestAccel!.y * _latestAccel!.y +
          _latestAccel!.z * _latestAccel!.z,
    );
    return (mag - 9.8).abs();
  }

  double _gyroMagnitude() {
    if (_latestGyro == null) return 0.0;
    return sqrt(
      _latestGyro!.x * _latestGyro!.x +
          _latestGyro!.y * _latestGyro!.y +
          _latestGyro!.z * _latestGyro!.z,
    );
  }

  bool _isMoving() {
    return _accelDeviation() > _accelMovingThreshold ||
        _gyroMagnitude() > _gyroMovingThreshold;
  }

  bool _isDriving() {
    return _accelDeviation() > _accelDrivingThreshold;
  }

  String _accuracyLabel(LocationAccuracy acc) {
    switch (acc) {
      case LocationAccuracy.high:
        return 'high (GPS)';
      case LocationAccuracy.medium:
        return 'medium (balanced)';
      case LocationAccuracy.low:
        return 'low (cell)';
      default:
        return acc.toString();
    }
  }
}
