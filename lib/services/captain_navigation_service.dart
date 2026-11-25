import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

/// Turn-by-turn maneuver instruction parsed from OSRM `steps=true`.
class RouteStepInstruction {
  const RouteStepInstruction({
    required this.instructionText,
    required this.streetName,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.maneuverPoint,
    required this.maneuverType,
    this.modifier = '',
  });

  final String instructionText;
  final String streetName;
  final double distanceMeters;
  final double durationSeconds;
  final LatLng maneuverPoint;
  final String maneuverType;
  final String modifier;
}

/// Candidate or active route option calculated by OSRM.
class CaptainRouteOption {
  const CaptainRouteOption({
    required this.index,
    required this.distanceKm,
    required this.durationMin,
    required this.points,
    this.steps = const [],
    this.isFastest = false,
    this.isShortest = false,
  });

  final int index;
  final double distanceKm;
  final double durationMin;
  final List<LatLng> points;
  final List<RouteStepInstruction> steps;
  final bool isFastest;
  final bool isShortest;

  String get badgeLabel {
    if (isFastest && isShortest) return 'الأسرع والأقصر';
    if (isFastest) return 'الأسرع';
    if (isShortest) return 'الأقصر';
    return 'مسار بديل';
  }
}

/// Live navigation progress and off-route snapshot.
class NavigationProgressSnapshot {
  const NavigationProgressSnapshot({
    required this.progress,
    required this.remainingKm,
    required this.remainingMin,
    required this.distanceToRouteMeters,
    required this.isOffRoute,
    this.nextStep,
    this.followingStep,
    this.distanceToNextStepMeters = 0,
    this.dynamicInstruction = '',
    this.speechKey,
  });

  final double progress;
  final double remainingKm;
  final double remainingMin;
  final double distanceToRouteMeters;
  final bool isOffRoute;
  final RouteStepInstruction? nextStep;
  final RouteStepInstruction? followingStep;
  final double distanceToNextStepMeters;
  final String dynamicInstruction;
  final String? speechKey;
}

