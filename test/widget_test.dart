import 'package:car/main.dart';
import 'package:car/models/ride_models.dart';
import 'package:car/pages/captain_pages.dart';
import 'package:car/pages/safety_page.dart';
import 'package:car/services/captain_navigation_service.dart';
import 'package:car/services/ride_backend_service.dart';
import 'package:car/widgets/darb_components.dart';
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
}
