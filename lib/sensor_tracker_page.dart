import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'services/mongo_service.dart';
import 'services/location_tracker.dart';

class SensorTrackerPage extends StatefulWidget {
  const SensorTrackerPage({super.key});

  @override
  State<SensorTrackerPage> createState() => _SensorTrackerPageState();
}

class _SensorTrackerPageState extends State<SensorTrackerPage>
    with TickerProviderStateMixin {
  final MongoService _mongoService = MongoService();

  String _getMotionStateLabel(MotionState state) {
    switch (state) {
      case MotionState.walking:
        return '🚶';
      case MotionState.driving:
        return '🚗';
      case MotionState.stationary:
        return '🧘';
    }
  }

  final List<LatLng> _routePoints = [];
  late final MapController _mapController;
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<CompassEvent>? _compassSubscription;
  LatLng? _currentLocation;
  bool _isAutoCentering = true;
  Timer? _recenterTimer;
  AnimationController? _mapAnimationController;

  ResolvedPlace? _currentPlace;
  bool _isResolvingPlace = false;
  String? _resolveError;
  LatLng? _lastResolvedLocation;
  DateTime _lastResolvedTime = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _checkPermissions();
    _checkServiceStatus();

    // Setup initial location centering
    Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
          ),
        )
        .then((pos) {
          if (mounted) {
            setState(() {
              final latLng = LatLng(pos.latitude, pos.longitude);
              _currentLocation = latLng;
              _mapController.move(latLng, 15.0);
              _resolveLocation(latLng);
            });
          }
        })
        .catchError((e) {
          debugPrint('Error getting initial location: $e');
        });

    _mongoService.onLog = (message) {
      if (mounted) {
        final timestamp = DateTime.now()
            .toLocal()
            .toString()
            .split(' ')
            .last
            .substring(0, 8);

        // Track last sync time for notification
        if (message.toLowerCase().contains('sent') ||
            message.toLowerCase().contains('flushed')) {
          // Push updated motion state + sync time to background notification
          FlutterBackgroundService().invoke('motionState', {
            'state': _mongoService.motionState.name,
            'lastSync': timestamp,
          });
        }
        setState(() {});
      }
    };

    _mongoService.onMotionStateChanged = (state) {
      if (mounted) {
        setState(() {});
      }
    };

    // Listen to location updates
    _positionSubscription = _mongoService.tracker.positionStream.listen((
      position,
    ) {
      if (mounted) {
        setState(() {
          final latLng = LatLng(position.latitude, position.longitude);
          _currentLocation = latLng;
          _routePoints.add(latLng);
          if (_isAutoCentering) {
            _mapController.move(latLng, _mapController.camera.zoom);
          }
          _resolveLocation(latLng);
        });
      }
    });

    // Listen to compass/device rotation updates
    _compassSubscription = FlutterCompass.events?.listen((event) {
      if (mounted && event.heading != null) {
        _mapController.rotate(-event.heading!);
      }
    });
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _compassSubscription?.cancel();
    _recenterTimer?.cancel();
    _mapAnimationController?.stop();
    _mapAnimationController?.dispose();
    super.dispose();
  }

  void _animatedMapMove(LatLng destLocation, double destZoom) {
    _mapAnimationController?.stop();
    _mapAnimationController?.dispose();

    final camera = _mapController.camera;
    final latTween = Tween<double>(
      begin: camera.center.latitude,
      end: destLocation.latitude,
    );
    final lngTween = Tween<double>(
      begin: camera.center.longitude,
      end: destLocation.longitude,
    );
    final zoomTween = Tween<double>(begin: camera.zoom, end: destZoom);

    final controller = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _mapAnimationController = controller;

    final animation = CurvedAnimation(
      parent: controller,
      curve: Curves.fastOutSlowIn,
    );

    controller.addListener(() {
      if (mounted) {
        _mapController.move(
          LatLng(latTween.evaluate(animation), lngTween.evaluate(animation)),
          zoomTween.evaluate(animation),
        );
      }
    });

    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        controller.dispose();
        if (_mapAnimationController == controller) {
          _mapAnimationController = null;
        }
      }
    });

    controller.forward();
  }

  void _onMapGesture() {
    _mapAnimationController?.stop();
    _mapAnimationController?.dispose();
    _mapAnimationController = null;

    setState(() {
      _isAutoCentering = false;
    });
    _recenterTimer?.cancel();
    _recenterTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) {
        setState(() {
          _isAutoCentering = true;
          if (_currentLocation != null) {
            _animatedMapMove(_currentLocation!, _mapController.camera.zoom);
          }
        });
      }
    });
  }

  Future<void> _resolveLocation(LatLng location) async {
    if (_isResolvingPlace) return;

    final lastResolved = _lastResolvedLocation;
    final now = DateTime.now();
    if (lastResolved != null) {
      final distance = Geolocator.distanceBetween(
        lastResolved.latitude,
        lastResolved.longitude,
        location.latitude,
        location.longitude,
      );
      final timeSinceLastResolve = now.difference(_lastResolvedTime);

      if (distance < 20.0 &&
          timeSinceLastResolve < const Duration(seconds: 15)) {
        return;
      }
    }

    setState(() {
      _isResolvingPlace = true;
      _resolveError = null;
    });

    _lastResolvedLocation = location;
    _lastResolvedTime = now;

    try {
      final client = HttpClient();
      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?format=jsonv2'
        '&lat=${location.latitude}&lon=${location.longitude}'
        '&addressdetails=1',
      );

      final request = await client.getUrl(url);
      request.headers.set('user-agent', 'wayrouter_flutter_app');

      final response = await request.close();
      if (response.statusCode == 200) {
        final responseBody = await response.transform(utf8.decoder).join();
        final Map<String, dynamic> data =
            jsonDecode(responseBody) as Map<String, dynamic>;

        if (mounted) {
          setState(() {
            _currentPlace = ResolvedPlace.fromJson(data);
            _isResolvingPlace = false;
          });
        }
      } else {
        throw HttpException(
          'Server returned status code ${response.statusCode}',
        );
      }
    } catch (e) {
      debugPrint('Error resolving location details: $e');
      if (mounted) {
        setState(() {
          _isResolvingPlace = false;
          _resolveError = 'Failed to resolve location details';
        });
      }
    }
  }

  Widget _buildLocationDetailsCard() {
    if (_isResolvingPlace && _currentPlace == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            CupertinoActivityIndicator(
              radius: 6,
            ),
            SizedBox(width: 8),
            Text(
              'Resolving address...',
              style: TextStyle(
                color: Color(0xFF6B7280),
                fontSize: 12.5,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      );
    }

    if (_resolveError != null && _currentPlace == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Text(
          _resolveError!,
          style: const TextStyle(
            color: Color(0xFFEF4444),
            fontSize: 12.5,
            fontWeight: FontWeight.w400,
          ),
        ),
      );
    }

    final place = _currentPlace;
    if (place == null) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  place.name,
                  style: const TextStyle(
                    color: Color(0xFF111827),
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (place.categories.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  place.categories.join(' • '),
                  style: const TextStyle(
                    color: Color(0xFFF43F5E),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (_isResolvingPlace) ...[
                const SizedBox(width: 8),
                const CupertinoActivityIndicator(
                  radius: 5,
                ),
              ],
            ],
          ),
          const SizedBox(height: 3),
          Text(
            place.address,
            style: const TextStyle(
              color: Color(0xFF6B7280),
              fontSize: 12.5,
              height: 1.3,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Future<void> _checkServiceStatus() async {
    final isRunning = await FlutterBackgroundService().isRunning();
    if (isRunning) {
      try {
        await _mongoService.connect();
        _mongoService.startTracking();
      } catch (e) {
        debugPrint('Error auto-starting tracker: $e');
      }
    }
  }

  Future<void> _checkPermissions() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF9FAFB),
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          'Wayrouter',
          style: TextStyle(
            color: Color(0xFF111827),
            fontWeight: FontWeight.w800,
            fontSize: 20,
            letterSpacing: 0.8,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: Text(_getMotionStateLabel(_mongoService.motionState)),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              height: 240,
              margin: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFE5E7EB), width: 1),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(6),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Stack(
                  children: [
                    FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter:
                            _currentLocation ?? const LatLng(9.9312, 76.2673),
                        initialZoom: 15.0,
                        maxZoom: 18.0,
                        minZoom: 3.0,
                        onPositionChanged: (camera, hasGesture) {
                          if (hasGesture) {
                            _onMapGesture();
                          }
                        },
                      ),
                      children: [
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.github.wayrouter',
                        ),
                        if (_routePoints.isNotEmpty)
                          PolylineLayer(
                            polylines: [
                              Polyline(
                                points: _routePoints,
                                strokeWidth: 4.0,
                                color: const Color(0xFFF43F5E),
                              ),
                            ],
                          ),
                        MarkerLayer(
                          markers: [
                            if (_currentLocation != null)
                              Marker(
                                point: _currentLocation!,
                                width: 18,
                                height: 18,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: const Color(0xFF4B5563),
                                      width: 2.0,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withAlpha(50),
                                        blurRadius: 4,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            _buildLocationDetailsCard(),
          ],
        ),
      ),
    );
  }
}

