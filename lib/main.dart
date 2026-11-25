import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models/ride_models.dart';
import 'pages/captain_pages.dart';
import 'pages/incoming_location_page.dart';
import 'pages/offline_maps_page.dart';
import 'pages/safety_page.dart';
import 'services/incoming_link_service.dart';
import 'services/map_link_parser.dart';
import 'services/notification_center.dart';
import 'services/offline_maps_service.dart';
import 'services/passenger_api.dart';
import 'services/ride_backend_service.dart';
import 'theme/darb_theme.dart';
import 'widgets/car_graphic.dart';
import 'widgets/darb_components.dart';
import 'widgets/ride_sheets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RideApp());

  // Notification setup must not hold the first Flutter frame hostage. A
  // plugin setup error should leave the ride screen usable on the device.
  unawaited(
    NotificationCenterService.initialize().catchError((Object error) {
      debugPrint('تعذر تهيئة الإشعارات: $error');
    }),
  );
}

const green = Color(0xFF087F65);
const ink = Color(0xFF142421);
const canvas = Color(0xFFF5F6F2);
final passengerLoggedIn = ValueNotifier<bool>(false);
final currentUserRole = ValueNotifier<UserRole>(UserRole.passenger);
String get savedPlacesStorageKey =>
    currentUserRole.value == UserRole.captain
        ? 'darb_saved_places_captain_v1'
        : 'darb_saved_places';

class Place {
  const Place(this.name, this.detail, this.point);
  final String name;
  final String detail;
  final LatLng point;

  Map<String, Object> toJson() => {
    'name': name,
    'detail': detail,
    'lat': point.latitude,
    'lon': point.longitude,
  };

  factory Place.fromJson(Map<String, dynamic> value) => Place(
    value['name'] as String,
    value['detail'] as String,
    LatLng((value['lat'] as num).toDouble(), (value['lon'] as num).toDouble()),
  );
}

class MapRepository {
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 10),
      headers: {'User-Agent': 'DarbPassenger/1.0 (Iraq passenger app)'},
    ),
  );

  Future<List<Place>> search(String query) async {
    final response = await _dio.get(
      'https://nominatim.openstreetmap.org/search',
      queryParameters: {'q': '$query, Iraq', 'format': 'jsonv2', 'limit': 7},
    );
    return (response.data as List).map((item) {
      final name =
          (item['name'] ?? item['display_name'].toString().split(',').first)
              .toString();
      return Place(
        name,
        item['display_name'].toString(),
        LatLng(
          double.parse(item['lat'].toString()),
          double.parse(item['lon'].toString()),
        ),
      );
    }).toList();
  }

  Future<RouteInfo> route(
    LatLng from,
    LatLng to, {
    List<LatLng> stops = const [],
    bool roundTrip = false,
  }) async {
    final waypoints = [from, ...stops, to, if (roundTrip) from];
    final coordinates = waypoints
        .map((point) => '${point.longitude},${point.latitude}')
        .join(';');
    final response = await _dio.get(
      'https://router.project-osrm.org/route/v1/driving/$coordinates',
      queryParameters: {
        'overview': 'full',
        'geometries': 'geojson',
        'alternatives': 'true',
      },
    );
    final routeItems = response.data['routes'] as List;
    RouteInfo parseRoute(dynamic item) {
      final points = (item['geometry']['coordinates'] as List)
          .map(
            (value) => LatLng(
              (value[1] as num).toDouble(),
              (value[0] as num).toDouble(),
            ),
          )
          .toList();
      return RouteInfo(
        (item['distance'] as num).toDouble() / 1000,
        (item['duration'] as num).toDouble() / 60,
        points,
      );
    }

    final parsed = routeItems.map(parseRoute).toList();
    final primary = parsed.first;
    return RouteInfo(
      primary.kilometers,
      primary.minutes,
      primary.points,
      alternatives: parsed.skip(1).toList(),
    );
  }
}

class RouteInfo {
  const RouteInfo(
    this.kilometers,
    this.minutes,
    this.points, {
    this.alternatives = const [],
  });
  final double kilometers;
  final double minutes;
  final List<LatLng> points;
  final List<RouteInfo> alternatives;
}

enum RideBookingStatus {
  idle,
  searching,
  driverAssigned,
  driverArrived,
  inProgress,
  completed,
}

class RideState {
  const RideState({
    this.origin,
    this.destination,
    this.originName = '',
    this.destinationName = '',
    this.originHeading = 0,
    this.stops = const [],
    this.route,
    this.routeOptions = const [],
    this.selectedRouteIndex = 0,
    this.driverPosition,
    this.driverHeading = 0,
    this.driverMarkerColor = 0xFF194BFB,
    this.locating = false,
    this.dark = false,
    this.roundTrip = false,
    this.secondDestination,
    this.stopWaitMinutes = 0,
    this.serviceCategory = 'taxi', // 'taxi' or 'box'
    this.selectedTier = 'saver', // 'saver' or 'plus'
    this.promoCode,
    this.discountAmount = 0,
    this.rideStatus = RideBookingStatus.idle,
    this.driverName = 'محمد ناصر ليهوب',
    this.driverCar = 'أبيض Kia Optima',
    this.driverPhone = '',
    this.driverPlate = '',
    this.driverPhotoUrl = '',
    this.driverRating = 4.9,
    this.tripTimeFormatted = 'الرحلة الاثنين بعدالظهر',
    this.lastRating = 5,
    this.lastFeedbackSubmitted = false,
    this.focusTarget,
    this.focusNonce = 0,
  });

  final LatLng? origin;
  final LatLng? destination;
  final String originName;
  final String destinationName;
  final double originHeading;
  final List<Place> stops;
  final RouteInfo? route;
  final List<RouteInfo> routeOptions;
  final int selectedRouteIndex;
  final LatLng? driverPosition;
  final double driverHeading;
  final int driverMarkerColor;
  final bool locating;
  final bool dark;
  final bool roundTrip;
  final Place? secondDestination;
  final int stopWaitMinutes;
  final String serviceCategory;
  final String selectedTier;
  final String? promoCode;
  final int discountAmount;
  final RideBookingStatus rideStatus;
  final String driverName;
  final String driverCar;
  final String driverPhone;
  final String driverPlate;
  final String driverPhotoUrl;
  final double driverRating;
  final String tripTimeFormatted;
  final int lastRating;
  final bool lastFeedbackSubmitted;
  final LatLng? focusTarget;
  final int focusNonce;

  RideState copy({
    LatLng? origin,
    LatLng? destination,
    String? originName,
    String? destinationName,
    double? originHeading,
    List<Place>? stops,
    RouteInfo? route,
    List<RouteInfo>? routeOptions,
    int? selectedRouteIndex,
    LatLng? driverPosition,
    double? driverHeading,
    int? driverMarkerColor,
    bool clearDriverPosition = false,
    bool clearRoute = false,
    bool? locating,
    bool? dark,
    bool? roundTrip,
    Place? secondDestination,
    bool clearSecondDestination = false,
    int? stopWaitMinutes,
    String? serviceCategory,
    String? selectedTier,
    String? promoCode,
    bool clearPromo = false,
    int? discountAmount,
    RideBookingStatus? rideStatus,
    String? driverName,
    String? driverCar,
    String? driverPhone,
    String? driverPlate,
    String? driverPhotoUrl,
    double? driverRating,
    String? tripTimeFormatted,
    int? lastRating,
    bool? lastFeedbackSubmitted,
    LatLng? focusTarget,
    int? focusNonce,
  }) => RideState(
    origin: origin ?? this.origin,
    destination: destination ?? this.destination,
    originName: originName ?? this.originName,
    destinationName: destinationName ?? this.destinationName,
    originHeading: originHeading ?? this.originHeading,
    stops: stops ?? this.stops,
    route: clearRoute ? null : route ?? this.route,
    routeOptions: clearRoute ? const [] : routeOptions ?? this.routeOptions,
    selectedRouteIndex: clearRoute
        ? 0
        : selectedRouteIndex ?? this.selectedRouteIndex,
    driverPosition: clearDriverPosition
        ? null
        : driverPosition ?? this.driverPosition,
    driverHeading: driverHeading ?? this.driverHeading,
    driverMarkerColor: driverMarkerColor ?? this.driverMarkerColor,
    locating: locating ?? this.locating,
    dark: dark ?? this.dark,
    roundTrip: roundTrip ?? this.roundTrip,
    secondDestination: clearSecondDestination
        ? null
        : (secondDestination ?? this.secondDestination),
    stopWaitMinutes: stopWaitMinutes ?? this.stopWaitMinutes,
    serviceCategory: serviceCategory ?? this.serviceCategory,
    selectedTier: selectedTier ?? this.selectedTier,
    promoCode: clearPromo ? null : (promoCode ?? this.promoCode),
    discountAmount: clearPromo ? 0 : (discountAmount ?? this.discountAmount),
    rideStatus: rideStatus ?? this.rideStatus,
    driverName: driverName ?? this.driverName,
    driverCar: driverCar ?? this.driverCar,
    driverPhone: driverPhone ?? this.driverPhone,
    driverPlate: driverPlate ?? this.driverPlate,
    driverPhotoUrl: driverPhotoUrl ?? this.driverPhotoUrl,
    driverRating: driverRating ?? this.driverRating,
    tripTimeFormatted: tripTimeFormatted ?? this.tripTimeFormatted,
    lastRating: lastRating ?? this.lastRating,
    lastFeedbackSubmitted: lastFeedbackSubmitted ?? this.lastFeedbackSubmitted,
    focusTarget: focusTarget ?? this.focusTarget,
    focusNonce: focusNonce ?? this.focusNonce,
  );
}

class RideCubit extends Cubit<RideState> {
  RideCubit(this.repository) : super(const RideState());

  final MapRepository repository;
  StreamSubscription<Position>? _positionSubscription;
  DateTime? _lastDriverRerouteAt;

  /// Feed this with live captain GPS updates from the driver service.
  /// When the captain is more than 350 m from the current route, fetch a new
  /// route to the passenger destination and update remaining distance/ETA.
  Future<void> updateDriverPosition(LatLng position, {double? heading}) async {
    if (state.rideStatus != RideBookingStatus.inProgress ||
        state.destination == null) {
      return;
    }
    emit(
      state.copy(
        driverPosition: position,
        driverHeading: heading ?? state.driverHeading,
      ),
    );
    final route = state.route;
    if (route == null || route.points.isEmpty) return;

    const distance = Distance();
    final offRouteKm = route.points
        .map((point) => distance.as(LengthUnit.Kilometer, position, point))
        .reduce((a, b) => a < b ? a : b);
    final now = DateTime.now();
    if (offRouteKm <= 0.35 ||
        (_lastDriverRerouteAt != null &&
            now.difference(_lastDriverRerouteAt!) <
                const Duration(seconds: 10))) {
      return;
    }

    _lastDriverRerouteAt = now;
    try {
      final replacement = await repository.route(position, state.destination!);
      if (state.rideStatus == RideBookingStatus.inProgress) {
        emit(
          state.copy(
            route: replacement,
            routeOptions: [replacement],
            selectedRouteIndex: 0,
            driverPosition: position,
          ),
        );
      }
    } catch (_) {
      // Keep the last valid route visible until the routing service recovers.
    }
  }

  Future<void> locate() async {
    emit(state.copy(locating: true));
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw Exception('فعّل خدمة الموقع من إعدادات الجهاز.');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception('إذن الموقع غير متاح. اختر نقطة الانطلاق بالبحث.');
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      emit(
        state.copy(
          origin: LatLng(position.latitude, position.longitude),
          originName: 'موقعي الحالي',
          originHeading: position.heading,
          locating: false,
          clearRoute: true,
        ),
      );
      await _positionSubscription?.cancel();
      _positionSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 5,
            ),
          ).listen((next) {
            if (state.originName != 'موقعي الحالي') return;
            emit(
              state.copy(
                origin: LatLng(next.latitude, next.longitude),
                originHeading: next.heading,
              ),
            );
          });
      await calculateRoute();
    } catch (_) {
      emit(state.copy(locating: false));
      rethrow;
    }
  }

  void setOrigin(Place place) {
    _positionSubscription?.cancel();
    emit(
      state.copy(
        origin: place.point,
        originName: place.name,
        originHeading: 0,
        clearRoute: true,
      ),
    );
    calculateRoute();
  }

  void setOriginPoint(LatLng point, {String? name}) {
    _positionSubscription?.cancel();
    emit(
      state.copy(
        origin: point,
        originName: name ?? 'نقطة الانطلاق المحددة',
        originHeading: 0,
        clearRoute: true,
      ),
    );
    calculateRoute();
  }

  void setDestination(Place place) {
    emit(
      state.copy(
        destination: place.point,
        destinationName: place.name,
        clearRoute: true,
      ),
    );
    calculateRoute();
  }

  void setMapDestination(LatLng point, {String? name}) {
    emit(
      state.copy(
        destination: point,
        destinationName: name ?? 'نقطة الوصول المحددة',
        clearRoute: true,
      ),
    );
    calculateRoute();
  }

  void setSecondDestination(Place? place) {
    emit(
      state.copy(
        secondDestination: place,
        clearSecondDestination: place == null,
        clearRoute: true,
      ),
    );
    calculateRoute();
  }

  void setStopWaitMinutes(int minutes) =>
      emit(state.copy(stopWaitMinutes: minutes));

  void setServiceCategory(String category) =>
      emit(state.copy(serviceCategory: category));

  void setSelectedTier(String tier) => emit(state.copy(selectedTier: tier));

  void applyPromoCode(String code, int discount) =>
      emit(state.copy(promoCode: code, discountAmount: discount));

  void focusOnPoint(LatLng point) => emit(
    state.copy(focusTarget: point, focusNonce: state.focusNonce + 1),
  );

  void removePromoCode() => emit(state.copy(clearPromo: true));

  void setRideStatus(RideBookingStatus status) {
    if (status == RideBookingStatus.idle ||
        status == RideBookingStatus.searching) {
      _lastDriverRerouteAt = null;
      emit(state.copy(rideStatus: status, clearDriverPosition: true));
      return;
    }
    emit(state.copy(rideStatus: status));
  }

  void selectRoute(int index) {
    if (index < 0 || index >= state.routeOptions.length) return;
    emit(
      state.copy(route: state.routeOptions[index], selectedRouteIndex: index),
    );
  }

  /// Called by the ride API when the driver assignment payload arrives.
  void updateDriverDetails({
    required String name,
    required String car,
    required String phone,
    required String plate,
    required String photoUrl,
    required double rating,
  }) {
    emit(
      state.copy(
        driverName: name,
        driverCar: car,
        driverPhone: phone,
        driverPlate: plate,
        driverPhotoUrl: photoUrl,
        driverRating: rating,
      ),
    );
  }

  void setDriverMarkerColor(int colorValue) {
    emit(state.copy(driverMarkerColor: colorValue));
    SharedPreferences.getInstance().then(
      (preferences) =>
          preferences.setInt('darb_driver_marker_color', colorValue),
    );
  }

  void setLastRating(int rating) =>
      emit(state.copy(lastRating: rating, lastFeedbackSubmitted: true));

  void resetAfterRide() {
    _lastDriverRerouteAt = null;
    emit(
      RideState(
        dark: state.dark,
        driverMarkerColor: state.driverMarkerColor,
        lastRating: state.lastRating,
        lastFeedbackSubmitted: state.lastFeedbackSubmitted,
      ),
    );
  }

  void setStops(List<Place> stops) {
    emit(state.copy(stops: stops, clearRoute: true));
    calculateRoute();
  }

  void setRoundTrip(bool value) {
    emit(state.copy(roundTrip: value, clearRoute: true));
    calculateRoute();
  }

  int priceForTier(String tier) {
    int base = (tier == 'plus')
        ? 1500
        : (state.serviceCategory == 'box' ? 1250 : 1000);
    int extra = 0;
    if (state.secondDestination != null) {
      extra += 500;
    }
    if (state.stopWaitMinutes > 0) {
      extra += (state.stopWaitMinutes <= 5
          ? 250
          : state.stopWaitMinutes <= 15
          ? 500
          : 750);
    }
    if (state.roundTrip) {
      extra += (base * 0.6).round();
      extra = ((extra / 250).round()) * 250;
    }
    final total = base + extra - state.discountAmount;
    return total < 500 ? 500 : total;
  }

  int get currentPrice => priceForTier(state.selectedTier);

  Future<void> calculateRoute() async {
    if (state.origin == null || state.destination == null) {
      emit(state.copy(clearRoute: true));
      return;
    }
    final allStops = [
      ...state.stops.map((s) => s.point),
      if (state.secondDestination != null) state.secondDestination!.point,
    ];
    try {
      final result = await repository.route(
        state.origin!,
        state.destination!,
        stops: allStops,
        roundTrip: state.roundTrip,
      );
      emit(
        state.copy(
          route: result,
          routeOptions: [result, ...result.alternatives],
          selectedRouteIndex: 0,
        ),
      );
    } catch (_) {
      // Fallback straight-line route representation
      final dist = _approxDistance(state.origin!, state.destination!);
      final points = [
        state.origin!,
        if (state.secondDestination != null) state.secondDestination!.point,
        state.destination!,
        if (state.roundTrip) state.origin!,
      ];
      final fallback = RouteInfo(dist, dist * 2.2, points);
      emit(
        state.copy(
          route: fallback,
          routeOptions: [fallback],
          selectedRouteIndex: 0,
        ),
      );
    }
  }

  double _approxDistance(LatLng p1, LatLng p2) {
    const Distance distance = Distance();
    return distance.as(LengthUnit.Kilometer, p1, p2);
  }

  Future<void> loadTheme() async {
    final preferences = await SharedPreferences.getInstance();
    final dark = preferences.getBool('darb_dark_theme') ?? false;
    final markerColor = preferences.getInt('darb_driver_marker_color');
    if (dark != state.dark || markerColor != null) {
      emit(
        state.copy(
          dark: dark,
          driverMarkerColor: markerColor ?? state.driverMarkerColor,
        ),
      );
    }
  }

  void toggleTheme() {
    final dark = !state.dark;
    emit(state.copy(dark: dark));
    SharedPreferences.getInstance().then(
      (preferences) => preferences.setBool('darb_dark_theme', dark),
    );
  }

  @override
  Future<void> close() async {
    await _positionSubscription?.cancel();
    return super.close();
  }
}

