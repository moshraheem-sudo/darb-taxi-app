import {
  CaptainApprovalStatus,
  DocType,
  RideDispatchStatus,
  UserRole,
} from '../domain/rideStateMachine';

export class ConflictError extends Error {
  readonly statusCode = 409;
}
export class ForbiddenError extends Error {
  readonly statusCode = 403;
}
export class NotFoundError extends Error {
  readonly statusCode = 404;
}
export class BadRequestError extends Error {
  readonly statusCode = 400;
}
export class UnauthorizedError extends Error {
  readonly statusCode = 401;
}

export interface UserEntity {
  id: string;
  fullName: string;
  phone: string;
  roles: UserRole[];
  passengerRating: number;
  passengerTotalTrips: number;
}

export interface CaptainProfileDto {
  id: string;
  full_name: string;
  phone: string;
  car_model: string;
  car_color: string;
  plate_number: string;
  vehicle_tier: 'saver' | 'plus' | 'box';
  approval_status: CaptainApprovalStatus;
  is_online: boolean;
  rating: number;
  total_trips: number;
  total_earnings: number;
  documents: Partial<Record<DocType, string>>;
}

export interface RideDto {
  ride_id: string;
  passenger_id: string;
  passenger_name: string;
  passenger_phone: string;
  origin_lat: number;
  origin_lng: number;
  origin_name: string;
  destination_lat: number;
  destination_lng: number;
  destination_name: string;
  second_destination_name?: string;
  second_destination_lat?: number;
  second_destination_lng?: number;
  stop_wait_minutes: number;
  round_trip: boolean;
  service_category: 'taxi' | 'box';
  selected_tier: 'saver' | 'plus' | 'box';
  fare_iqd: number;
  discount_iqd: number;
  final_fare_iqd: number;
  distance_km: number;
  duration_min: number;
  status: RideDispatchStatus;
  captain_id?: string;
  captain_name?: string;
  captain_phone?: string;
  captain_car?: string;
  captain_plate?: string;
  captain_rating?: number;
  version: number;
  created_at: string;
}

export interface NearbyCaptainMatch {
  captainId: string;
  distanceMeters: number;
  fcmTokens: string[];
}

export interface CreateRideInput {
  passengerId: string;
  idempotencyKey?: string;
  originLat: number;
  originLng: number;
  originName: string;
  destinationLat: number;
  destinationLng: number;
  destinationName: string;
  secondDestinationName?: string;
  secondDestinationLat?: number;
  secondDestinationLng?: number;
  stopWaitMinutes: number;
  roundTrip: boolean;
  serviceCategory: 'taxi' | 'box';
  selectedTier: 'saver' | 'plus' | 'box';
  promoCode?: string;
}

export interface IDbStore {
  // Auth & OTP
  createOtp(params: {
    phone: string;
    role: UserRole;
    codeHash: string;
    ttlSeconds: number;
  }): Promise<void>;

  verifyOtpAndUpsertUser(params: {
    phone: string;
    role: UserRole;
    codeHash: string;
    fullNameFallback: string;
  }): Promise<UserEntity>;

  saveRefreshToken(params: {
    userId: string;
    tokenHash: string;
    expiresAt: Date;
  }): Promise<void>;

  rotateRefreshToken(params: {
    oldTokenHash: string;
    newTokenHash: string;
    expiresAt: Date;
  }): Promise<UserEntity>;

  revokeRefreshToken(tokenHash: string): Promise<void>;

  registerFcmToken(params: {
    userId: string;
    fcmToken: string;
    platform: string;
  }): Promise<void>;

  getUserFcmTokens(userId: string): Promise<string[]>;
  getUserById(userId: string): Promise<UserEntity | null>;

  // Captain & Documents & Admin
  getCaptainProfile(captainId: string): Promise<CaptainProfileDto>;
  upsertCaptainProfile(params: {
    captainId: string;
    fullName: string;
    carModel: string;
    carColor: string;
    plateNumber: string;
    vehicleTier: 'saver' | 'plus' | 'box';
  }): Promise<CaptainProfileDto>;

  upsertCaptainDocument(params: {
    captainId: string;
    docType: DocType;
    storageKey: string;
    mimeType: string;
  }): Promise<CaptainProfileDto>;

  setCaptainAvailability(params: {
    captainId: string;
    isOnline: boolean;
    lat?: number;
    lng?: number;
  }): Promise<{ is_online: boolean }>;

  updateCaptainLocation(params: {
    captainId: string;
    lat: number;
    lng: number;
    heading: number;
  }): Promise<void>;

  listPendingCaptains(): Promise<CaptainProfileDto[]>;

  setCaptainApproval(params: {
    captainId: string;
    adminId: string;
    status: 'approved' | 'rejected';
    reason?: string;
  }): Promise<CaptainProfileDto>;

  // Rides & Dispatch & Ratings
  createRide(input: CreateRideInput): Promise<{ ride: RideDto; deduplicated: boolean }>;

  findNearbyEligibleCaptains(params: {
    rideId: string;
    originLat: number;
    originLng: number;
    tier: 'saver' | 'plus' | 'box';
    radiusMeters: number;
    limit: number;
  }): Promise<NearbyCaptainMatch[]>;

  recordDispatchAttempts(
    rideId: string,
    matches: NearbyCaptainMatch[],
  ): Promise<void>;

  acceptRideAtomic(params: {
    rideId: string;
    captainId: string;
    expectedVersion?: number;
  }): Promise<RideDto>;

  rejectRide(params: { rideId: string; captainId: string }): Promise<void>;

  updateRideStatus(params: {
    rideId: string;
    actorId: string;
    actorRole: UserRole;
    nextStatus: RideDispatchStatus;
    cancelReason?: string;
  }): Promise<RideDto>;

  getActiveRideForUser(userId: string, role: UserRole): Promise<RideDto | null>;
  getRideById(rideId: string): Promise<RideDto | null>;

  listCaptainRides(captainId: string): Promise<Array<Record<string, unknown>>>;
  listPassengerRides(passengerId: string): Promise<Array<Record<string, unknown>>>;

  submitRating(params: {
    rideId: string;
    raterId: string;
    raterRole: 'passenger' | 'captain';
    stars: number;
    comment?: string;
  }): Promise<{ newRating: number }>;

  close(): Promise<void>;
}
