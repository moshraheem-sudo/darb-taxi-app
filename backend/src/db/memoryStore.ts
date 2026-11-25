import crypto from 'node:crypto';
import {
  calculateServerFareIqd,
  CaptainApprovalStatus,
  DocType,
  haversineKm,
  RideDispatchStatus,
  RideStateMachine,
  UserRole,
} from '../domain/rideStateMachine';
import {
  BadRequestError,
  CaptainProfileDto,
  ConflictError,
  CreateRideInput,
  ForbiddenError,
  IDbStore,
  NearbyCaptainMatch,
  NotFoundError,
  RideDto,
  UnauthorizedError,
  UserEntity,
} from './types';

interface MemUser {
  id: string;
  fullName: string;
  phone: string;
  roles: Set<UserRole>;
  passengerRating: number;
  passengerTotalTrips: number;
}

interface MemCaptain {
  userId: string;
  approvalStatus: CaptainApprovalStatus;
  isOnline: boolean;
  lat?: number;
  lng?: number;
  heading: number;
  locationUpdatedAt?: number;
  rating: number;
  totalTrips: number;
  totalEarningsIqd: number;
  carModel: string;
  carColor: string;
  plateNumber: string;
  vehicleTier: 'saver' | 'plus' | 'box';
  documents: Partial<Record<DocType, string>>;
}

interface MemOtp {
  phone: string;
  role: UserRole;
  codeHash: string;
  attempts: number;
  expiresAt: number;
  consumed: boolean;
}

interface MemRefresh {
  userId: string;
  expiresAt: number;
  revoked: boolean;
}

export class MemoryStore implements IDbStore {
  private users = new Map<string, MemUser>();
  private phoneIndex = new Map<string, string>();
  private captains = new Map<string, MemCaptain>();
  private otps: MemOtp[] = [];
  private refreshTokens = new Map<string, MemRefresh>();
  private fcmTokens = new Map<string, { userId: string; platform: string }>();
  private rides = new Map<string, RideDto>();
  private idempotencyIndex = new Map<string, string>();
  private dispatchAttempts = new Map<string, Set<string>>();
  private promoCodes = new Map<string, number>([['DARB500', 500]]);

  async createOtp(params: {
    phone: string;
    role: UserRole;
    codeHash: string;
    ttlSeconds: number;
  }): Promise<void> {
    this.otps.push({
      phone: params.phone,
      role: params.role,
      codeHash: params.codeHash,
      attempts: 0,
      expiresAt: Date.now() + params.ttlSeconds * 1000,
      consumed: false,
    });
  }

  async verifyOtpAndUpsertUser(params: {
    phone: string;
    role: UserRole;
    codeHash: string;
    fullNameFallback: string;
  }): Promise<UserEntity> {
    const otp = [...this.otps]
      .reverse()
      .find(
        (o) => o.phone === params.phone && o.role === params.role && !o.consumed,
      );
    if (!otp || otp.expiresAt < Date.now()) {
      throw new UnauthorizedError('رمز التحقق غير صالح أو منتهي الصلاحية.');
    }
    if (otp.attempts >= 5) {
      throw new UnauthorizedError('تم تجاوز عدد محاولات التحقق المسموحة.');
    }
    if (otp.codeHash !== params.codeHash) {
      otp.attempts += 1;
      throw new UnauthorizedError('رمز التحقق غير صحيح.');
    }
    otp.consumed = true;

    let userId = this.phoneIndex.get(params.phone);
    let user = userId ? this.users.get(userId) : undefined;
    if (!user) {
      userId = crypto.randomUUID();
      user = {
        id: userId,
        fullName: params.fullNameFallback,
        phone: params.phone,
        roles: new Set([params.role]),
        passengerRating: 5.0,
        passengerTotalTrips: 0,
      };
      this.users.set(userId, user);
      this.phoneIndex.set(params.phone, userId);
    } else {
      user.roles.add(params.role);
    }

    if (params.role === 'captain' && !this.captains.has(user.id)) {
      this.captains.set(user.id, {
        userId: user.id,
        approvalStatus: 'unsubmitted',
        isOnline: false,
        heading: 0,
        rating: 4.9,
        totalTrips: 0,
        totalEarningsIqd: 0,
        carModel: '',
        carColor: '',
        plateNumber: '',
        vehicleTier: 'saver',
        documents: {},
      });
    }

    return {
      id: user.id,
      fullName: user.fullName,
      phone: user.phone,
      roles: [...user.roles],
      passengerRating: user.passengerRating,
      passengerTotalTrips: user.passengerTotalTrips,
    };
  }

