import 'package:car/main.dart';
import 'package:car/models/ride_models.dart';
import 'package:car/pages/captain_pages.dart';
import 'package:car/pages/incoming_location_page.dart';
import 'package:car/pages/offline_maps_page.dart';
import 'package:car/pages/safety_page.dart';
import 'package:car/services/captain_navigation_service.dart';
import 'package:car/services/captain_photo_service.dart';
import 'package:car/services/iraqi_navigation_service.dart';
import 'package:car/services/map_link_parser.dart';
import 'package:car/services/offline_maps_service.dart';
import 'package:car/services/ride_backend_service.dart';
import 'package:car/widgets/darb_components.dart';
import 'package:dio/dio.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRouteRepository extends MapRepository {
  int requests = 0;

  @override
  Future<RouteInfo> route(
    LatLng from,
    LatLng to, {
    List<LatLng> stops = const [],
    bool roundTrip = false,
  }) async {
    requests++;
    final primary = RouteInfo(5, 10, [from, to]);
    return RouteInfo(
      primary.kilometers,
      primary.minutes,
      primary.points,
      alternatives: [
        RouteInfo(8, 14, [
          from,
          LatLng(from.latitude + .02, from.longitude),
          to,
        ]),
      ],
    );
  }
}

Future<void> _selectEndpoints(WidgetTester tester) async {
  await tester.tap(find.byTooltip('اختر الانطلاق من الخريطة'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('تأكيد هذا المكان'));
  await tester.pumpAndSettle();

  await tester.tap(find.byTooltip('اختر الوصول من الخريطة'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('تأكيد هذا المكان'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'passenger_logged_in': true,
      'darb_saved_places_schema_v3': true,
    });
  });
  testWidgets('asks for both locations and hides price until route is ready', (
    tester,
  ) async {
    await tester.pumpWidget(const RideApp());
    await tester.pump();

    expect(find.text('أين تبدأ رحلتك؟'), findsOneWidget);
    expect(find.text('تحديد نقطة الانطلاق'), findsOneWidget);
    expect(find.text('تحديد نقطة الوصول'), findsOneWidget);
    expect(find.text('الانطلاق'), findsNothing);
    expect(find.text('الوصول'), findsNothing);
    expect(find.text('توفير'), findsNothing);
    expect(find.text('عرض الأسعار'), findsNothing);
  });

  testWidgets('shows prices after route setup and selects Plus', (
    tester,
  ) async {
    await tester.pumpWidget(const RideApp());
    await tester.pump();
    await _selectEndpoints(tester);

    expect(find.text('قسيمة'), findsOneWidget);
    expect(find.text('خيارات الرحلة'), findsOneWidget);
    expect(find.text('توفير'), findsOneWidget);
    expect(find.text('بَلَس'), findsOneWidget);
    await tester.tap(find.text('بَلَس'));
    await tester.pump();
    expect(find.text('طلب بَلَس'), findsOneWidget);
  });

  testWidgets('bottom ride sheet collapses and expands with a drag', (
    tester,
  ) async {
    await tester.pumpWidget(const RideApp());
    await tester.pump();
    await _selectEndpoints(tester);

    final sheet = find.byKey(const ValueKey('ride-sheet-gesture'));
    await tester.drag(sheet, const Offset(0, 260));
    await tester.pumpAndSettle();
    expect(find.textContaining('السعر الحالي:'), findsOneWidget);

    await tester.drag(sheet, const Offset(0, -260));
    await tester.pumpAndSettle();
    expect(find.text('خيارات الرحلة'), findsOneWidget);
  });

  testWidgets('opens and applies a promo code after locations are set', (
    tester,
  ) async {
    await tester.pumpWidget(const RideApp());
    await tester.pump();
    await _selectEndpoints(tester);

    await tester.tap(find.text('قسيمة'));
    await tester.pumpAndSettle();
    expect(find.text('رمز الخصم'), findsWidgets);
    expect(find.text('هل لديك رمز خصم؟'), findsOneWidget);
    expect(find.text('رجاءً أدخل رمز الخصم'), findsOneWidget);
    expect(find.text('تثبيت الرمز'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'DARB2026');
    await tester.tap(find.text('تثبيت الرمز'));
    await tester.pumpAndSettle();
    expect(find.textContaining('DARB2026'), findsOneWidget);
  });

  testWidgets('opens ride options after locations are set', (tester) async {
    await tester.pumpWidget(const RideApp());
    await tester.pump();
    await _selectEndpoints(tester);

    await tester.tap(find.text('خيارات الرحلة'));
    await tester.pumpAndSettle();
    expect(find.textContaining('لا يمكن تغيير الخيارات'), findsOneWidget);
    expect(find.text('الوجهة الثانية'), findsOneWidget);
    expect(find.text('التوقف في الطريق'), findsOneWidget);
    expect(find.text('رحلة ذهاب وإياب'), findsOneWidget);
  });

  testWidgets('clears the finished trip after the driver rating is submitted', (
    tester,
  ) async {
    await tester.pumpWidget(const RideApp());
    await tester.pump();
    await _selectEndpoints(tester);
    tester
        .element(find.byType(HomePage))
        .read<RideCubit>()
        .setRideStatus(RideBookingStatus.inProgress);
    await tester.pumpAndSettle();

    await tester.tap(find.text('إنهاء الرحلة وتقييم السائق'));
    await tester.pumpAndSettle();
    expect(find.text('تقييم السائق'), findsOneWidget);
    await tester.tap(find.text('إرسال التقييم'));
    await tester.pumpAndSettle();

    expect(find.text('أين تبدأ رحلتك؟'), findsOneWidget);
    expect(find.text('تحديد نقطة الانطلاق'), findsOneWidget);
    expect(find.text('تحديد نقطة الوصول'), findsOneWidget);
    expect(find.text('السعر الحالي:'), findsNothing);
    final state = tester.element(find.byType(HomePage)).read<RideCubit>().state;
    expect(state.origin, isNull);
    expect(state.destination, isNull);
    expect(state.rideStatus, RideBookingStatus.idle);
  });

  testWidgets('clears the finished trip when the rating sheet is closed', (
    tester,
  ) async {
    await tester.pumpWidget(const RideApp());
    await tester.pump();
    await _selectEndpoints(tester);
    tester
        .element(find.byType(HomePage))
        .read<RideCubit>()
        .setRideStatus(RideBookingStatus.inProgress);
    await tester.pumpAndSettle();

    await tester.tap(find.text('إنهاء الرحلة وتقييم السائق'));
    await tester.pumpAndSettle();
    expect(find.text('تقييم السائق'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text('أين تبدأ رحلتك؟'), findsOneWidget);
    expect(find.text('تحديد نقطة الانطلاق'), findsOneWidget);
    expect(find.text('تحديد نقطة الوصول'), findsOneWidget);
    expect(find.text('السعر الحالي:'), findsNothing);
    final state = tester.element(find.byType(HomePage)).read<RideCubit>().state;
    expect(state.origin, isNull);
    expect(state.destination, isNull);
    expect(state.rideStatus, RideBookingStatus.idle);
  });

  testWidgets('dark theme applies a night filter to map tiles', (tester) async {
    await tester.pumpWidget(const RideApp());
    await tester.pump();
    tester.element(find.byType(HomePage)).read<RideCubit>().toggleTheme();
    await tester.pumpAndSettle();

    final tileLayer = tester.widget<TileLayer>(find.byType(TileLayer).first);
    expect(tileLayer.tileBuilder, isNotNull);
    expect(
      tester
          .element(find.text('أين تبدأ رحلتك؟'))
          .findAncestorWidgetOfExactType<Container>(),
      isNotNull,
    );
  });

  test(
    'route alternatives can be selected and live deviation recalculates',
    () async {
      final repository = _FakeRouteRepository();
      final cubit = RideCubit(repository);
      cubit.setOriginPoint(const LatLng(32.5, 45.8));
      cubit.setMapDestination(const LatLng(32.55, 45.85));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(cubit.state.routeOptions, hasLength(2));
      cubit.selectRoute(1);
      expect(cubit.state.route?.kilometers, 8);
      expect(cubit.state.selectedRouteIndex, 1);

      cubit.setRideStatus(RideBookingStatus.inProgress);
      await cubit.updateDriverPosition(const LatLng(33, 46), heading: 90);
      expect(repository.requests, 2);
      expect(cubit.state.driverPosition, const LatLng(33, 46));
      expect(cubit.state.driverHeading, 90);
      await cubit.close();
    },
  );

  testWidgets('unified login screen shows customer and captain role options', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'passenger_logged_in': false,
      'darb_saved_places_schema_v3': true,
    });
    passengerLoggedIn.value = false;
    await tester.pumpWidget(const RideApp());
    await tester.pumpAndSettle();

    expect(find.text('الدخول كزبون'), findsOneWidget);
    expect(find.text('الدخول ككابتن'), findsOneWidget);
    expect(find.text('دخول حر (زبون)'), findsOneWidget);
    expect(find.text('دخول حر (كابتن)'), findsOneWidget);
  });

  test('end-to-end ride dispatch & atomic captain acceptance lock', () async {
    final backend = RideBackendService.instance;
    final req = RideRequestPayload(
      rideId: 'ride_test_1',
      passengerName: 'علي حسن',
      passengerPhone: '+9647701112233',
      originLat: 32.505,
      originLng: 45.823,
      originName: 'الكوت، حي الزهراء',
      destinationLat: 32.518,
      destinationLng: 45.836,
      destinationName: 'الكوت، شارع الضفاف',
      fareIqd: 1500,
      distanceKm: 3.2,
      durationMin: 8,
      createdAt: DateTime.now(),
    );

    await backend.createRideRequest(req);
    const captain1 = CaptainProfile(
      id: 'cap_1',
      fullName: 'محمد ناصر',
      carModel: 'Kia Optima',
      carColor: 'أبيض',
      plateNumber: '45821',
      approvalStatus: CaptainApprovalStatus.approved,
      isOnline: true,
    );
    const captain2 = CaptainProfile(
      id: 'cap_2',
      fullName: 'كابتن آخر',
      approvalStatus: CaptainApprovalStatus.approved,
      isOnline: true,
    );

    final accepted = await backend.acceptRideAtomic(
      request: req,
      captain: captain1,
    );
    expect(accepted.status, RideDispatchStatus.accepted);
    expect(accepted.captainId, 'cap_1');

    // Second captain trying to accept the same ride must get RideConflictException
    await expectLater(
      backend.acceptRideAtomic(request: req, captain: captain2),
      throwsA(isA<RideConflictException>()),
    );

    final arrived = await backend.updateRideStatus(
      request: accepted,
      nextStatus: RideDispatchStatus.arrived,
    );
    expect(arrived.status, RideDispatchStatus.arrived);

    final started = await backend.updateRideStatus(
      request: arrived,
      nextStatus: RideDispatchStatus.inProgress,
    );
    expect(started.status, RideDispatchStatus.inProgress);

    final completed = await backend.updateRideStatus(
      request: started,
      nextStatus: RideDispatchStatus.completed,
    );
    expect(completed.status, RideDispatchStatus.completed);

    await backend.recordCaptainCompletedTrip(completed, captain1);
    final history = await backend.loadCaptainHistory();
    expect(history, isNotEmpty);
    expect(history.first['ride_id'], 'ride_test_1');
  });

  testWidgets('captain dashboard supports developer approval and going online', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'passenger_logged_in': true,
      'darb_user_role': 'captain',
      'darb_captain_profile_v1':
          '{"id":"cap_1","full_name":"كابتن اختبار","car_model":"Kia Optima","plate_number":"1234","photo_url":"https://cdn.darb.iq/cap.jpg"}',
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: CaptainHomePage(),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();

    expect(find.text('اعتماد فوري للمطور — تفعيل الكابتن'), findsOneWidget);
    await tester.tap(find.text('اعتماد فوري للمطور — تفعيل الكابتن'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();

    expect(find.text('غير متاح'), findsOneWidget);
    await tester.tap(find.text('غير متاح'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
    expect(find.text('متاح'), findsOneWidget);
  });

  test('RideStateMachine & unified domain models enforce valid transitions', () {
    expect(
      RideStateMachine.canTransition(
        RideDispatchStatus.searching,
        RideDispatchStatus.accepted,
      ),
      isTrue,
    );
    expect(
      RideStateMachine.canTransition(
        RideDispatchStatus.searching,
        RideDispatchStatus.completed,
      ),
      isFalse,
    );
    expect(
      RideStateMachine.nextCaptainStep(RideDispatchStatus.accepted),
      RideDispatchStatus.arrived,
    );
    expect(
      RideStateMachine.nextCaptainStep(RideDispatchStatus.arrived),
      RideDispatchStatus.inProgress,
    );
    expect(
      RideStateMachine.nextCaptainStep(RideDispatchStatus.inProgress),
      RideDispatchStatus.completed,
    );

    const vehicle = VehicleInfo(
      model: 'Kia Optima',
      color: 'أبيض',
      plateNumber: '45821',
    );
    expect(vehicle.displayLabel, 'أبيض Kia Optima');

    final loc = UserLocation.fromJson(
      const UserLocation(latitude: 32.5, longitude: 45.8, heading: 90).toJson(),
    );
    expect(loc.latitude, 32.5);
    expect(loc.heading, 90);
  });

  test('ride cancellation clears pending local dispatch & blocks re-accept', () async {
    SharedPreferences.setMockInitialValues({});
    final backend = RideBackendService.instance;
    final demo = await backend.triggerLocalDemoRequest(
      const LatLng(32.505, 45.823),
    );
    expect(demo.status, RideDispatchStatus.searching);

    final cancelled = await backend.updateRideStatus(
      request: demo,
      nextStatus: RideDispatchStatus.cancelled,
    );
    expect(cancelled.status, RideDispatchStatus.cancelled);
    expect(await backend.loadPendingLocalRide(), isNull);

    // Invalid transition after cancellation must throw StateError
    await expectLater(
      backend.updateRideStatus(
        request: cancelled,
        nextStatus: RideDispatchStatus.inProgress,
      ),
      throwsA(isA<StateError>()),
    );
  });

  testWidgets('safety center renders Emergency SOS and trusted contacts empty state', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: SafetyCenterPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('نداء الطوارئ السريع (SOS)'), findsOneWidget);
    expect(find.text('لا توجد جهات اتصال موثوقة'), findsOneWidget);
  });

  testWidgets('DarbStateView renders empty and offline states', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              DarbStateView.empty(
                icon: Icons.inbox_outlined,
                title: 'فارغ',
              ),
              DarbStateView.offline(),
            ],
          ),
        ),
      ),
    );
    expect(find.text('فارغ'), findsOneWidget);
    expect(find.text('لا يوجد اتصال بالإنترنت'), findsOneWidget);
  });

  test('CaptainNavigationService parses actual OSRM routes without inventing fake routes & detects off-route', () {
    final routes = CaptainNavigationService.parseOsrmRoutes([
      {
        'distance': 4500, // 4.5 km (longer distance, faster time)
        'duration': 300, // 5 min (fastest)
        'geometry': {
          'coordinates': [
            [45.8180, 32.5128],
            [45.8250, 32.5180],
          ],
        },
        'legs': [
          {
            'steps': [
              {
                'distance': 200,
                'duration': 20,
                'name': 'شارع الضفاف',
                'maneuver': {
                  'type': 'turn',
                  'modifier': 'right',
                  'location': [45.8210, 32.5150],
                },
              },
            ],
          },
        ],
      },
      {
        'distance': 3200, // 3.2 km (shortest)
        'duration': 480, // 8 min
        'geometry': {
          'coordinates': [
            [45.8180, 32.5128],
            [45.8220, 32.5150],
          ],
        },
        'legs': [],
      },
    ]);

    // Must return exactly the 2 provided routes (never fabricate a 3rd)
    expect(routes, hasLength(2));
    expect(routes[0].isFastest, isTrue);
    expect(routes[0].isShortest, isFalse);
    expect(routes[0].badgeLabel, 'الأسرع');
    expect(routes[0].steps.first.instructionText, contains('يميناً'));

    expect(routes[1].isShortest, isTrue);
    expect(routes[1].isFastest, isFalse);
    expect(routes[1].badgeLabel, 'الأقصر');

    // On-route point
    final onRoute = CaptainNavigationService.computeProgress(
      current: const LatLng(32.5128, 45.8180),
      route: routes[0],
    );
    expect(onRoute.isOffRoute, isFalse);

    // Off-route point (> 65m away)
    final offRoute = CaptainNavigationService.computeProgress(
      current: const LatLng(32.5300, 45.8400),
      route: routes[0],
    );
    expect(offRoute.isOffRoute, isTrue);
  });

  test('IraqiNavigationService preserves exact coordinates without PII and persists preference', () async {
    SharedPreferences.setMockInitialValues({});
    const destLat = 32.51842319;
    const destLng = 45.83619482;

    final geoUri = IraqiNavigationService.buildExactGeoUri(destLat, destLng);
    expect(geoUri, 'geo:32.51842319,45.83619482?q=32.51842319,45.83619482');
    expect(IraqiNavigationService.packageFor(IraqiNavApp.dahliz), 'com.ms.jaber.wain');
    expect(IraqiNavigationService.packageFor(IraqiNavApp.darbuna), 'iq.darbuna.app');

    expect(await IraqiNavigationService.loadPreferredNavApp(), IraqiNavApp.ask);
    await IraqiNavigationService.savePreferredNavApp(IraqiNavApp.darbuna);
    expect(await IraqiNavigationService.loadPreferredNavApp(), IraqiNavApp.darbuna);

    expect(
      IraqiNavigationService.storeUrlFor(IraqiNavApp.darbuna),
      'https://play.google.com/store/apps/details?id=iq.darbuna.app',
    );
    expect(
      IraqiNavigationService.storeUrlFor(IraqiNavApp.dahliz),
      'https://dahliz.app/ar/',
    );
  });

  testWidgets('CaptainOnboardingPage keeps Save button visible in SafeArea on small screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: CaptainOnboardingPage(),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
    expect(find.text('حفظ وإرسال للموافقة'), findsOneWidget);
  });

  group('MapLinkParserService', () {
    test('extracts URL from conversational WhatsApp/Telegram text', () {
      const msg =
          'هلا حبيبي هذا موقعي تعال هنا https://maps.google.com/?q=33.315200,44.366100 انتظرني بالباب';
      expect(
        MapLinkParserService.extractFirstUrl(msg),
        'https://maps.google.com/?q=33.315200,44.366100',
      );
      expect(MapLinkParserService.extractFirstUrl('geo:32.5184,45.8361'), 'geo:32.5184,45.8361');
      expect(
        MapLinkParserService.extractFirstUrl('افتح darb://location?lat=33.3&lng=44.4'),
        'darb://location?lat=33.3&lng=44.4',
      );
    });

    test('parses Google Maps formats (!3d!4d, @lat,lng, dir/, api=1)', () {
      final exactPin = MapLinkParserService.parseUrl(
        'https://www.google.com/maps/place/Baghdad+Mall/@33.3120,44.3500,15z/data=!3m1!4b1!4m6!3m5!1s0x15577f:0x123!8m2!3d33.315241!4d44.366149',
      );
      expect(exactPin, isNotNull);
      expect(exactPin!.latitude, closeTo(33.315241, 0.00001));
      expect(exactPin.longitude, closeTo(44.366149, 0.00001));
      expect(exactPin.placeName, 'Baghdad Mall');
      expect(exactPin.placeId, '0x15577f:0x123');

      final atCoords = MapLinkParserService.parseUrl(
        'https://www.google.com/maps/@32.5184,45.8361,16z',
      );
      expect(atCoords, isNotNull);
      expect(atCoords!.latitude, closeTo(32.5184, 0.0001));
      expect(atCoords.longitude, closeTo(45.8361, 0.0001));

      final dirSlash = MapLinkParserService.parseUrl(
        'https://www.google.com/maps/dir/33.3100,44.3600/33.3400,44.4000/',
      );
      expect(dirSlash, isNotNull);
      expect(dirSlash!.hasDirections, isTrue);
      expect(dirSlash.originLatitude, closeTo(33.3100, 0.0001));
      expect(dirSlash.originLongitude, closeTo(44.3600, 0.0001));
      expect(dirSlash.latitude, closeTo(33.3400, 0.0001));
      expect(dirSlash.longitude, closeTo(44.4000, 0.0001));

      final apiDir = MapLinkParserService.parseUrl(
        'https://www.google.com/maps/dir/?api=1&origin=33.3100,44.3600&destination=33.3400,44.4000',
      );
      expect(apiDir, isNotNull);
      expect(apiDir!.hasDirections, isTrue);
      expect(apiDir.originLatitude, closeTo(33.3100, 0.0001));
      expect(apiDir.latitude, closeTo(33.3400, 0.0001));
    });

    test('parses Apple Maps, OpenStreetMap, Waze, Bing, geo:, and darb://', () {
      final apple = MapLinkParserService.parseUrl(
        'https://maps.apple.com/?ll=33.3152,44.3661&q=Al-Mansour',
      );
      expect(apple, isNotNull);
      expect(apple!.latitude, closeTo(33.3152, 0.0001));
      expect(apple.longitude, closeTo(44.3661, 0.0001));

      final osm = MapLinkParserService.parseUrl(
        'https://www.openstreetmap.org/?mlat=32.5184&mlon=45.8361#map=16/32.5184/45.8361',
      );
      expect(osm, isNotNull);
      expect(osm!.latitude, closeTo(32.5184, 0.0001));
      expect(osm.longitude, closeTo(45.8361, 0.0001));

      final waze = MapLinkParserService.parseUrl(
        'https://waze.com/ul?ll=33.3152,44.3661&navigate=yes',
      );
      expect(waze, isNotNull);
      expect(waze!.latitude, closeTo(33.3152, 0.0001));

      final bing = MapLinkParserService.parseUrl(
        'https://www.bing.com/maps?cp=33.3152~44.3661&lvl=15',
      );
      expect(bing, isNotNull);
      expect(bing!.latitude, closeTo(33.3152, 0.0001));
      expect(bing.longitude, closeTo(44.3661, 0.0001));

      final geo = MapLinkParserService.parseUrl('geo:32.5184,45.8361?q=32.5184,45.8361(Kut)');
      expect(geo, isNotNull);
      expect(geo!.latitude, closeTo(32.5184, 0.0001));
      expect(geo.longitude, closeTo(45.8361, 0.0001));

      final darb = MapLinkParserService.parseUrl(
        'darb://location?lat=33.3152&lng=44.3661&name=Baghdad',
      );
      expect(darb, isNotNull);
      expect(darb!.latitude, closeTo(33.3152, 0.0001));
      expect(darb.longitude, closeTo(44.3661, 0.0001));
      expect(darb.placeName, 'Baghdad');
    });

    test('resolves short maps.app.goo.gl redirect using Dio and rejects invalid links', () async {
      final dio = Dio()..httpClientAdapter = _FakeRedirectAdapter();
      final resolved = await MapLinkParserService.resolveAndParse(
        'شوف هذا الموقع https://maps.app.goo.gl/abc123',
        dio: dio,
      );
      expect(resolved, isNotNull);
      expect(resolved!.latitude, closeTo(33.3152, 0.0001));
      expect(resolved.longitude, closeTo(44.3661, 0.0001));

      final invalid = await MapLinkParserService.resolveAndParse(
        'https://example.com/no-coordinates-here',
        dio: dio,
      );
      expect(invalid, isNull);
    });
  });

  testWidgets('IncomingLocationPage renders details and asks confirmation when ride is active', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var setDestCalled = false;
    var setBothCalled = false;
    const loc = ParsedMapLocation(
      source: 'Google Maps',
      latitude: 33.315241,
      longitude: 44.366149,
      rawUrl: 'https://maps.google.com/?q=33.315241,44.366149',
      placeName: 'ساحة التحرير',
      address: 'بغداد، العراق',
      originLatitude: 33.300000,
      originLongitude: 44.350000,
      originName: 'المنصور',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: IncomingLocationPage(
            location: loc,
            isRideActive: true,
            onSetDestination: () => setDestCalled = true,
            onSetOrigin: () {},
            onSetBoth: () => setBothCalled = true,
            onViewOnMap: () {},
          ),
        ),
      ),
    );

    expect(find.text('موقع مشترك'), findsOneWidget);
    expect(find.text('المصدر: Google Maps'), findsOneWidget);
    expect(find.text('ساحة التحرير'), findsOneWidget);
    expect(find.textContaining('https://'), findsNothing);
    expect(find.text('اعتماد الانطلاق والوجهة معاً'), findsOneWidget);

    await tester.tap(find.text('اعتماد كوجهة'));
    await tester.pumpAndSettle();

    expect(find.text('رحلة نشطة حالياً'), findsOneWidget);
    expect(setDestCalled, isFalse);

    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle();
    expect(setDestCalled, isTrue);
    expect(setBothCalled, isFalse);
  });

  test('CaptainNavigationService speedKmh & OffRouteDetector filter GPS noise', () {
    expect(CaptainNavigationService.speedKmh(0.4), 0);
    expect(CaptainNavigationService.speedKmh(10.0), 36);

    final detector = OffRouteDetector(
      maxAcceptableAccuracyMeters: 45,
      consecutiveSamplesRequired: 2,
    );
    // Low-accuracy sample should never trigger reroute
    expect(detector.evaluate(isSampleOffRoute: true, accuracyMeters: 80), isFalse);
    // Single accurate off-route sample should not trigger reroute yet
    expect(detector.evaluate(isSampleOffRoute: true, accuracyMeters: 10), isFalse);
    // Second consecutive accurate off-route sample confirms reroute
    expect(detector.evaluate(isSampleOffRoute: true, accuracyMeters: 10), isTrue);
    // Back on route resets
    expect(detector.evaluate(isSampleOffRoute: false, accuracyMeters: 10), isFalse);
    expect(detector.evaluate(isSampleOffRoute: true, accuracyMeters: 10), isFalse);
  });

  test('CaptainPhotoService validates single clear face & remote URLs only', () {
    expect(CaptainPhotoService.isRemotePhotoUrl('/data/user/0/photo.jpg'), isFalse);
    expect(CaptainPhotoService.isRemotePhotoUrl('https://cdn.darb.iq/c1.jpg'), isTrue);

    expect(CaptainPhotoService.validateFaceMetrics(faceCount: 0).isValid, isFalse);
    expect(CaptainPhotoService.validateFaceMetrics(faceCount: 2).isValid, isFalse);
    expect(
      CaptainPhotoService.validateFaceMetrics(faceCount: 1, faceAreaRatio: 0.02).isValid,
      isFalse,
    );
    expect(
      CaptainPhotoService.validateFaceMetrics(
        faceCount: 1,
        faceAreaRatio: 0.25,
        filePath: '/tmp/face.jpg',
      ).isValid,
      isTrue,
    );

    const profile = CaptainProfile(fullName: 'أحمد', carModel: 'Optima', plateNumber: '1234');
    expect(profile.hasProfilePhoto, isFalse);
    expect(profile.copyWith(localPhotoPath: '/tmp/face.jpg').hasProfilePhoto, isTrue);
  });

  testWidgets('CaptainOnboardingPage shows mandatory photo section & blocks save without photo', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: CaptainOnboardingPage(),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();

    expect(find.text('الصورة الشخصية للكابتن'), findsOneWidget);
    expect(find.text('الكاميرا'), findsOneWidget);
    expect(find.text('المعرض'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'كابتن علي');
    await tester.enterText(find.byType(TextField).at(2), 'Kia Optima');
    await tester.enterText(find.byType(TextField).at(4), 'بغداد 12345');
    await tester.tap(find.text('حفظ وإرسال للموافقة'));
    await tester.pump();

    expect(find.text('يرجى التقاط أو اختيار الصورة الشخصية للكابتن أولاً.'), findsOneWidget);
  });

  test('MapLinkParserService handles geo:/ and geo:0,0?q=lat,lng formats', () {
    final slashGeo = MapLinkParserService.parseUrl(
      'geo:/32.52074471,45.801719892?q=%D8%8C+%D8%B4%D8%A7%D8%B1%D8%B9+%D8%A7%D9%84%D9%83%D9%81%D8%A7%D8%A1%D8%A7%D8%AA',
    );
    expect(slashGeo, isNotNull);
    expect(slashGeo!.latitude, closeTo(32.52074471, 0.000001));
    expect(slashGeo.longitude, closeTo(45.801719892, 0.000001));
    expect(slashGeo.placeName, 'شارع الكفاءات');

    final zeroGeoWithQ = MapLinkParserService.parseUrl(
      'geo:0,0?q=32.52074471,45.801719892(WhatsApp+Pin)',
    );
    expect(zeroGeoWithQ, isNotNull);
    expect(zeroGeoWithQ!.latitude, closeTo(32.52074471, 0.000001));
    expect(zeroGeoWithQ.longitude, closeTo(45.801719892, 0.000001));
    expect(zeroGeoWithQ.placeName, 'WhatsApp Pin');

    expect(MapLinkParserService.parseUrl('geo:0,0'), isNull);
  });

  testWidgets('GoRouter redirects external geo:/ URI without throwing GoException', (
    tester,
  ) async {
    await tester.pumpWidget(const RideApp());
    await tester.pump();

    router.go('geo:/32.52074471,45.801719892?q=%D8%A8%D8%BA%D8%AF%D8%A7%D8%AF');
    await tester.pumpAndSettle();

    expect(find.textContaining('GoException'), findsNothing);
    expect(find.textContaining('Page Not Found'), findsNothing);
    expect(find.text('موقع مشترك'), findsOneWidget);
    expect(find.text('بغداد'), findsOneWidget);
    expect(find.textContaining('geo:'), findsNothing);
  });

  test('RideBackendService triggerMultipleLocalDemoRequests generates 3 priced requests', () async {
    SharedPreferences.setMockInitialValues({});
    final created = await RideBackendService.instance
        .triggerMultipleLocalDemoRequests(const LatLng(32.5050, 45.8230));
    expect(created, hasLength(3));
    expect(created.map((e) => e.fareIqd).toList(), [1500, 3000, 4500]);
  });

  test('OfflineMapsService covers All Iraq + 18 Iraqi governorates with valid tile math', () {
    expect(OfflineMapsService.regions.length, 20);
    final allIraq = OfflineMapsService.regions.first;
    expect(allIraq.isAllIraq, isTrue);
    expect(allIraq.nameAr, 'كل العراق');
    expect(OfflineMapsService.countTilesForRegion(allIraq), greaterThan(0));
    expect(OfflineMapsService.estimateSizeMb(allIraq), greaterThan(0));
    final (x, y) = OfflineMapsService.latLngToTile(32.5050, 45.8230, 12);
    expect(x, greaterThan(0));
    expect(y, greaterThan(0));
  });

  testWidgets('OfflineMapsPage renders Iraq and governorates list & map tabs', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: OfflineMapsPage(),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    expect(find.text('خرائط دون اتصال'), findsOneWidget);
    expect(find.text('كل العراق'), findsOneWidget);
    expect(find.text('بغداد'), findsOneWidget);
    expect(find.text('واسط'), findsOneWidget);
    expect(find.text('خريطة'), findsNothing);
  });

  test('savedPlacesStorageKey separates passenger and captain favorites', () {
    currentUserRole.value = UserRole.passenger;
    expect(savedPlacesStorageKey, 'darb_saved_places');
    currentUserRole.value = UserRole.captain;
    expect(savedPlacesStorageKey, 'darb_saved_places_captain_v1');
    currentUserRole.value = UserRole.passenger;
  });
}

class _FakeRedirectAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.host == 'maps.app.goo.gl') {
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          Headers.contentTypeHeader: ['text/plain'],
          'location': ['https://www.google.com/maps/@33.3152,44.3661,16z'],
        },
      );
    }
    return ResponseBody.fromString('', 404);
  }
}