/// Handles OSRM multi-route fetching, turn-by-turn parsing, TTS, and off-route checks.
class CaptainNavigationService {
  CaptainNavigationService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 8),
                receiveTimeout: const Duration(seconds: 12),
              ),
            );

  final Dio _dio;
  static const _ttsChannel = MethodChannel('iq.ridepassenger.car/tts');
  static const Distance _geo = Distance();
  static const double offRouteThresholdMeters = 65;

  static Future<void> speakArabic(String text) async {
    if (text.trim().isEmpty) return;
    try {
      await _ttsChannel.invokeMethod<void>('speakArabic', {'text': text});
    } catch (_) {}
  }

  static Future<void> stopSpeaking() async {
    try {
      await _ttsChannel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  /// Calculates bearing in degrees (0..360) from [from] to [to].
  static double bearingDegrees(LatLng from, LatLng to) {
    final lat1 = from.latitude * math.pi / 180;
    final lat2 = to.latitude * math.pi / 180;
    final dLon = (to.longitude - from.longitude) * math.pi / 180;
    final y = math.sin(dLon) * math.cos(lat2);
    final x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  /// Fetches up to 3 actual calculated routes from OSRM.
  /// Never fabricates extra routes if OSRM returns fewer than 3.
  Future<List<CaptainRouteOption>> fetchAlternativeRoutes(
    LatLng from,
    LatLng to,
  ) async {
    final coords =
        '${from.longitude},${from.latitude};${to.longitude},${to.latitude}';
    final res = await _dio.get(
      'https://router.project-osrm.org/route/v1/driving/$coords',
      queryParameters: const {
        'overview': 'full',
        'geometries': 'geojson',
        'alternatives': '3',
        'steps': 'true',
      },
    );
    final data = res.data;
    if (data is! Map || data['routes'] is! List) return const [];
    return parseOsrmRoutes(data['routes'] as List);
  }

  /// Parses raw OSRM `routes` JSON into tagged [CaptainRouteOption] items.
  static List<CaptainRouteOption> parseOsrmRoutes(List<dynamic> rawRoutes) {
    if (rawRoutes.isEmpty) return const [];
    final limited = rawRoutes.take(3).toList();
    final parsed = <CaptainRouteOption>[];

    for (var i = 0; i < limited.length; i++) {
      final item = limited[i];
      if (item is! Map) continue;
      final coords = item['geometry'] is Map
          ? item['geometry']['coordinates'] as List?
          : null;
      if (coords == null || coords.isEmpty) continue;

      final points = coords
          .whereType<List>()
          .map(
            (v) => LatLng((v[1] as num).toDouble(), (v[0] as num).toDouble()),
          )
          .toList();
      if (points.isEmpty) continue;

      final distanceKm = ((item['distance'] as num?)?.toDouble() ?? 0) / 1000.0;
      final durationMin = ((item['duration'] as num?)?.toDouble() ?? 0) / 60.0;
      final steps = _parseSteps(item['legs']);

      parsed.add(
        CaptainRouteOption(
          index: i,
          distanceKm: distanceKm,
          durationMin: durationMin,
          points: points,
          steps: steps,
        ),
      );
    }

    if (parsed.isEmpty) return const [];

    var fastestIdx = 0;
    var shortestIdx = 0;
    for (var i = 1; i < parsed.length; i++) {
      if (parsed[i].durationMin < parsed[fastestIdx].durationMin) {
        fastestIdx = i;
      }
      if (parsed[i].distanceKm < parsed[shortestIdx].distanceKm) {
        shortestIdx = i;
      }
    }

    return [
      for (var i = 0; i < parsed.length; i++)
        CaptainRouteOption(
          index: parsed[i].index,
          distanceKm: parsed[i].distanceKm,
          durationMin: parsed[i].durationMin,
          points: parsed[i].points,
          steps: parsed[i].steps,
          isFastest: i == fastestIdx,
          isShortest: i == shortestIdx,
        ),
    ];
  }

  static List<RouteStepInstruction> _parseSteps(dynamic rawLegs) {
    if (rawLegs is! List) return const [];
    final steps = <RouteStepInstruction>[];
    for (final leg in rawLegs) {
      if (leg is! Map || leg['steps'] is! List) continue;
      for (final s in (leg['steps'] as List)) {
        if (s is! Map) continue;
        final maneuver = s['maneuver'] is Map ? s['maneuver'] as Map : const {};
        final loc = maneuver['location'] as List?;
        if (loc == null || loc.length < 2) continue;
        final type = (maneuver['type'] ?? '').toString();
        final modifier = (maneuver['modifier'] ?? '').toString();
        final name = (s['name'] ?? '').toString().trim();
        steps.add(
          RouteStepInstruction(
            instructionText: formatArabicInstruction(
              type: type,
              modifier: modifier,
              streetName: name,
            ),
            streetName: name,
            distanceMeters: (s['distance'] as num?)?.toDouble() ?? 0,
            durationSeconds: (s['duration'] as num?)?.toDouble() ?? 0,
            maneuverPoint: LatLng(
              (loc[1] as num).toDouble(),
              (loc[0] as num).toDouble(),
            ),
            maneuverType: type,
            modifier: modifier,
          ),
        );
      }
    }
    return steps;
  }

  static String formatArabicInstruction({
    required String type,
    required String modifier,
    required String streetName,
  }) {
    final streetSuffix = streetName.isEmpty ? '' : ' إلى $streetName';
    if (type == 'depart') return 'انطلق$streetSuffix';
    if (type == 'arrive') return 'الوصول إلى وجهة الزبون';
    if (type == 'roundabout' || type == 'rotary') {
      return 'ادخل الدوار ثم اتجه$streetSuffix';
    }
    switch (modifier) {
      case 'right':
      case 'slight right':
      case 'sharp right':
        return 'اتجه يميناً$streetSuffix';
      case 'left':
      case 'slight left':
      case 'sharp left':
        return 'اتجه يساراً$streetSuffix';
      case 'uturn':
        return 'استدر للخلف (U-Turn)$streetSuffix';
      default:
        return 'استمر للأمام$streetSuffix';
    }
  }

  /// Computes progress, remaining distance/ETA, off-route status, and next step.
  static NavigationProgressSnapshot computeProgress({
    required LatLng current,
    required CaptainRouteOption route,
  }) {
    if (route.points.isEmpty) {
      return const NavigationProgressSnapshot(
        progress: 0,
        remainingKm: 0,
        remainingMin: 0,
        distanceToRouteMeters: 0,
        isOffRoute: false,
      );
    }

    var nearestIdx = 0;
    var minDistM = double.infinity;
    for (var i = 0; i < route.points.length; i++) {
      final d = _geo.as(LengthUnit.Meter, current, route.points[i]);
      if (d < minDistM) {
        minDistM = d;
        nearestIdx = i;
      }
    }

    var remainingMeters = 0.0;
    for (var i = nearestIdx; i < route.points.length - 1; i++) {
      remainingMeters += _geo.as(
        LengthUnit.Meter,
        route.points[i],
        route.points[i + 1],
      );
    }

    final totalMeters = math.max(1.0, route.distanceKm * 1000.0);
    final progress = (1.0 - (remainingMeters / totalMeters)).clamp(0.0, 1.0);
    final remainingKm = remainingMeters / 1000.0;
    final remainingMin = (route.durationMin * (1.0 - progress)).clamp(
      0.0,
      route.durationMin,
    );

    RouteStepInstruction? nextStep;
    RouteStepInstruction? followingStep;
    double distToNextM = 0;
    String dynamicInstruction = '';
    String? speechKey;

    if (route.steps.isNotEmpty) {
      var nextStepIdx = -1;
      for (var i = 0; i < route.steps.length; i++) {
        final step = route.steps[i];
        if (step.maneuverType == 'depart') continue;
        final dStep = _geo.as(LengthUnit.Meter, current, step.maneuverPoint);
        if (dStep > 15 || step.maneuverType == 'arrive') {
          nextStep = step;
          distToNextM = dStep;
          nextStepIdx = i;
          break;
        }
      }
      if (nextStep == null) {
        nextStep = route.steps.last;
        nextStepIdx = route.steps.length - 1;
        distToNextM = _geo.as(
          LengthUnit.Meter,
          current,
          nextStep.maneuverPoint,
        );
      }
      if (nextStepIdx + 1 < route.steps.length) {
        followingStep = route.steps[nextStepIdx + 1];
      }

      if (distToNextM <= 35) {
        dynamicInstruction = 'انعطف الآن: ${nextStep.instructionText}';
        speechKey = '${nextStepIdx}_now';
      } else if (distToNextM <= 120) {
        dynamicInstruction = 'استعد للانعطاف: ${nextStep.instructionText}';
        speechKey = '${nextStepIdx}_prep';
      } else {
        final roundedM = (distToNextM / 50).round() * 50;
        final distLabel = roundedM >= 1000
            ? '${(roundedM / 1000).toStringAsFixed(1)} كم'
            : '$roundedM متر';
        dynamicInstruction = 'بعد $distLabel: ${nextStep.instructionText}';
        speechKey = '${nextStepIdx}_far';
      }
    }

    return NavigationProgressSnapshot(
      progress: progress,
      remainingKm: remainingKm,
      remainingMin: remainingMin,
      distanceToRouteMeters: minDistM,
      isOffRoute: minDistM > offRouteThresholdMeters,
      nextStep: nextStep,
      followingStep: followingStep,
      distanceToNextStepMeters: distToNextM,
      dynamicInstruction: dynamicInstruction,
      speechKey: speechKey,
    );
  }

  /// Converts GPS speed in m/s to rounded km/h, suppressing stationary jitter.
  static int speedKmh(double speedMps) {
    if (speedMps.isNaN || speedMps <= 0.6) return 0;
    return (speedMps * 3.6).round();
  }
}

/// Filters GPS noise before confirming off-route rerouting.
class OffRouteDetector {
  OffRouteDetector({
    this.maxAcceptableAccuracyMeters = 45,
    this.consecutiveSamplesRequired = 2,
  });

  final double maxAcceptableAccuracyMeters;
  final int consecutiveSamplesRequired;
  int _consecutiveOffRoute = 0;

  void reset() => _consecutiveOffRoute = 0;

  /// Returns `true` only when enough accurate consecutive samples are off-route.
  bool evaluate({
    required bool isSampleOffRoute,
    double accuracyMeters = 0,
  }) {
    if (accuracyMeters > maxAcceptableAccuracyMeters) {
      return false;
    }
    if (!isSampleOffRoute) {
      _consecutiveOffRoute = 0;
      return false;
    }
    _consecutiveOffRoute++;
    return _consecutiveOffRoute >= consecutiveSamplesRequired;
  }
}