  async saveRefreshToken(params: {
    userId: string;
    tokenHash: string;
    expiresAt: Date;
  }): Promise<void> {
    this.refreshTokens.set(params.tokenHash, {
      userId: params.userId,
      expiresAt: params.expiresAt.getTime(),
      revoked: false,
    });
  }

  async rotateRefreshToken(params: {
    oldTokenHash: string;
    newTokenHash: string;
    expiresAt: Date;
  }): Promise<UserEntity> {
    const rec = this.refreshTokens.get(params.oldTokenHash);
    if (!rec || rec.revoked || rec.expiresAt < Date.now()) {
      throw new UnauthorizedError('جلسة الدخول منتهية، يرجى إعادة تسجيل الدخول.');
    }
    rec.revoked = true;
    this.refreshTokens.set(params.newTokenHash, {
      userId: rec.userId,
      expiresAt: params.expiresAt.getTime(),
      revoked: false,
    });
    const user = await this.getUserById(rec.userId);
    if (!user) throw new UnauthorizedError('الحساب غير موجود.');
    return user;
  }

  async revokeRefreshToken(tokenHash: string): Promise<void> {
    const rec = this.refreshTokens.get(tokenHash);
    if (rec) rec.revoked = true;
  }

  async registerFcmToken(params: {
    userId: string;
    fcmToken: string;
    platform: string;
  }): Promise<void> {
    this.fcmTokens.set(params.fcmToken, {
      userId: params.userId,
      platform: params.platform,
    });
  }

  async getUserFcmTokens(userId: string): Promise<string[]> {
    const out: string[] = [];
    for (const [token, val] of this.fcmTokens.entries()) {
      if (val.userId === userId) out.push(token);
    }
    return out;
  }

  async getUserById(userId: string): Promise<UserEntity | null> {
    const u = this.users.get(userId);
    if (!u) return null;
    return {
      id: u.id,
      fullName: u.fullName,
      phone: u.phone,
      roles: [...u.roles],
      passengerRating: u.passengerRating,
      passengerTotalTrips: u.passengerTotalTrips,
    };
  }

  async getCaptainProfile(captainId: string): Promise<CaptainProfileDto> {
    const u = this.users.get(captainId);
    const c = this.captains.get(captainId);
    if (!u || !c) throw new NotFoundError('ملف الكابتن غير موجود.');
    return {
      id: u.id,
      full_name: u.fullName,
      phone: u.phone,
      car_model: c.carModel,
      car_color: c.carColor,
      plate_number: c.plateNumber,
      vehicle_tier: c.vehicleTier,
      approval_status: c.approvalStatus,
      is_online: c.isOnline,
      rating: c.rating,
      total_trips: c.totalTrips,
      total_earnings: c.totalEarningsIqd,
      documents: { ...c.documents },
    };
  }

  async upsertCaptainProfile(params: {
    captainId: string;
    fullName: string;
    carModel: string;
    carColor: string;
    plateNumber: string;
    vehicleTier: 'saver' | 'plus' | 'box';
  }): Promise<CaptainProfileDto> {
    const u = this.users.get(params.captainId);
    const c = this.captains.get(params.captainId);
    if (!u || !c) throw new NotFoundError('ملف الكابتن غير موجود.');
    u.fullName = params.fullName;
    c.carModel = params.carModel;
    c.carColor = params.carColor;
    c.plateNumber = params.plateNumber;
    c.vehicleTier = params.vehicleTier;
    if (c.approvalStatus === 'unsubmitted') c.approvalStatus = 'pending';
    return this.getCaptainProfile(params.captainId);
  }

