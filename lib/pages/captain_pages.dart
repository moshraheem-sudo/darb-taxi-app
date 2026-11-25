import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/ride_models.dart';
import '../services/location_service.dart';
import '../services/notification_center.dart';
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

class _CaptainHomePageState extends State<CaptainHomePage> {
  final _map = MapController();
  final _backend = RideBackendService.instance;
  final _locationService = GeolocatorLocationService.instance;
  final _dio = Dio();

  bool _mapReady = false;
  double _mapRotation = 0;
  LatLng _captainPosition = const LatLng(32.5050, 45.8230);
  double _captainHeading = 0;
  CaptainProfile _profile = const CaptainProfile();
  bool _loading = true;
  bool _busy = false;
  bool _hasServerUrl = false;

  RideRequestPayload? _incomingRequest;
  RideRequestPayload? _activeRide;
  List<LatLng> _routePoints = const [];

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
    _initCaptain();
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
          _incomingRequest = pendingLocal;
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
      setState(() => _incomingRequest = req);
      _startRequestCountdown();
      _loadRouteForRide(req);
      SystemSound.play(SystemSoundType.alert);
      HapticFeedback.heavyImpact();
      NotificationCenterService.addCaptainAlert(
        title: 'طلب رحلة جديد (${formatIraqiDinar(req.fareIqd)})',
        body: '${req.originName} -> ${req.destinationName}',
      );
    });

    _claimedSub = _backend.claimedRideIds.listen((rideId) {
      if (!mounted) return;
      if (_incomingRequest?.rideId == rideId && _activeRide?.rideId != rideId) {
        _requestCountdownTimer?.cancel();
        setState(() {
          _incomingRequest = null;
          _routePoints = const [];
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
    _requestCountdownTimer?.cancel();
    _simMoveTimer?.cancel();
    _gpsSub?.cancel();
    _reqSub?.cancel();
    _claimedSub?.cancel();
    _updateSub?.cancel();
    super.dispose();
  }

  Future<void> _startGpsTracking() async {
    try {
      final pos = await _locationService.getCurrentUserLocation();
      if (!mounted) return;
      final pt = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _captainPosition = pt;
        _captainHeading = pos.heading;
      });
      if (_mapReady) _map.move(pt, 15);
      await _backend.publishCaptainLocation(
        position: pt,
        heading: pos.heading,
        activeRideId: _activeRide?.rideId,
      );

      await _gpsSub?.cancel();
      _gpsSub = _locationService
          .watchUserLocation(distanceFilterMeters: 8)
          .listen((next) {
            if (!mounted) return;
            final nextPt = LatLng(next.latitude, next.longitude);
            setState(() {
              _captainPosition = nextPt;
              _captainHeading = next.heading;
            });
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
    if (value && _profile.approvalStatus != CaptainApprovalStatus.approved) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('أكمل بيانات الكابتن والموافقة على الحساب أولاً.'),
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
          setState(() => _incomingRequest = pending);
          _loadRouteForRide(pending);
        }
      } else {
        await _gpsSub?.cancel();
        _backend.disconnectRealtime();
        if (mounted) setState(() => _incomingRequest = null);
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

  void _startRequestCountdown() {
    _requestCountdownTimer?.cancel();
    if (mounted) setState(() => _requestCountdown = 30);
    _requestCountdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || _incomingRequest == null) {
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

  Future<void> _acceptIncoming() async {
    _requestCountdownTimer?.cancel();
    final req = _incomingRequest;
    if (req == null) return;
    setState(() => _busy = true);
    try {
      final accepted = await _backend.acceptRideAtomic(
        request: req,
        captain: _profile,
      );
      if (!mounted) return;
      setState(() {
        _incomingRequest = null;
        _activeRide = accepted;
      });
      await _loadRouteForRide(accepted);
      if (!_hasServerUrl) _startSimulatedMove();
    } on RideConflictException catch (e) {
      if (mounted) {
        setState(() => _incomingRequest = null);
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

  Future<void> _rejectIncoming() async {
    _requestCountdownTimer?.cancel();
    final req = _incomingRequest;
    if (req == null) return;
    await _backend.rejectRide(rideId: req.rideId, captainId: _profile.id);
    if (mounted) {
      setState(() {
        _incomingRequest = null;
        _routePoints = const [];
      });
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
        });
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
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم إلغاء الرحلة.')),
        );
      } else {
        setState(() => _activeRide = updated);
        await _loadRouteForRide(updated);
        if (!_hasServerUrl && next == RideDispatchStatus.inProgress) {
          _startSimulatedMove();
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
      idx += (_routePoints.length > 20) ? (_routePoints.length ~/ 12) : 1;
      setState(() => _captainPosition = nextPt);
      _backend.publishCaptainLocation(
        position: nextPt,
        heading: _captainHeading,
        activeRideId: _activeRide?.rideId,
      );
    });
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
              onPositionChanged: (camera, _) {
                if ((camera.rotation - _mapRotation).abs() > 0.5 && mounted) {
                  setState(() => _mapRotation = camera.rotation);
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
              ),
              if (_routePoints.isNotEmpty)
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
                  Marker(
                    point: _captainPosition,
                    width: 44,
                    height: 44,
                    child: AnimatedRotation(
                      turns: _captainHeading / 360,
                      duration: const Duration(milliseconds: 250),
                      child: Container(
                        decoration: BoxDecoration(
                          color: _captainGreen,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: const [
                            BoxShadow(color: Colors.black26, blurRadius: 6),
                          ],
                        ),
                        child: const Icon(
                          Icons.navigation,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
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
                  padding: const EdgeInsets.only(left: 16, bottom: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_mapRotation.abs() > 1.0) ...[
                          FloatingActionButton.small(
                            heroTag: 'captain_compass',
                            onPressed: () {
                              if (_mapReady) _map.rotate(0);
                              setState(() => _mapRotation = 0);
                            },
                            backgroundColor: surface,
                            foregroundColor: const Color(0xFFE53935),
                            child: AnimatedRotation(
                              turns: _mapRotation / 360,
                              duration: const Duration(milliseconds: 120),
                              child: const Icon(Icons.explore),
                            ),
                          ),
                          const SizedBox(height: 10),
                        ],
                        FloatingActionButton.small(
                          heroTag: 'captain_my_loc',
                          onPressed: _startGpsTracking,
                          backgroundColor: surface,
                          foregroundColor: primaryText,
                          child: const Icon(Icons.my_location),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_loading)
                  const LinearProgressIndicator()
                else if (_activeRide != null)
                  _buildActiveRideCard(
                    _activeRide!,
                    surface,
                    primaryText,
                    secondaryText,
                  )
                else if (_incomingRequest != null)
                  _buildIncomingRequestCard(
                    _incomingRequest!,
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
                Text(
                  formatIraqiDinar(_profile.totalEarnings),
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                    color: primaryText,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
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
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: _captainGreen.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Text(
                      '★ ${_profile.rating.toStringAsFixed(1)}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12.5,
                        color: primaryText,
                      ),
                    ),
                    Text(
                      '${_profile.totalTrips} رحلة',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12.5,
                        color: primaryText,
                      ),
                    ),
                    Text(
                      formatIraqiDinar(_profile.totalEarnings),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12.5,
                        color: _captainGreen,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _profile.isOnline
                    ? 'أنت متاح الآن؛ ستصلك إشعارات الطلبات القريبة فورياً.'
                    : 'اضغط على «غير متاح» بالأعلى لتفعيل استقبال الطلبات.',
                style: TextStyle(fontSize: 13, color: secondaryText),
              ),
              if (_profile.isOnline && !_hasServerUrl) ...[
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _backend.triggerLocalDemoRequest(
                          _captainPosition,
                        ),
                  icon: const Icon(Icons.notifications_active_outlined),
                  label: const Text('محاكاة طلب زبون تجريبي (محلي)'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _captainBlue,
                    minimumSize: const Size.fromHeight(46),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () async {
                  await context.push('/captain/onboarding');
                  final refreshed = await _backend.loadCaptainProfile();
                  if (mounted) setState(() => _profile = refreshed);
                },
                icon: const Icon(Icons.edit_document),
                label: const Text('إدارة بيانات السيارة والمستمسكات'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildIncomingRequestCard(
    RideRequestPayload req,
    Color surface,
    Color primaryText,
    Color secondaryText,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
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
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: _captainBlue.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    'طلب رحلة جديد',
                    style: TextStyle(
                      color: _captainBlue,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
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
                const Spacer(),
                Text(
                  formatIraqiDinar(req.fareIqd),
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: primaryText,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _requestCountdown / 30,
                minHeight: 4,
                backgroundColor: secondaryText.withValues(alpha: 0.15),
                color: _requestCountdown <= 10 ? Colors.redAccent : _captainBlue,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'الزبون: ${req.passengerName}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
                color: primaryText,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'الانطلاق: ${req.originName}',
              style: TextStyle(fontSize: 13, color: secondaryText),
            ),
            Text(
              'الوصول: ${req.destinationName}',
              style: TextStyle(fontSize: 13, color: secondaryText),
            ),
            if (req.distanceKm > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'المسافة: ${req.distanceKm.toStringAsFixed(1)} كم • ${req.durationMin.round()} دقيقة',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: _captainGreen,
                  ),
                ),
              ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : _rejectIncoming,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: const Text('رفض'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: _busy ? null : _acceptIncoming,
                    style: FilledButton.styleFrom(
                      backgroundColor: _captainGreen,
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: const Text(
                      'قبول الطلب',
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
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: ride.status == RideDispatchStatus.inProgress
                    ? 1.0
                    : (ride.status == RideDispatchStatus.arrived ? 0.66 : 0.33),
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
            const SizedBox(height: 14),
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
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await _backend.loadCaptainProfile();
    if (!mounted) return;
    setState(() {
      _profile = p;
      _name.text = p.fullName;
      _phone.text = p.phone;
      _carModel.text = p.carModel;
      _carColor.text = p.carColor;
      _plate.text = p.plateNumber;
      _tier = p.vehicleTier;
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
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(18),
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
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: _captainGreen,
                    minimumSize: const Size.fromHeight(52),
                  ),
                  child: Text(
                    _saving ? 'جارٍ الحفظ...' : 'حفظ وإرسال للموافقة',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
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
        : now.subtract(const Duration(days: 7));
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
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'all', label: Text('الكل')),
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