class ResolvedPlace {
  final String name;
  final String address;
  final List<String> categories;

  ResolvedPlace({
    required this.name,
    required this.address,
    required this.categories,
  });

  factory ResolvedPlace.fromJson(Map<String, dynamic> json) {
    final addressMap = json['address'] as Map<String, dynamic>?;

    final List<String> categories = [];
    final String? osmClass = json['class'] as String?;
    final String? osmType = json['type'] as String?;
    if (osmClass != null && osmClass != 'place') {
      categories.add(osmClass);
    }
    if (osmType != null && osmType != osmClass && osmType != 'yes') {
      categories.add(osmType);
    }

    String resolvedName = '';

    if (json['name'] != null && (json['name'] as String).isNotEmpty) {
      resolvedName = json['name'] as String;
    } else if (addressMap != null) {
      resolvedName =
          addressMap['amenity'] as String? ??
          addressMap['shop'] as String? ??
          addressMap['tourism'] as String? ??
          addressMap['building'] as String? ??
          addressMap['road'] as String? ??
          addressMap['suburb'] as String? ??
          'Unknown Location';
    } else {
      resolvedName = 'Point of Interest';
    }

    final String displayName =
        json['display_name'] as String? ?? 'No address available';

    return ResolvedPlace(
      name: resolvedName,
      address: displayName,
      categories: categories
          .map((c) => _capitalize(c.replaceAll('_', ' ')))
          .toList(),
    );
  }

  static String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }
}