  async upsertCaptainDocument(params: {
    captainId: string;
    docType: DocType;
    storageKey: string;
    mimeType: string;
  }): Promise<CaptainProfileDto> {
    const c = this.captains.get(params.captainId);
    if (!c) throw new NotFoundError('ملف الكابتن غير موجود.');
    c.documents[params.docType] = params.storageKey;
    if (c.approvalStatus === 'unsubmitted' || c.approvalStatus === 'rejected') {
      c.approvalStatus = 'pending';
    }
    return this.getCaptainProfile(params.captainId);
  }

  async setCaptainAvailability(params: {
    captainId: string;
    isOnline: boolean;
    lat?: number;
    lng?: number;
  }): Promise<{ is_online: boolean }> {
    const c = this.captains.get(params.captainId);
    if (!c) throw new NotFoundError('ملف الكابتن غير موجود.');
    if (params.isOnline && c.approvalStatus !== 'approved') {
      throw new ForbiddenError('لا يمكن تفعيل حالة متاح قبل اعتماد الحساب من الإدارة.');
    }
    c.isOnline = params.isOnline;
    if (params.lat !== undefined && params.lng !== undefined) {
      c.lat = params.lat;
      c.lng = params.lng;
      c.locationUpdatedAt = Date.now();
    }
    return { is_online: c.isOnline };
  }

  async updateCaptainLocation(params: {
    captainId: string;
    lat: number;
    lng: number;
    heading: number;
  }): Promise<void> {
    const c = this.captains.get(params.captainId);
    if (!c) return;
    c.lat = params.lat;
    c.lng = params.lng;
    c.heading = params.heading;
    c.locationUpdatedAt = Date.now();
  }

  async listPendingCaptains(): Promise<CaptainProfileDto[]> {
    const out: CaptainProfileDto[] = [];
    for (const c of this.captains.values()) {
      if (c.approvalStatus === 'pending') {
        out.push(await this.getCaptainProfile(c.userId));
      }
    }
    return out;
  }

  async setCaptainApproval(params: {
    captainId: string;
    adminId: string;
    status: 'approved' | 'rejected';
    reason?: string;
  }): Promise<CaptainProfileDto> {
    const c = this.captains.get(params.captainId);
    if (!c) throw new NotFoundError('الكابتن غير موجود.');
    c.approvalStatus = params.status;
    if (params.status === 'rejected') c.isOnline = false;
    return this.getCaptainProfile(params.captainId);
  }

  async createRide(
    input: CreateRideInput,
  ): Promise<{ ride: RideDto; deduplicated: boolean }> {
    if (input.idempotencyKey) {
      const existingId = this.idempotencyIndex.get(input.idempotencyKey);
      if (existingId && this.rides.has(existingId)) {
        return { ride: { ...this.rides.get(existingId)! }, deduplicated: true };
      }
    }
    const passenger = this.users.get(input.passengerId);
    if (!passenger) throw new NotFoundError('حساب الزبون غير موجود.');

    const distanceKm = Number(
      haversineKm(
        input.originLat,
        input.originLng,
        input.destinationLat,
        input.destinationLng,
      ).toFixed(2),
    );
    const durationMin = Math.max(2, Math.round(distanceKm * 2.2));
    const promoDiscount = input.promoCode
      ? (this.promoCodes.get(input.promoCode.trim().toUpperCase()) ?? 0)
      : 0;
    const pricing = calculateServerFareIqd({
      distanceKm,
      selectedTier: input.selectedTier,
      stopWaitMinutes: input.stopWaitMinutes,
      roundTrip: input.roundTrip,
      discountIqd: promoDiscount,
    });

    const ride: RideDto = {
      ride_id: crypto.randomUUID(),
      passenger_id: passenger.id,
      passenger_name: passenger.fullName,
      passenger_phone: passenger.phone,
      origin_lat: input.originLat,
      origin_lng: input.originLng,
      origin_name: input.originName,
      destination_lat: input.destinationLat,
      destination_lng: input.destinationLng,
      destination_name: input.destinationName,
      second_destination_name: input.secondDestinationName,
      second_destination_lat: input.secondDestinationLat,
      second_destination_lng: input.secondDestinationLng,
      stop_wait_minutes: input.stopWaitMinutes,
      round_trip: input.roundTrip,
      service_category: input.serviceCategory,
      selected_tier: input.selectedTier,
      fare_iqd: pricing.fareIqd,
      discount_iqd: pricing.discountIqd,
      final_fare_iqd: pricing.finalFareIqd,
      distance_km: distanceKm,
      duration_min: durationMin,
      status: 'searching',
      version: 1,
      created_at: new Date().toISOString(),
    };

    this.rides.set(ride.ride_id, ride);
    if (input.idempotencyKey) {
      this.idempotencyIndex.set(input.idempotencyKey, ride.ride_id);
    }
    return { ride: { ...ride }, deduplicated: false };
  }

