import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/ride_models.dart';
import '../services/captain_navigation_service.dart';
import '../services/captain_photo_service.dart';
import '../services/iraqi_navigation_service.dart';
import '../services/location_service.dart';
import '../services/notification_center.dart';
import '../services/offline_maps_service.dart';
import '../services/ride_backend_service.dart';
import '../widgets/ride_sheets.dart';

const _captainGreen = Color(0xFF087F65);
const _captainBlue = Color(0xFF0038FF);
const _captainInk = Color(0xFF142421);

class CaptainHomePage extends StatefulWidget {
  const CaptainHomePage({super.key});

  @override
  State<CaptainHomePage> createState() => _CaptainHomePageState();
}

class _CaptainHomePageState extends State<CaptainHomePage>
    with TickerProviderStateMixin {
  final _map = MapController();
  final _backend = RideBackendService.instance;
  final _locationService = GeolocatorLocationService.instance;
  final _dio = Dio();
  late final CaptainNavigationService _navService = CaptainNavigationService(
    dio: _dio,
  );
  late final AnimationController _navAnimController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  );
  final OffRouteDetector _offRouteDetector = OffRouteDetector();

  bool _mapReady = false;
  double _mapRotation = 0;
  double _currentZoom = 14.5;
  LatLng _captainPosition = const LatLng(32.5050, 45.8230);
  LatLng _animStartPos = const LatLng(32.5050, 45.8230);
  LatLng _animEndPos = const LatLng(32.5050, 45.8230);
  double _captainHeading = 0;
  double _animStartHeading = 0;
  double _animEndHeading = 0;
  int _speedKmh = 0;
  bool _autoRotateMap = true;
  CaptainProfile _profile = const CaptainProfile();
  bool _loading = true;
  bool _busy = false;
  bool _hasServerUrl = false;
  bool _onBreak = false;

  List<RideRequestPayload> _incomingRequests = const [];
  int _selectedIncomingIndex = 0;
  RideRequestPayload? get _incomingRequest =>
      (_incomingRequests.isNotEmpty &&
              _selectedIncomingIndex >= 0 &&
              _selectedIncomingIndex < _incomingRequests.length)
          ? _incomingRequests[_selectedIncomingIndex]
          : null;
  RideRequestPayload? _activeRide;
  List<LatLng> _routePoints = const [];
  List<CaptainRouteOption> _routeOptions = const [];
  int _selectedRouteIndex = 0;
  bool _selectingRoute = false;
  bool _navigationActive = false;
  bool _offRoute = false;
  bool _rerouting = false;
  double _navProgress = 0;
  double _remainingKm = 0;
  double _remainingMin = 0;
  RouteStepInstruction? _nextInstruction;
  RouteStepInstruction? _followingInstruction;
  String _dynamicInstruction = '';
  bool _followCamera = true;
  bool _voiceEnabled = true;
  String? _lastSpokenKey;
  String? _navPromptShownForRideId;

  StreamSubscription<UserLocation>? _gpsSub;
  StreamSubscription<RideRequestPayload>? _reqSub;
  StreamSubscription<String>? _claimedSub;
  StreamSubscription<RideRequestPayload>? _updateSub;
  Timer? _simMoveTimer;
  Timer? _requestCountdownTimer;
  int _requestCountdown = 30;

  @override
  void initState() {
    super.initState();
    _navAnimController.addListener(_onNavAnimationTick);
    focusedMapPin.addListener(_onFocusedMapPinChanged);
    captainIncomingDestination.addListener(_onCaptainIncomingDestination);
    _initCaptain();
  }

  void _onCaptainIncomingDestination() {
    final dest = captainIncomingDestination.value;
    if (!mounted || dest == null) return;
    captainIncomingDestination.value = null;
    if (_mapReady) {
      _followCamera = false;
      _map.move(dest.point, 15.5);
    }
    focusedMapPin.value = dest;
    setState(() {});
  }

  void _onFocusedMapPinChanged() {
    if (!mounted) return;
    final pin = focusedMapPin.value;
    if (pin != null && _mapReady) {
      _followCamera = false;
      _map.move(pin.point, 16.5);
    }
    setState(() {});
  }

  void _onNavAnimationTick() {
    if (!mounted) return;
    final t = Curves.easeOutCubic.transform(_navAnimController.value);
    final lat = ui.lerpDouble(_animStartPos.latitude, _animEndPos.latitude, t)!;
    final lng = ui.lerpDouble(_animStartPos.longitude, _animEndPos.longitude, t)!;
    var deltaHeading = ((_animEndHeading - _animStartHeading + 540) % 360) - 180;
    final heading = (_animStartHeading + deltaHeading * t + 360) % 360;
    setState(() {
      _captainPosition = LatLng(lat, lng);
      _captainHeading = heading;
    });
    if (_navigationActive && _followCamera && _mapReady) {
      _map.move(_captainPosition, _currentZoom < 15.5 ? 16.5 : _currentZoom);
      if (_autoRotateMap) {
        _map.rotate(-heading);
      }
    }
  }

  void _animateCaptainTo(LatLng target, double heading) {
    _animStartPos = _captainPosition;
    _animEndPos = target;
    _animStartHeading = _captainHeading;
    _animEndHeading = heading;
    _navAnimController
      ..reset()
      ..forward();
  }

  Future<void> _initCaptain() async {
    final profile = await _backend.loadCaptainProfile();
    final serverUrl = await _backend.configuredBaseUrl();
    final pendingLocal = await _backend.fetchActiveRide();
    if (!mounted) return;

    setState(() {
      _profile = profile;
      _hasServerUrl = serverUrl != null;
      _loading = false;
      if (pendingLocal != null) {
        if (pendingLocal.status == RideDispatchStatus.searching &&
            profile.isOnline) {
          _incomingRequests = [pendingLocal];
          _selectedIncomingIndex = 0;
        } else if (pendingLocal.captainId == profile.id &&
            pendingLocal.status != RideDispatchStatus.completed &&
            pendingLocal.status != RideDispatchStatus.cancelled) {
          _activeRide = pendingLocal;
        }
      }
    });

    if (_activeRide != null) {
      _loadRouteForRide(_activeRide!);
    } else if (_incomingRequest != null) {
      _loadRouteForRide(_incomingRequest!);
      _startRequestCountdown();
    }

    _reqSub = _backend.incomingRequests.listen((req) {
      if (!mounted || !_profile.isOnline || _activeRide != null) return;
      if (_profile.approvalStatus != CaptainApprovalStatus.approved) return;
      setState(() {
        final next = List<RideRequestPayload>.from(_incomingRequests)
          ..removeWhere((r) => r.rideId == req.rideId)
          ..add(req);
        next.sort(
          (a, b) => _distanceKmTo(a).compareTo(_distanceKmTo(b)),
        );
        _incomingRequests = next;
        _selectedIncomingIndex = 0;
      });
      _startRequestCountdown();
      if (_incomingRequest != null) {
        _loadRouteForRide(_incomingRequest!);
      }
      SystemSound.play(SystemSoundType.alert);
      HapticFeedback.heavyImpact();
      NotificationCenterService.addCaptainAlert(
        title: 'طلب رحلة جديد (${formatIraqiDinar(req.fareIqd)})',
        body: '${req.originName} -> ${req.destinationName}',
      );
    });

    _claimedSub = _backend.claimedRideIds.listen((rideId) {
      if (!mounted) return;
      if (_incomingRequests.any((r) => r.rideId == rideId) &&
          _activeRide?.rideId != rideId) {
        setState(() {
          _incomingRequests = _incomingRequests
              .where((r) => r.rideId != rideId)
              .toList();
          if (_selectedIncomingIndex >= _incomingRequests.length) {
            _selectedIncomingIndex = 0;
          }
          if (_incomingRequests.isEmpty) {
            _requestCountdownTimer?.cancel();
            _routePoints = const [];
          }
        });
      }
    });

    _updateSub = _backend.rideUpdates.listen((updated) {
      if (!mounted) return;
      if (_activeRide?.rideId == updated.rideId) {
        if (updated.status == RideDispatchStatus.cancelled ||
            updated.status == RideDispatchStatus.completed) {
          setState(() {
            _activeRide = null;
            _routePoints = const [];
          });
        } else {
          setState(() => _activeRide = updated);
        }
      }
    });

    if (_profile.isOnline) {
      await _startGpsTracking();
      await _backend.connectRealtime(role: UserRole.captain);
    }
  }

  @override
  void dispose() {
    captainIncomingDestination.removeListener(_onCaptainIncomingDestination);
    focusedMapPin.removeListener(_onFocusedMapPinChanged);
    _navAnimController.removeListener(_onNavAnimationTick);
    _navAnimController.dispose();
    _requestCountdownTimer?.cancel();
    _simMoveTimer?.cancel();
    _gpsSub?.cancel();
    _reqSub?.cancel();
    _claimedSub?.cancel();
    _updateSub?.cancel();
    unawaited(NotificationCenterService.cancelOngoingNavigationNotification());
    super.dispose();
  }

  Future<void> _startGpsTracking({bool? highPrecision}) async {
    final useHigh = highPrecision ?? _navigationActive;
    try {
      final pos = await _locationService.getCurrentUserLocation();
      if (!mounted) return;
      final pt = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _captainPosition = pt;
        _captainHeading = pos.heading;
        _speedKmh = CaptainNavigationService.speedKmh(pos.speedMps);
      });
      if (_mapReady) _map.move(pt, useHigh ? 16.5 : 15);
      await _backend.publishCaptainLocation(
        position: pt,
        heading: pos.heading,
        activeRideId: _activeRide?.rideId,
      );

      await _gpsSub?.cancel();
      _gpsSub = _locationService
          .watchUserLocation(
            distanceFilterMeters: useHigh ? 5 : 20,
            highPrecision: useHigh,
          )
          .listen((next) {
            if (!mounted) return;
            final nextPt = LatLng(next.latitude, next.longitude);
            setState(() {
              _speedKmh = CaptainNavigationService.speedKmh(next.speedMps);
            });
            _animateCaptainTo(nextPt, next.heading);
            _updateNavigationMetrics(
              nextPt,
              accuracyMeters: next.accuracyMeters,
            );
            _backend.publishCaptainLocation(
              position: nextPt,
              heading: next.heading,
              activeRideId: _activeRide?.rideId,
            );
          });
    } catch (_) {}
  }

  Future<void> _loadRouteForRide(RideRequestPayload ride) async {
    try {
      final from = _activeRide?.status == RideDispatchStatus.inProgress
          ? LatLng(ride.originLat, ride.originLng)
          : _captainPosition;
      final to = _activeRide?.status == RideDispatchStatus.accepted
          ? LatLng(ride.originLat, ride.originLng)
          : LatLng(ride.destinationLat, ride.destinationLng);
      final coords =
          '${from.longitude},${from.latitude};${to.longitude},${to.latitude}';
      final res = await _dio.get(
        'https://router.project-osrm.org/route/v1/driving/$coords',
        queryParameters: {'overview': 'full', 'geometries': 'geojson'},
      );
      final first = (res.data['routes'] as List).first;
      final pts = (first['geometry']['coordinates'] as List)
          .map(
            (v) => LatLng((v[1] as num).toDouble(), (v[0] as num).toDouble()),
          )
          .toList();
      if (mounted) {
        setState(() => _routePoints = pts);
        _fitPoints([
          _captainPosition,
          LatLng(ride.originLat, ride.originLng),
          LatLng(ride.destinationLat, ride.destinationLng),
        ]);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _routePoints = [
            _captainPosition,
            LatLng(ride.originLat, ride.originLng),
            LatLng(ride.destinationLat, ride.destinationLng),
          ];
        });
      }
    }
  }

  Future<void> _enterRouteSelection(RideRequestPayload ride) async {
    final from = LatLng(ride.originLat, ride.originLng);
    final to = LatLng(ride.destinationLat, ride.destinationLng);
    try {
      final options = await _navService.fetchAlternativeRoutes(from, to);
      if (!mounted) return;
      if (options.isNotEmpty) {
        setState(() {
          _routeOptions = options;
          _selectedRouteIndex = 0;
          _selectingRoute = true;
          _navigationActive = false;
          _offRoute = false;
          _routePoints = options.first.points;
        });
        _fitPoints([
          from,
          to,
          for (final opt in options) ...opt.points,
        ]);
        return;
      }
    } catch (_) {}

    if (!mounted) return;
    await _loadRouteForRide(ride);
    if (!mounted) return;
    setState(() {
      _routeOptions = const [];
      _selectingRoute = true;
      _navigationActive = false;
    });
  }

  void _confirmSelectedRoute() {
    if (_activeRide == null) return;
    final chosen = (_routeOptions.isNotEmpty &&
            _selectedRouteIndex < _routeOptions.length)
        ? _routeOptions[_selectedRouteIndex]
        : CaptainRouteOption(
            index: 0,
            distanceKm: _activeRide!.distanceKm,
            durationMin: _activeRide!.durationMin,
            points: _routePoints,
          );
    setState(() {
      _routeOptions = [chosen];
      _selectedRouteIndex = 0;
      _routePoints = chosen.points;
      _selectingRoute = false;
      _navigationActive = true;
      _followCamera = true;
      _offRoute = false;
      _navProgress = 0;
      _remainingKm = chosen.distanceKm;
      _remainingMin = chosen.durationMin;
      _nextInstruction =
          chosen.steps.isNotEmpty ? chosen.steps.first : null;
      _followingInstruction =
          chosen.steps.length > 1 ? chosen.steps[1] : null;
      _dynamicInstruction = _nextInstruction?.instructionText ?? '';
      _lastSpokenKey = null;
      _currentZoom = 16.5;
    });
    _offRouteDetector.reset();
    _fitPoints(chosen.points);
    unawaited(OfflineMapsService.instance.precacheRouteCorridor(chosen.points));
    if (_voiceEnabled && _dynamicInstruction.isNotEmpty) {
      CaptainNavigationService.speakArabic(_dynamicInstruction);
    }
    unawaited(
      NotificationCenterService.showOngoingNavigationNotification(
        title: 'الملاحة النشطة — ${_activeRide!.destinationName}',
        body: _dynamicInstruction.isNotEmpty
            ? _dynamicInstruction
            : 'اتبع المسار المعتمد',
      ),
    );
    unawaited(_startGpsTracking(highPrecision: true));
    if (!_hasServerUrl) {
      _startSimulatedMove();
    }
  }

  void _updateNavigationMetrics(
    LatLng current, {
    double accuracyMeters = 0,
  }) {
    if (!_navigationActive || _activeRide == null || _routeOptions.isEmpty) {
      return;
    }
    final activeRoute = _routeOptions.first;
    final snap = CaptainNavigationService.computeProgress(
      current: current,
      route: activeRoute,
    );
    final confirmedOffRoute = _offRouteDetector.evaluate(
      isSampleOffRoute: snap.isOffRoute,
      accuracyMeters: accuracyMeters,
    );
    if (!mounted) return;
    setState(() {
      _navProgress = snap.progress;
      _remainingKm = snap.remainingKm;
      _remainingMin = snap.remainingMin;
      _nextInstruction = snap.nextStep;
      _followingInstruction = snap.followingStep;
      _dynamicInstruction = snap.dynamicInstruction;
      _offRoute = confirmedOffRoute;
    });
    if (_followCamera && _mapReady) {
      _map.move(current, _currentZoom < 15.5 ? 16.5 : _currentZoom);
      if (_autoRotateMap) {
        _map.rotate(-_captainHeading);
      }
    }
    if (_voiceEnabled &&
        !confirmedOffRoute &&
        snap.speechKey != null &&
        snap.speechKey != _lastSpokenKey &&
        snap.dynamicInstruction.isNotEmpty) {
      _lastSpokenKey = snap.speechKey;
      CaptainNavigationService.speakArabic(snap.dynamicInstruction);
      unawaited(
        NotificationCenterService.showOngoingNavigationNotification(
          title:
              '${snap.remainingKm.toStringAsFixed(1)} كم • ${snap.remainingMin.ceil()} د',
          body: snap.dynamicInstruction,
        ),
      );
    }
    if (confirmedOffRoute && !_rerouting) {
      if (_voiceEnabled) {
        CaptainNavigationService.speakArabic(
          'تم الخروج عن المسار، جارٍ إعادة الحساب',
        );
      }
      _rerouteFromCurrent(current, _activeRide!);
    }
  }

  Future<void> _rerouteFromCurrent(
    LatLng current,
    RideRequestPayload ride,
  ) async {
    _rerouting = true;
    try {
      final to = LatLng(ride.destinationLat, ride.destinationLng);
      final routes = await _navService.fetchAlternativeRoutes(current, to);
      if (!mounted || !_navigationActive || routes.isEmpty) return;
      final rerouted = routes.first;
      setState(() {
        _routeOptions = [rerouted];
        _selectedRouteIndex = 0;
        _routePoints = rerouted.points;
        _offRoute = false;
        _remainingKm = rerouted.distanceKm;
        _remainingMin = rerouted.durationMin;
        _nextInstruction =
            rerouted.steps.isNotEmpty ? rerouted.steps.first : null;
      });
    } catch (_) {
      // Keep original route & off-route banner if offline
    } finally {
      _rerouting = false;
    }
  }

  void _fitPoints(List<LatLng> points) {
    if (!_mapReady || points.isEmpty) return;
    final bounds = LatLngBounds.fromPoints(points);
    _map.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.fromLTRB(40, 100, 40, 290),
      ),
    );
  }

  Future<void> _toggleOnline(bool value) async {
    if (value &&
        (_profile.approvalStatus != CaptainApprovalStatus.approved ||
            !_profile.hasProfilePhoto)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            !_profile.hasProfilePhoto
                ? 'يرجى رفع الصورة الشخصية للكابتن أولاً قبل تفعيل حالة متاح للعمل.'
                : 'أكمل بيانات الكابتن والموافقة على الحساب أولاً.',
          ),
        ),
      );
      await context.push('/captain/onboarding');
      final refreshed = await _backend.loadCaptainProfile();
      if (mounted) setState(() => _profile = refreshed);
      return;
    }

    setState(() => _busy = true);
    try {
      final updated = await _backend.setCaptainOnline(
        current: _profile,
        online: value,
        position: _captainPosition,
      );
      if (mounted) setState(() => _profile = updated);
      if (value) {
        await _startGpsTracking();
        final pending = await _backend.loadPendingLocalRide();
        if (mounted &&
            pending != null &&
            pending.status == RideDispatchStatus.searching) {
          setState(() {
            _incomingRequests = [pending];
            _selectedIncomingIndex = 0;
          });
          _loadRouteForRide(pending);
        }
      } else {
        await _gpsSub?.cancel();
        _backend.disconnectRealtime();
        if (mounted) {
          setState(() {
            _incomingRequests = const [];
            _selectedIncomingIndex = 0;
          });
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _devApproveNow() async {
    final approved = await _backend.saveCaptainProfile(
      _profile.copyWith(
        fullName: _profile.fullName.isEmpty
            ? 'محمد ناصر ليهوب'
            : _profile.fullName,
        carModel: _profile.carModel.isEmpty ? 'Kia Optima' : _profile.carModel,
        carColor: _profile.carColor.isEmpty ? 'أبيض' : _profile.carColor,
        plateNumber: _profile.plateNumber.isEmpty
            ? 'واسط 45821'
            : _profile.plateNumber,
        approvalStatus: CaptainApprovalStatus.approved,
      ),
    );
    if (!mounted) return;
    setState(() => _profile = approved);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        backgroundColor: _captainGreen,
        content: Text('تم اعتماد حساب الكابتن في وضع المطور.'),
      ),
    );
  }

  double _distanceKmTo(RideRequestPayload req) =>
      _locationService.distanceKm(
        _captainPosition,
        LatLng(req.originLat, req.originLng),
      );

  void _startRequestCountdown() {
    _requestCountdownTimer?.cancel();
    if (mounted) setState(() => _requestCountdown = 30);
    _requestCountdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || _incomingRequests.isEmpty) {
        t.cancel();
        return;
      }
      if (_requestCountdown <= 1) {
        t.cancel();
        _rejectIncoming();
      } else {
        setState(() => _requestCountdown -= 1);
      }
    });
  }

  Future<void> _acceptIncoming([RideRequestPayload? specific]) async {
    _requestCountdownTimer?.cancel();
    final req = specific ?? _incomingRequest;
    if (req == null) return;
    setState(() => _busy = true);
    try {
      final accepted = await _backend.acceptRideAtomic(
        request: req,
        captain: _profile,
      );
      if (!mounted) return;
      setState(() {
        _incomingRequests = const [];
        _selectedIncomingIndex = 0;
        _activeRide = accepted;
      });
      await _loadRouteForRide(accepted);
      if (!_hasServerUrl) _startSimulatedMove();
    } on RideConflictException catch (e) {
      if (mounted) {
        setState(() {
          _incomingRequests = _incomingRequests
              .where((r) => r.rideId != req.rideId)
              .toList();
          _selectedIncomingIndex = 0;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر قبول الطلب. تحقق من الاتصال.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rejectIncoming([RideRequestPayload? specific]) async {
    final req = specific ?? _incomingRequest;
    if (req == null) return;
    await _backend.rejectRide(rideId: req.rideId, captainId: _profile.id);
    if (mounted) {
      setState(() {
        _incomingRequests = _incomingRequests
            .where((r) => r.rideId != req.rideId)
            .toList();
        if (_selectedIncomingIndex >= _incomingRequests.length) {
          _selectedIncomingIndex = 0;
        }
        if (_incomingRequests.isEmpty) {
          _requestCountdownTimer?.cancel();
          _routePoints = const [];
        }
      });
      if (_incomingRequest != null) {
        _loadRouteForRide(_incomingRequest!);
      }
    }
  }

  Future<void> _advanceRideStatus(RideDispatchStatus next) async {
    final ride = _activeRide;
    if (ride == null) return;
    setState(() => _busy = true);
    try {
      final updated = await _backend.updateRideStatus(
        request: ride,
        nextStatus: next,
      );
      if (!mounted) return;
      if (next == RideDispatchStatus.completed) {
        _simMoveTimer?.cancel();
        await _backend.recordCaptainCompletedTrip(updated, _profile);
        final refreshed = await _backend.loadCaptainProfile();
        if (!mounted) return;
        setState(() {
          _profile = refreshed;
          _activeRide = null;
          _routePoints = const [];
          _routeOptions = const [];
          _selectingRoute = false;
          _navigationActive = false;
          _offRoute = false;
          _nextInstruction = null;
          _navPromptShownForRideId = null;
          _speedKmh = 0;
        });
        unawaited(NotificationCenterService.cancelOngoingNavigationNotification());
        if (_mapReady) _map.rotate(0);
        unawaited(_startGpsTracking(highPrecision: false));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: _captainGreen,
            content: Text(
              'تم إنهاء الرحلة بنجاح (+${formatIraqiDinar(updated.fareIqd)})',
            ),
          ),
        );
      } else if (next == RideDispatchStatus.cancelled) {
        _simMoveTimer?.cancel();
        setState(() {
          _activeRide = null;
          _routePoints = const [];
          _routeOptions = const [];
          _selectingRoute = false;
          _navigationActive = false;
          _offRoute = false;
          _nextInstruction = null;
          _navPromptShownForRideId = null;
          _speedKmh = 0;
        });
        unawaited(NotificationCenterService.cancelOngoingNavigationNotification());
        if (_mapReady) _map.rotate(0);
        unawaited(_startGpsTracking(highPrecision: false));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم إلغاء الرحلة.')),
        );
      } else if (next == RideDispatchStatus.inProgress) {
        setState(() => _activeRide = updated);
        await _enterRouteSelection(updated);
      } else {
        setState(() => _activeRide = updated);
        await _loadRouteForRide(updated);
        if (next == RideDispatchStatus.arrived &&
            _navPromptShownForRideId != updated.rideId) {
          _navPromptShownForRideId = updated.rideId;
          if (mounted) {
            await _showExternalNavChoiceDialog(updated);
          }
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startSimulatedMove() {
    _simMoveTimer?.cancel();
    if (_routePoints.length < 2) return;
    int idx = 0;
    _simMoveTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _activeRide == null || idx >= _routePoints.length) {
        timer.cancel();
        return;
      }
      final nextPt = _routePoints[idx];
      final bearing = CaptainNavigationService.bearingDegrees(
        _captainPosition,
        nextPt,
      );
      idx += (_routePoints.length > 20) ? (_routePoints.length ~/ 12) : 1;
      setState(() {
        _captainPosition = nextPt;
        _captainHeading = bearing;
      });
      _updateNavigationMetrics(nextPt);
      _backend.publishCaptainLocation(
        position: nextPt,
        heading: _captainHeading,
        activeRideId: _activeRide?.rideId,
      );
    });
  }

  Future<void> _sendQuickMessage(String phone, String text) async {
    if (phone.trim().isEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم نسخ الرسالة السريعة: $text')),
        );
      }
      return;
    }
    final uri = Uri(
      scheme: 'sms',
      path: phone.trim(),
      queryParameters: {'body': text},
    );
    await launchUrl(uri);
  }

  Future<void> _toggleBreak(bool enterBreak) async {
    if (enterBreak) {
      if (_profile.isOnline) {
        await _toggleOnline(false);
      }
      if (mounted) setState(() => _onBreak = true);
    } else {
      if (mounted) setState(() => _onBreak = false);
      await _toggleOnline(true);
    }
  }

  Future<void> _contactCustomer(String scheme, String phone) async {
    if (phone.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('رقم هاتف الزبون غير متوفر.')),
      );
      return;
    }
    await launchUrl(Uri(scheme: scheme, path: phone.trim()));
  }

  Future<void> _showExternalNavChoiceDialog(RideRequestPayload ride) async {
    final darbunaInstalled =
        await IraqiNavigationService.isAppInstalled(IraqiNavApp.darbuna);
    final dahlizInstalled =
        await IraqiNavigationService.isAppInstalled(IraqiNavApp.dahliz);
    final preferred = await IraqiNavigationService.loadPreferredNavApp();
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('هل تريد متابعة الرحلة باستخدام تطبيق ملاحة خارجي؟'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'تُمرر إحداثيات الوجهة المسجلة فقط دون بيانات الزبون الشخصية.',
              style: TextStyle(fontSize: 12.5, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            _ExternalNavOptionTile(
              title: 'المتابعة عبر دربونة',
              installed: darbunaInstalled,
              isPreferred: preferred == IraqiNavApp.darbuna,
              color: _captainBlue,
              onTap: () async {
                Navigator.pop(ctx);
                await _launchSelectedIraqiNav(IraqiNavApp.darbuna, ride);
              },
            ),
            const SizedBox(height: 8),
            _ExternalNavOptionTile(
              title: 'المتابعة عبر دهليز',
              installed: dahlizInstalled,
              isPreferred: preferred == IraqiNavApp.dahliz,
              color: _captainGreen,
              onTap: () async {
                Navigator.pop(ctx);
                await _launchSelectedIraqiNav(IraqiNavApp.dahliz, ride);
              },
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx),
              style: FilledButton.styleFrom(
                backgroundColor: _captainGreen,
                minimumSize: const Size.fromHeight(46),
              ),
              icon: const Icon(Icons.map_outlined),
              label: const Text('متابعة الرحلة داخل تطبيق درب'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _launchSelectedIraqiNav(
    IraqiNavApp app,
    RideRequestPayload ride,
  ) async {
    final res = await IraqiNavigationService.launchExternalNav(
      app: app,
      destLat: ride.destinationLat,
      destLng: ride.destinationLng,
    );
    if (!mounted) return;
    if (res == ExternalNavLaunchResult.notInstalled) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${IraqiNavigationService.labelFor(app)} غير مثبت'),
          content: Text(
            'تطبيق ${IraqiNavigationService.labelFor(app)} غير مثبت على هذا الجهاز. يمكنك تثبيته من المتجر الرسمي أو متابعة الملاحة داخل درب.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('متابعة داخل درب'),
            ),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                IraqiNavigationService.openStoreForApp(app);
              },
              style: FilledButton.styleFrom(backgroundColor: _captainGreen),
              icon: const Icon(Icons.download_outlined),
              label: const Text('تثبيت التطبيق'),
            ),
          ],
        ),
      );
    } else if (res == ExternalNavLaunchResult.unsupportedGeo) {
      final exactCoords = '${ride.destinationLat}, ${ride.destinationLng}';
      await Clipboard.setData(ClipboardData(text: exactCoords));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'لا يدعم التطبيق تمرير الإحداثيات مباشرة؛ تم نسخ إحداثيات الوجهة الدقيقة ($exactCoords).',
          ),
        ),
      );
    }
  }

  Future<void> _openNavigation(LatLng target) async {
    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=${target.latitude},${target.longitude}&travelmode=driving',
    );
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final surface = dark ? const Color(0xFF182522) : Colors.white;
    final primaryText = dark ? Colors.white : _captainInk;
    final secondaryText = dark ? Colors.white70 : Colors.grey.shade700;

    final focusRide = _activeRide ?? _incomingRequest;

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _captainPosition,
              initialZoom: 14.5,
              onMapReady: () => _mapReady = true,
              onPositionChanged: (camera, hasGesture) {
                _currentZoom = camera.zoom;
                if ((camera.rotation - _mapRotation).abs() > 0.5 && mounted) {
                  setState(() => _mapRotation = camera.rotation);
                }
                if (hasGesture && _followCamera && _navigationActive && mounted) {
                  setState(() => _followCamera = false);
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                fallbackUrl:
                    'https://{s}.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png',
                subdomains: const ['a', 'b', 'c'],
                userAgentPackageName: 'iq.ridepassenger.car',
                maxZoom: 19,
                keepBuffer: 4,
                tileProvider: DarbOfflineTileProvider(),
                tileBuilder: dark ? darkModeTileBuilder : null,
              ),
              if (_selectingRoute && _routeOptions.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    for (var i = 0; i < _routeOptions.length; i++)
                      if (i != _selectedRouteIndex)
                        Polyline(
                          points: _routeOptions[i].points,
                          color: _routeColorForIndex(i).withValues(alpha: 0.42),
                          strokeWidth: 3.5,
                        ),
                    if (_selectedRouteIndex < _routeOptions.length)
                      Polyline(
                        points: _routeOptions[_selectedRouteIndex].points,
                        color: _routeColorForIndex(_selectedRouteIndex),
                        strokeWidth: 6.5,
                      ),
                  ],
                )
              else if (_routePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _routePoints,
                      color: _captainBlue,
                      strokeWidth: 5.5,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  if (focusedMapPin.value != null)
                    Marker(
                      point: focusedMapPin.value!.point,
                      width: 140,
                      height: 82,
                      rotate: true,
                      alignment: Alignment.topCenter,
                      child: GestureDetector(
                        onTap: () => focusedMapPin.value = null,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (focusedMapPin.value!.label.isNotEmpty)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEA4335),
                                  borderRadius: BorderRadius.circular(10),
                                  boxShadow: const [
                                    BoxShadow(color: Colors.black26, blurRadius: 4),
                                  ],
                                ),
                                child: Text(
                                  focusedMapPin.value!.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            const Icon(
                              Icons.location_on,
                              color: Color(0xFFEA4335),
                              size: 46,
                            ),
                          ],
                        ),
                      ),
                    ),
                  Marker(
                    point: _captainPosition,
                    width: 48,
                    height: 48,
                    child: AnimatedRotation(
                      turns: _captainHeading / 360,
                      duration: const Duration(milliseconds: 280),
                      child: const _TriangularNavArrow(),
                    ),
                  ),
                  if (focusRide != null) ...[
                    Marker(
                      point: LatLng(focusRide.originLat, focusRide.originLng),
                      width: 100,
                      height: 75,
                      rotate: true,
                      alignment: Alignment.topCenter,
                      child: const LocationMapMarker(
                        title: 'الزبون',
                        pinColor: Color(0xFFE56A2B),
                        isSquare: false,
                      ),
                    ),
                    Marker(
                      point: LatLng(
                        focusRide.destinationLat,
                        focusRide.destinationLng,
                      ),
                      width: 100,
                      height: 75,
                      rotate: true,
                      alignment: Alignment.topCenter,
                      child: const LocationMapMarker(
                        title: 'الوجهة',
                        pinColor: _captainBlue,
                        isSquare: true,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),

          // Top Captain Bar
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  IconButton.filled(
                    tooltip: 'الملف الشخصي',
                    onPressed: () => context.push('/profile'),
                    style: IconButton.styleFrom(
                      backgroundColor: surface,
                      foregroundColor: primaryText,
                      elevation: 4,
                    ),
                    icon: const Icon(Icons.person_outline),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Material(
                      color: _profile.isOnline ? _captainGreen : surface,
                      elevation: 4,
                      borderRadius: BorderRadius.circular(24),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: _busy
                            ? null
                            : () => _toggleOnline(!_profile.isOnline),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _profile.isOnline
                                      ? Colors.white
                                      : const Color(0xFFE56A2B),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  _profile.isOnline ? 'متاح' : 'غير متاح',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                    color: _profile.isOnline
                                        ? Colors.white
                                        : primaryText,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'الأرباح والسجل',
                    onPressed: () => context.push('/captain/history'),
                    style: IconButton.styleFrom(
                      backgroundColor: surface,
                      foregroundColor: _captainGreen,
                      elevation: 4,
                    ),
                    icon: const Icon(Icons.account_balance_wallet_outlined),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    tooltip: 'خرائط دون اتصال',
                    onPressed: () => context.push('/offline-maps'),
                    style: IconButton.styleFrom(
                      backgroundColor: surface,
                      foregroundColor: _captainBlue,
                      elevation: 4,
                    ),
                    icon: const Icon(Icons.download_for_offline_outlined),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    tooltip: 'الإشعارات',
                    onPressed: () => context.push('/notifications'),
                    style: IconButton.styleFrom(
                      backgroundColor: surface,
                      foregroundColor: primaryText,
                      elevation: 4,
                    ),
                    icon: const Icon(Icons.notifications_none),
                  ),
                ],
              ),
            ),
          ),

          // Top Navigation Banner (Turn-by-Turn & Off-Route Alert)
          if (_navigationActive && (_nextInstruction != null || _offRoute))
            Positioned(
              top: MediaQuery.paddingOf(context).top + 70,
              left: 16,
              right: 16,
              child: Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(18),
                color: _offRoute ? const Color(0xFFD93829) : _captainInk,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _offRoute
                            ? Icons.alt_route_rounded
                            : _maneuverIcon(_nextInstruction?.modifier ?? ''),
                        color: Colors.white,
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _offRoute
                                  ? 'تم الخروج عن المسار — جارٍ إعادة الحساب...'
                                  : (_dynamicInstruction.isNotEmpty
                                      ? _dynamicInstruction
                                      : (_nextInstruction?.instructionText ??
                                          'اتبع المسار المعتمد')),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 13.5,
                              ),
                            ),
                            if (!_offRoute && _nextInstruction != null)
                              Text(
                                'المتبقي ${_remainingKm.toStringAsFixed(1)} كم (${_remainingMin.ceil()} د)${_followingInstruction != null ? ' • بعدها: ${_followingInstruction!.instructionText}' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11.5,
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: _voiceEnabled ? 'كتم التوجيه الصوتي' : 'تفعيل التوجيه الصوتي',
                        onPressed: () {
                          setState(() => _voiceEnabled = !_voiceEnabled);
                          if (!_voiceEnabled) {
                            CaptainNavigationService.stopSpeaking();
                          }
                        },
                        icon: Icon(
                          _voiceEnabled
                              ? Icons.volume_up_rounded
                              : Icons.volume_off_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Bottom Controls + Captain Panel
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(bottom: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (_navigationActive)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: surface.withValues(alpha: 0.94),
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: const [
                              BoxShadow(color: Colors.black26, blurRadius: 8),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '$_speedKmh',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w900,
                                  color: primaryText,
                                  height: 1.0,
                                ),
                              ),
                              Text(
                                'كم/س',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                  color: secondaryText,
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        const SizedBox.shrink(),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_navigationActive && _routePoints.isNotEmpty) ...[
                            FloatingActionButton.small(
                              heroTag: 'captain_fit_route',
                              tooltip: 'عرض المسار الكامل',
                              onPressed: () {
                                setState(() => _followCamera = false);
                                _fitPoints(_routePoints);
                              },
                              backgroundColor: surface,
                              foregroundColor: primaryText,
                              child: const Icon(Icons.alt_route_rounded),
                            ),
                            const SizedBox(height: 8),
                            FloatingActionButton.small(
                              heroTag: 'captain_auto_rotate',
                              tooltip: _autoRotateMap
                                  ? 'إيقاف تدوير الخريطة'
                                  : 'تدوير الخريطة تلقائياً',
                              onPressed: () {
                                setState(() => _autoRotateMap = !_autoRotateMap);
                                if (!_autoRotateMap && _mapReady) {
                                  _map.rotate(0);
                                  setState(() => _mapRotation = 0);
                                }
                              },
                              backgroundColor: _autoRotateMap
                                  ? _captainBlue
                                  : surface,
                              foregroundColor: _autoRotateMap
                                  ? Colors.white
                                  : primaryText,
                              child: const Icon(Icons.screen_rotation_alt_rounded),
                            ),
                            const SizedBox(height: 8),
                          ],
                          if (_mapRotation.abs() > 1.0) ...[
                            FloatingActionButton.small(
                              heroTag: 'captain_compass',
                              tooltip: 'العودة لاتجاه الشمال',
                              onPressed: () {
                                if (_mapReady) _map.rotate(0);
                                setState(() {
                                  _mapRotation = 0;
                                  _autoRotateMap = false;
                                });
                              },
                              backgroundColor: surface,
                              foregroundColor: const Color(0xFFE53935),
                              child: AnimatedRotation(
                                turns: _mapRotation / 360,
                                duration: const Duration(milliseconds: 120),
                                child: const Icon(Icons.explore),
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                          if (_navigationActive) ...[
                            FloatingActionButton.small(
                              heroTag: 'captain_zoom_in',
                              tooltip: 'تكبير',
                              onPressed: () {
                                if (!_mapReady) return;
                                final z = (_currentZoom + 1).clamp(3.0, 19.0);
                                _map.move(_map.camera.center, z);
                              },
                              backgroundColor: surface,
                              foregroundColor: primaryText,
                              child: const Icon(Icons.add),
                            ),
                            const SizedBox(height: 6),
                            FloatingActionButton.small(
                              heroTag: 'captain_zoom_out',
                              tooltip: 'تصغير',
                              onPressed: () {
                                if (!_mapReady) return;
                                final z = (_currentZoom - 1).clamp(3.0, 19.0);
                                _map.move(_map.camera.center, z);
                              },
                              backgroundColor: surface,
                              foregroundColor: primaryText,
                              child: const Icon(Icons.remove),
                            ),
                            const SizedBox(height: 8),
                          ],
                          FloatingActionButton.small(
                            heroTag: 'captain_my_loc',
                            tooltip: 'إعادة التمركز',
                            onPressed: () {
                              setState(() => _followCamera = true);
                              if (_mapReady) {
                                _map.move(
                                  _captainPosition,
                                  _navigationActive ? 16.5 : 15,
                                );
                                if (_navigationActive && _autoRotateMap) {
                                  _map.rotate(-_captainHeading);
                                }
                              }
                              _startGpsTracking(highPrecision: _navigationActive);
                            },
                            backgroundColor: !_followCamera && _navigationActive
                                ? _captainBlue
                                : surface,
                            foregroundColor: !_followCamera && _navigationActive
                                ? Colors.white
                                : primaryText,
                            child: const Icon(Icons.my_location),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (_loading)
                  const LinearProgressIndicator()
                else if (_activeRide != null && _selectingRoute)
                  _buildRouteSelectionSheet(
                    _activeRide!,
                    surface,
                    primaryText,
                    secondaryText,
                  )
                else if (_activeRide != null)
                  _buildActiveRideCard(
                    _activeRide!,
                    surface,
                    primaryText,
                    secondaryText,
                  )
                else if (_incomingRequests.isNotEmpty)
                  _buildIncomingRequestsQueue(
                    surface,
                    primaryText,
                    secondaryText,
                  )
                else
                  _buildStandbyCard(surface, primaryText, secondaryText),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStandbyCard(
    Color surface,
    Color primaryText,
    Color secondaryText,
  ) {
    final approved = _profile.approvalStatus == CaptainApprovalStatus.approved;
    final statusLabel = switch (_profile.approvalStatus) {
      CaptainApprovalStatus.approved => 'حساب معتمد',
      CaptainApprovalStatus.pending => 'قيد المراجعة والموافقة',
      CaptainApprovalStatus.rejected => 'مرفوض — يرجى تحديث المستمسكات',
      CaptainApprovalStatus.unsubmitted => 'بيانات الكابتن غير مكتملة',
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 16)],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: _captainGreen.withValues(alpha: 0.14),
                  child: const Icon(Icons.local_taxi, color: _captainGreen),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _profile.fullName.isEmpty
                            ? 'بوابة الكابتن'
                            : _profile.fullName,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: primaryText,
                        ),
                      ),
                      Text(
                        statusLabel,
                        style: TextStyle(
                          fontSize: 13,
                          color: approved
                              ? _captainGreen
                              : const Color(0xFFE56A2B),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (!approved) ...[
              FilledButton.icon(
                onPressed: () async {
                  await context.push('/captain/onboarding');
                  final refreshed = await _backend.loadCaptainProfile();
                  if (mounted) setState(() => _profile = refreshed);
                },
                icon: const Icon(Icons.badge_outlined),
                label: const Text('إكمال معلومات السيارة والمستمسكات'),
                style: FilledButton.styleFrom(
                  backgroundColor: _captainBlue,
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
              if (!_hasServerUrl) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _devApproveNow,
                  icon: const Icon(Icons.verified_outlined, color: _captainGreen),
                  label: const Text('اعتماد فوري للمطور — تفعيل الكابتن'),
                ),
              ],
            ] else ...[
              if (_onBreak)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE56A2B).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.coffee_outlined, color: Color(0xFFE56A2B)),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'أنت في استراحة مؤقتة حالياً',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5),
                        ),
                      ),
                      TextButton(
                        onPressed: _busy ? null : () => _toggleBreak(false),
                        child: const Text('إنهاء الاستراحة'),
                      ),
                    ],
                  ),
                ),
              Text(
                _profile.isOnline
                    ? 'أنت متاح الآن؛ ستصلك إشعارات الطلبات القريبة فورياً.'
                    : 'اضغط على «غير متاح» بالأعلى لتفعيل استقبال الطلبات.',
                style: TextStyle(fontSize: 13, color: secondaryText),
              ),
              if (_profile.isOnline && !_onBreak) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _toggleBreak(true),
                  icon: const Icon(Icons.coffee_outlined, size: 18),
                  label: const Text('أخذ استراحة مؤقتة'),
                ),
              ],
              if (_profile.isOnline && !_hasServerUrl) ...[
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _backend.triggerMultipleLocalDemoRequests(
                          _captainPosition,
                        ),
                  icon: const Icon(Icons.notifications_active_outlined),
                  label: const Text('محاكاة طلبات زبائن قريبة (تجريبي)'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _captainBlue,
                    minimumSize: const Size.fromHeight(46),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildIncomingRequestsQueue(
    Color surface,
    Color primaryText,
    Color secondaryText,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        border: Border.all(color: _captainBlue, width: 1.5),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 18)],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.near_me_rounded, color: _captainBlue, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'طلبات الزبائن القريبة (${_incomingRequests.length})',
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w900,
                      color: primaryText,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: (_requestCountdown <= 10
                            ? Colors.redAccent
                            : _captainGreen)
                        .withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$_requestCountdown ث',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                      color: _requestCountdown <= 10
                          ? Colors.redAccent
                          : _captainGreen,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _incomingRequests.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, idx) {
                  final req = _incomingRequests[idx];
                  final selected = idx == _selectedIncomingIndex;
                  final awayKm = _distanceKmTo(req);
                  return InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () {
                      setState(() => _selectedIncomingIndex = idx);
                      _loadRouteForRide(req);
                    },
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: selected
                            ? _captainBlue.withValues(alpha: 0.08)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: selected
                              ? _captainBlue
                              : Colors.grey.withValues(alpha: 0.35),
                          width: selected ? 1.8 : 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  req.passengerName,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14.5,
                                    color: primaryText,
                                  ),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: _captainGreen.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  formatIraqiDinar(req.fareIqd),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 13.5,
                                    color: _captainGreen,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'يبعد عنك ${awayKm.toStringAsFixed(1)} كم • مسافة الرحلة ${req.distanceKm.toStringAsFixed(1)} كم',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: _captainBlue,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'من: ${req.originName}\nإلى: ${req.destinationName}',
                            style: TextStyle(fontSize: 12, color: secondaryText),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed:
                                      _busy ? null : () => _rejectIncoming(req),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.redAccent,
                                    minimumSize: const Size.fromHeight(40),
                                  ),
                                  child: const Text('تجاهل'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                flex: 2,
                                child: FilledButton(
                                  onPressed:
                                      _busy ? null : () => _acceptIncoming(req),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: _captainGreen,
                                    minimumSize: const Size.fromHeight(40),
                                  ),
                                  child: const Text(
                                    'قبول الرحلة',
                                    style: TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _routeColorForIndex(int idx) {
    switch (idx) {
      case 0:
        return _captainBlue;
      case 1:
        return _captainGreen;
      default:
        return const Color(0xFFE56A2B);
    }
  }

  IconData _maneuverIcon(String modifier) {
    if (modifier.contains('right')) return Icons.turn_right_rounded;
    if (modifier.contains('left')) return Icons.turn_left_rounded;
    if (modifier == 'uturn') return Icons.u_turn_right_rounded;
    return Icons.straight_rounded;
  }

  Widget _buildRouteSelectionSheet(
    RideRequestPayload ride,
    Color surface,
    Color primaryText,
    Color secondaryText,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 18)],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.alt_route_rounded, color: _captainBlue),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'اختر مسار الملاحة إلى الوجهة',
                    style: TextStyle(
                      fontSize: 16.5,
                      fontWeight: FontWeight.w900,
                      color: primaryText,
                    ),
                  ),
                ),
                Text(
                  '${_routeOptions.length} مسارات',
                  style: TextStyle(fontSize: 12.5, color: secondaryText),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'إلى: ${ride.destinationName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: secondaryText),
            ),
            const SizedBox(height: 12),
            if (_routeOptions.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'يتوفر المسار المباشر الحالي فقط (تعذر جلب بدائل إضافية من محرك التوجيه).',
                  style: TextStyle(fontSize: 12.5, color: secondaryText),
                ),
              )
            else
              Row(
                children: [
                  for (var idx = 0; idx < _routeOptions.length; idx++) ...[
                    if (idx > 0) const SizedBox(width: 8),
                    Expanded(
                      child: Builder(
                        builder: (context) {
                          final opt = _routeOptions[idx];
                          final selected = idx == _selectedRouteIndex;
                          final eta = DateTime.now().add(
                            Duration(minutes: opt.durationMin.ceil()),
                          );
                          final hour12 = eta.hour % 12 == 0 ? 12 : eta.hour % 12;
                          final amPm = eta.hour >= 12 ? 'PM' : 'AM';
                          final etaText =
                              'تصل $hour12:${eta.minute.toString().padLeft(2, '0')} $amPm';
                          return InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () {
                              setState(() {
                                _selectedRouteIndex = idx;
                                _routePoints = opt.points;
                              });
                              _fitPoints(opt.points);
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: selected ? _captainGreen : surface,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: selected
                                      ? _captainGreen
                                      : Colors.grey.withValues(alpha: 0.3),
                                  width: selected ? 2 : 1,
                                ),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircleAvatar(
                                    radius: 13,
                                    backgroundColor: selected
                                        ? Colors.white
                                        : const Color(0xFFB7791F),
                                    child: Icon(
                                      selected
                                          ? Icons.navigation_rounded
                                          : Icons.u_turn_right_rounded,
                                      size: 15,
                                      color: selected
                                          ? _captainGreen
                                          : Colors.white,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    opt.badgeLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      color: selected
                                          ? Colors.white
                                          : primaryText,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${opt.durationMin.ceil()} دقيقة',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w900,
                                      color: selected
                                          ? Colors.white
                                          : primaryText,
                                    ),
                                  ),
                                  Text(
                                    etaText,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: selected
                                          ? Colors.white.withValues(alpha: 0.9)
                                          : secondaryText,
                                    ),
                                  ),
                                  Text(
                                    '${opt.distanceKm.toStringAsFixed(1)} كم',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                      color: selected
                                          ? Colors.white.withValues(alpha: 0.95)
                                          : secondaryText,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _confirmSelectedRoute,
              style: FilledButton.styleFrom(
                backgroundColor: _captainGreen,
                minimumSize: const Size.fromHeight(50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: const Icon(Icons.navigation_rounded),
              label: const Text(
                'اعتماد المسار والبدء بالملاحة',
                style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmCancelActiveRide() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إلغاء الرحلة الحالية؟'),
        content: const Text(
          'سيتم إشعار الزبون بإلغاء الرحلة وإغلاق الطلب الحالي.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('تراجع'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('تأكيد الإلغاء'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _advanceRideStatus(RideDispatchStatus.cancelled);
    }
  }

  Widget _buildActiveRideCard(
    RideRequestPayload ride,
    Color surface,
    Color primaryText,
    Color secondaryText,
  ) {
    final (statusText, actionLabel, nextStatus) = switch (ride.status) {
      RideDispatchStatus.accepted => (
        'تم قبول الطلب — توجه للزبون',
        'وصلت إلى الزبون',
        RideDispatchStatus.arrived,
      ),
      RideDispatchStatus.arrived => (
        'وصلت إلى نقطة الانطلاق',
        'بدأت الرحلة',
        RideDispatchStatus.inProgress,
      ),
      _ => (
        'الرحلة جارية الآن',
        'انتهت الرحلة',
        RideDispatchStatus.completed,
      ),
    };

    final navTarget = ride.status == RideDispatchStatus.inProgress
        ? LatLng(ride.destinationLat, ride.destinationLng)
        : LatLng(ride.originLat, ride.originLng);

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 18)],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: _captainGreen.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    statusText,
                    style: const TextStyle(
                      color: _captainGreen,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  formatIraqiDinar(ride.fareIqd),
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    color: primaryText,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_navigationActive) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'المتبقي: ${_remainingKm.toStringAsFixed(1)} كم • ${_remainingMin.ceil()} دقيقة',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: _captainBlue,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : () => _enterRouteSelection(ride),
                    icon: const Icon(Icons.alt_route_rounded, size: 16),
                    label: const Text('المسارات'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  Text(
                    '${(_navProgress * 100).round()}%',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: secondaryText,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
            ],
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _navigationActive
                    ? _navProgress
                    : (ride.status == RideDispatchStatus.inProgress
                        ? 1.0
                        : (ride.status == RideDispatchStatus.arrived
                            ? 0.66
                            : 0.33)),
                minHeight: 5,
                backgroundColor: secondaryText.withValues(alpha: 0.15),
                color: ride.status == RideDispatchStatus.inProgress
                    ? _captainGreen
                    : _captainBlue,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: _captainGreen.withValues(alpha: 0.12),
                  child: const Icon(Icons.person_outline, color: _captainGreen),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ride.passengerName,
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.bold,
                          color: primaryText,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          const Icon(
                            Icons.trip_origin,
                            size: 13,
                            color: Color(0xFFE56A2B),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              ride.originName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12.5, color: secondaryText),
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          const Icon(
                            Icons.flag_rounded,
                            size: 13,
                            color: _captainBlue,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              ride.destinationName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12.5, color: secondaryText),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: 'الاتصال بالزبون',
                  onPressed: () => _contactCustomer('tel', ride.passengerPhone),
                  icon: const Icon(Icons.phone),
                ),
                const SizedBox(width: 6),
                IconButton.filledTonal(
                  tooltip: 'مراسلة الزبون',
                  onPressed: () => _contactCustomer('sms', ride.passengerPhone),
                  icon: const Icon(Icons.chat_bubble_outline),
                ),
                const SizedBox(width: 6),
                IconButton.filledTonal(
                  tooltip: 'الملاحة على الخريطة',
                  onPressed: () => _openNavigation(navTarget),
                  icon: const Icon(Icons.directions, color: _captainBlue),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final msg in const [
                    'أنا في الطريق إليك',
                    'وصلت عند نقطة الانطلاق',
                    'أنتظرك لمدة دقائق',
                  ])
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 6),
                      child: ActionChip(
                        avatar: const Icon(Icons.bolt_rounded, size: 16),
                        label: Text(msg, style: const TextStyle(fontSize: 12)),
                        onPressed: () =>
                            _sendQuickMessage(ride.passengerPhone, msg),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (RideStateMachine.canTransition(
                  ride.status,
                  RideDispatchStatus.cancelled,
                )) ...[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : _confirmCancelActiveRide,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        minimumSize: const Size.fromHeight(50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text('إلغاء'),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _advanceRideStatus(nextStatus),
                    style: FilledButton.styleFrom(
                      backgroundColor:
                          nextStatus == RideDispatchStatus.completed
                              ? _captainGreen
                              : _captainBlue,
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      actionLabel,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Captain Onboarding & Documents Page
// -----------------------------------------------------------------------------

class CaptainOnboardingPage extends StatefulWidget {
  const CaptainOnboardingPage({super.key});

  @override
  State<CaptainOnboardingPage> createState() => _CaptainOnboardingPageState();
}

class _CaptainOnboardingPageState extends State<CaptainOnboardingPage> {
  final _backend = RideBackendService.instance;
  final _picker = ImagePicker();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _carModel = TextEditingController();
  final _carColor = TextEditingController();
  final _plate = TextEditingController();

  CaptainProfile _profile = const CaptainProfile();
  String _tier = 'saver';
  IraqiNavApp _preferredNav = IraqiNavApp.ask;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await _backend.loadCaptainProfile();
    final prefNav = await IraqiNavigationService.loadPreferredNavApp();
    if (!mounted) return;
    setState(() {
      _profile = p;
      _name.text = p.fullName;
      _phone.text = p.phone;
      _carModel.text = p.carModel;
      _carColor.text = p.carColor;
      _plate.text = p.plateNumber;
      _tier = p.vehicleTier;
      _preferredNav = prefNav;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _carModel.dispose();
    _carColor.dispose();
    _plate.dispose();
    super.dispose();
  }

  Future<void> _pickDocument(String key) async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 75,
    );
    if (picked == null) return;
    setState(() => _saving = true);
    try {
      final updated = await _backend.uploadCaptainDocument(
        current: _profile,
        docKey: key,
        filePath: picked.path,
      );
      if (mounted) setState(() => _profile = updated);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickCaptainPhoto(ImageSource source) async {
    setState(() => _saving = true);
    try {
      final result = await CaptainPhotoService.pickCropAndValidate(
        source: source,
      );
      if (result == null || !mounted) return;
      if (!result.isValid || result.filePath == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text(result.message),
          ),
        );
        return;
      }
      final updated = _profile.copyWith(localPhotoPath: result.filePath!);
      setState(() => _profile = updated);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: _captainGreen,
          content: Text(result.message),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty ||
        _carModel.text.trim().isEmpty ||
        _plate.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('أدخل الاسم ونوع السيارة ورقم اللوحة أولاً.'),
        ),
      );
      return;
    }
    if (!_profile.hasProfilePhoto) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('يرجى التقاط أو اختيار الصورة الشخصية للكابتن أولاً.'),
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final saved = await _backend.saveCaptainProfile(
        _profile.copyWith(
          fullName: _name.text.trim(),
          phone: _phone.text.trim(),
          carModel: _carModel.text.trim(),
          carColor: _carColor.text.trim(),
          plateNumber: _plate.text.trim(),
          vehicleTier: _tier,
        ),
      );
      if (!mounted) return;
      setState(() => _profile = saved);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: _captainGreen,
          content: Text('تم حفظ بيانات الكابتن وإرسالها للمراجعة.'),
        ),
      );
      context.pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final docItems = const [
      ('nationalId', 'الهوية الوطنية / البطاقة الموحدة', Icons.badge_outlined),
      ('driverLicense', 'إجازة السوق', Icons.credit_card_outlined),
      ('vehicleReg', 'سنوية السيارة', Icons.description_outlined),
      ('carPhoto', 'صورة السيارة', Icons.directions_car_outlined),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('بيانات الكابتن والمستمسكات')),
      bottomNavigationBar: _loading
          ? null
          : SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  border: Border(
                    top: BorderSide(color: Theme.of(context).dividerColor),
                  ),
                ),
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: _captainGreen,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: Text(
                    _saving ? 'جارٍ الحفظ...' : 'حفظ وإرسال للموافقة',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              top: false,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
                children: [
                Card(
                  child: ListTile(
                    leading: Icon(
                      _profile.approvalStatus == CaptainApprovalStatus.approved
                          ? Icons.verified
                          : Icons.hourglass_top_rounded,
                      color:
                          _profile.approvalStatus ==
                              CaptainApprovalStatus.approved
                          ? _captainGreen
                          : const Color(0xFFE56A2B),
                    ),
                    title: Text(
                      'حالة الحساب: ${switch (_profile.approvalStatus) {
                        CaptainApprovalStatus.approved => 'معتمد وجاهز للعمل',
                        CaptainApprovalStatus.pending => 'قيد المراجعة من الإدارة',
                        CaptainApprovalStatus.rejected => 'مرفوض — حدّث المستمسكات',
                        CaptainApprovalStatus.unsubmitted => 'بانتظار إكمال البيانات',
                      }}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(
                      color: _profile.hasProfilePhoto
                          ? _captainGreen.withValues(alpha: 0.45)
                          : Colors.orange.withValues(alpha: 0.55),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.face_retouching_natural_rounded,
                                color: _captainGreen),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'الصورة الشخصية للكابتن',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: _profile.hasProfilePhoto
                                    ? _captainGreen.withValues(alpha: 0.14)
                                    : Colors.orange.withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                _profile.hasProfilePhoto ? 'معتمدة' : 'مطلوبة',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: _profile.hasProfilePhoto
                                      ? _captainGreen
                                      : Colors.deepOrange,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Center(
                          child: Container(
                            width: 96,
                            height: 96,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _captainGreen.withValues(alpha: 0.1),
                              border: Border.all(
                                color: _profile.hasProfilePhoto
                                    ? _captainGreen
                                    : Colors.grey.shade400,
                                width: 2.5,
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: CaptainPhotoService.isRemotePhotoUrl(
                                    _profile.photoUrl)
                                ? Image.network(
                                    _profile.photoUrl,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => const Icon(
                                      Icons.person_rounded,
                                      size: 48,
                                      color: _captainGreen,
                                    ),
                                  )
                                : (_profile.localPhotoPath.isNotEmpty &&
                                        File(_profile.localPhotoPath)
                                            .existsSync())
                                    ? Image.file(
                                        File(_profile.localPhotoPath),
                                        fit: BoxFit.cover,
                                      )
                                    : const Icon(
                                        Icons.person_rounded,
                                        size: 48,
                                        color: _captainGreen,
                                      ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'تُظهر هذه الصورة للزبون للتعرّف على السائق. يجب أن تكون صورة واضحة لوجه واحد فقط بنسبة 1:1.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade700,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _saving
                                    ? null
                                    : () => _pickCaptainPhoto(
                                        ImageSource.camera,
                                      ),
                                icon: const Icon(Icons.camera_alt_outlined),
                                label: Text(
                                  _profile.hasProfilePhoto
                                      ? 'إعادة التصوير'
                                      : 'الكاميرا',
                                ),
                                style: FilledButton.styleFrom(
                                  backgroundColor: _captainGreen,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _saving
                                    ? null
                                    : () => _pickCaptainPhoto(
                                        ImageSource.gallery,
                                      ),
                                icon: const Icon(Icons.photo_library_outlined),
                                label: Text(
                                  _profile.hasProfilePhoto
                                      ? 'تغيير الصورة'
                                      : 'المعرض',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'الاسم الكامل للكابتن',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'رقم الهاتف',
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _carModel,
                  decoration: const InputDecoration(
                    labelText: 'نوع وموديل السيارة (مثال: Kia Optima 2022)',
                    prefixIcon: Icon(Icons.local_taxi_outlined),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _carColor,
                        decoration: const InputDecoration(
                          labelText: 'لون السيارة',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _plate,
                        decoration: const InputDecoration(
                          labelText: 'رقم اللوحة',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: _tier,
                  decoration: const InputDecoration(
                    labelText: 'فئة المركبة',
                    prefixIcon: Icon(Icons.category_outlined),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'saver', child: Text('توفير')),
                    DropdownMenuItem(value: 'plus', child: Text('بَلَس')),
                    DropdownMenuItem(value: 'box', child: Text('بوكس')),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _tier = v);
                  },
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<IraqiNavApp>(
                  initialValue: _preferredNav,
                  decoration: const InputDecoration(
                    labelText: 'تطبيق الملاحة المفضل',
                    prefixIcon: Icon(Icons.navigation_outlined),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: IraqiNavApp.ask,
                      child: Text('السؤال في كل مرة'),
                    ),
                    DropdownMenuItem(
                      value: IraqiNavApp.dahliz,
                      child: Text('دهليز (Dahliz)'),
                    ),
                    DropdownMenuItem(
                      value: IraqiNavApp.darbuna,
                      child: Text('دربونة (Darbuna)'),
                    ),
                  ],
                  onChanged: (v) async {
                    if (v != null) {
                      setState(() => _preferredNav = v);
                      await IraqiNavigationService.savePreferredNavApp(v);
                    }
                  },
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    const Text(
                      'المستمسكات المطلوبة',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    Text(
                      '${_profile.documents.length} / ${docItems.length} مرفوع',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: _profile.hasAllDocuments
                            ? _captainGreen
                            : const Color(0xFFE56A2B),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (_profile.documents.length / docItems.length).clamp(0.0, 1.0),
                    minHeight: 5,
                    color: _profile.hasAllDocuments ? _captainGreen : _captainBlue,
                  ),
                ),
                const SizedBox(height: 10),
                ...docItems.map((item) {
                  final path = _profile.documents[item.$1];
                  final attached = path != null && path.isNotEmpty;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Card(
                      child: ListTile(
                        leading: Icon(
                          item.$3,
                          color: attached ? _captainGreen : Colors.grey,
                        ),
                        title: Text(item.$2),
                        subtitle: Text(
                          attached ? 'تم الإرفاق بنجاح' : 'اضغط لرفع الصورة',
                        ),
                        trailing: attached && File(path).existsSync()
                            ? const Icon(
                                Icons.check_circle,
                                color: _captainGreen,
                              )
                            : const Icon(Icons.upload_file),
                        onTap: _saving ? null : () => _pickDocument(item.$1),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
    );
  }
}

// -----------------------------------------------------------------------------
// Captain Earnings, Trips History & Ratings Page
// -----------------------------------------------------------------------------

class CaptainHistoryPage extends StatefulWidget {
  const CaptainHistoryPage({super.key});

  @override
  State<CaptainHistoryPage> createState() => _CaptainHistoryPageState();
}

class _CaptainHistoryPageState extends State<CaptainHistoryPage> {
  final _backend = RideBackendService.instance;
  CaptainProfile _profile = const CaptainProfile();
  List<Map<String, dynamic>> _trips = [];
  bool _loading = true;
  String _period = 'all'; // 'all' | 'week' | 'today'

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await _backend.loadCaptainProfile();
    final trips = await _backend.loadCaptainHistory();
    if (!mounted) return;
    setState(() {
      _profile = p;
      _trips = trips;
      _loading = false;
    });
  }

  List<Map<String, dynamic>> get _filteredTrips {
    if (_period == 'all') return _trips;
    final now = DateTime.now();
    final cutoff = _period == 'today'
        ? DateTime(now.year, now.month, now.day)
        : _period == 'week'
            ? now.subtract(const Duration(days: 7))
            : now.subtract(const Duration(days: 30));
    return _trips.where((t) {
      final dt = DateTime.tryParse((t['date'] ?? '').toString());
      return dt != null && !dt.isBefore(cutoff);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final visibleTrips = _filteredTrips;
    final filteredEarnings = _period == 'all' && visibleTrips.isEmpty
        ? _profile.totalEarnings
        : visibleTrips.fold<int>(
            0,
            (sum, t) => sum + ((t['fare_iqd'] as num?)?.toInt() ?? 0),
          );
    final totalKm = visibleTrips.fold<double>(
      0,
      (sum, t) => sum + ((t['distance_km'] as num?)?.toDouble() ?? 0),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('سجل الرحلات والأرباح')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(18),
              children: [
                if (_profile.carModel.isNotEmpty || _profile.plateNumber.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Card(
                      child: ListTile(
                        leading: const Icon(Icons.directions_car_filled, color: _captainGreen),
                        title: Text(
                          '${_profile.carColor} ${_profile.carModel}'.trim(),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text('لوحة: ${_profile.plateNumber.isEmpty ? 'غير محددة' : _profile.plateNumber}'),
                        trailing: Text(
                          '★ ${_profile.rating.toStringAsFixed(1)}',
                          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
                        ),
                      ),
                    ),
                  ),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'all', label: Text('الكل')),
                    ButtonSegment(value: 'month', label: Text('شهر')),
                    ButtonSegment(value: 'week', label: Text('7 أيام')),
                    ButtonSegment(value: 'today', label: Text('اليوم')),
                  ],
                  selected: {_period},
                  onSelectionChanged: (s) => setState(() => _period = s.first),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _SummaryBox(
                        title: 'الأرباح',
                        value: formatIraqiDinar(filteredEarnings),
                        icon: Icons.payments_outlined,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SummaryBox(
                        title: 'الرحلات',
                        value: '${_period == 'all' && visibleTrips.isEmpty ? _profile.totalTrips : visibleTrips.length}',
                        icon: Icons.route,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SummaryBox(
                        title: 'المسافة',
                        value: '${totalKm.toStringAsFixed(1)} كم',
                        icon: Icons.speed_outlined,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SummaryBox(
                        title: 'التقييم',
                        value: '${_profile.rating}',
                        icon: Icons.star,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const Text(
                  'الرحلات المكتملة',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                if (visibleTrips.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'لا توجد رحلات مكتملة في هذه الفترة.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                else
                  ...visibleTrips.map(
                    (t) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Card(
                        child: ListTile(
                          leading: const Icon(
                            Icons.local_taxi,
                            color: _captainGreen,
                          ),
                          title: Text('${t['origin']} -> ${t['destination']}'),
                          subtitle: Text(
                            'الزبون: ${t['passenger_name'] ?? 'زبون درب'}',
                          ),
                          trailing: Text(
                            formatIraqiDinar(
                              (t['fare_iqd'] as num?)?.toInt() ?? 0,
                            ),
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: _captainGreen,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _TriangularNavArrow extends StatelessWidget {
  const _TriangularNavArrow();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(34, 34),
      painter: _ArrowTrianglePainter(),
    );
  }
}

class _ArrowTrianglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = ui.Path()
      ..moveTo(w * 0.5, h * 0.08)
      ..lineTo(w * 0.88, h * 0.88)
      ..lineTo(w * 0.5, h * 0.68)
      ..lineTo(w * 0.12, h * 0.88)
      ..close();
    canvas.drawShadow(path, Colors.black.withValues(alpha: 0.45), 4, false);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..strokeJoin = ui.StrokeJoin.round,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = _captainBlue
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ExternalNavOptionTile extends StatelessWidget {
  const _ExternalNavOptionTile({
    required this.title,
    required this.installed,
    required this.isPreferred,
    required this.color,
    required this.onTap,
  });

  final String title;
  final bool installed;
  final bool isPreferred;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        side: BorderSide(color: isPreferred ? color : Colors.grey.shade400),
      ),
      child: Row(
        children: [
          Icon(Icons.navigation_outlined, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  installed ? 'مثبت على الجهاز' : 'غير مثبت (متاح عبر المتجر)',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: installed ? _captainGreen : Colors.grey,
                  ),
                ),
              ],
            ),
          ),
          if (isPreferred)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'المفضل',
                style: TextStyle(fontSize: 10.5, color: color, fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
    );
  }
}

class _SummaryBox extends StatelessWidget {
  const _SummaryBox({
    required this.title,
    required this.value,
    required this.icon,
  });

  final String title;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        child: Column(
          children: [
            Icon(icon, color: _captainGreen),
            const SizedBox(height: 6),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
            ),
            Text(
              title,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
