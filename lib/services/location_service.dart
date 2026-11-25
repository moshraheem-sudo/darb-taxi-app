import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models/ride_models.dart';
import 'ride_repositories.dart';

/// Concrete GPS location service backed by [Geolocator].
/// Designed behind [LocationServiceInterface] so Passenger & Captain modules
/// share one tested permission/stream implementation.
class GeolocatorLocationService implements LocationServiceInterface {
  GeolocatorLocationService._();
  static final GeolocatorLocationService instance =
      GeolocatorLocationService._();

  static const Distance _distance = Distance();

  Future<void> _ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw Exception('فعّل خدمة الموقع من إعدادات الجهاز.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw Exception('إذن الموقع غير متاح. يمكنك تحديد الموقع يدوياً من الخريطة.');
    }
  }

  @override
  Future<UserLocation> getCurrentUserLocation() async {
    await _ensurePermission();
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 12),
      ),
    );
    return UserLocation(
      latitude: position.latitude,
      longitude: position.longitude,
      heading: position.heading,
      updatedAt: DateTime.now(),
    );
  }

  @override
  Stream<UserLocation> watchUserLocation({int distanceFilterMeters = 5}) {
    return Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilterMeters,
      ),
    ).map(
      (pos) => UserLocation(
        latitude: pos.latitude,
        longitude: pos.longitude,
        heading: pos.heading,
        updatedAt: DateTime.now(),
      ),
    );
  }

  @override
  double distanceKm(LatLng from, LatLng to) =>
      _distance.as(LengthUnit.Kilometer, from, to);
}