  async findNearbyEligibleCaptains(params: {
    rideId: string;
    originLat: number;
    originLng: number;
    tier: 'saver' | 'plus' | 'box';
    radiusMeters: number;
    limit: number;
  }): Promise<NearbyCaptainMatch[]> {
    const attempted = this.dispatchAttempts.get(params.rideId) ?? new Set<string>();
    const matches: NearbyCaptainMatch[] = [];

    for (const c of this.captains.values()) {
      if (!c.isOnline || c.approvalStatus !== 'approved') continue;
      if (c.lat === undefined || c.lng === undefined) continue;
      if (c.vehicleTier !== params.tier) continue;
      if (attempted.has(c.userId)) continue;

      const hasActiveRide = [...this.rides.values()].some(
        (r) =>
          r.captain_id === c.userId &&
          (r.status === 'accepted' || r.status === 'arrived' || r.status === 'in_progress'),
      );
      if (hasActiveRide) continue;

      const distMeters = Math.round(
        haversineKm(params.originLat, params.originLng, c.lat, c.lng) * 1000,
      );
      if (distMeters <= params.radiusMeters) {
        matches.push({
          captainId: c.userId,
          distanceMeters: distMeters,
          fcmTokens: await this.getUserFcmTokens(c.userId),
        });
      }
    }

    matches.sort((a, b) => a.distanceMeters - b.distanceMeters);
    return matches.slice(0, params.limit);
  }

  async recordDispatchAttempts(
    rideId: string,
    matches: NearbyCaptainMatch[],
  ): Promise<void> {
    const set = this.dispatchAttempts.get(rideId) ?? new Set<string>();
    for (const m of matches) set.add(m.captainId);
    this.dispatchAttempts.set(rideId, set);
  }

  async acceptRideAtomic(params: {
    rideId: string;
    captainId: string;
    expectedVersion?: number;
  }): Promise<RideDto> {
    const c = this.captains.get(params.captainId);
    const u = this.users.get(params.captainId);
    if (!c || !u || c.approvalStatus !== 'approved' || !c.isOnline) {
      throw new ForbiddenError('يجب أن يكون الكابتن معتمداً ومتاحاً لقبول الرحلة.');
    }

    const hasActive = [...this.rides.values()].some(
      (r) =>
        r.captain_id === params.captainId &&
        (r.status === 'accepted' || r.status === 'arrived' || r.status === 'in_progress'),
    );
    if (hasActive) throw new ConflictError('لديك رحلة نشطة حالياً بالفعل.');

    const ride = this.rides.get(params.rideId);
    if (
      !ride ||
      ride.status !== 'searching' ||
      (params.expectedVersion !== undefined && ride.version !== params.expectedVersion)
    ) {
      throw new ConflictError('تم قبول هذا الطلب من كابتن آخر للتو.');
    }

    ride.status = 'accepted';
    ride.version += 1;
    ride.captain_id = u.id;
    ride.captain_name = u.fullName;
    ride.captain_phone = u.phone;
    ride.captain_car = [c.carColor, c.carModel].filter(Boolean).join(' ');
    ride.captain_plate = c.plateNumber;
    ride.captain_rating = c.rating;
    return { ...ride };
  }

