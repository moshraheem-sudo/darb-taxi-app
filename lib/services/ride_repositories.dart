import 'package:latlong2/latlong.dart';

import '../models/ride_models.dart';

/// Authentication & session contract for both Passenger and Captain accounts.
abstract class AuthRepository {
  Future<void> requestOtp({
    required String name,
    required String phone,
    required UserRole role,
  });

  Future<void> verifyOtp({
    required String phone,
    required String code,
    required UserRole role,
  });

  Future<void> clearSession();
}

/// Captain profile, document verification, availability, and earnings contract.
abstract class CaptainRepository {
  Future<CaptainProfile> loadCaptainProfile();
  Future<CaptainProfile> saveCaptainProfile(CaptainProfile profile);
  Future<CaptainProfile> uploadCaptainDocument({
    required CaptainProfile current,
    required String docKey,
    required String filePath,
  });
  Future<CaptainProfile> setCaptainOnline({
    required CaptainProfile current,
    required bool online,
    LatLng? position,
  });
  Future<List<Map<String, dynamic>>> loadCaptainHistory();
}

/// Real-time ride request, atomic acceptance, status transition, and tracking contract.
abstract class RideDispatchRepository {
  Stream<RideRequestPayload> get incomingRequests;
  Stream<RideRequestPayload> get rideUpdates;
  Stream<LatLng> get driverLocations;
  Stream<String> get claimedRideIds;

  Future<void> connectRealtime({required UserRole role});
  void disconnectRealtime();

  Future<RideRequestPayload> createRideRequest(RideRequestPayload request);
  Future<RideRequestPayload> acceptRideAtomic({
    required RideRequestPayload request,
    required CaptainProfile captain,
  });
  Future<void> rejectRide({required String rideId, required String captainId});
  Future<RideRequestPayload> updateRideStatus({
    required RideRequestPayload request,
    required RideDispatchStatus nextStatus,
  });
  Future<RideRequestPayload?> fetchActiveRide();
  Future<void> submitRideRating({
    required String rideId,
    required int stars,
    String? comment,
  });
  Future<List<Map<String, dynamic>>> loadPassengerHistory();
}

/// Abstraction for device GPS & background location updates (ready for live tracking).
abstract class LocationServiceInterface {
  Future<UserLocation> getCurrentUserLocation();
  Stream<UserLocation> watchUserLocation({
    int distanceFilterMeters = 5,
    bool highPrecision = true,
  });
  double distanceKm(LatLng from, LatLng to);
}

/// Abstraction for local + FCM push notifications.
abstract class NotificationServiceInterface {
  Future<void> initialize();
  Future<void> notify({
    required String title,
    required String body,
    String kind = 'general',
  });
  Future<void> notifyCaptainRequest({
    required String title,
    required String body,
  });
  Future<void> registerPushToken(String token);
}