final router = GoRouter(
  redirect: (context, state) {
    final scheme = state.uri.scheme.toLowerCase();
    if (scheme == 'geo' ||
        scheme == 'darb' ||
        scheme == 'http' ||
        scheme == 'https') {
      IncomingLinkService.instance.emitExternalUri(state.uri.toString());
      return '/';
    }
    return null;
  },
  errorBuilder: (context, state) => const HomePage(),
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => ValueListenableBuilder<UserRole>(
        valueListenable: currentUserRole,
        builder: (context, role, _) => role == UserRole.captain
            ? const CaptainHomePage()
            : const HomePage(),
      ),
    ),
    GoRoute(
      path: '/captain/onboarding',
      builder: (context, state) => const CaptainOnboardingPage(),
    ),
    GoRoute(
      path: '/captain/history',
      builder: (context, state) => const CaptainHistoryPage(),
    ),
    GoRoute(path: '/ride', builder: (context, state) => const RidePage()),
    GoRoute(path: '/profile', builder: (context, state) => const ProfilePage()),
    GoRoute(
      path: '/favorites',
      builder: (context, state) => const FavoritePlacesPage(),
    ),
    GoRoute(path: '/history', builder: (context, state) => const HistoryPage()),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsPage(),
    ),
    GoRoute(
      path: '/offline-maps',
      builder: (context, state) => const OfflineMapsPage(),
    ),
    GoRoute(
      path: '/notifications',
      builder: (context, state) => const NotificationCenterPage(),
    ),
    GoRoute(
      path: '/safety',
      builder: (context, state) => const SafetyCenterPage(),
    ),
    GoRoute(
      path: '/login',
      builder: (context, state) => const PassengerLoginPage(),
    ),
    GoRoute(
      path: '/support',
      builder: (context, state) {
        final extra = state.extra;
        final details = extra is Map ? extra['details']?.toString() : null;
        final category = extra is Map ? extra['category']?.toString() : null;
        return SupportCenterPage(
          initialDetails: details,
          initialCategory: category,
        );
      },
    ),
    GoRoute(
      path: '/rides/:rideId/feedback',
      builder: (context, state) =>
          RideFeedbackPage(rideId: state.pathParameters['rideId']!),
    ),
    GoRoute(
      path: '/incoming-location',
      builder: (context, state) {
        final extra = state.extra;
        if (extra is! ParsedMapLocation) {
          return const HomePage();
        }
        final isCaptain = currentUserRole.value == UserRole.captain;
        final cubit = context.read<RideCubit>();
        final isRideActive = cubit.state.rideStatus != RideBookingStatus.idle;
        return IncomingLocationPage(
          location: extra,
          isRideActive: isRideActive,
          onSetDestination: () {
            final target = LatLng(extra.latitude, extra.longitude);
            final label = extra.placeName ?? extra.address ?? 'وجهة مشتركة';
            focusedMapPin.value = null;
            if (isCaptain) {
              captainIncomingDestination.value = FocusedMapPin(
                target,
                label: label,
              );
            } else {
              cubit.setMapDestination(target, name: label);
              cubit.focusOnPoint(target);
            }
            context.go('/');
          },
          onSetOrigin: () {
            final target = LatLng(extra.latitude, extra.longitude);
            final label = extra.placeName ?? extra.address ?? 'نقطة انطلاق';
            if (isCaptain) {
              focusedMapPin.value = FocusedMapPin(target, label: label);
            } else {
              focusedMapPin.value = null;
              cubit.setOriginPoint(target, name: label);
              cubit.focusOnPoint(target);
            }
            context.go('/');
          },
          onSetBoth: extra.hasDirections
              ? () {
                  final origin = LatLng(
                    extra.originLatitude!,
                    extra.originLongitude!,
                  );
                  final dest = LatLng(extra.latitude, extra.longitude);
                  focusedMapPin.value = null;
                  if (isCaptain) {
                    captainIncomingDestination.value = FocusedMapPin(
                      dest,
                      label: extra.placeName ?? extra.address ?? 'وجهة مشتركة',
                    );
                  } else {
                    cubit.setOriginPoint(origin, name: extra.originName);
                    cubit.setMapDestination(
                      dest,
                      name: extra.placeName ?? extra.address,
                    );
                  }
                  context.go('/');
                }
              : null,
          onViewOnMap: () {
            final target = LatLng(extra.latitude, extra.longitude);
            focusedMapPin.value = FocusedMapPin(
              target,
              label: extra.placeName ?? extra.address ?? 'الموقع المحدد',
            );
            cubit.focusOnPoint(target);
            context.go('/');
          },
        );
      },
    ),
  ],
);

class RideApp extends StatefulWidget {
  const RideApp({super.key});

  @override
  State<RideApp> createState() => _RideAppState();
}

final ValueNotifier<Locale> appLocale = ValueNotifier<Locale>(
  const Locale('ar'),
);

class _RideAppState extends State<RideApp> {
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<String>? _incomingLinkSub;
  ParsedMapLocation? _pendingIncomingLocation;

  @override
  void initState() {
    super.initState();
    passengerLoggedIn.addListener(_flushPendingIncomingLocation);
    SharedPreferences.getInstance().then((preferences) {
      currentUserRole.value = userRoleFromString(
        preferences.getString('darb_user_role'),
      );
      passengerLoggedIn.value =
          preferences.getBool('passenger_logged_in') ?? false;
      final lang = preferences.getString('darb_locale') ?? 'ar';
      appLocale.value = Locale(lang == 'en' ? 'en' : 'ar');
    });
    _initIncomingLinks();
  }

  Future<void> _initIncomingLinks() async {
    _incomingLinkSub = IncomingLinkService.instance.rawIncomingLinks.listen(
      (rawText) => unawaited(_handleRawIncomingLink(rawText)),
    );
    final initialLink =
        await IncomingLinkService.instance.initializeAndCheckInitial();
    if (initialLink != null && initialLink.isNotEmpty) {
      await _handleRawIncomingLink(initialLink);
    }
  }

