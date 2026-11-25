import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

class FocusedMapPin {
  const FocusedMapPin(this.point, {this.label = ''});
  final LatLng point;
  final String label;
}

final ValueNotifier<FocusedMapPin?> focusedMapPin =
    ValueNotifier<FocusedMapPin?>(null);

final ValueNotifier<FocusedMapPin?> captainIncomingDestination =
    ValueNotifier<FocusedMapPin?>(null);

enum UserRole { passenger, captain }

enum CaptainApprovalStatus { unsubmitted, pending, approved, rejected }

enum RideDispatchStatus {
  searching,
  accepted,
  arrived,
  inProgress,
  completed,
  cancelled,
}

String userRoleToString(UserRole role) =>
    role == UserRole.captain ? 'captain' : 'passenger';

UserRole userRoleFromString(String? value) =>
    value == 'captain' ? UserRole.captain : UserRole.passenger;

String approvalStatusToString(CaptainApprovalStatus status) {
  switch (status) {
    case CaptainApprovalStatus.unsubmitted:
      return 'unsubmitted';
    case CaptainApprovalStatus.pending:
      return 'pending';
    case CaptainApprovalStatus.approved:
      return 'approved';
    case CaptainApprovalStatus.rejected:
      return 'rejected';
  }
}

CaptainApprovalStatus approvalStatusFromString(String? value) {
  switch (value) {
    case 'pending':
      return CaptainApprovalStatus.pending;
    case 'approved':
      return CaptainApprovalStatus.approved;
    case 'rejected':
      return CaptainApprovalStatus.rejected;
    default:
      return CaptainApprovalStatus.unsubmitted;
  }
}

String dispatchStatusToString(RideDispatchStatus status) {
  switch (status) {
    case RideDispatchStatus.searching:
      return 'searching';
    case RideDispatchStatus.accepted:
      return 'accepted';
    case RideDispatchStatus.arrived:
      return 'arrived';
    case RideDispatchStatus.inProgress:
      return 'in_progress';
    case RideDispatchStatus.completed:
      return 'completed';
    case RideDispatchStatus.cancelled:
      return 'cancelled';
  }
}

RideDispatchStatus dispatchStatusFromString(String? value) {
  switch (value) {
    case 'accepted':
      return RideDispatchStatus.accepted;
    case 'arrived':
      return RideDispatchStatus.arrived;
    case 'in_progress':
      return RideDispatchStatus.inProgress;
    case 'completed':
      return RideDispatchStatus.completed;
    case 'cancelled':
      return RideDispatchStatus.cancelled;
    default:
      return RideDispatchStatus.searching;
  }
}

/// Enforces valid, consistent ride state transitions between Passenger and Captain.
class RideStateMachine {
  const RideStateMachine._();

  static const Map<RideDispatchStatus, Set<RideDispatchStatus>> _allowed = {
    RideDispatchStatus.searching: {
      RideDispatchStatus.accepted,
      RideDispatchStatus.cancelled,
    },
    RideDispatchStatus.accepted: {
      RideDispatchStatus.arrived,
      RideDispatchStatus.cancelled,
    },
    RideDispatchStatus.arrived: {
      RideDispatchStatus.inProgress,
      RideDispatchStatus.cancelled,
    },
    RideDispatchStatus.inProgress: {
      RideDispatchStatus.completed,
      RideDispatchStatus.cancelled,
    },
    RideDispatchStatus.completed: {},
    RideDispatchStatus.cancelled: {},
  };

  static bool canTransition(
    RideDispatchStatus from,
    RideDispatchStatus to,
  ) => _allowed[from]?.contains(to) ?? false;

  static RideDispatchStatus? nextCaptainStep(RideDispatchStatus current) {
    switch (current) {
      case RideDispatchStatus.accepted:
        return RideDispatchStatus.arrived;
      case RideDispatchStatus.arrived:
        return RideDispatchStatus.inProgress;
      case RideDispatchStatus.inProgress:
        return RideDispatchStatus.completed;
      case RideDispatchStatus.searching:
      case RideDispatchStatus.completed:
      case RideDispatchStatus.cancelled:
        return null;
    }
  }

  static String label(RideDispatchStatus status) {
    switch (status) {
      case RideDispatchStatus.searching:
        return 'جارٍ البحث عن كابتن';
      case RideDispatchStatus.accepted:
        return 'تم قبول الطلب';
      case RideDispatchStatus.arrived:
        return 'وصلت إلى الزبون';
      case RideDispatchStatus.inProgress:
        return 'بدأت الرحلة';
      case RideDispatchStatus.completed:
        return 'انتهت الرحلة';
      case RideDispatchStatus.cancelled:
        return 'ملغاة';
    }
  }
}