  async rejectRide(_params: { rideId: string; captainId: string }): Promise<void> {}

  async updateRideStatus(params: {
    rideId: string;
    actorId: string;
    actorRole: UserRole;
    nextStatus: RideDispatchStatus;
  }): Promise<RideDto> {
    const ride = this.rides.get(params.rideId);
    if (!ride) throw new NotFoundError('الرحلة غير موجودة.');
    if (params.actorRole === 'passenger' && ride.passenger_id !== params.actorId) {
      throw new ForbiddenError('لا تملك صلاحية تعديل هذه الرحلة.');
    }
    if (params.actorRole === 'captain' && ride.captain_id !== params.actorId) {
      throw new ForbiddenError('هذه الرحلة غير مسندة إليك.');
    }
    if (!RideStateMachine.canTransition(ride.status, params.nextStatus)) {
      throw new BadRequestError(`انتقال غير صالح من ${ride.status} إلى ${params.nextStatus}.`);
    }
    ride.status = params.nextStatus;
    ride.version += 1;

    if (params.nextStatus === 'completed' && ride.captain_id) {
      const cap = this.captains.get(ride.captain_id);
      if (cap) {
        cap.totalTrips += 1;
        cap.totalEarningsIqd += ride.final_fare_iqd;
      }
      const pax = this.users.get(ride.passenger_id);
      if (pax) pax.passengerTotalTrips += 1;
    }

    return { ...ride };
  }

  async getActiveRideForUser(
    userId: string,
    role: UserRole,
  ): Promise<RideDto | null> {
    const found = [...this.rides.values()]
      .reverse()
      .find(
        (r) =>
          (role === 'captain' ? r.captain_id === userId : r.passenger_id === userId) &&
          !RideStateMachine.isTerminal(r.status),
      );
    return found ? { ...found } : null;
  }

  async getRideById(rideId: string): Promise<RideDto | null> {
    const r = this.rides.get(rideId);
    return r ? { ...r } : null;
  }

  async listCaptainRides(captainId: string): Promise<Array<Record<string, unknown>>> {
    return [...this.rides.values()]
      .filter((r) => r.captain_id === captainId && r.status === 'completed')
      .map((r) => ({
        ride_id: r.ride_id,
        date: r.created_at,
        passenger_name: r.passenger_name,
        origin: r.origin_name,
        destination: r.destination_name,
        fare_iqd: r.final_fare_iqd,
        distance_km: r.distance_km,
      }));
  }

  async listPassengerRides(passengerId: string): Promise<Array<Record<string, unknown>>> {
    return [...this.rides.values()]
      .filter((r) => r.passenger_id === passengerId)
      .map((r) => ({
        ride_id: r.ride_id,
        date: r.created_at,
        captain_name: r.captain_name ?? 'كابتن درب',
        origin: r.origin_name,
        destination: r.destination_name,
        fare_iqd: r.final_fare_iqd,
        distance_km: r.distance_km,
        status: r.status,
      }));
  }

  async submitRating(params: {
    rideId: string;
    raterId: string;
    raterRole: 'passenger' | 'captain';
    stars: number;
  }): Promise<{ newRating: number }> {
    const ride = this.rides.get(params.rideId);
    if (!ride || ride.status !== 'completed') {
      throw new BadRequestError('يمكن تقييم الرحلة بعد اكتمالها فقط.');
    }
    if (params.raterRole === 'passenger' && ride.captain_id) {
      const c = this.captains.get(ride.captain_id);
      if (c) {
        c.rating = Number(((c.rating + params.stars) / 2).toFixed(2));
        return { newRating: c.rating };
      }
    }
    return { newRating: 5.0 };
  }

  async close(): Promise<void> {}
}