  Future<void> _handleRawIncomingLink(String rawText) async {
    final parsed = await IncomingLinkService.instance.parseIncomingText(rawText);
    if (!mounted) return;
    if (parsed == null) {
      final isEn = appLocale.value.languageCode == 'en';
      _scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(
            isEn
                ? 'Could not extract valid coordinates from the shared link'
                : 'تعذر استخراج إحداثيات صالحة من الرابط المشترك',
          ),
        ),
      );
      return;
    }

    if (!passengerLoggedIn.value) {
      _pendingIncomingLocation = parsed;
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      router.push('/incoming-location', extra: parsed);
    });
  }

  void _flushPendingIncomingLocation() {
    if (!passengerLoggedIn.value || _pendingIncomingLocation == null) return;
    final pending = _pendingIncomingLocation!;
    _pendingIncomingLocation = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      router.push('/incoming-location', extra: pending);
    });
  }

  @override
  void dispose() {
    passengerLoggedIn.removeListener(_flushPendingIncomingLocation);
    _incomingLinkSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) => RideCubit(MapRepository())..loadTheme(),
    child: Builder(
      builder: (context) {
        final dark = context.watch<RideCubit>().state.dark;
        return ValueListenableBuilder<Locale>(
          valueListenable: appLocale,
          builder: (context, locale, _) => ValueListenableBuilder<bool>(
            valueListenable: passengerLoggedIn,
            builder: (context, loggedIn, _) {
              return MaterialApp.router(
                scaffoldMessengerKey: _scaffoldMessengerKey,
                debugShowCheckedModeBanner: false,
                routerConfig: router,
                themeMode: dark ? ThemeMode.dark : ThemeMode.light,
                theme: _theme(false),
                darkTheme: _theme(true),
                builder: (context, child) => Directionality(
                  textDirection: locale.languageCode == 'en'
                      ? TextDirection.ltr
                      : TextDirection.rtl,
                  child: loggedIn
                      ? (child ?? const SizedBox.shrink())
                      : Navigator(
                          onGenerateRoute: (_) => MaterialPageRoute<void>(
                            builder: (_) => const PassengerLoginPage(),
                          ),
                        ),
                ),
              );
            },
          ),
        );
      },
    ),
  );

  ThemeData _theme(bool dark) => DarbTheme.build(dark);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final _map = MapController();
  bool _mapReady = false;
  bool _mapTilesUnavailable = false;
  int _tileRetryKey = 0;
  bool _sheetCollapsed = false;
  double _sheetDragDelta = 0;
  double _bottomPanelHeight = 220;
  final GlobalKey _bottomPanelKey = GlobalKey();
  bool _setupDialogOpen = false;
  bool _isMapMoving = false;
  double _mapRotation = 0;
  String? _pickingMode; // 'origin', 'destination', 'second'
  LatLng? _mapCenterTemp;
  String? _message;
  List<Place> _recentPlaces = [];
  List<Place> _savedPlaces = [];
  Timer? _rideSimulationTimer;
  StreamSubscription<RideRequestPayload>? _rideUpdatesSub;
  StreamSubscription<LatLng>? _driverLocationSub;
  RideRequestPayload? _activeBackendRide;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSavedPlaces();
    _initRealtimeListeners();
    _restoreActiveRideIfAny();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkLocationAtLaunch();
    });
  }

  Future<void> _restoreActiveRideIfAny() async {
    final pending = await RideBackendService.instance.fetchActiveRide();
    if (!mounted || pending == null) return;
    if (pending.status == RideDispatchStatus.completed ||
        pending.status == RideDispatchStatus.cancelled) {
      return;
    }
    _activeBackendRide = pending;
    final cubit = context.read<RideCubit>();
    cubit.setOriginPoint(
      LatLng(pending.originLat, pending.originLng),
      name: pending.originName,
    );
    cubit.setMapDestination(
      LatLng(pending.destinationLat, pending.destinationLng),
      name: pending.destinationName,
    );
    if (pending.captainName != null && pending.captainName!.isNotEmpty) {
      cubit.updateDriverDetails(
        name: pending.captainName!,
        car: pending.captainCar ?? 'أبيض Kia Optima',
        phone: pending.captainPhone ?? '',
        plate: pending.captainPlate ?? '',
        photoUrl: pending.captainPhotoUrl ?? '',
        rating: pending.captainRating ?? 4.9,
      );
    }
    switch (pending.status) {
      case RideDispatchStatus.searching:
        cubit.setRideStatus(RideBookingStatus.searching);
        break;
      case RideDispatchStatus.accepted:
        cubit.setRideStatus(RideBookingStatus.driverAssigned);
        break;
      case RideDispatchStatus.arrived:
        cubit.setRideStatus(RideBookingStatus.driverArrived);
        break;
      case RideDispatchStatus.inProgress:
        cubit.setRideStatus(RideBookingStatus.inProgress);
        break;
      case RideDispatchStatus.completed:
      case RideDispatchStatus.cancelled:
        break;
    }
  }

  void _initRealtimeListeners() {
    _rideUpdatesSub = RideBackendService.instance.rideUpdates.listen((
      updated,
    ) {
      if (!mounted) return;
      if (_activeBackendRide != null &&
          _activeBackendRide!.rideId != updated.rideId) {
        return;
      }
      _activeBackendRide = updated;
      _rideSimulationTimer?.cancel();
      final cubit = context.read<RideCubit>();
      if (updated.captainName != null && updated.captainName!.isNotEmpty) {
        cubit.updateDriverDetails(
          name: updated.captainName!,
          car: updated.captainCar ?? 'أبيض Kia Optima',
          phone: updated.captainPhone ?? '',
          plate: updated.captainPlate ?? '',
          photoUrl: updated.captainPhotoUrl ?? '',
          rating: updated.captainRating ?? 4.9,
        );
      }
      switch (updated.status) {
        case RideDispatchStatus.searching:
          cubit.setRideStatus(RideBookingStatus.searching);
          break;
        case RideDispatchStatus.accepted:
          cubit.setRideStatus(RideBookingStatus.driverAssigned);
          break;
        case RideDispatchStatus.arrived:
          cubit.setRideStatus(RideBookingStatus.driverArrived);
          break;
        case RideDispatchStatus.inProgress:
          cubit.setRideStatus(RideBookingStatus.inProgress);
          break;
        case RideDispatchStatus.completed:
          _activeBackendRide = null;
          _completeRideAndRate();
          break;
        case RideDispatchStatus.cancelled:
          _activeBackendRide = null;
          cubit.setRideStatus(RideBookingStatus.idle);
          break;
      }
    });

    _driverLocationSub = RideBackendService.instance.driverLocations.listen((
      pos,
    ) {
      if (!mounted) return;
      final cubit = context.read<RideCubit>();
      if (cubit.state.rideStatus == RideBookingStatus.driverAssigned ||
          cubit.state.rideStatus == RideBookingStatus.driverArrived ||
          cubit.state.rideStatus == RideBookingStatus.inProgress) {
        cubit.updateDriverPosition(pos);
      }
    });
  }

  Future<void> _loadSavedPlaces() async {
    final preferences = await SharedPreferences.getInstance();
    if (!preferences.containsKey('darb_saved_places_schema_v3')) {
      await preferences.remove('darb_saved_places');
      await preferences.setBool('darb_saved_places_schema_v3', true);
    }
    List<Place> decodePlaces(String? value) {
      if (value == null) return [];
      try {
        return (jsonDecode(value) as List)
            .map(
              (item) => Place.fromJson(Map<String, dynamic>.from(item as Map)),
            )
            .toList();
      } catch (_) {
        return [];
      }
    }

    if (!mounted) return;
    setState(() {
      _recentPlaces = decodePlaces(preferences.getString('darb_recent_places'));
      _savedPlaces = decodePlaces(preferences.getString('darb_saved_places'));
    });
  }

  Future<void> _rememberDestination(Place place) async {
    _recentPlaces = [
      place,
      ..._recentPlaces.where((item) => item.name != place.name),
    ].take(5).toList();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      'darb_recent_places',
      jsonEncode(_recentPlaces.map((item) => item.toJson()).toList()),
    );
    if (mounted) setState(() {});
  }

  Future<void> _savePlace(Place place) async {
    final prefs = await SharedPreferences.getInstance();
    _savedPlaces = [
      place,
      ..._savedPlaces.where((item) => item.point != place.point),
    ];
    await prefs.setString(
      'darb_saved_places',
      jsonEncode(_savedPlaces.map((p) => p.toJson()).toList()),
    );
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تم حفظ المكان في المفضلة')));
    }
  }

  Future<void> _savePlaceWithName(LatLng point) async {
    final controller = TextEditingController(
      text: 'مفضلة ${_savedPlaces.length + 1}',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حفظ مكان مفضل'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'اسم المكان',
            hintText: 'مثال: المنزل، العمل، الجامعة',
          ),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('حفظ في المفضلة'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || name == null || name.isEmpty) return;
    await _savePlace(
      Place(
        name,
        '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}',
        point,
      ),
    );
  }

  Future<void> _removeSavedPlace(Place place) async {
    final prefs = await SharedPreferences.getInstance();
    _savedPlaces = _savedPlaces
        .where((item) => item.point != place.point || item.name != place.name)
        .toList();
    await prefs.setString(
      'darb_saved_places',
      jsonEncode(_savedPlaces.map((p) => p.toJson()).toList()),
    );
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حذف المكان من المفضلة')),
      );
    }
  }

  Future<void> _showMapActions(LatLng point, {Place? existingFavorite}) async {
    final exactPoint = LatLng(point.latitude, point.longitude);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                existingFavorite != null
                    ? existingFavorite.name
                    : 'خيارات الموقع المحدد',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${exactPoint.latitude.toStringAsFixed(5)}, ${exactPoint.longitude.toStringAsFixed(5)}',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.trip_origin, color: Color(0xFFE56A2B)),
                title: const Text('تحديد كنقطة انطلاق'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  context.read<RideCubit>().setOriginPoint(
                    exactPoint,
                    name: existingFavorite?.name ?? 'نقطة الانطلاق المحددة',
                  );
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.flag_rounded,
                  color: Color(0xFF0038FF),
                ),
                title: const Text('تحديد كنقطة وصول'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  context.read<RideCubit>().setMapDestination(
                    exactPoint,
                    name: existingFavorite?.name ?? 'نقطة الوصول المحددة',
                  );
                },
              ),
              if (existingFavorite == null)
                ListTile(
                  leading: const Icon(
                    Icons.favorite_border,
                    color: Color(0xFFE91E63),
                  ),
                  title: const Text('إضافة إلى المفضلة'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _savePlaceWithName(exactPoint);
                  },
                )
              else
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                  ),
                  title: const Text('حذف من المفضلة'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _removeSavedPlace(existingFavorite);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('مشاركة الموقع'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  SharePlus.instance.share(
                    ShareParams(
                      text:
                          'موقعي على الخريطة: https://www.openstreetmap.org/?mlat=${exactPoint.latitude}&mlon=${exactPoint.longitude}#map=17/${exactPoint.latitude}/${exactPoint.longitude}',
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _rideSimulationTimer?.cancel();
    _rideUpdatesSub?.cancel();
    _driverLocationSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_setupDialogOpen) {
      _checkLocationAtLaunch();
    }
  }

  Future<void> _checkLocationAtLaunch() async {
    if (context.read<RideCubit>().state.locating) return;
    final current = context.read<RideCubit>().state;
    // Do not replace a pickup point the passenger selected manually when the
    // app resumes from the background.
    // Do not request GPS on launch: passengers must explicitly choose a pickup.
    if (current.origin == null || current.originName != 'موقعي الحالي') return;
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    final permission = await Geolocator.checkPermission();
    if (!mounted) return;
    if (!serviceEnabled ||
        permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      await _showLocationSetup();
      return;
    }
    await _locate();
  }

  Future<void> _locate({bool showSetup = false}) async {
    final cubit = context.read<RideCubit>();
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (mounted) await _showLocationSetup();
      return;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) await _showLocationSetup();
      return;
    }
    try {
      await cubit.locate();
      if (!mounted) return;
      final point = cubit.state.origin;
      if (_mapReady && point != null) _map.move(point, 15);
      setState(() => _message = null);
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = error.toString().replaceFirst('Exception: ', ''),
        );
        if (showSetup) _showLocationSetup();
      }
    }
  }

  Future<void> _showLocationSetup() async {
    if (_setupDialogOpen || !mounted) return;
    _setupDialogOpen = true;
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    final permission = await Geolocator.checkPermission();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.location_searching, color: green, size: 34),
        title: const Text('فعّل الموقع للانطلاق'),
        content: Text(
          !serviceEnabled
              ? 'خدمة الموقع متوقفة. فعّلها لتحديد نقطة الانطلاق ومتابعة حركة الرحلة.'
              : 'اسمح لتطبيق درب باستخدام موقعك لتحديد الانطلاق بدقة ومتابعة تحركك. يمكنك اختيار الموقع يدوياً من الخريطة.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('اختيار يدوي'),
          ),
          FilledButton.icon(
            onPressed: () async {
              Navigator.pop(dialogContext);
              if (!serviceEnabled) {
                await Geolocator.openLocationSettings();
              } else if (permission == LocationPermission.deniedForever) {
                await Geolocator.openAppSettings();
              } else {
                await _locate(showSetup: true);
              }
            },
            icon: Icon(
              !serviceEnabled || permission == LocationPermission.deniedForever
                  ? Icons.settings
                  : Icons.my_location,
            ),
            label: Text(
              !serviceEnabled
                  ? 'تشغيل خدمة الموقع'
                  : permission == LocationPermission.deniedForever
                  ? 'فتح إعدادات التطبيق'
                  : 'السماح بالموقع',
            ),
          ),
        ],
      ),
    );
    _setupDialogOpen = false;
  }

  void _fitRouteBounds() {
    final state = context.read<RideCubit>().state;
    if (state.origin != null && state.destination != null && _mapReady) {
      final points = [
        state.origin!,
        if (state.secondDestination != null) state.secondDestination!.point,
        state.destination!,
      ];
      final bounds = LatLngBounds.fromPoints(points);
      _map.fitCamera(
        CameraFit.bounds(
          bounds: bounds,
          padding: const EdgeInsets.fromLTRB(40, 90, 40, 320),
        ),
      );
    }
  }

  Future<void> _choosePlace(String target) async {
    final cubit = context.read<RideCubit>();
    final place = await showDialog<Place>(
      context: context,
      builder: (context) => _PlaceSearchDialog(
        repository: cubit.repository,
        savedPlaces: _savedPlaces,
        recentPlaces: _recentPlaces,
      ),
    );
    if (!mounted || place == null) return;
    if (target == 'origin') {
      cubit.setOrigin(place);
      _rememberDestination(place);
    } else if (target == 'destination') {
      cubit.setDestination(place);
      _rememberDestination(place);
    } else if (target == 'second') {
      cubit.setSecondDestination(place);
    }
    if (_mapReady) _map.move(place.point, 15);
  }

  void _confirmPoint(LatLng point) {
    final cubit = context.read<RideCubit>();
    final confirmedPoint = point;
    if (_pickingMode == 'origin') {
      cubit.setOriginPoint(confirmedPoint, name: 'نقطة الانطلاق المحددة');
    } else if (_pickingMode == 'destination') {
      cubit.setMapDestination(confirmedPoint, name: 'نقطة الوصول المحددة');
    } else if (_pickingMode == 'second') {
      cubit.setSecondDestination(
        Place('الوجهة الثانية', 'واسط، الكوت', confirmedPoint),
      );
    } else if (_pickingMode == 'favorite') {
      _savePlaceWithName(confirmedPoint);
    }
    setState(() {
      _pickingMode = null;
      _mapCenterTemp = null;
    });
  }

  void _openPromoSheet() {
    final cubit = context.read<RideCubit>();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => PromoCodeSheet(
        currentCode: cubit.state.promoCode,
        onApply: (code, discount) {
          cubit.applyPromoCode(code, discount);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: const Color(0xFF194BFB),
              content: Text(
                'تم تطبيق رمز الخصم "$code" بنجاح (-$discount د.ع)',
              ),
            ),
          );
        },
      ),
    );
  }

  void _openRideOptionsSheet() {
    final cubit = context.read<RideCubit>();
    final state = cubit.state;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => RideOptionsSheet(
        selectedTier: state.selectedTier,
        secondDestinationName: state.secondDestination?.name,
        stopWaitMinutes: state.stopWaitMinutes,
        roundTrip: state.roundTrip,
        basePrice: cubit.priceForTier(state.selectedTier),
        onSelectSecondDestination: () {
          Navigator.pop(context);
          _choosePlace('second');
        },
        onRemoveSecondDestination: () {
          cubit.setSecondDestination(null);
        },
        onChangeStopWait: (minutes) {
          cubit.setStopWaitMinutes(minutes);
        },
        onChangeRoundTrip: (roundTrip) {
          cubit.setRoundTrip(roundTrip);
        },
        onConfirm: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: green,
              content: Text('تم حفظ وتأكيد خيارات الرحلة بنجاح'),
            ),
          );
        },
      ),
    );
  }

  Future<void> _startRideBooking() async {
    final cubit = context.read<RideCubit>();
    final state = cubit.state;
    if (state.origin == null || state.destination == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('حدد نقطة الانطلاق والوصول أولاً.')),
      );
      return;
    }
    cubit.setRideStatus(RideBookingStatus.searching);

    final prefs = await SharedPreferences.getInstance();
    final passengerName = prefs.getString('passenger_name') ?? 'زبون درب';
    final passengerPhone = prefs.getString('passenger_phone') ?? '';
    final payload = RideRequestPayload(
      rideId: 'ride_${DateTime.now().millisecondsSinceEpoch}',
      passengerName: passengerName,
      passengerPhone: passengerPhone,
      originLat: state.origin!.latitude,
      originLng: state.origin!.longitude,
      originName: state.originName,
      destinationLat: state.destination!.latitude,
      destinationLng: state.destination!.longitude,
      destinationName: state.destinationName,
      secondDestinationName: state.secondDestination?.name,
      secondDestinationLat: state.secondDestination?.point.latitude,
      secondDestinationLng: state.secondDestination?.point.longitude,
      stopWaitMinutes: state.stopWaitMinutes,
      roundTrip: state.roundTrip,
      serviceCategory: state.serviceCategory,
      selectedTier: state.selectedTier,
      fareIqd: cubit.currentPrice,
      promoCode: state.promoCode,
      discountAmount: state.discountAmount,
      distanceKm: state.route?.kilometers ?? 0,
      durationMin: state.route?.minutes ?? 0,
      createdAt: DateTime.now(),
    );

    try {
      final created = await RideBackendService.instance.createRideRequest(
        payload,
      );
      _activeBackendRide = created;
    } catch (_) {
      if (!mounted) return;
      cubit.setRideStatus(RideBookingStatus.idle);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر إرسال الطلب إلى الخادم. حاول مجدداً.')),
      );
      return;
    }
  }

  void _cancelRide() {
    _rideSimulationTimer?.cancel();
    final active = _activeBackendRide;
    _activeBackendRide = null;
    if (active != null) {
      unawaited(
        RideBackendService.instance
            .updateRideStatus(
              request: active,
              nextStatus: RideDispatchStatus.cancelled,
            )
            .catchError((_) => active),
      );
    }
    context.read<RideCubit>().setRideStatus(RideBookingStatus.idle);
  }

  Future<void> _launchDriverContact(String scheme) async {
    final phone = context.read<RideCubit>().state.driverPhone.trim();
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('لم تصل بيانات اتصال السائق من الخادم بعد.'),
        ),
      );
      return;
    }
    try {
      final launched = await launchUrl(Uri(scheme: scheme, path: phone));
      if (!launched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا يوجد تطبيق مناسب لهذا الإجراء.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر فتح تطبيق الاتصال أو الرسائل.')),
        );
      }
    }
  }

  Future<void> _shareActiveRideDetails(RideState state) async {
    final dest = state.destination;
    final mapUrl = dest == null
        ? ''
        : '\nرابط الوجهة: https://www.openstreetmap.org/?mlat=${dest.latitude}&mlon=${dest.longitude}#map=16/${dest.latitude}/${dest.longitude}';
    final msg =
        'أشارك معك تفاصيل رحلتي عبر تطبيق درب:\n'
        'الكابتن: ${state.driverName}\n'
        'السيارة: ${state.driverCar}${state.driverPlate.isNotEmpty ? ' (${state.driverPlate})' : ''}\n'
        'من: ${state.originName}\n'
        'إلى: ${state.destinationName}$mapUrl';
    await SharePlus.instance.share(ShareParams(text: msg));
  }

  Future<void> _completeRideAndRate() async {
    _rideSimulationTimer?.cancel();
    final cubit = context.read<RideCubit>();
    final state = cubit.state;
    _saveCompletedRide(state, cubit.currentPrice);
    cubit.setRideStatus(RideBookingStatus.completed);

    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => DriverRatingSheet(
          driverName: state.driverName,
          driverCar: state.driverCar,
          destinationName: state.destinationName.isNotEmpty
              ? state.destinationName
              : 'الكوت، شارع الضفاف',
          tripTime: state.tripTimeFormatted,
          onSubmit: (rating, comment) {
            cubit.setLastRating(rating);
            final rideId = _activeBackendRide?.rideId;
            if (rideId != null && rideId.isNotEmpty) {
              unawaited(
                RideBackendService.instance
                    .submitRideRating(
                      rideId: rideId,
                      stars: rating,
                      comment: comment,
                    )
                    .catchError((_) {}),
              );
            }
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: green,
                content: Text(
                  'شكراً لمشاركتنا تقييمك ($rating نجوم)! نسعد دائماً بخدمتك.',
                ),
              ),
            );
          },
        ),
      );
    } finally {
      _activeBackendRide = null;
      // Reset unconditionally once the rating sheet closes. The modal can be
      // dismissed with the close button or the system back action, in which
      // case the ride status may no longer match "completed".
      cubit.resetAfterRide();
      if (mounted) {
        setState(() {
          _sheetCollapsed = false;
          _pickingMode = null;
          _mapCenterTemp = null;
        });
        if (_mapReady) {
          _map.move(const LatLng(32.5050, 45.8230), 14.5);
        }
      }
    }
  }

  Future<void> _saveCompletedRide(RideState ride, int price) async {
    final preferences = await SharedPreferences.getInstance();
    final previous = preferences.getString('darb_completed_rides');
    final List<dynamic> rides = previous == null
        ? <dynamic>[]
        : (jsonDecode(previous) as List<dynamic>);
    final rideId = DateTime.now().millisecondsSinceEpoch.toString();
    rides.insert(0, {
      'id': rideId,
      'date': DateTime.now().toIso8601String(),
      'origin': ride.originName,
      'destination': ride.destinationName,
      'driver': ride.driverName,
      'car': ride.driverCar,
      if (ride.driverPhotoUrl.isNotEmpty) 'captain_photo_url': ride.driverPhotoUrl,
      'captain_rating': ride.driverRating,
      'price': price,
      'kilometers': ride.route?.kilometers,
    });
    await preferences.setString(
      'darb_completed_rides',
      jsonEncode(rides.take(100).toList()),
    );
  }

  LatLng _centerPinPoint(BuildContext context) {
    if (!_mapReady) return _mapCenterTemp ?? const LatLng(32.5050, 45.8230);
    final size = MediaQuery.sizeOf(context);
    final pinScreenOffset = Offset(
      size.width / 2,
      (size.height - _bottomPanelHeight) / 2,
    );
    return _map.camera.screenOffsetToLatLng(pinScreenOffset);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<RideCubit>().state;
    final cubit = context.read<RideCubit>();
    final center = state.origin ?? const LatLng(32.5050, 45.8230);
    final controlsAtTop =
        _bottomPanelHeight > MediaQuery.sizeOf(context).height * 0.55;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final renderObject = _bottomPanelKey.currentContext?.findRenderObject();
      if (renderObject is RenderBox && renderObject.hasSize) {
        final measured = renderObject.size.height;
        if ((measured - _bottomPanelHeight).abs() > 1) {
          setState(() => _bottomPanelHeight = measured);
        }
      }
    });

    return BlocListener<RideCubit, RideState>(
      listenWhen: (prev, curr) =>
          prev.focusNonce != curr.focusNonce && curr.focusTarget != null,
      listener: (context, state) {
        if (_mapReady && state.focusTarget != null) {
          _map.move(state.focusTarget!, 16.5);
          _map.rotate(0);
          setState(() => _mapRotation = 0);
        }
      },
      child: Scaffold(
        body: Stack(
        children: [
          // 1. Full Screen Interactive Map
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: center,
              initialZoom: 14.5,
              onMapReady: () {
                _mapReady = true;
                _fitRouteBounds();
              },
              onPositionChanged: (camera, hasGesture) {
                if ((camera.rotation - _mapRotation).abs() > 0.5 && mounted) {
                  setState(() => _mapRotation = camera.rotation);
                }
                if (hasGesture) {
                  if (!_isMapMoving) {
                    setState(() => _isMapMoving = true);
                  }
                  if (_pickingMode != null) {
                    _mapCenterTemp = _centerPinPoint(context);
                  }
                }
              },
              onMapEvent: (event) {
                if (event is MapEventMoveEnd ||
                    event is MapEventFlingAnimationEnd ||
                    event is MapEventDoubleTapZoomEnd ||
                    event is MapEventRotateEnd) {
                  if (mounted) {
                    setState(() {
                      _isMapMoving = false;
                      _mapRotation = _map.camera.rotation;
                      if (_pickingMode != null) {
                        _mapCenterTemp = _centerPinPoint(context);
                      }
                    });
                  }
                }
              },
              onTap: (tapPosition, point) {
                if (_pickingMode != null) {
                  _confirmPoint(point);
                } else {
                  _showMapActions(point);
                }
              },
            ),
            children: [
              TileLayer(
                key: ValueKey(_tileRetryKey),
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                fallbackUrl:
                    'https://{s}.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png',
                subdomains: const ['a', 'b', 'c'],
                userAgentPackageName: 'iq.ridepassenger.car',
                maxZoom: 19,
                keepBuffer: 4,
                panBuffer: 2,
                tileDisplay: const TileDisplay.fadeIn(
                  duration: Duration(milliseconds: 120),
                ),
                tileProvider: DarbOfflineTileProvider(),
                tileBuilder: state.dark ? darkModeTileBuilder : null,
                errorTileCallback: (tile, error, stackTrace) {
                  if (!_mapTilesUnavailable && mounted) {
                    setState(() => _mapTilesUnavailable = true);
                  }
                },
              ),

              // Route Polyline Layer
              if (state.route != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: state.route!.points,
                      color: state.dark
                          ? const Color(0xFF8EAAFF)
                          : const Color(0xFF194BFB),
                      strokeWidth: 5.5,
                    ),
                  ],
                ),

              // Locked Map Markers (Keep Pin Point Position Strictly Fixed)
              MarkerLayer(
                markers: [
                  if (state.driverPosition != null)
                    Marker(
                      point: state.driverPosition!,
                      width: 54,
                      height: 60,
                      child: AnimatedRotation(
                        turns: state.driverHeading / 360,
                        duration: const Duration(milliseconds: 350),
                        curve: Curves.easeOut,
                        child: TopDownCarMarker(
                          color: Color(state.driverMarkerColor),
                        ),
                      ),
                    ),
                  // Origin Marker: Orange Circle with "الانطلاق" Pill
                  if (state.origin != null)
                    Marker(
                      point: state.origin!,
                      width: 100,
                      height: 75,
                      rotate: true,
                      alignment: Alignment.topCenter,
                      child: const LocationMapMarker(
                        title: 'الانطلاق',
                        pinColor: Color(0xFFE56A2B),
                        isSquare: false,
                      ),
                    ),

                  // Destination Marker: Blue Square with "الوصول" Pill
                  if (state.destination != null)
                    Marker(
                      point: state.destination!,
                      width: 100,
                      height: 75,
                      rotate: true,
                      alignment: Alignment.topCenter,
                      child: const LocationMapMarker(
                        title: 'الوصول',
                        pinColor: Color(0xFF0038FF),
                        isSquare: true,
                      ),
                    ),

                  // Second Destination Marker (if set)
                  if (state.secondDestination != null)
                    Marker(
                      point: state.secondDestination!.point,
                      width: 110,
                      height: 75,
                      rotate: true,
                      alignment: Alignment.topCenter,
                      child: const LocationMapMarker(
                        title: 'الوجهة الثانية',
                        pinColor: Color(0xFF8E24AA),
                        isSquare: true,
                      ),
                    ),
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
                  for (final place in _savedPlaces)
                    Marker(
                      point: place.point,
                      width: 18,
                      height: 18,
                      rotate: true,
                      alignment: Alignment.center,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _showMapActions(
                          place.point,
                          existingFavorite: place,
                        ),
                        child: Tooltip(
                          message: place.name,
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFFE91E63),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white,
                                width: 1.5,
                              ),
                              boxShadow: const [
                                BoxShadow(color: Colors.black26, blurRadius: 3),
                              ],
                            ),
                            child: const Icon(
                              Icons.favorite,
                              color: Colors.white,
                              size: 10,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),

              RichAttributionWidget(
                attributions: [
                  TextSourceAttribution('© OpenStreetMap contributors • HOT'),
                ],
                alignment: AttributionAlignment.bottomLeft,
              ),
            ],
          ),

          if (state.rideStatus == RideBookingStatus.idle)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              bottom: _bottomPanelHeight,
              child: Center(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    final point = _centerPinPoint(context);
                    if (_pickingMode != null) {
                      _confirmPoint(point);
                    } else {
                      _showMapActions(point);
                    }
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOut,
                        transform: Matrix4.translationValues(
                          0,
                          _isMapMoving ? -10 : 0,
                          0,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_pickingMode != null) ...[
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: state.dark
                                      ? const Color(0xFF1F2E2A)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(14),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Colors.black26,
                                      blurRadius: 6,
                                      offset: Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Text(
                                  _pickingMode == 'origin'
                                      ? 'تحديد الانطلاق'
                                      : (_pickingMode == 'destination'
                                          ? 'تحديد الوصول'
                                          : 'الوجهة الثانية'),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: state.dark ? Colors.white : ink,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              DarbPinGroundShadow(lifted: _isMapMoving),
                              const SizedBox(height: 2),
                            ],
                            Icon(
                              Icons.location_on,
                              size: 42,
                              color: _pickingMode == 'origin'
                                  ? const Color(0xFFE56A2B)
                                  : (_pickingMode == 'second'
                                      ? const Color(0xFF8E24AA)
                                      : const Color(0xFF0038FF)),
                              shadows: const [
                                Shadow(
                                  color: Colors.black38,
                                  blurRadius: 8,
                                  offset: Offset(0, 3),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: _isMapMoving ? 8 : 6,
                        height: _isMapMoving ? 4 : 3,
                        decoration: BoxDecoration(
                          color: Colors.black45,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          if (_mapTilesUnavailable)
            Positioned(
              top: 136,
              left: 18,
              right: 18,
              child: Material(
                color: Colors.white,
                elevation: 5,
                borderRadius: BorderRadius.circular(14),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.map_outlined, color: green),
                  title: const Text('تعذر تحميل الخريطة'),
                  subtitle: const Text('تحقق من الإنترنت ثم أعد المحاولة.'),
                  trailing: IconButton(
                    tooltip: 'إعادة تحميل الخريطة',
                    onPressed: () => setState(() {
                      _mapTilesUnavailable = false;
                      _tileRetryKey++;
                    }),
                    icon: const Icon(Icons.refresh),
                  ),
                ),
              ),
            ),

          // 3. Top Navigation Bar
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  // Profile Button
                  IconButton.filled(
                    tooltip: 'الملف الشخصي',
                    onPressed: () => context.push('/profile'),
                    style: IconButton.styleFrom(
                      backgroundColor: state.dark
                          ? const Color(0xFF22312E)
                          : Colors.white,
                      foregroundColor: state.dark ? Colors.white : ink,
                      elevation: 4,
                      shadowColor: Colors.black26,
                    ),
                    icon: const Icon(Icons.person_outline),
                  ),
                  const SizedBox(width: 8),

                  // Notifications/Menu button
                  IconButton.filled(
                    tooltip: 'مركز الإشعارات',
                    onPressed: () => context.push('/notifications'),
                    style: IconButton.styleFrom(
                      backgroundColor: state.dark
                          ? const Color(0xFF22312E)
                          : Colors.white,
                      foregroundColor: state.dark ? Colors.white : ink,
                      elevation: 4,
                      shadowColor: Colors.black26,
                    ),
                    icon: const Icon(Icons.notifications_none),
                  ),
                ],
              ),
            ),
          ),

          // 4. Notice Message Banner
          if (_message != null)
            Positioned(
              top: 80,
              left: 16,
              right: 16,
              child: _Notice(
                message: _message!,
                onClose: () => setState(() => _message = null),
              ),
            ),

          // 5. BOTTOM STACK: Floating Map Controls + Bottom Sheet (never overlapped!)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!controlsAtTop)
                  Padding(
                    padding: const EdgeInsets.only(left: 16, right: 16, bottom: 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _buildMapControlButtons(state),
                    ),
                  ),
                _pickingMode != null
                    ? KeyedSubtree(
                        key: _bottomPanelKey,
                        child: _buildMapPickingCard(),
                      )
                    : KeyedSubtree(
                        key: _bottomPanelKey,
                        child: GestureDetector(
                          key: const ValueKey('ride-sheet-gesture'),
                          behavior: HitTestBehavior.opaque,
                          onVerticalDragStart: (_) => _sheetDragDelta = 0,
                          onVerticalDragUpdate: (details) =>
                              _sheetDragDelta += details.delta.dy,
                          onVerticalDragEnd: (_) {
                            if (_sheetDragDelta > 60 && !_sheetCollapsed) {
                              setState(() => _sheetCollapsed = true);
                            } else if (_sheetDragDelta < -60 &&
                                _sheetCollapsed) {
                              setState(() => _sheetCollapsed = false);
                            }
                          },
                          child: AnimatedSize(
                            duration: const Duration(milliseconds: 240),
                            curve: Curves.easeOutCubic,
                            alignment: Alignment.bottomCenter,
                            child: _sheetCollapsed
                                ? _buildCollapsedRideSheet(state, cubit)
                                : _buildRideBookingSheet(context, state, cubit),
                          ),
                        ),
                      ),
              ],
            ),
          ),
          if (controlsAtTop)
            Positioned(
              left: 16,
              top: 112,
              child: _buildMapControlButtons(state),
            ),
        ],
      ),
      ),
    );
  }

  Widget _buildMapControlButtons(RideState state) {
    final bg = state.dark ? const Color(0xFF22312E) : Colors.white;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_mapRotation.abs() > 1.0) ...[
          FloatingActionButton.small(
            heroTag: 'fab_compass',
            tooltip: 'إعادة توجيه الخريطة للشمال',
            onPressed: () {
              if (_mapReady) {
                _map.rotate(0);
              }
              setState(() => _mapRotation = 0);
            },
            backgroundColor: bg,
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
          heroTag: 'fab_fit',
          tooltip: 'عرض المسار كاملاً',
          onPressed: () {
            if (_mapReady) _map.rotate(0);
            setState(() => _mapRotation = 0);
            _fitRouteBounds();
          },
          backgroundColor: bg,
          foregroundColor: state.dark
              ? const Color(0xFF8EAAFF)
              : const Color(0xFF0038FF),
          child: const Icon(Icons.alt_route_rounded),
        ),
        const SizedBox(height: 10),
        FloatingActionButton.small(
          heroTag: 'fab_my_location',
          tooltip: 'موقعي',
          onPressed: () => _locate(showSetup: true),
          backgroundColor: bg,
          foregroundColor: state.dark ? Colors.white : ink,
          child: state.locating
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.my_location),
        ),
      ],
    );
  }

  /// Bottom Card when user is selecting a point on the map
  Widget _buildMapPickingCard() {
    final dark = context.read<RideCubit>().state.dark;
    final surface = dark ? const Color(0xFF182522) : Colors.white;
    final primaryText = dark ? Colors.white : ink;
    final title = _pickingMode == 'origin'
        ? 'تحديد نقطة الانطلاق'
        : (_pickingMode == 'destination'
              ? 'تحديد نقطة الوصول'
              : (_pickingMode == 'favorite'
                    ? 'حفظ مكان في المفضلة'
                    : 'تحديد الوجهة الثانية'));
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          const BoxShadow(
            color: Colors.black12,
            blurRadius: 16,
            offset: Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: primaryText,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'حرّك الخريطة أو اضغط مباشرة لوضع النقطة بدقة، ثم اضغط تأكيد.',
              style: TextStyle(
                fontSize: 13,
                color: dark ? Colors.white70 : Colors.grey,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => setState(() => _pickingMode = null),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('إلغاء'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: () =>
                        _confirmPoint(_centerPinPoint(context)),
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('تأكيد هذا المكان'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0038FF),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
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

  /// Bottom Sheet matching Image 3: Tabs, Ride Tiers, Coupon & Options, CTA Button
  Widget _buildRideBookingSheet(
    BuildContext context,
    RideState state,
    RideCubit cubit,
  ) {
    if (state.rideStatus == RideBookingStatus.searching) {
      return _buildSearchingSheet(state);
    } else if (state.rideStatus == RideBookingStatus.driverAssigned ||
        state.rideStatus == RideBookingStatus.driverArrived ||
        state.rideStatus == RideBookingStatus.inProgress) {
      return _buildActiveRideSheet(state);
    }

    if (state.origin == null || state.destination == null) {
      return _buildLocationSelectionSheet(state);
    }

    final isTaxi = state.serviceCategory == 'taxi';
    final isSaver = state.selectedTier == 'saver';
    final isPlus = state.selectedTier == 'plus';
    final saverPrice = cubit.priceForTier('saver');
    final plusPrice = cubit.priceForTier('plus');
    final boxPrice = cubit.priceForTier('box');
    final dark = state.dark;
    final surface = dark ? const Color(0xFF182522) : Colors.white;
    final primaryText = dark ? Colors.white : const Color(0xFF142421);

    return Container(
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 20,
            offset: Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Top Tabs: بوكس | تكسي (Image 3)
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => cubit.setServiceCategory('taxi'),
                      borderRadius: BorderRadius.circular(8),
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              'تكسي',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: isTaxi
                                    ? FontWeight.w900
                                    : FontWeight.w600,
                                color: isTaxi
                                    ? primaryText
                                    : (dark ? Colors.white60 : Colors.grey),
                              ),
                            ),
                          ),
                          Container(
                            height: 3,
                            color: isTaxi
                                ? const Color(0xFF194BFB)
                                : Colors.transparent,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: () => cubit.setServiceCategory('box'),
                      borderRadius: BorderRadius.circular(8),
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              'بوكس',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: !isTaxi
                                    ? FontWeight.w900
                                    : FontWeight.w600,
                                color: !isTaxi
                                    ? primaryText
                                    : (dark ? Colors.white60 : Colors.grey),
                              ),
                            ),
                          ),
                          Container(
                            height: 3,
                            color: !isTaxi
                                ? const Color(0xFF194BFB)
                                : Colors.transparent,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              if (state.routeOptions.length > 1) ...[
                _buildRouteChoices(state, cubit),
                const SizedBox(height: 12),
              ],

              // Show the current fare as soon as both endpoints are selected.
              if (isTaxi) ...[
                // Option 1: توفير (Saver)
                _buildRideTierTile(
                  title: 'توفير',
                  subtitle: 'التكسي الأوفر',
                  price: saverPrice,
                  badgeType: 'dollar',
                  dark: dark,
                  isSelected: isSaver,
                  onTap: () => cubit.setSelectedTier('saver'),
                ),
                const SizedBox(height: 8),

                // Option 2: بَلَس (Plus)
                _buildRideTierTile(
                  title: 'بَلَس',
                  subtitle: 'راحة أكثر',
                  price: plusPrice,
                  badgeType: 'star',
                  dark: dark,
                  isSelected: isPlus,
                  onTap: () => cubit.setSelectedTier('plus'),
                ),
              ] else ...[
                // Parcel delivery tier (Box)
                _buildRideTierTile(
                  title: 'بوكس درب',
                  subtitle: 'توصيل سريع وموثوق للطرود',
                  price: boxPrice,
                  badgeType: 'box',
                  dark: dark,
                  isSelected: true,
                  onTap: () {},
                ),
              ],
              const SizedBox(height: 12),

              // Quick Action Bar: قسيمة (Image 1) & خيارات الرحلة (Image 2)
              Row(
                children: [
                  // قسيمة (Promo code button)
                  Expanded(
                    child: InkWell(
                      onTap: _openPromoSheet,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        height: 48,
                        decoration: BoxDecoration(
                          color: state.promoCode != null
                              ? const Color(0xFFEEF2FF)
                              : (dark
                                    ? const Color(0xFF22322E)
                                    : Colors.grey.shade50),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: state.promoCode != null
                                ? const Color(0xFF194BFB)
                                : Colors.grey.shade300,
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.local_offer_outlined,
                              size: 20,
                              color: state.promoCode != null
                                  ? const Color(0xFF194BFB)
                                  : primaryText,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              state.promoCode != null
                                  ? 'خصم ${state.discountAmount} د.ع'
                                  : 'قسيمة',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: state.promoCode != null
                                    ? const Color(0xFF194BFB)
                                    : primaryText,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // خيارات الرحلة (Ride options button)
                  Expanded(
                    child: InkWell(
                      onTap: _openRideOptionsSheet,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        height: 48,
                        decoration: BoxDecoration(
                          color:
                              (state.secondDestination != null ||
                                  state.stopWaitMinutes > 0 ||
                                  state.roundTrip)
                              ? const Color(0xFFEEF2FF)
                              : (dark
                                    ? const Color(0xFF22322E)
                                    : Colors.grey.shade50),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color:
                                (state.secondDestination != null ||
                                    state.stopWaitMinutes > 0 ||
                                    state.roundTrip)
                                ? const Color(0xFF194BFB)
                                : Colors.grey.shade300,
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.tune_rounded,
                              size: 20,
                              color:
                                  (state.secondDestination != null ||
                                      state.stopWaitMinutes > 0 ||
                                      state.roundTrip)
                                  ? const Color(0xFF194BFB)
                                  : primaryText,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'خيارات الرحلة',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: primaryText,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Coupon and trip options stay optional; request uses the visible fare.
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _startRideBooking,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0038FF),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  child: Text(
                    !isTaxi ? 'طلب بوكس' : (isPlus ? 'طلب بَلَس' : 'طلب توفير'),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCollapsedRideSheet(RideState state, RideCubit cubit) => Material(
    color: state.dark ? const Color(0xFF182522) : Colors.white,
    elevation: 12,
    borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
    child: InkWell(
      onTap: () => setState(() => _sheetCollapsed = false),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 18, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              const SizedBox(height: 9),
              Row(
                children: [
                  if (state.rideStatus == RideBookingStatus.driverAssigned ||
                      state.rideStatus == RideBookingStatus.driverArrived ||
                      state.rideStatus == RideBookingStatus.inProgress) ...[
                    _CaptainAvatar(
                      photoUrl: state.driverPhotoUrl,
                      radius: 18,
                      dark: state.dark,
                    ),
                    const SizedBox(width: 10),
                  ] else ...[
                    const Icon(Icons.keyboard_arrow_up, color: green, size: 26),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          state.rideStatus == RideBookingStatus.inProgress
                              ? 'رحلتك جارية الآن'
                              : state.rideStatus ==
                                    RideBookingStatus.driverAssigned
                              ? 'الكابتن في الطريق إليك'
                              : state.origin != null &&
                                    state.destination != null
                              ? 'السعر الحالي: ${formatIraqiDinar(cubit.currentPrice)}'
                              : 'حدد نقطة الانطلاق والوصول',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                        Text(
                          state.rideStatus == RideBookingStatus.inProgress &&
                                  state.route != null
                              ? '${state.route!.kilometers.toStringAsFixed(1)} كم ${state.driverPosition != null ? "متبقية" : "للمسار"} • ${state.route!.minutes.round()} دقيقة تقريباً'
                              : state.rideStatus ==
                                    RideBookingStatus.driverAssigned
                              ? '${state.driverName} • ${state.driverCar}'
                              : state.origin != null &&
                                    state.destination != null
                              ? '${state.originName}  ←  ${state.destinationName}'
                              : 'اسحب للأعلى أو اضغط لعرض القائمة',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.black54,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.keyboard_arrow_up, color: green),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _buildRouteChoices(RideState state, RideCubit cubit) {
    final routes = state.routeOptions;
    if (routes.length < 2) return const SizedBox.shrink();
    final shortestIndex = routes.indexOf(
      routes.reduce((a, b) => a.kilometers <= b.kilometers ? a : b),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.alt_route_rounded, size: 17, color: green),
            const SizedBox(width: 6),
            Text(
              'اختر المسار',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: state.dark ? Colors.white : const Color(0xFF142421),
              ),
            ),
            const Spacer(),
            Text(
              'يمكن أن تتوفر بدائل حسب الطريق',
              style: TextStyle(
                fontSize: 10,
                color: state.dark ? Colors.white60 : Colors.black54,
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: List.generate(routes.length, (index) {
              final option = routes[index];
              final selected = state.selectedRouteIndex == index;
              return Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: InkWell(
                  onTap: () => cubit.selectRoute(index),
                  borderRadius: BorderRadius.circular(12),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 142,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: selected
                          ? (state.dark
                                ? const Color(0xFF243B57)
                                : const Color(0xFFEEF2FF))
                          : (state.dark
                                ? const Color(0xFF22322E)
                                : Colors.white),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected
                            ? const Color(0xFF557BFF)
                            : (state.dark
                                  ? const Color(0xFF3B4B47)
                                  : Colors.black12),
                        width: selected ? 1.5 : 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          index == shortestIndex
                              ? 'الأقصر'
                              : (index == 0
                                    ? 'الموصى به'
                                    : 'بديل ${index + 1}'),
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: state.dark ? Colors.white : ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${option.kilometers.toStringAsFixed(1)} كم • ${option.minutes.round()} د',
                          style: TextStyle(
                            fontSize: 11,
                            color: state.dark ? Colors.white70 : Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildLocationSelectionSheet(RideState state) => Container(
    padding: const EdgeInsets.fromLTRB(18, 14, 18, 20),
    decoration: BoxDecoration(
      color: state.dark ? const Color(0xFF182522) : Colors.white,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      boxShadow: [
        const BoxShadow(
          color: Colors.black12,
          blurRadius: 18,
          offset: Offset(0, -3),
        ),
      ],
    ),
    child: SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'أين تبدأ رحلتك؟',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w900,
              color: state.dark ? Colors.white : ink,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'اختر الانطلاق والوصول لتظهر الأسعار مباشرة. القسيمة وخيارات الرحلة اختيارية.',
            style: TextStyle(
              fontSize: 13,
              color: state.dark ? Colors.white70 : Colors.black54,
            ),
          ),
          const SizedBox(height: 12),
          _endpointRow(
            icon: Icons.trip_origin,
            color: const Color(0xFFE56A2B),
            title: state.origin == null
                ? 'تحديد نقطة الانطلاق'
                : state.originName,
            onSearch: () => _choosePlace('origin'),
            mapTooltip: 'اختر الانطلاق من الخريطة',
            onMap: () => setState(() {
              _pickingMode = 'origin';
              _mapCenterTemp = _map.camera.center;
            }),
          ),
          const SizedBox(height: 8),
          _endpointRow(
            icon: Icons.flag_outlined,
            color: const Color(0xFF0038FF),
            title: state.destination == null
                ? 'تحديد نقطة الوصول'
                : state.destinationName,
            onSearch: () => _choosePlace('destination'),
            mapTooltip: 'اختر الوصول من الخريطة',
            onMap: () => setState(() {
              _pickingMode = 'destination';
              _mapCenterTemp = _map.camera.center;
            }),
          ),
        ],
      ),
    ),
  );

  Widget _endpointRow({
    required IconData icon,
    required Color color,
    required String title,
    required String mapTooltip,
    required VoidCallback onSearch,
    required VoidCallback onMap,
  }) => Container(
    decoration: BoxDecoration(
      color: context.read<RideCubit>().state.dark
          ? const Color(0xFF22312E)
          : const Color(0xFFF7F8FA),
      borderRadius: BorderRadius.circular(15),
      border: Border.all(
        color: context.read<RideCubit>().state.dark
            ? const Color(0xFF30413D)
            : const Color(0xFFE8EAED),
      ),
    ),
    child: Row(
      children: [
        const SizedBox(width: 12),
        Icon(icon, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        IconButton(
          tooltip: 'البحث عن مكان',
          onPressed: onSearch,
          icon: const Icon(Icons.search),
        ),
        IconButton(
          tooltip: mapTooltip,
          onPressed: onMap,
          icon: const Icon(Icons.map_outlined),
        ),
      ],
    ),
  );

  /// Individual Ride Tier Tile matching Image 3 design
  Widget _buildRideTierTile({
    required String title,
    required String subtitle,
    required int price,
    required String badgeType,
    required bool dark,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? (dark ? const Color(0xFF243B57) : const Color(0xFFEEF2FF))
              : (dark ? const Color(0xFF182522) : Colors.white),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? const Color(0xFF194BFB) : Colors.grey.shade200,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            // Price on left in RTL
            Text(
              formatIraqiDinar(price),
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w900,
                color: dark ? Colors.white : const Color(0xFF142421),
              ),
            ),
            const Spacer(),

            // Title and Subtitle
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: dark ? Colors.white : const Color(0xFF142421),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 13,
                    color: dark ? Colors.white70 : Colors.grey.shade600,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 14),

            // Car Graphic with badge
            CarGraphic(badgeType: badgeType, size: 55),
          ],
        ),
      ),
    );
  }

  /// Searching Status Card
  Widget _buildSearchingSheet(RideState state) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: state.dark ? const Color(0xFF182522) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 20)],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 78,
                  height: 78,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF0038FF).withValues(alpha: 0.08),
                  ),
                ),
                const SizedBox.square(
                  dimension: 58,
                  child: CircularProgressIndicator(
                    strokeWidth: 4,
                    valueColor: AlwaysStoppedAnimation(Color(0xFF0038FF)),
                  ),
                ),
                const Icon(
                  Icons.local_taxi_rounded,
                  color: Color(0xFF0038FF),
                  size: 24,
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'جارٍ البحث عن أقرب كابتن...',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            Text(
              'نبحث عن أفضل سيارة متوفرة بالقرب من ${state.originName}',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13.5,
                color: state.dark ? Colors.white70 : Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: state.dark
                    ? const Color(0xFF22322E)
                    : const Color(0xFFF3F6F9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.route_outlined, size: 17, color: green),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${state.originName}  ←  ${state.destinationName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    formatIraqiDinar(context.read<RideCubit>().currentPrice),
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF0038FF),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: _cancelRide,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('إلغاء الطلب'),
            ),
          ],
        ),
      ),
    );
  }

  /// Active Trip / Driver Assigned Card
  Widget _buildActiveRideSheet(RideState state) {
    final isEnRoute = state.rideStatus == RideBookingStatus.inProgress;
    final isArrived = state.rideStatus == RideBookingStatus.driverArrived;
    final route = state.route;
    final panelColor = state.dark ? const Color(0xFF182522) : Colors.white;
    final mutedText = state.dark ? Colors.white70 : Colors.black54;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
      decoration: BoxDecoration(
        color: panelColor,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 20)],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Status tag
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: state.dark
                        ? const Color(0xFF26382C)
                        : (isEnRoute
                              ? const Color(0xFFE8F5E9)
                              : const Color(0xFFE8F0FE)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    isEnRoute
                        ? 'الرحلة جارية الآن'
                        : (isArrived
                              ? 'وصل الكابتن إلى نقطة الانطلاق!'
                              : 'تم قبول الطلب — الكابتن في الطريق إليك'),
                    style: TextStyle(
                      color: state.dark
                          ? const Color(0xFF9AD8A2)
                          : (isEnRoute
                                ? const Color(0xFF2E7D32)
                                : const Color(0xFF194BFB)),
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  formatIraqiDinar(context.read<RideCubit>().currentPrice),
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                    color: state.dark ? Colors.white : ink,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: isEnRoute ? 1.0 : (isArrived ? 0.66 : 0.33),
                minHeight: 5,
                backgroundColor: state.dark
                    ? const Color(0xFF263531)
                    : const Color(0xFFE7ECF6),
                color: isEnRoute ? green : const Color(0xFF194BFB),
              ),
            ),
            const SizedBox(height: 12),

            if (route != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 11,
                  horizontal: 8,
                ),
                decoration: BoxDecoration(
                  color: state.dark
                      ? const Color(0xFF22322E)
                      : const Color(0xFFF4F6FF),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _rideMetric(
                        Icons.route_outlined,
                        '${route.kilometers.toStringAsFixed(1)} كم',
                        isEnRoute && state.driverPosition != null
                            ? 'المسافة المتبقية'
                            : 'المسافة الكلية',
                      ),
                    ),
                    Container(
                      width: 1,
                      height: 34,
                      color: state.dark ? Colors.white24 : Colors.black12,
                    ),
                    Expanded(
                      child: _rideMetric(
                        Icons.schedule_outlined,
                        '${route.minutes.round()} دقيقة',
                        isEnRoute && state.driverPosition != null
                            ? 'الوقت المتبقي للوصول'
                            : 'مدة الطريق المقدرة',
                      ),
                    ),
                  ],
                ),
              ),
            if (route != null) const SizedBox(height: 14),

            // Driver Card
            Row(
              children: [
                Container(
                  width: 62,
                  height: 62,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: state.dark
                        ? const Color(0xFF273B38)
                        : const Color(0xFFEAF0FF),
                    border: Border.all(color: const Color(0xFFDAE3FF)),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: state.driverPhotoUrl.isEmpty
                      ? const Icon(
                          Icons.person_rounded,
                          size: 38,
                          color: Color(0xFF194BFB),
                        )
                      : Image.network(
                          state.driverPhotoUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.person_rounded,
                            size: 38,
                            color: Color(0xFF194BFB),
                          ),
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        state.driverName,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: state.dark ? Colors.white : ink,
                        ),
                      ),
                      Text(
                        state.driverCar,
                        style: TextStyle(fontSize: 13, color: mutedText),
                      ),
                      Text(
                        state.driverPlate.isEmpty
                            ? 'رقم السيارة: غير متوفر من الخادم'
                            : 'رقم السيارة: ${state.driverPlate}',
                        style: TextStyle(fontSize: 12, color: mutedText),
                      ),
                      Text(
                        state.driverPhone.isEmpty
                            ? 'رقم الهاتف غير متوفر من الخادم'
                            : 'الهاتف: ${state.driverPhone}',
                        style: TextStyle(fontSize: 12, color: mutedText),
                      ),
                      Row(
                        children: [
                          const Icon(
                            Icons.star,
                            size: 16,
                            color: Color(0xFFFFB800),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${state.driverRating}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton.filledTonal(
                      tooltip: 'اتصال بالكابتن',
                      onPressed: () => _launchDriverContact('tel'),
                      icon: const Icon(Icons.call_outlined),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'إرسال رسالة SMS',
                      onPressed: () => _launchDriverContact('sms'),
                      icon: const Icon(Icons.sms_outlined),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'مشاركة تفاصيل الرحلة للأمان',
                      onPressed: () => _shareActiveRideDetails(state),
                      icon: const Icon(Icons.share_outlined),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'الطوارئ (SOS)',
                      onPressed: () => context.push('/safety'),
                      icon: const Icon(
                        Icons.emergency_outlined,
                        color: Colors.redAccent,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 18),

            FilledButton.icon(
              onPressed: isEnRoute ? _completeRideAndRate : _cancelRide,
              style: FilledButton.styleFrom(
                backgroundColor: isEnRoute
                    ? const Color(0xFF194BFB)
                    : Colors.blueGrey,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: Icon(
                isEnRoute ? Icons.star_rate_rounded : Icons.close_rounded,
              ),
              label: Text(
                isEnRoute ? 'إنهاء الرحلة وتقييم السائق' : 'إلغاء الطلب',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rideMetric(IconData icon, String value, String label) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(icon, size: 19, color: const Color(0xFF194BFB)),
      const SizedBox(width: 7),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
          ),
          Text(
            label,
            style: const TextStyle(fontSize: 10, color: Colors.black54),
          ),
        ],
      ),
    ],
  );
}

class _PlaceSearchDialog extends StatefulWidget {
  const _PlaceSearchDialog({
    required this.repository,
    this.savedPlaces = const [],
    this.recentPlaces = const [],
  });
  final MapRepository repository;
  final List<Place> savedPlaces;
  final List<Place> recentPlaces;
  @override
  State<_PlaceSearchDialog> createState() => _PlaceSearchDialogState();
}

class _PlaceSearchDialogState extends State<_PlaceSearchDialog> {
  final _controller = TextEditingController();
  List<Place> _results = [];
  bool _loading = false;
  String? _error;

  Future<void> _search() async {
    if (_controller.text.trim().length < 3) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await widget.repository.search(_controller.text.trim());
      if (mounted) setState(() => _results = results);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'تعذر البحث. تحقق من اتصال الإنترنت.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('ابحث عن مكان'),
    content: SizedBox(
      width: 420,
      height: 380,
      child: Column(
        children: [
          TextField(
            controller: _controller,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: 'المنطقة أو اسم المكان',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                onPressed: _search,
                icon: const Icon(Icons.arrow_forward),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
          if (_results.isEmpty &&
              (_controller.text.isEmpty) &&
              (widget.savedPlaces.isNotEmpty || widget.recentPlaces.isNotEmpty))
            Expanded(
              child: ListView(
                children: [
                  if (widget.savedPlaces.isNotEmpty)
                    const ListTile(
                      title: Text(
                        'الأماكن المحفوظة',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      dense: true,
                    ),
                  ...widget.savedPlaces.map(
                    (place) =>
                        _placeTile(place, Icons.bookmark, green, context),
                  ),
                  if (widget.recentPlaces.isNotEmpty)
                    const ListTile(
                      title: Text(
                        'أماكن حديثة',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      dense: true,
                    ),
                  ...widget.recentPlaces.map(
                    (place) => _placeTile(
                      place,
                      Icons.history,
                      Colors.blueGrey,
                      context,
                    ),
                  ),
                ],
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                itemCount: _results.length,
                itemBuilder: (context, index) {
                  final place = _results[index];
                  return ListTile(
                    leading: const Icon(Icons.place_outlined, color: green),
                    title: Text(
                      place.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      place.detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.pop(context, place),
                  );
                },
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('إغلاق'),
      ),
    ],
  );

  Widget _placeTile(
    Place place,
    IconData icon,
    Color color,
    BuildContext context,
  ) => ListTile(
    leading: Icon(icon, color: color),
    title: Text(place.name, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(place.detail, maxLines: 1, overflow: TextOverflow.ellipsis),
    onTap: () => Navigator.pop(context, place),
  );
}

class RidePage extends StatefulWidget {
  const RidePage({super.key});
  @override
  State<RidePage> createState() => _RidePageState();
}

class _RidePageState extends State<RidePage> {
  String _vehicle = 'اقتصادية';
  bool _busy = false;
  final _couponController = TextEditingController();
  final _basePrices = {'اقتصادية': 2500, 'مريحة': 4000, 'عائلية': 6000};

  @override
  void dispose() {
    _couponController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _calculate());
  }

  Future<void> _calculate() async {
    setState(() => _busy = true);
    try {
      await context.read<RideCubit>().calculateRoute();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر حساب المسار. تحقق من الإنترنت.')),
        );
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  String _price(int value) =>
      '${_arabicDigits(value.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ','))} د.ع';

  String _arabicDigits(String value) {
    const western = '0123456789';
    const eastern = '٠١٢٣٤٥٦٧٨٩';
    return value.split('').map((character) {
      final index = western.indexOf(character);
      return index < 0 ? character : eastern[index];
    }).join();
  }

  Future<void> _addStop() async {
    final cubit = context.read<RideCubit>();
    if (cubit.state.stops.length >= 5) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يمكن إضافة خمس نقاط توقف كحد أقصى.')),
      );
      return;
    }
    final place = await showDialog<Place>(
      context: context,
      builder: (context) => _PlaceSearchDialog(repository: cubit.repository),
    );
    if (!mounted || place == null) return;
    cubit.setStops([...cubit.state.stops, place]);
    await _calculate();
  }

  void _removeStop(Place place) {
    final cubit = context.read<RideCubit>();
    cubit.setStops(cubit.state.stops.where((stop) => stop != place).toList());
    _calculate();
  }

  void _moveStop(int index, int direction) {
    final stops = [...context.read<RideCubit>().state.stops];
    final next = index + direction;
    if (next < 0 || next >= stops.length) return;
    final place = stops.removeAt(index);
    stops.insert(next, place);
    context.read<RideCubit>().setStops(stops);
    _calculate();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<RideCubit>().state;
    final distance = state.route?.kilometers;
    final estimated = distance == null
        ? null
        : ((_basePrices[_vehicle]! + distance * 550) / 500).round() * 500;
    return Scaffold(
      appBar: AppBar(title: const Text('تفاصيل الرحلة')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: SizedBox(
              height: 180,
              child: state.origin != null && state.destination != null
                  ? FlutterMap(
                      options: MapOptions(
                        initialCenter: LatLng(
                          (state.origin!.latitude +
                                  state.destination!.latitude) /
                              2,
                          (state.origin!.longitude +
                                  state.destination!.longitude) /
                              2,
                        ),
                        initialZoom: 11,
                      ),
                      children: [
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'iq.ridepassenger.car',
                          tileProvider: DarbOfflineTileProvider(),
                          tileBuilder: state.dark ? darkModeTileBuilder : null,
                        ),
                        if (state.route != null)
                          PolylineLayer(
                            polylines: [
                              Polyline(
                                points: state.route!.points,
                                color: state.dark
                                    ? const Color(0xFF8EAAFF)
                                    : green,
                                strokeWidth: 5,
                              ),
                            ],
                          ),
                        MarkerLayer(
                          markers: [
                            Marker(
                              point: state.origin!,
                              width: 28,
                              height: 28,
                              child: const _Pin(icon: Icons.circle),
                            ),
                            Marker(
                              point: state.destination!,
                              width: 28,
                              height: 28,
                              child: const _Pin(
                                icon: Icons.flag,
                                color: Color(0xFFE18345),
                              ),
                            ),
                            ...state.stops.map(
                              (stop) => Marker(
                                point: stop.point,
                                width: 25,
                                height: 25,
                                child: const _Pin(
                                  icon: Icons.more_horiz,
                                  color: Color(0xFF536B64),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    )
                  : const ColoredBox(
                      color: Color(0xFFE7EBE5),
                      child: Center(child: Text('حدد الانطلاق والوجهة')),
                    ),
            ),
          ),
          const SizedBox(height: 14),
          _PlaceRow(
            icon: Icons.radio_button_checked,
            tint: green,
            title: state.originName,
            subtitle: 'الانطلاق',
            onTap: () {},
          ),
          const Divider(),
          _PlaceRow(
            icon: Icons.location_on,
            tint: const Color(0xFFE18345),
            title: state.destinationName.isEmpty
                ? 'لم تحدد الوجهة'
                : state.destinationName,
            subtitle: 'الوجهة',
            onTap: () {},
          ),
          ...state.stops.asMap().entries.map(
            (entry) => Card(
              child: ListTile(
                leading: const Icon(Icons.add_road, color: green),
                title: Text(entry.value.name),
                subtitle: Text('الوجهة الإضافية ${entry.key + 1}'),
                trailing: Wrap(
                  spacing: 0,
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _moveStop(entry.key, -1),
                      icon: const Icon(Icons.keyboard_arrow_up),
                      tooltip: 'تقديم التوقف',
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _moveStop(entry.key, 1),
                      icon: const Icon(Icons.keyboard_arrow_down),
                      tooltip: 'تأخير التوقف',
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _removeStop(entry.value),
                      icon: const Icon(Icons.close),
                      tooltip: 'حذف التوقف',
                    ),
                  ],
                ),
              ),
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _addStop,
              icon: const Icon(Icons.add_location_alt_outlined),
              label: const Text('إضافة وجهة أو نقطة توقف'),
            ),
          ),
          Card(
            child: SwitchListTile.adaptive(
              value: state.roundTrip,
              secondary: const Icon(Icons.swap_horiz, color: green),
              title: const Text('رحلة ذهاب وإياب'),
              subtitle: const Text('العودة إلى نقطة الانطلاق بعد الوصول'),
              onChanged: (value) {
                context.read<RideCubit>().setRoundTrip(value);
                _calculate();
              },
            ),
          ),
          const SizedBox(height: 12),
          if (_busy || state.route == null) const LinearProgressIndicator(),
          if (state.route != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.route, color: green),
                title: Text(
                  '${_arabicDigits(state.route!.kilometers.toStringAsFixed(1))} كم • ${_arabicDigits(state.route!.minutes.round().toString())} دقيقة',
                ),
                trailing: IconButton(
                  onPressed: _calculate,
                  icon: const Icon(Icons.refresh),
                ),
              ),
            ),
          const Text(
            'اختر نوع السيارة',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          ..._basePrices.entries.map(
            (entry) => Card(
              color: _vehicle == entry.key ? const Color(0xFFE5EFE8) : null,
              child: ListTile(
                onTap: () => setState(() => _vehicle = entry.key),
                leading: const Icon(Icons.local_taxi_outlined, color: green),
                title: Text(entry.key),
                subtitle: Text('سعر بداية تجريبي: ${_price(entry.value)}'),
                trailing: Icon(
                  _vehicle == entry.key
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: _vehicle == entry.key ? green : Colors.grey,
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: const Color(0xFFE9F1E9),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                const Icon(Icons.payments_outlined, color: green),
                const SizedBox(width: 8),
                const Expanded(child: Text('الدفع نقداً بالدينار العراقي')),
                Text(
                  estimated == null ? 'بانتظار المسار' : _price(estimated),
                  style: const TextStyle(
                    color: green,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _couponController,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: 'رمز الخصم',
              hintText: 'أدخل الرمز',
              prefixIcon: const Icon(Icons.sell_outlined),
              suffixIcon: TextButton(
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'لا يمكن التحقق من الخصم قبل ربط خادم التسعير.',
                    ),
                  ),
                ),
                child: const Text('تحقق'),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'سيُطبّق الخصم بعد التحقق منه من الخادم فقط.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: estimated == null || _busy ? null : _confirm,
            style: FilledButton.styleFrom(
              backgroundColor: green,
              minimumSize: const Size.fromHeight(52),
            ),
            child: const Text('تأكيد طلب الرحلة'),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'السعر المعروض تقدير تجريبي محلي. لا ينشئ التطبيق رحلة حتى يتصل بخادم التسعير والطلبات.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirm() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final configured = prefs.getString('api_base_url') != null;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(configured ? 'تعذر إرسال الطلب' : 'الخادم غير متصل'),
        content: Text(
          configured ? 'تعذر الاتصال بالخادم. تحقق من الخدمة والإنترنت.' : 'لم يتم إنشاء رحلة أو سائق تجريبي. اربط التطبيق بخادم الطلبات لإرسال طلب حقيقي.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('حسناً'),
          ),
        ],
      ),
    );
  }
}

class FavoritePlacesPage extends StatefulWidget {
  const FavoritePlacesPage({super.key});
  @override
  State<FavoritePlacesPage> createState() => _FavoritePlacesPageState();
}

class _FavoritePlacesPageState extends State<FavoritePlacesPage> {
  List<Place> _places = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(savedPlacesStorageKey);
    if (!mounted) return;
    setState(() {
      _places = raw == null
          ? []
          : (jsonDecode(raw) as List<dynamic>)
                .whereType<Map>()
                .map((item) => Place.fromJson(Map<String, dynamic>.from(item)))
                .toList();
      _loading = false;
    });
  }

  Future<void> _remove(Place place) async {
    final preferences = await SharedPreferences.getInstance();
    _places.removeWhere((item) => item.point == place.point);
    await preferences.setString(
      savedPlacesStorageKey,
      jsonEncode(_places.map((item) => item.toJson()).toList()),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('الأماكن المفضلة')),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _places.isEmpty
        ? const Center(
            child: Padding(
              padding: EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bookmark_border, size: 60, color: Colors.grey),
                  SizedBox(height: 12),
                  Text(
                    'لا توجد أماكن مفضلة',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'اضغط مطولاً على مكان في الخريطة واحفظه للمفضلة.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          )
        : ListView.separated(
            padding: const EdgeInsets.all(14),
            itemCount: _places.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final place = _places[index];
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.location_on, color: green),
                  title: Text(place.name),
                  subtitle: Text(place.detail),
                  trailing: IconButton(
                    tooltip: 'حذف من المفضلة',
                    onPressed: () => _remove(place),
                    icon: const Icon(Icons.delete_outline),
                  ),
                  onTap: () {
                    showModalBottomSheet<void>(
                      context: context,
                      showDragHandle: true,
                      builder: (sheetContext) => SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ListTile(
                                leading: const Icon(
                                  Icons.near_me_outlined,
                                  color: Color(0xFF194BFB),
                                ),
                                title: const Text('الذهاب إلى الموقع'),
                                onTap: () {
                                  Navigator.pop(sheetContext);
                                  focusedMapPin.value = FocusedMapPin(
                                    place.point,
                                    label: place.name,
                                  );
                                  context.read<RideCubit>().focusOnPoint(
                                    place.point,
                                  );
                                  context.go('/');
                                },
                              ),
                              ListTile(
                                leading: const Icon(
                                  Icons.trip_origin,
                                  color: green,
                                ),
                                title: const Text('تحديد كنقطة انطلاق'),
                                onTap: () {
                                  Navigator.pop(sheetContext);
                                  context.read<RideCubit>().setOrigin(place);
                                  context.go('/');
                                },
                              ),
                              ListTile(
                                leading: const Icon(
                                  Icons.flag_outlined,
                                  color: Color(0xFF0038FF),
                                ),
                                title: const Text('تحديد كنقطة وصول'),
                                onTap: () {
                                  Navigator.pop(sheetContext);
                                  context.read<RideCubit>().setDestination(
                                    place,
                                  );
                                  context.go('/');
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
  );
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  String? _passengerName;
  @override
  void initState() {
    super.initState();
    _loadName();
  }

  Future<void> _loadName() async {
    final preferences = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _passengerName = preferences.getString('passenger_name'));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('حسابي')),
    body: SafeArea(
      top: false,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          28 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: green,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            children: [
              CircleAvatar(
                radius: 32,
                backgroundColor: Colors.white,
                child: Icon(Icons.person, color: green, size: 36),
              ),
              SizedBox(height: 12),
              Text(
                _passengerName == null
                    ? 'مرحباً بك في درب'
                    : 'مرحباً ${_passengerName!}',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                'سجّل الدخول لبدء رحلتك',
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _MenuTile(
          icon: Icons.phone_android,
          title: 'تسجيل الدخول برقم الهاتف',
          onTap: () async {
            await context.push('/login');
            await _loadName();
          },
        ),
        _MenuTile(
          icon: Icons.notifications_none,
          title: 'مركز الإشعارات',
          onTap: () => context.push('/notifications'),
        ),
        _MenuTile(
          icon: Icons.history,
          title: 'سجل الرحلات',
          onTap: () => context.push('/history'),
        ),
        _MenuTile(
          icon: Icons.star_outline,
          title: 'الأماكن المفضلة',
          onTap: () => context.push('/favorites'),
        ),
        _MenuTile(
          icon: Icons.shield_outlined,
          title: 'الأمان والطوارئ (SOS)',
          onTap: () => context.push('/safety'),
        ),
        _MenuTile(
          icon: Icons.support_agent,
          title: 'المساعدة والشكاوى',
          onTap: () => context.push('/support'),
        ),
        _MenuTile(
          icon: Icons.settings_outlined,
          title: 'الإعدادات',
          onTap: () => context.push('/settings'),
        ),
        ValueListenableBuilder<UserRole>(
          valueListenable: currentUserRole,
          builder: (context, role, _) => Column(
            children: [
              if (role == UserRole.captain)
                _MenuTile(
                  icon: Icons.badge_outlined,
                  title: 'بيانات الكابتن والمستمسكات',
                  onTap: () => context.push('/captain/onboarding'),
                ),
              _MenuTile(
                icon: Icons.swap_horiz_rounded,
                title: role == UserRole.captain
                    ? 'التبديل إلى واجهة الزبون (للمطور)'
                    : 'التبديل إلى واجهة الكابتن (للمطور)',
                onTap: () async {
                  final next = role == UserRole.captain
                      ? UserRole.passenger
                      : UserRole.captain;
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString(
                    'darb_user_role',
                    userRoleToString(next),
                  );
                  currentUserRole.value = next;
                  if (context.mounted) context.go('/');
                },
              ),
            ],
          ),
        ),
        _MenuTile(
          icon: Icons.logout,
          title: 'تسجيل الخروج',
          onTap: () async {
            await RideBackendService.instance.clearSession();
            passengerLoggedIn.value = false;
          },
        ),
        ],
      ),
    ),
  );
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<Map<String, dynamic>> _rides = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rides = await RideBackendService.instance.loadPassengerHistory();
    if (mounted) {
      setState(() {
        _rides = rides;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('سجل الرحلات')),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _rides.isEmpty
        ? const Center(
            child: Padding(
              padding: EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.receipt_long_outlined,
                    size: 60,
                    color: Colors.grey,
                  ),
                  SizedBox(height: 12),
                  Text(
                    'لا توجد رحلات مكتملة بعد',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'تُحفظ الرحلات المكتملة على هذا الجهاز.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          )
        : RefreshIndicator(
            onRefresh: _load,
            child: ListView.separated(
              padding: const EdgeInsets.all(14),
              itemCount: _rides.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final ride = _rides[index];
                final date = DateTime.tryParse(ride['date']?.toString() ?? '');
                final dateLabel = date == null
                    ? ''
                    : '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}  ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
                final fareVal = (ride['fare_iqd'] ?? ride['price'] as num?)?.toInt();
                final kmVal = ride['distance_km'] ?? ride['kilometers'];
                final captainLabel = ride['captain_name'] ?? ride['driver'] ?? 'الكابتن';
                return Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.trip_origin, size: 16, color: Color(0xFFE56A2B)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${ride['origin'] ?? 'الانطلاق'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w800),
                              ),
                            ),
                            if (fareVal != null)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: green.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  formatIraqiDinar(fareVal),
                                  style: const TextStyle(
                                    color: green,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 12.5,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(Icons.flag_rounded, size: 16, color: Color(0xFF0038FF)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${ride['destination'] ?? 'الوصول'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            _CaptainAvatar(
                              photoUrl:
                                  ride['captain_photo_url']?.toString() ?? '',
                              radius: 16,
                              dark: Theme.of(context).brightness == Brightness.dark,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '$captainLabel${ride['car'] != null ? ' • ${ride['car']}' : ''}',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            if (ride['captain_rating'] != null) ...[
                              const Icon(Icons.star, size: 14, color: Color(0xFFFFB800)),
                              const SizedBox(width: 2),
                              Text(
                                '${ride['captain_rating']}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (dateLabel.isNotEmpty || kmVal != null)
                          Text(
                            '$dateLabel${kmVal == null ? '' : ' • $kmVal كم'}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: OutlinedButton.icon(
                            onPressed: () => context.push(
                              '/support',
                              extra: {
                                'category': 'شكوى على السائق',
                                'details':
                                    'شكوى بخصوص الرحلة ${ride['ride_id'] ?? ride['id']} بتاريخ $dateLabel.\n\n',
                              },
                            ),
                            icon: const Icon(
                              Icons.report_gmailerrorred_outlined,
                            ),
                            label: const Text('تقديم شكوى عن الرحلة'),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
  );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _notificationsEnabled = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _notificationsEnabled =
          prefs.getBool('darb_notifications_enabled') ?? false;
      _loading = false;
    });
  }

  Future<void> _toggleNotifications(bool enabled) async {
    final accepted = await NotificationCenterService.setEnabled(enabled);
    if (!mounted) return;
    if (!accepted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لم يتم منح إذن الإشعارات من النظام.')),
      );
      return;
    }
    setState(() => _notificationsEnabled = enabled);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('الإعدادات')),
    body: SafeArea(
      top: false,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          14,
          14,
          14,
          28 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
        SwitchListTile(
          value: context.watch<RideCubit>().state.dark,
          onChanged: (value) => context.read<RideCubit>().toggleTheme(),
          secondary: const Icon(Icons.dark_mode_outlined),
          title: const Text('الوضع الليلي'),
        ),
        ValueListenableBuilder<Locale>(
          valueListenable: appLocale,
          builder: (context, locale, _) => Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'لغة التطبيق واتجاه الواجهة',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'ar', label: Text('العربية (RTL)')),
                      ButtonSegment(value: 'en', label: Text('English (LTR)')),
                    ],
                    selected: {locale.languageCode},
                    onSelectionChanged: (s) async {
                      final code = s.first;
                      appLocale.value = Locale(code);
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setString('darb_locale', code);
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'لون سيارة الكابتن على الخريطة',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 14,
                  children: [
                    for (final color in const [
                      0xFF194BFB,
                      0xFF16A085,
                      0xFFE05B4B,
                      0xFFF39C12,
                      0xFF34495E,
                    ])
                      InkWell(
                        onTap: () => context
                            .read<RideCubit>()
                            .setDriverMarkerColor(color),
                        customBorder: const CircleBorder(),
                        child: CircleAvatar(
                          radius: 17,
                          backgroundColor: Color(color),
                          child:
                              context
                                      .watch<RideCubit>()
                                      .state
                                      .driverMarkerColor ==
                                  color
                              ? const Icon(
                                  Icons.check,
                                  size: 18,
                                  color: Colors.white,
                                )
                              : null,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        SwitchListTile(
          value: _notificationsEnabled,
          onChanged: _loading ? null : _toggleNotifications,
          secondary: const Icon(Icons.notifications_active_outlined),
          title: const Text('إشعارات الجهاز'),
          subtitle: const Text(
            'حالة الرحلة ورسائل خدمة الزبائن عند ورودها',
          ),
        ),
        const ListTile(
          leading: Icon(Icons.privacy_tip_outlined),
          title: Text('الخصوصية'),
          subtitle: Text(
            'جلسة الدخول آمنة؛ والوجهات المفضلة محفوظة محلياً على جهازك.',
          ),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.download_for_offline_outlined, color: green),
          title: const Text('خرائط دون اتصال'),
          subtitle: const Text('تنزيل خريطة العراق أو المحافظات للعمل بلا إنترنت'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/offline-maps'),
        ),
        if (currentUserRole.value == UserRole.captain) ...[
          const Divider(),
          ListTile(
            leading: const Icon(Icons.directions_car_outlined, color: green),
            title: const Text('إدارة بيانات السيارة والمستمسكات'),
            subtitle: const Text('إكمال معلومات المركبة والصورة الشخصية والوثائق'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/captain/onboarding'),
          ),
        ],
        ],
      ),
    ),
  );
}

class NotificationCenterPage extends StatefulWidget {
  const NotificationCenterPage({super.key});
  @override
  State<NotificationCenterPage> createState() => _NotificationCenterPageState();
}

class _NotificationCenterPageState extends State<NotificationCenterPage> {
  late Future<List<CenterNotification>> _items;
  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => _items = NotificationCenterService.all();
  Future<void> _markAllRead() async {
    await NotificationCenterService.markAllRead();
    if (mounted) setState(_reload);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('مركز الإشعارات'),
      actions: [
        IconButton(
          tooltip: 'تمييز الكل كمقروء',
          onPressed: _markAllRead,
          icon: const Icon(Icons.done_all),
        ),
      ],
    ),
    body: FutureBuilder<List<CenterNotification>>(
      future: _items,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final entries = snapshot.data ?? const <CenterNotification>[];
        if (entries.isEmpty) {
          return const _EmptyState(
            icon: Icons.notifications_none,
            title: 'لا توجد إشعارات',
            message: 'ستظهر هنا تحديثات الرحلة ورسائل خدمة الزبائن عند ربط الحساب بالخادم.',
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            setState(_reload);
            await _items;
          },
          child: ListView.separated(
            padding: const EdgeInsets.all(14),
            itemCount: entries.length,
            separatorBuilder: (context, index) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final item = entries[index];
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: item.read
                        ? canvas
                        : const Color(0xFFE5F1EA),
                    child: Icon(
                      item.kind == 'support'
                          ? Icons.support_agent
                          : Icons.local_taxi_outlined,
                      color: green,
                    ),
                  ),
                  title: Text(
                    item.title,
                    style: TextStyle(
                      fontWeight: item.read
                          ? FontWeight.normal
                          : FontWeight.bold,
                    ),
                  ),
                  subtitle: Text('${item.body}\n${item.createdAt.toLocal()}'),
                  isThreeLine: true,
                ),
              );
            },
          ),
        );
      },
    ),
  );
}

class PassengerLoginPage extends StatefulWidget {
  const PassengerLoginPage({super.key});
  @override
  State<PassengerLoginPage> createState() => _PassengerLoginPageState();
}

class _PassengerLoginPageState extends State<PassengerLoginPage> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _backend = RideBackendService.instance;
  UserRole _selectedRole = UserRole.passenger;
  bool _isSignup = true;
  bool _codeRequested = false;
  bool _busy = false;
  String? _error;

  Future<void> _developerAccess(UserRole role) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'passenger_name',
      role == UserRole.captain ? 'كابتن مطور درب' : 'مطور درب',
    );
    await prefs.setString('passenger_phone', '+9647700000000');
    await prefs.setString('darb_user_role', userRoleToString(role));
    await prefs.setBool('passenger_logged_in', true);
    currentUserRole.value = role;
    passengerLoggedIn.value = true;
    if (mounted && context.canPop()) context.pop();
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  String get _internationalPhone => '+964${_phone.text.trim()}';

  Future<void> _requestCode() async {
    if (_isSignup) {
      final nameParts = _name.text.trim().split(RegExp(r'\s+'));
      if (nameParts.length < 3) {
        setState(() => _error = 'اكتب الاسم الثلاثي كاملاً.');
        return;
      }
    }
    if (!RegExp(r'^7[0-9]{9}$').hasMatch(_phone.text.trim())) {
      setState(
        () => _error = 'أدخل رقم الهاتف العراقي بعد +964، مثال: 7XXXXXXXXX.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _backend.requestOtp(
        name: _isSignup
            ? _name.text.trim()
            : (_selectedRole == UserRole.captain ? 'كابتن درب' : 'راكب درب'),
        phone: _internationalPhone,
        role: _selectedRole,
      );
      if (mounted) setState(() => _codeRequested = true);
    } catch (error) {
      if (mounted) setState(() => _error = _apiError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    if (!RegExp(r'^[0-9]{4,8}$').hasMatch(_code.text.trim())) {
      setState(() => _error = 'أدخل رمز التحقق الذي وصلك عبر SMS.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _backend.verifyOtp(
        phone: _internationalPhone,
        code: _code.text.trim(),
        role: _selectedRole,
      );
      final prefs = await SharedPreferences.getInstance();
      if (_name.text.trim().isNotEmpty) {
        await prefs.setString('passenger_name', _name.text.trim());
      }
      await prefs.setString('passenger_phone', _internationalPhone);
      await prefs.setString('darb_user_role', userRoleToString(_selectedRole));
      await prefs.setBool('passenger_logged_in', true);
      currentUserRole.value = _selectedRole;
      passengerLoggedIn.value = true;
      if (_selectedRole == UserRole.captain) {
        final captainProfile = await _backend.loadCaptainProfile();
        if (!captainProfile.hasRequiredInfo || !captainProfile.hasProfilePhoto) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            router.push('/captain/onboarding');
          });
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم التحقق من الحساب بنجاح.')),
        );
        if (context.canPop()) context.pop();
      }
    } catch (error) {
      if (mounted) setState(() => _error = _apiError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _apiError(Object error) {
    if (error is StateError || error is FormatException) {
      return error.toString().replaceFirst('Bad state: ', '');
    }
    if (error is DioException && error.response == null) {
      return 'تعذر الاتصال بالخادم. تحقق من الإنترنت وعنوان الخادم.';
    }
    return 'لم تكتمل العملية. تحقق من البيانات وحاول مجدداً.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final primaryText = dark ? Colors.white : ink;
    final secondaryText = dark ? Colors.white70 : const Color(0xFF5A6562);
    final cardBg = dark ? const Color(0xFF182522) : Colors.white;

    final accent = _selectedRole == UserRole.captain
        ? const Color(0xFF0038FF)
        : green;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark
                ? [const Color(0xFF0D1715), const Color(0xFF121E1B)]
                : [const Color(0xFFF3F8F6), Colors.white],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          child: Container(
                            key: ValueKey(_selectedRole),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _selectedRole == UserRole.captain
                                      ? Icons.local_taxi_rounded
                                      : Icons.verified_user_outlined,
                                  size: 16,
                                  color: accent,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  _selectedRole == UserRole.captain
                                      ? 'بوابة الكابتن'
                                      : 'بوابة الزبون',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: accent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        IconButton.filledTonal(
                          tooltip: dark ? 'الوضع النهاري' : 'الوضع الليلي',
                          onPressed: () =>
                              context.read<RideCubit>().toggleTheme(),
                          icon: Icon(
                            dark
                                ? Icons.light_mode_outlined
                                : Icons.dark_mode_outlined,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 22,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: _selectedRole == UserRole.captain
                                ? const [Color(0xFF0038FF), Color(0xFF1E6BFF)]
                                : const [green, Color(0xFF0A9D7D)],
                            begin: Alignment.topRight,
                            end: Alignment.bottomLeft,
                          ),
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [
                            BoxShadow(
                              color: accent.withValues(alpha: 0.28),
                              blurRadius: 18,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: const Column(
                          children: [
                            Icon(
                              Icons.directions_car_filled_rounded,
                              color: Colors.white,
                              size: 40,
                            ),
                            SizedBox(height: 4),
                            Text(
                              'درب',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 26,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      _codeRequested
                          ? 'تحقق من رقمك'
                          : (_isSignup ? 'إنشاء حساب جديد' : 'تسجيل الدخول'),
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        color: primaryText,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _codeRequested
                          ? 'أدخل رمز SMS الذي أرسله الخادم إلى $_internationalPhone'
                          : 'أهلاً بك في درب — تنقّل بسهولة وأمان داخل العراق',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: secondaryText),
                    ),
                    const SizedBox(height: 18),

              // Unified Account Type Selector: الدخول كزبون | الدخول ككابتن
              if (!_codeRequested) ...[
                Row(
                  children: [
                    Expanded(
                      child: _RoleOptionCard(
                        title: 'الدخول كزبون',
                        subtitle: 'طلب سيارة وتوصيل',
                        icon: Icons.person_pin_circle_outlined,
                        selected: _selectedRole == UserRole.passenger,
                        dark: dark,
                        onTap: () => setState(() {
                          _selectedRole = UserRole.passenger;
                          _error = null;
                        }),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _RoleOptionCard(
                        title: 'الدخول ككابتن',
                        subtitle: 'استقبال الطلبات والأرباح',
                        icon: Icons.local_taxi_outlined,
                        selected: _selectedRole == UserRole.captain,
                        dark: dark,
                        onTap: () => setState(() {
                          _selectedRole = UserRole.captain;
                          _error = null;
                        }),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
              ],

              // Mode Switcher: تسجيل الدخول | إنشاء حساب
              if (!_codeRequested)
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: dark
                        ? const Color(0xFF22312E)
                        : const Color(0xFFE9EEEC),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setState(() {
                            _isSignup = false;
                            _error = null;
                          }),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            decoration: BoxDecoration(
                              color: !_isSignup ? cardBg : Colors.transparent,
                              borderRadius: BorderRadius.circular(11),
                              boxShadow: !_isSignup
                                  ? const [
                                      BoxShadow(
                                        color: Colors.black12,
                                        blurRadius: 4,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Text(
                              'تسجيل الدخول',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontWeight: !_isSignup
                                    ? FontWeight.w800
                                    : FontWeight.w600,
                                color: !_isSignup ? primaryText : secondaryText,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setState(() {
                            _isSignup = true;
                            _error = null;
                          }),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            decoration: BoxDecoration(
                              color: _isSignup ? cardBg : Colors.transparent,
                              borderRadius: BorderRadius.circular(11),
                              boxShadow: _isSignup
                                  ? const [
                                      BoxShadow(
                                        color: Colors.black12,
                                        blurRadius: 4,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Text(
                              'إنشاء حساب',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontWeight: _isSignup
                                    ? FontWeight.w800
                                    : FontWeight.w600,
                                color: _isSignup ? primaryText : secondaryText,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 18),

              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: dark
                        ? const Color(0xFF30413D)
                        : const Color(0xFFE6EAE8),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!_codeRequested) ...[
                      if (_isSignup) ...[
                        TextField(
                          controller: _name,
                          textCapitalization: TextCapitalization.words,
                          decoration: const InputDecoration(
                            labelText: 'الاسم الثلاثي',
                            hintText: 'مثال: علي حسن محمد',
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                        ),
                        const SizedBox(height: 14),
                      ],
                      Directionality(
                        textDirection: TextDirection.ltr,
                        child: TextField(
                          controller: _phone,
                          keyboardType: TextInputType.phone,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(10),
                          ],
                          decoration: const InputDecoration(
                            prefixText: '+964 ',
                            hintText: '7XXXXXXXXX',
                            labelText: 'رقم الهاتف',
                            prefixIcon: Icon(Icons.phone_android_outlined),
                          ),
                        ),
                      ),
                    ] else ...[
                      Directionality(
                        textDirection: TextDirection.ltr,
                        child: TextField(
                          controller: _code,
                          autofocus: true,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(8),
                          ],
                          decoration: const InputDecoration(
                            labelText: 'رمز التحقق (OTP)',
                            prefixIcon: Icon(Icons.sms_outlined),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => setState(() {
                                    _codeRequested = false;
                                    _error = null;
                                  }),
                            child: const Text('تغيير الرقم'),
                          ),
                          TextButton(
                            onPressed: _busy ? null : _requestCode,
                            child: const Text('إعادة إرسال الرمز'),
                          ),
                        ],
                      ),
                    ],
                    if (_error != null)
                      Container(
                        margin: const EdgeInsets.only(top: 12),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.redAccent.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.error_outline_rounded,
                              color: Colors.redAccent,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error!,
                                style: const TextStyle(
                                  color: Colors.redAccent,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 18),
                    FilledButton(
                      onPressed: _busy
                          ? null
                          : (_codeRequested ? _verify : _requestCode),
                      style: FilledButton.styleFrom(
                        backgroundColor: accent,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: _busy
                          ? const SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              _codeRequested
                                  ? 'تحقق وأكمل الدخول'
                                  : (_isSignup
                                      ? 'إنشاء الحساب وإرسال الرمز'
                                      : 'إرسال رمز الدخول'),
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(child: Divider(color: theme.dividerColor)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      'أو',
                      style: TextStyle(color: secondaryText, fontSize: 13),
                    ),
                  ),
                  Expanded(child: Divider(color: theme.dividerColor)),
                ],
              ),
              const SizedBox(height: 16),

              // Free Developer Access Buttons (Passenger & Captain)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _developerAccess(UserRole.passenger),
                      icon: const Icon(
                        Icons.person_outline,
                        color: green,
                        size: 18,
                      ),
                      label: const Text(
                        'دخول حر (زبون)',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: primaryText,
                        minimumSize: const Size.fromHeight(50),
                        side: BorderSide(color: green.withValues(alpha: 0.6)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _developerAccess(UserRole.captain),
                      icon: const Icon(
                        Icons.local_taxi_outlined,
                        color: Color(0xFF0038FF),
                        size: 18,
                      ),
                      label: const Text(
                        'دخول حر (كابتن)',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: primaryText,
                        minimumSize: const Size.fromHeight(50),
                        side: const BorderSide(color: Color(0xFF0038FF)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'يتيح الدخول الحر للمطور تجربة الخريطة، المفضلة، خيارات الرحلة، والتقييم مباشرة بدون خادم.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: secondaryText),
              ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SupportCenterPage extends StatefulWidget {
  const SupportCenterPage({
    this.initialCategory,
    this.initialDetails,
    super.key,
  });
  final String? initialCategory;
  final String? initialDetails;
  @override
  State<SupportCenterPage> createState() => _SupportCenterPageState();
}

class _SupportCenterPageState extends State<SupportCenterPage> {
  final _details = TextEditingController();
  final _api = PassengerApi();
  String _category = 'مشكلة في رحلة';
  bool _busy = false;
  String? _error;
  final _categories = const [
    'مشكلة في رحلة',
    'شكوى على السائق',
    'الكابتن والتعامل',
    'نظافة أو راحة السيارة',
    'التكييف',
    'اختلاف الأجرة',
    'مشكلة تقنية',
    'أخرى',
  ];

  @override
  void initState() {
    super.initState();
    _details.text = widget.initialDetails ?? '';
    if (widget.initialCategory != null &&
        _categories.contains(widget.initialCategory)) {
      _category = widget.initialCategory!;
    }
  }

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_details.text.trim().length < 8) {
      setState(() => _error = 'اكتب تفاصيل أكثر حتى نتمكن من مساعدتك.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _api.submitSupport(
        category: _category,
        details: _details.text.trim(),
      );
      if (mounted) {
        await NotificationCenterService.add(
          title: 'تم استلام بلاغك',
          body: 'سيتواصل معك فريق الخدمة عبر التطبيق.',
          kind: 'support',
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم إرسال البلاغ إلى مركز الخدمة.')),
        );
        _details.clear();
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is StateError
              ? error.message.toString()
              : 'تعذر إرسال البلاغ. لم يُرسل؛ تحقق من الخادم والإنترنت.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('مركز خدمة الزبائن')),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Card(
          child: ExpansionTile(
            leading: const Icon(Icons.help_outline, color: green),
            title: const Text('كيف أتواصل مع الكابتن؟'),
            children: const [
              Padding(
                padding: EdgeInsets.all(16),
                child: Text('تظهر خيارات الاتصال بعد قبول الرحلة من الخادم.'),
              ),
            ],
          ),
        ),
        Card(
          child: ExpansionTile(
            leading: const Icon(Icons.receipt_long_outlined, color: green),
            title: const Text('كيف أبلغ عن أجرة مختلفة؟'),
            children: const [
              Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'اختر «اختلاف الأجرة» واكتب المبلغ الظاهر والتفاصيل. أرفق رقم الرحلة بعد ربط الحساب.',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text('إرسال بلاغ', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          initialValue: _category,
          decoration: const InputDecoration(
            labelText: 'نوع البلاغ',
            border: OutlineInputBorder(),
          ),
          items: _categories
              .map((item) => DropdownMenuItem(value: item, child: Text(item)))
              .toList(),
          onChanged: (value) {
            if (value != null) setState(() => _category = value);
          },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _details,
          minLines: 4,
          maxLines: 8,
          decoration: const InputDecoration(
            labelText: 'اشرح المشكلة',
            alignLabelWithHint: true,
            border: OutlineInputBorder(),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: green,
            minimumSize: const Size.fromHeight(50),
          ),
          icon: const Icon(Icons.send_outlined),
          label: Text(_busy ? 'جارٍ الإرسال' : 'إرسال إلى مركز الخدمة'),
        ),
        const SizedBox(height: 8),
        const Text(
          'يحتاج إرسال البلاغ إلى خادم الخدمة. لن نعرض تأكيداً قبل استلام الخادم له.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    ),
  );
}

class RideFeedbackPage extends StatefulWidget {
  const RideFeedbackPage({required this.rideId, super.key});
  final String rideId;
  @override
  State<RideFeedbackPage> createState() => _RideFeedbackPageState();
}

class _RideFeedbackPageState extends State<RideFeedbackPage> {
  final _details = TextEditingController();
  final _api = PassengerApi();
  final Set<String> _selected = {};
  int _rating = 0;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_rating == 0) {
      setState(() => _error = 'اختر تقييماً من نجمة إلى خمس نجوم.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _api.submitRideFeedback(
        rideId: widget.rideId,
        reasons: [..._selected, 'التقييم: $_rating/5'],
        details: _details.text.trim(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم إرسال التقييم إلى مركز الخدمة.')),
        );
        context.pop();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'تعذر إرسال التقييم. لم يُرسل؛ حاول مجدداً عند اتصال الخادم.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<RideCubit>().state;
    final dark = state.dark;
    final surface = dark ? const Color(0xFF182522) : Colors.white;
    final primaryText = dark ? Colors.white : const Color(0xFF142421);
    final mutedText = dark ? Colors.white70 : const Color(0xFF5A5F6B);
    return Scaffold(
      backgroundColor: surface,
      appBar: AppBar(
        title: const Text(
          'تقييم السائق',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        backgroundColor: surface,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.close, color: dark ? Colors.white : Colors.black87),
          onPressed: () => context.pop(),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Driver Card
            Row(
              children: [
                _CaptainAvatar(
                  photoUrl: state.driverPhotoUrl,
                  radius: 30,
                  dark: dark,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        state.driverName,
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w900,
                          color: primaryText,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${state.driverCar}${state.driverPlate.isNotEmpty ? ' • ${state.driverPlate}' : ''}',
                        style: TextStyle(fontSize: 14, color: mutedText),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          const Icon(Icons.star, size: 15, color: Color(0xFFFFB800)),
                          const SizedBox(width: 4),
                          Text(
                            state.driverRating.toStringAsFixed(1),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: primaryText,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),

            // Route destination
            Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0038FF),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    state.destinationName.isNotEmpty
                        ? state.destinationName
                        : 'الكوت، شارع الضفاف',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: primaryText,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 10),

            // Date
            Row(
              children: [
                const Icon(
                  Icons.calendar_today_outlined,
                  size: 18,
                  color: Colors.grey,
                ),
                const SizedBox(width: 10),
                Text(
                  state.tripTimeFormatted,
                  style: TextStyle(
                    fontSize: 15,
                    color: mutedText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),

            // Rating section
            Text(
              'قيم الرحلة والسائق',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w900,
                color: primaryText,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'كيف كانت الرحلة؟',
              style: TextStyle(fontSize: 15, color: mutedText),
            ),
            const SizedBox(height: 18),

            // Stars
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(5, (index) {
                final starIndex = index + 1;
                return IconButton(
                  iconSize: 42,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  icon: Icon(
                    starIndex <= (_rating == 0 ? 5 : _rating)
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    color: starIndex <= (_rating == 0 ? 5 : _rating)
                        ? const Color(0xFFFFB800)
                        : Colors.grey.shade300,
                  ),
                  onPressed: () => setState(() => _rating = starIndex),
                );
              }),
            ),

            // Labels under stars
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'سيء جداً',
                    style: TextStyle(fontSize: 13, color: mutedText),
                  ),
                  Text(
                    'جيد جداً',
                    style: TextStyle(fontSize: 13, color: mutedText),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Privacy Notice
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.visibility_off_outlined,
                  size: 20,
                  color: Color(0xFF5A5F6B),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'سيتم الاحتفاظ بتقييمك بشكل سري ولن يعرف السائق به.',
                    style: TextStyle(
                      fontSize: 13,
                      color: Color(0xFF5A5F6B),
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),

            // Submit Button
            SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: _busy ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF0038FF),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: 0,
                ),
                child: Text(
                  _busy ? 'جارٍ الإرسال...' : 'إرسال التقييم',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });
  final IconData icon;
  final String title;
  final String message;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 62, color: Colors.grey),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

class _Pin extends StatelessWidget {
  const _Pin({required this.icon, this.color = green});
  final IconData icon;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 3),
      boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
    ),
    child: Icon(icon, color: Colors.white, size: 19),
  );
}

class _PlaceRow extends StatelessWidget {
  const _PlaceRow({
    required this.icon,
    required this.tint,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final Color tint;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Icon(icon, color: tint, size: 23),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
          const Icon(Icons.search, color: Colors.grey),
        ],
      ),
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.message, required this.onClose});
  final String message;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.all(12),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        const Icon(Icons.info_outline, color: green),
        const SizedBox(width: 8),
        Expanded(child: Text(message)),
        IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
      ],
    ),
  );
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.icon,
    required this.title,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      onTap: onTap,
      leading: Icon(icon, color: green),
      title: Text(title),
      trailing: const Icon(Icons.chevron_left),
    ),
  );
}

class _RoleOptionCard extends StatelessWidget {
  const _RoleOptionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.dark,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final bool dark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final activeColor = green;
    final bg = selected
        ? activeColor.withValues(alpha: dark ? 0.24 : 0.1)
        : (dark ? const Color(0xFF182522) : Colors.white);
    final borderColor = selected
        ? activeColor
        : (dark ? const Color(0xFF30413D) : const Color(0xFFE2E5E4));
    final textColor = dark ? Colors.white : ink;
    final subColor = dark ? Colors.white70 : const Color(0xFF5A6562);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor, width: selected ? 1.8 : 1),
        ),
        child: Column(
          children: [
            Icon(icon, color: selected ? activeColor : subColor, size: 28),
            const SizedBox(height: 6),
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 14,
                color: textColor,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: subColor),
            ),
          ],
        ),
      ),
    );
  }
}

class _CaptainAvatar extends StatelessWidget {
  const _CaptainAvatar({
    required this.photoUrl,
    required this.radius,
    required this.dark,
  });

  final String photoUrl;
  final double radius;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final isRemote =
        photoUrl.startsWith('https://') || photoUrl.startsWith('http://');
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: dark ? const Color(0xFF273B38) : const Color(0xFFEAF0FF),
        border: Border.all(color: const Color(0xFFDAE3FF)),
      ),
      clipBehavior: Clip.antiAlias,
      child: !isRemote
          ? Icon(
              Icons.person_rounded,
              size: radius * 1.15,
              color: const Color(0xFF194BFB),
            )
          : Image.network(
              photoUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Icon(
                Icons.person_rounded,
                size: radius * 1.15,
                color: const Color(0xFF194BFB),
              ),
            ),
    );
  }
}
