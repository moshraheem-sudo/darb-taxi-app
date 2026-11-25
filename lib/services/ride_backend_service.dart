import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../models/ride_models.dart';
import 'captain_photo_service.dart';
import 'notification_center.dart';
import 'ride_repositories.dart';

class RideConflictException implements Exception {
  const RideConflictException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Unified REST + Socket.IO + Local Dispatch Bridge for both Passenger & Captain.
///
/// When `api_base_url` is configured in Settings, all auth, ride creation,
/// atomic acceptance, status updates, and GPS tracking go through the live
/// backend server + Socket.IO real-time channel.
///
/// When no backend URL is configured (Developer Free Access / offline testing),
/// the local dispatch bus (`_localRideController` + `SharedPreferences`)
/// coordinates Passenger <-> Captain transitions end-to-end on the device.
class RideBackendService
    implements AuthRepository, CaptainRepository, RideDispatchRepository {
  RideBackendService._() {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onError: (err, handler) async {
          final path = err.requestOptions.path;
          final alreadyRetried = err.requestOptions.extra['_retried'] == true;
          if (err.response?.statusCode == 401 &&
              !alreadyRetried &&
              !path.contains('/auth/')) {
            final newToken = await refreshSession();
            if (newToken != null) {
              final opts = err.requestOptions;
              opts.extra['_retried'] = true;
              opts.headers['Authorization'] = 'Bearer $newToken';
              try {
                final retryRes = await _dio.fetch(opts);
                return handler.resolve(retryRes);
              } catch (_) {}
            }
          }
          handler.next(err);
        },
      ),
    );
  }
  static final RideBackendService instance = RideBackendService._();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 12),
    ),
  );
  static const _secureStorage = FlutterSecureStorage();
  static const _accessTokenKey = 'passenger_access_token';
  static const _refreshTokenKey = 'darb_refresh_token';

  io.Socket? _socket;
  final Set<String> _seenRideIds = <String>{};

  final _incomingRequestsController =
      StreamController<RideRequestPayload>.broadcast();
  final _rideUpdatesController =
      StreamController<RideRequestPayload>.broadcast();
  final _driverLocationController = StreamController<LatLng>.broadcast();
  final _rideClaimedController = StreamController<String>.broadcast();

  @override
  Stream<RideRequestPayload> get incomingRequests =>
      _incomingRequestsController.stream;
  @override
  Stream<RideRequestPayload> get rideUpdates => _rideUpdatesController.stream;
  @override
  Stream<LatLng> get driverLocations => _driverLocationController.stream;
  @override
  Stream<String> get claimedRideIds => _rideClaimedController.stream;

  static const _localActiveRideKey = 'darb_local_active_dispatch_v1';
  static const _localCaptainProfileKey = 'darb_captain_profile_v1';
  static const _localCaptainTripsKey = 'darb_captain_completed_rides_v1';

  Future<String?> configuredBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString('api_base_url')?.trim();
    if (value == null || value.isEmpty) return null;
    return value.replaceFirst(RegExp(r'/+$'), '');
  }

  Future<String?> _token() async {
    try {
      return await _secureStorage.read(key: 'passenger_access_token');
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Real-time Socket.IO Connection
  // ---------------------------------------------------------------------------

  @override
  Future<void> connectRealtime({required UserRole role}) async {
    final base = await configuredBaseUrl();
    if (base == null) return;
    final token = await _token();

    _socket?.dispose();
    _socket = io.io(
      base,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .enableAutoConnect()
          .enableReconnection()
          .setReconnectionAttempts(999)
          .setReconnectionDelay(2000)
          .setAuth({'token': token ?? '', 'role': userRoleToString(role)})
          .build(),
    );

    _socket!.on('ride:new_request', (data) {
      if (data is Map) {
        final payload = RideRequestPayload.fromJson(
          Map<String, dynamic>.from(data),
        );
        if (_seenRideIds.add(payload.rideId)) {
          _incomingRequestsController.add(payload);
          unawaited(
            NotificationCenterService.addCaptainAlert(
              title: 'طلب رحلة جديد (${payload.fareIqd} د.ع)',
              body: '${payload.originName} -> ${payload.destinationName}',
            ),
          );
        }
      }
    });

    _socket!.on('ride:claimed', (data) {
      final rideId = data is Map ? data['ride_id']?.toString() : data?.toString();
      if (rideId != null && rideId.isNotEmpty) {
        _rideClaimedController.add(rideId);
      }
    });

    _socket!.on('ride:status_changed', (data) {
      if (data is Map) {
        final payload = RideRequestPayload.fromJson(
          Map<String, dynamic>.from(data),
        );
        _rideUpdatesController.add(payload);
      }
    });

    _socket!.on('driver:location_update', (data) {
      if (data is Map && data['lat'] != null && data['lng'] != null) {
        _driverLocationController.add(
          LatLng(
            (data['lat'] as num).toDouble(),
            (data['lng'] as num).toDouble(),
          ),
        );
      }
    });

    _socket!.onConnect((_) {
      _socket?.emit('ride:sync', {});
    });

    _socket!.onReconnect((_) {
      _socket?.emit('ride:sync', {});
    });

    _socket!.onConnectError((err) {
      debugPrint('Socket.IO connect error: $err');
    });
  }

  @override
  void disconnectRealtime() {
    _socket?.dispose();
    _socket = null;
  }

  // ---------------------------------------------------------------------------
  // Unified Auth (Customer & Captain)
  // ---------------------------------------------------------------------------

  @override
  Future<void> requestOtp({
    required String name,
    required String phone,
    required UserRole role,
  }) async {
    final base = await configuredBaseUrl();
    if (base == null) {
      throw StateError('أضف عنوان خادم الخدمة من الإعدادات أولاً.');
    }
    await _dio.post(
      '$base/auth/otp/request',
      data: {
        'full_name': name,
        'phone': phone,
        'role': userRoleToString(role),
      },
    );
  }

  @override
  Future<void> verifyOtp({
    required String phone,
    required String code,
    required UserRole role,
  }) async {
    final base = await configuredBaseUrl();
    if (base == null) {
      throw StateError('أضف عنوان خادم الخدمة من الإعدادات أولاً.');
    }
    final response = await _dio.post(
      '$base/auth/otp/verify',
      data: {
        'phone': phone,
        'code': code,
        'role': userRoleToString(role),
      },
    );
    final token = response.data is Map
        ? (response.data['access_token'] as String?)
        : null;
    if (token == null || token.isEmpty) {
      throw const FormatException('لم يُرجع الخادم رمز الدخول المتوقع.');
    }
    await _secureStorage.write(key: _accessTokenKey, value: token);
    final refreshToken = response.data is Map
        ? (response.data['refresh_token'] as String?)
        : null;
    if (refreshToken != null && refreshToken.isNotEmpty) {
      await _secureStorage.write(key: _refreshTokenKey, value: refreshToken);
    }
  }

  Future<String?> refreshSession() async {
    final base = await configuredBaseUrl();
    if (base == null) return null;
    String? refreshToken;
    try {
      refreshToken = await _secureStorage.read(key: _refreshTokenKey);
    } catch (_) {}
    if (refreshToken == null || refreshToken.isEmpty) return null;

    try {
      final prefs = await SharedPreferences.getInstance();
      final role = prefs.getString('user_role') ?? 'passenger';
      final response = await _dio.post(
        '$base/auth/token/refresh',
        data: {'refresh_token': refreshToken, 'role': role},
      );
      if (response.data is Map) {
        final nextAccess = response.data['access_token'] as String?;
        final nextRefresh = response.data['refresh_token'] as String?;
        if (nextAccess != null && nextAccess.isNotEmpty) {
          await _secureStorage.write(key: _accessTokenKey, value: nextAccess);
        }
        if (nextRefresh != null && nextRefresh.isNotEmpty) {
          await _secureStorage.write(key: _refreshTokenKey, value: nextRefresh);
        }
        return nextAccess;
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<void> clearSession() async {
    disconnectRealtime();
    try {
      final base = await configuredBaseUrl();
      final refreshToken = await _secureStorage.read(key: _refreshTokenKey);
      if (base != null && refreshToken != null && refreshToken.isNotEmpty) {
        await _dio.post(
          '$base/auth/logout',
          data: {'refresh_token': refreshToken},
        );
      }
    } catch (_) {}
    try {
      await _secureStorage.delete(key: _accessTokenKey);
      await _secureStorage.delete(key: _refreshTokenKey);
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('passenger_logged_in', false);
  }

  Future<void> registerFcmToken(String fcmToken) async {
    final base = await configuredBaseUrl();
    final token = await _token();
    if (base == null || token == null) return;
    try {
      await _dio.post(
        '$base/notifications/fcm-token',
        data: {'fcm_token': fcmToken},
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
    } catch (_) {
      // Non-fatal: retry on next session
    }
  }

  // ---------------------------------------------------------------------------
  // Captain Profile, Documents & Availability
  // ---------------------------------------------------------------------------

  @override
  Future<CaptainProfile> loadCaptainProfile() async {
    final base = await configuredBaseUrl();
    final token = await _token();
    if (base != null && token != null) {
      try {
        final response = await _dio.get(
          '$base/captain/profile',
          options: Options(headers: {'Authorization': 'Bearer $token'}),
        );
        if (response.data is Map) {
          final profile = CaptainProfile.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          );
          await _saveLocalCaptainProfile(profile);
          return profile;
        }
      } catch (_) {
        // Fallback to cached profile if offline
      }
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_localCaptainProfileKey);
    if (raw != null) {
      try {
        return CaptainProfile.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map),
        );
      } catch (_) {}
    }
    final name = prefs.getString('passenger_name') ?? 'كابتن درب';
    final phone = prefs.getString('passenger_phone') ?? '';
    return CaptainProfile(
      id: 'captain_local',
      fullName: name,
      phone: phone,
    );
  }

  Future<void> _saveLocalCaptainProfile(CaptainProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _localCaptainProfileKey,
      jsonEncode(profile.toJson()),
    );
  }

  @override
  Future<CaptainProfile> saveCaptainProfile(CaptainProfile profile) async {
    final base = await configuredBaseUrl();
    final token = await _token();
    final updated = profile.copyWith(
      approvalStatus:
          profile.approvalStatus == CaptainApprovalStatus.unsubmitted &&
              profile.hasRequiredInfo
          ? CaptainApprovalStatus.pending
          : profile.approvalStatus,
    );

    if (base != null && token != null) {
      final response = await _dio.post(
        '$base/captain/profile',
        data: updated.toJson(),
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      if (response.data is Map) {
        final remote = CaptainProfile.fromJson(
          Map<String, dynamic>.from(response.data as Map),
        );
        await _saveLocalCaptainProfile(remote);
        return remote;
      }
    }

    await _saveLocalCaptainProfile(updated);
    return updated;
  }

  @override
  Future<CaptainProfile> uploadCaptainDocument({
    required CaptainProfile current,
    required String docKey,
    required String filePath,
  }) async {
    final base = await configuredBaseUrl();
    final token = await _token();
    if (base != null && token != null) {
      final form = FormData.fromMap({
        'doc_type': docKey,
        'file': await MultipartFile.fromFile(filePath),
      });
      await _dio.post(
        '$base/captain/documents',
        data: form,
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
    }

    final nextDocs = Map<String, String>.from(current.documents);
    nextDocs[docKey] = filePath;
    final nextStatus =
        current.approvalStatus == CaptainApprovalStatus.unsubmitted &&
            current.hasRequiredInfo &&
            nextDocs.isNotEmpty
        ? CaptainApprovalStatus.pending
        : current.approvalStatus;
    final updated = current.copyWith(
      documents: nextDocs,
      approvalStatus: nextStatus,
    );
    await _saveLocalCaptainProfile(updated);
    return updated;
  }

  @override
  Future<CaptainProfile> setCaptainOnline({
    required CaptainProfile current,
    required bool online,
    LatLng? position,
  }) async {
    final base = await configuredBaseUrl();
    final token = await _token();
    if (base != null && token != null) {
      await _dio.post(
        '$base/captain/availability',
        data: {
          'is_online': online,
          if (position != null) 'lat': position.latitude,
          if (position != null) 'lng': position.longitude,
        },
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      if (online) {
        await connectRealtime(role: UserRole.captain);
      }
    }
    final updated = current.copyWith(isOnline: online);
    await _saveLocalCaptainProfile(updated);
    return updated;
  }

  Future<void> publishCaptainLocation({
    required LatLng position,
    double heading = 0,
    String? activeRideId,
  }) async {
    _driverLocationController.add(position);
    if (_socket?.connected == true) {
      _socket!.emit('captain:location', {
        'lat': position.latitude,
        'lng': position.longitude,
        'heading': heading,
        'ride_id': ?activeRideId,
      });
    }
    final base = await configuredBaseUrl();
    final token = await _token();
    if (base != null && token != null) {
      try {
        await _dio.post(
          '$base/captain/location',
          data: {
            'lat': position.latitude,
            'lng': position.longitude,
            'heading': heading,
            'ride_id': ?activeRideId,
          },
          options: Options(headers: {'Authorization': 'Bearer $token'}),
        );
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------------
  // Ride Lifecycle: Create -> Dispatch -> Atomic Accept -> Status -> Complete
  // ---------------------------------------------------------------------------

  @override
  Future<RideRequestPayload> createRideRequest(
    RideRequestPayload request,
  ) async {
    final base = await configuredBaseUrl();
    final token = await _token();
    if (base != null && token != null) {
      final response = await _dio.post(
        '$base/rides',
        data: request.toJson(),
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Idempotency-Key': request.rideId,
          },
        ),
      );
      await connectRealtime(role: UserRole.passenger);
      if (response.data is Map) {
        return RideRequestPayload.fromJson(
          Map<String, dynamic>.from(response.data as Map),
        );
      }
      return request;
    }

    // Local Dispatch Bus (Developer / Offline Mode)
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localActiveRideKey, jsonEncode(request.toJson()));
    _seenRideIds.add(request.rideId);
    _incomingRequestsController.add(request);
    _rideUpdatesController.add(request);
    return request;
  }

  Future<RideRequestPayload?> loadPendingLocalRide() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_localActiveRideKey);
    if (raw == null) return null;
    try {
      return RideRequestPayload.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  /// Atomically claims a ride for [captain].
  /// Throws [RideConflictException] if another captain already claimed it.
  @override
  Future<RideRequestPayload> acceptRideAtomic({
    required RideRequestPayload request,
    required CaptainProfile captain,
  }) async {
    final base = await configuredBaseUrl();
    final token = await _token();
    if (base != null && token != null) {
      try {
        final response = await _dio.post(
          '$base/rides/${request.rideId}/accept',
          data: {
            'captain_id': captain.id,
            'expected_version': request.version,
          },
          options: Options(headers: {'Authorization': 'Bearer $token'}),
        );
        if (response.data is Map) {
          final updated = RideRequestPayload.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          );
          _rideUpdatesController.add(updated);
          return updated;
        }
      } on DioException catch (err) {
        if (err.response?.statusCode == 409) {
          throw const RideConflictException(
            'تم قبول هذا الطلب من كابتن آخر للتو.',
          );
        }
        rethrow;
      }
    }

    // Local atomic check
    final current = await loadPendingLocalRide();
    if (current != null &&
        current.rideId == request.rideId &&
        current.status != RideDispatchStatus.searching) {
      throw const RideConflictException(
        'تم قبول هذا الطلب من كابتن آخر للتو.',
      );
    }

    final carDesc = [
      captain.carColor.trim(),
      captain.carModel.trim(),
    ].where((s) => s.isNotEmpty).join(' ');

    final updated = request.copyWith(
      status: RideDispatchStatus.accepted,
      captainId: captain.id.isEmpty ? 'captain_local' : captain.id,
      captainName: captain.fullName.isEmpty ? 'محمد ناصر ليهوب' : captain.fullName,
      captainPhone: captain.phone,
      captainCar: carDesc.isEmpty ? 'أبيض Kia Optima' : carDesc,
      captainPlate: captain.plateNumber,
      captainRating: captain.rating,
      captainPhotoUrl: CaptainPhotoService.isRemotePhotoUrl(captain.photoUrl)
          ? captain.photoUrl
          : null,
      version: request.version + 1,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localActiveRideKey, jsonEncode(updated.toJson()));
    _rideClaimedController.add(updated.rideId);
    _rideUpdatesController.add(updated);
    return updated;
  }

  @override
  Future<void> rejectRide({
    required String rideId,
    required String captainId,
  }) async {
    final base = await configuredBaseUrl();
    final token = await _token();
    if (base != null && token != null) {
      await _dio.post(
        '$base/rides/$rideId/reject',
        data: {'captain_id': captainId},
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
    }
  }

  /// Generates a realistic local demo ride request near [nearPoint] so
  /// developers can test Captain accept/reject/lifecycle without a live server.
  Future<RideRequestPayload> triggerLocalDemoRequest(LatLng nearPoint) async {
    final demo = RideRequestPayload(
      rideId: 'demo_${DateTime.now().millisecondsSinceEpoch}',
      passengerName: 'أحمد كريم (طلب تجريبي)',
      passengerPhone: '+9647712345678',
      originLat: nearPoint.latitude + 0.004,
      originLng: nearPoint.longitude + 0.003,
      originName: 'الكوت، حي الزهراء (تجريبي)',
      destinationLat: nearPoint.latitude + 0.015,
      destinationLng: nearPoint.longitude + 0.014,
      destinationName: 'الكوت، شارع الضفاف (تجريبي)',
      fareIqd: 1500,
      distanceKm: 2.8,
      durationMin: 7,
      createdAt: DateTime.now(),
    );
    return createRideRequest(demo);
  }

  @override
  Future<RideRequestPayload> updateRideStatus({
    required RideRequestPayload request,
    required RideDispatchStatus nextStatus,
  }) async {
    if (!RideStateMachine.canTransition(request.status, nextStatus)) {
      throw StateError(
        'انتقال غير صالح من ${RideStateMachine.label(request.status)} إلى ${RideStateMachine.label(nextStatus)}',
      );
    }
    final base = await configuredBaseUrl();
    final token = await _token();
    if (base != null && token != null) {
      final response = await _dio.patch(
        '$base/rides/${request.rideId}/status',
        data: {'status': dispatchStatusToString(nextStatus)},
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      if (response.data is Map) {
        final updated = RideRequestPayload.fromJson(
          Map<String, dynamic>.from(response.data as Map),
        );
        _rideUpdatesController.add(updated);
        return updated;
      }
    }

    final updated = request.copyWith(
      status: nextStatus,
      version: request.version + 1,
    );
    final prefs = await SharedPreferences.getInstance();
    if (nextStatus == RideDispatchStatus.completed ||
        nextStatus == RideDispatchStatus.cancelled) {
      await prefs.remove(_localActiveRideKey);
    } else {
      await prefs.setString(_localActiveRideKey, jsonEncode(updated.toJson()));
    }
    _rideUpdatesController.add(updated);
    return updated;
  }

  Future<void> recordCaptainCompletedTrip(
    RideRequestPayload trip,
    CaptainProfile captain,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_localCaptainTripsKey);
    final List<dynamic> list = raw == null
        ? <dynamic>[]
        : (jsonDecode(raw) as List<dynamic>);
    list.insert(0, {
      'ride_id': trip.rideId,
      'date': DateTime.now().toIso8601String(),
      'passenger_name': trip.passengerName,
      'origin': trip.originName,
      'destination': trip.destinationName,
      'fare_iqd': trip.fareIqd,
      'distance_km': trip.distanceKm,
    });
    await prefs.setString(
      _localCaptainTripsKey,
      jsonEncode(list.take(100).toList()),
    );
    final updatedProfile = captain.copyWith(
      totalTrips: captain.totalTrips + 1,
      totalEarnings: captain.totalEarnings + trip.fareIqd,
    );
    await _saveLocalCaptainProfile(updatedProfile);
  }

  @override
  Future<RideRequestPayload?> fetchActiveRide() async {
    final base = await configuredBaseUrl();
    if (base != null) {
      final token = await _token();
      if (token != null) {
        try {
          final response = await _dio.get(
            '$base/rides/active',
            options: Options(headers: {'Authorization': 'Bearer $token'}),
          );
          if (response.data is Map) {
            return RideRequestPayload.fromJson(
              Map<String, dynamic>.from(response.data as Map),
            );
          }
          return null;
        } catch (_) {}
      }
    }
    return loadPendingLocalRide();
  }

  @override
  Future<void> submitRideRating({
    required String rideId,
    required int stars,
    String? comment,
  }) async {
    final base = await configuredBaseUrl();
    final token = await _token();
    if (base == null || token == null) return;
    await _dio.post(
      '$base/rides/$rideId/rate',
      data: {
        'stars': stars,
        if (comment != null && comment.trim().isNotEmpty)
          'comment': comment.trim(),
      },
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
  }

  @override
  Future<List<Map<String, dynamic>>> loadPassengerHistory() async {
    final base = await configuredBaseUrl();
    if (base != null) {
      final token = await _token();
      if (token != null) {
        try {
          final response = await _dio.get(
            '$base/passenger/rides',
            options: Options(headers: {'Authorization': 'Bearer $token'}),
          );
          if (response.data is List) {
            return (response.data as List)
                .whereType<Map>()
                .map((m) => Map<String, dynamic>.from(m))
                .toList();
          }
        } catch (_) {}
      }
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('darb_completed_rides');
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .whereType<Map>()
          .map((ride) => Map<String, dynamic>.from(ride))
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<List<Map<String, dynamic>>> loadCaptainHistory() async {
    final base = await configuredBaseUrl();
    final token = await _token();
    if (base != null && token != null) {
      try {
        final response = await _dio.get(
          '$base/captain/rides',
          options: Options(headers: {'Authorization': 'Bearer $token'}),
        );
        if (response.data is List) {
          return (response.data as List)
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList();
        }
      } catch (_) {}
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_localCaptainTripsKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