class UserLocation {
  const UserLocation({
    required this.latitude,
    required this.longitude,
    this.heading = 0,
    this.speedMps = 0,
    this.accuracyMeters = 0,
    this.address = '',
    this.updatedAt,
  });

  final double latitude;
  final double longitude;
  final double heading;
  final double speedMps;
  final double accuracyMeters;
  final String address;
  final DateTime? updatedAt;

  Map<String, dynamic> toJson() => {
    'lat': latitude,
    'lng': longitude,
    'heading': heading,
    if (speedMps > 0) 'speed_mps': speedMps,
    if (accuracyMeters > 0) 'accuracy_m': accuracyMeters,
    if (address.isNotEmpty) 'address': address,
    if (updatedAt != null) 'updated_at': updatedAt!.toIso8601String(),
  };

  factory UserLocation.fromJson(Map<String, dynamic> json) => UserLocation(
    latitude: (json['lat'] as num).toDouble(),
    longitude: (json['lng'] as num).toDouble(),
    heading: (json['heading'] as num?)?.toDouble() ?? 0,
    speedMps: (json['speed_mps'] as num?)?.toDouble() ?? 0,
    accuracyMeters: (json['accuracy_m'] as num?)?.toDouble() ?? 0,
    address: (json['address'] ?? '').toString(),
    updatedAt: DateTime.tryParse((json['updated_at'] ?? '').toString()),
  );
}

class PassengerProfile {
  const PassengerProfile({
    this.id = '',
    this.fullName = 'زبون درب',
    this.phone = '',
    this.rating = 5.0,
    this.totalTrips = 0,
  });

  final String id;
  final String fullName;
  final String phone;
  final double rating;
  final int totalTrips;

  Map<String, dynamic> toJson() => {
    'id': id,
    'full_name': fullName,
    'phone': phone,
    'rating': rating,
    'total_trips': totalTrips,
  };

  factory PassengerProfile.fromJson(Map<String, dynamic> json) =>
      PassengerProfile(
        id: (json['id'] ?? '').toString(),
        fullName: (json['full_name'] ?? 'زبون درب').toString(),
        phone: (json['phone'] ?? '').toString(),
        rating: (json['rating'] as num?)?.toDouble() ?? 5.0,
        totalTrips: (json['total_trips'] as num?)?.toInt() ?? 0,
      );
}

class VehicleInfo {
  const VehicleInfo({
    this.model = '',
    this.color = '',
    this.plateNumber = '',
    this.tier = 'saver',
    this.year,
  });

  final String model;
  final String color;
  final String plateNumber;
  final String tier;
  final int? year;

  String get displayLabel =>
      [color.trim(), model.trim()].where((s) => s.isNotEmpty).join(' ');

  Map<String, dynamic> toJson() => {
    'model': model,
    'color': color,
    'plate_number': plateNumber,
    'tier': tier,
    if (year != null) 'year': year,
  };

  factory VehicleInfo.fromJson(Map<String, dynamic> json) => VehicleInfo(
    model: (json['model'] ?? json['car_model'] ?? '').toString(),
    color: (json['color'] ?? json['car_color'] ?? '').toString(),
    plateNumber: (json['plate_number'] ?? '').toString(),
    tier: (json['tier'] ?? json['vehicle_tier'] ?? 'saver').toString(),
    year: (json['year'] as num?)?.toInt(),
  );
}

class TripRecord {
  const TripRecord({
    required this.rideId,
    required this.passengerName,
    required this.captainName,
    this.captainPhotoUrl,
    this.captainCar,
    this.captainRating,
    required this.originName,
    required this.destinationName,
    required this.fareIqd,
    this.distanceKm = 0,
    this.rating,
    required this.completedAt,
  });

  final String rideId;
  final String passengerName;
  final String captainName;
  final String? captainPhotoUrl;
  final String? captainCar;
  final double? captainRating;
  final String originName;
  final String destinationName;
  final int fareIqd;
  final double distanceKm;
  final int? rating;
  final DateTime completedAt;

  Map<String, dynamic> toJson() => {
    'ride_id': rideId,
    'passenger_name': passengerName,
    'captain_name': captainName,
    if (captainPhotoUrl != null && captainPhotoUrl!.isNotEmpty)
      'captain_photo_url': captainPhotoUrl,
    if (captainCar != null && captainCar!.isNotEmpty) 'captain_car': captainCar,
    if (captainRating != null) 'captain_rating': captainRating,
    'origin': originName,
    'destination': destinationName,
    'fare_iqd': fareIqd,
    'distance_km': distanceKm,
    if (rating != null) 'rating': rating,
    'date': completedAt.toIso8601String(),
  };

  factory TripRecord.fromJson(Map<String, dynamic> json) => TripRecord(
    rideId: (json['ride_id'] ?? json['id'] ?? '').toString(),
    passengerName: (json['passenger_name'] ?? 'زبون درب').toString(),
    captainName: (json['captain_name'] ?? json['driver'] ?? 'كابتن درب')
        .toString(),
    captainPhotoUrl: json['captain_photo_url']?.toString(),
    captainCar: json['captain_car']?.toString(),
    captainRating: (json['captain_rating'] as num?)?.toDouble(),
    originName: (json['origin'] ?? '').toString(),
    destinationName: (json['destination'] ?? '').toString(),
    fareIqd: (json['fare_iqd'] ?? json['price'] as num?)?.toInt() ?? 0,
    distanceKm: (json['distance_km'] ?? json['kilometers'] as num?)?.toDouble() ?? 0,
    rating: (json['rating'] as num?)?.toInt(),
    completedAt:
        DateTime.tryParse((json['date'] ?? '').toString()) ?? DateTime.now(),
  );
}

class CaptainProfile {
  const CaptainProfile({
    this.id = '',
    this.fullName = '',
    this.phone = '',
    this.photoUrl = '',
    this.localPhotoPath = '',
    this.carModel = '',
    this.carColor = '',
    this.plateNumber = '',
    this.vehicleTier = 'saver',
    this.approvalStatus = CaptainApprovalStatus.unsubmitted,
    this.isOnline = false,
    this.rating = 4.9,
    this.totalTrips = 0,
    this.totalEarnings = 0,
    this.documents = const {},
  });

  final String id;
  final String fullName;
  final String phone;
  final String photoUrl;
  final String localPhotoPath;
  final String carModel;
  final String carColor;
  final String plateNumber;
  final String vehicleTier;
  final CaptainApprovalStatus approvalStatus;
  final bool isOnline;
  final double rating;
  final int totalTrips;
  final int totalEarnings;
  final Map<String, String> documents;

  bool get hasRequiredInfo =>
      fullName.trim().isNotEmpty &&
      carModel.trim().isNotEmpty &&
      plateNumber.trim().isNotEmpty;

  bool get hasProfilePhoto =>
      photoUrl.trim().isNotEmpty || localPhotoPath.trim().isNotEmpty;

  bool get hasAllDocuments =>
      documents.containsKey('nationalId') &&
      documents.containsKey('driverLicense') &&
      documents.containsKey('vehicleReg') &&
      documents.containsKey('carPhoto');

  CaptainProfile copyWith({
    String? id,
    String? fullName,
    String? phone,
    String? photoUrl,
    String? localPhotoPath,
    String? carModel,
    String? carColor,
    String? plateNumber,
    String? vehicleTier,
    CaptainApprovalStatus? approvalStatus,
    bool? isOnline,
    double? rating,
    int? totalTrips,
    int? totalEarnings,
    Map<String, String>? documents,
  }) => CaptainProfile(
    id: id ?? this.id,
    fullName: fullName ?? this.fullName,
    phone: phone ?? this.phone,
    photoUrl: photoUrl ?? this.photoUrl,
    localPhotoPath: localPhotoPath ?? this.localPhotoPath,
    carModel: carModel ?? this.carModel,
    carColor: carColor ?? this.carColor,
    plateNumber: plateNumber ?? this.plateNumber,
    vehicleTier: vehicleTier ?? this.vehicleTier,
    approvalStatus: approvalStatus ?? this.approvalStatus,
    isOnline: isOnline ?? this.isOnline,
    rating: rating ?? this.rating,
    totalTrips: totalTrips ?? this.totalTrips,
    totalEarnings: totalEarnings ?? this.totalEarnings,
    documents: documents ?? this.documents,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'full_name': fullName,
    'phone': phone,
    if (photoUrl.isNotEmpty) 'photo_url': photoUrl,
    if (localPhotoPath.isNotEmpty) 'local_photo_path': localPhotoPath,
    'car_model': carModel,
    'car_color': carColor,
    'plate_number': plateNumber,
    'vehicle_tier': vehicleTier,
    'approval_status': approvalStatusToString(approvalStatus),
    'is_online': isOnline,
    'rating': rating,
    'total_trips': totalTrips,
    'total_earnings': totalEarnings,
    'documents': documents,
  };

  factory CaptainProfile.fromJson(Map<String, dynamic> json) {
    final rawDocs = json['documents'];
    final docs = <String, String>{};
    if (rawDocs is Map) {
      rawDocs.forEach((key, value) {
        if (value != null) docs[key.toString()] = value.toString();
      });
    }
    return CaptainProfile(
      id: (json['id'] ?? '').toString(),
      fullName: (json['full_name'] ?? '').toString(),
      phone: (json['phone'] ?? '').toString(),
      photoUrl: (json['photo_url'] ?? '').toString(),
      localPhotoPath: (json['local_photo_path'] ?? '').toString(),
      carModel: (json['car_model'] ?? '').toString(),
      carColor: (json['car_color'] ?? '').toString(),
      plateNumber: (json['plate_number'] ?? '').toString(),
      vehicleTier: (json['vehicle_tier'] ?? 'saver').toString(),
      approvalStatus: approvalStatusFromString(
        json['approval_status']?.toString(),
      ),
      isOnline: json['is_online'] == true,
      rating: (json['rating'] as num?)?.toDouble() ?? 4.9,
      totalTrips: (json['total_trips'] as num?)?.toInt() ?? 0,
      totalEarnings: (json['total_earnings'] as num?)?.toInt() ?? 0,
      documents: docs,
    );
  }
}

class RideRequestPayload {
  const RideRequestPayload({
    required this.rideId,
    required this.passengerName,
    required this.passengerPhone,
    required this.originLat,
    required this.originLng,
    required this.originName,
    required this.destinationLat,
    required this.destinationLng,
    required this.destinationName,
    this.secondDestinationName,
    this.secondDestinationLat,
    this.secondDestinationLng,
    this.stopWaitMinutes = 0,
    this.roundTrip = false,
    this.serviceCategory = 'taxi',
    this.selectedTier = 'saver',
    required this.fareIqd,
    this.promoCode,
    this.discountAmount = 0,
    this.distanceKm = 0,
    this.durationMin = 0,
    this.status = RideDispatchStatus.searching,
    this.captainId,
    this.captainName,
    this.captainPhone,
    this.captainCar,
    this.captainPlate,
    this.captainRating,
    this.captainPhotoUrl,
    this.version = 1,
    required this.createdAt,
  });

  final String rideId;
  final String passengerName;
  final String passengerPhone;
  final double originLat;
  final double originLng;
  final String originName;
  final double destinationLat;
  final double destinationLng;
  final String destinationName;
  final String? secondDestinationName;
  final double? secondDestinationLat;
  final double? secondDestinationLng;
  final int stopWaitMinutes;
  final bool roundTrip;
  final String serviceCategory;
  final String selectedTier;
  final int fareIqd;
  final String? promoCode;
  final int discountAmount;
  final double distanceKm;
  final double durationMin;
  final RideDispatchStatus status;
  final String? captainId;
  final String? captainName;
  final String? captainPhone;
  final String? captainCar;
  final String? captainPlate;
  final double? captainRating;
  final String? captainPhotoUrl;
  final int version;
  final DateTime createdAt;

  RideRequestPayload copyWith({
    RideDispatchStatus? status,
    String? captainId,
    String? captainName,
    String? captainPhone,
    String? captainCar,
    String? captainPlate,
    double? captainRating,
    String? captainPhotoUrl,
    int? version,
  }) => RideRequestPayload(
    rideId: rideId,
    passengerName: passengerName,
    passengerPhone: passengerPhone,
    originLat: originLat,
    originLng: originLng,
    originName: originName,
    destinationLat: destinationLat,
    destinationLng: destinationLng,
    destinationName: destinationName,
    secondDestinationName: secondDestinationName,
    secondDestinationLat: secondDestinationLat,
    secondDestinationLng: secondDestinationLng,
    stopWaitMinutes: stopWaitMinutes,
    roundTrip: roundTrip,
    serviceCategory: serviceCategory,
    selectedTier: selectedTier,
    fareIqd: fareIqd,
    promoCode: promoCode,
    discountAmount: discountAmount,
    distanceKm: distanceKm,
    durationMin: durationMin,
    status: status ?? this.status,
    captainId: captainId ?? this.captainId,
    captainName: captainName ?? this.captainName,
    captainPhone: captainPhone ?? this.captainPhone,
    captainCar: captainCar ?? this.captainCar,
    captainPlate: captainPlate ?? this.captainPlate,
    captainRating: captainRating ?? this.captainRating,
    captainPhotoUrl: captainPhotoUrl ?? this.captainPhotoUrl,
    version: version ?? this.version,
    createdAt: createdAt,
  );

  Map<String, dynamic> toJson() => {
    'ride_id': rideId,
    'passenger_name': passengerName,
    'passenger_phone': passengerPhone,
    'origin_lat': originLat,
    'origin_lng': originLng,
    'origin_name': originName,
    'destination_lat': destinationLat,
    'destination_lng': destinationLng,
    'destination_name': destinationName,
    if (secondDestinationName != null)
      'second_destination_name': secondDestinationName,
    if (secondDestinationLat != null)
      'second_destination_lat': secondDestinationLat,
    if (secondDestinationLng != null)
      'second_destination_lng': secondDestinationLng,
    'stop_wait_minutes': stopWaitMinutes,
    'round_trip': roundTrip,
    'service_category': serviceCategory,
    'selected_tier': selectedTier,
    'fare_iqd': fareIqd,
    if (promoCode != null && promoCode!.isNotEmpty) 'promo_code': promoCode,
    if (discountAmount > 0) 'discount_iqd': discountAmount,
    'distance_km': distanceKm,
    'duration_min': durationMin,
    'status': dispatchStatusToString(status),
    if (captainId != null) 'captain_id': captainId,
    if (captainName != null) 'captain_name': captainName,
    if (captainPhone != null) 'captain_phone': captainPhone,
    if (captainCar != null) 'captain_car': captainCar,
    if (captainPlate != null) 'captain_plate': captainPlate,
    if (captainRating != null) 'captain_rating': captainRating,
    if (captainPhotoUrl != null && captainPhotoUrl!.isNotEmpty)
      'captain_photo_url': captainPhotoUrl,
    'version': version,
    'created_at': createdAt.toIso8601String(),
  };

  factory RideRequestPayload.fromJson(Map<String, dynamic> json) =>
      RideRequestPayload(
        rideId: (json['ride_id'] ?? json['id'] ?? '').toString(),
        passengerName: (json['passenger_name'] ?? 'زبون درب').toString(),
        passengerPhone: (json['passenger_phone'] ?? '').toString(),
        originLat: (json['origin_lat'] as num).toDouble(),
        originLng: (json['origin_lng'] as num).toDouble(),
        originName: (json['origin_name'] ?? 'نقطة الانطلاق').toString(),
        destinationLat: (json['destination_lat'] as num).toDouble(),
        destinationLng: (json['destination_lng'] as num).toDouble(),
        destinationName: (json['destination_name'] ?? 'الوجهة').toString(),
        secondDestinationName: json['second_destination_name']?.toString(),
        secondDestinationLat: (json['second_destination_lat'] as num?)
            ?.toDouble(),
        secondDestinationLng: (json['second_destination_lng'] as num?)
            ?.toDouble(),
        stopWaitMinutes: (json['stop_wait_minutes'] as num?)?.toInt() ?? 0,
        roundTrip: json['round_trip'] == true,
        serviceCategory: (json['service_category'] ?? 'taxi').toString(),
        selectedTier: (json['selected_tier'] ?? 'saver').toString(),
        fareIqd: (json['final_fare_iqd'] ?? json['fare_iqd'] as num?)?.toInt() ?? 1000,
        promoCode: json['promo_code']?.toString(),
        discountAmount: (json['discount_iqd'] as num?)?.toInt() ?? 0,
        distanceKm: (json['distance_km'] as num?)?.toDouble() ?? 0,
        durationMin: (json['duration_min'] as num?)?.toDouble() ?? 0,
        status: dispatchStatusFromString(json['status']?.toString()),
        captainId: json['captain_id']?.toString(),
        captainName: json['captain_name']?.toString(),
        captainPhone: json['captain_phone']?.toString(),
        captainCar: json['captain_car']?.toString(),
        captainPlate: json['captain_plate']?.toString(),
        captainRating: (json['captain_rating'] as num?)?.toDouble(),
        captainPhotoUrl: json['captain_photo_url']?.toString(),
        version: (json['version'] as num?)?.toInt() ?? 1,
        createdAt:
            DateTime.tryParse((json['created_at'] ?? '').toString()) ??
            DateTime.now(),
      );
}
