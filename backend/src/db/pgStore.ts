import { Pool, PoolClient } from 'pg';
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

export class PgStore implements IDbStore {
  constructor(private readonly pool: Pool) {}

  private async withTx<T>(fn: (client: PoolClient) => Promise<T>): Promise<T> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      const res = await fn(client);
      await client.query('COMMIT');
      return res;
    } catch (err) {
      await client.query('ROLLBACK').catch(() => {});
      throw err;
    } finally {
      client.release();
    }
  }

  async createOtp(params: {
    phone: string;
    role: UserRole;
    codeHash: string;
    ttlSeconds: number;
  }): Promise<void> {
    await this.pool.query(
      `INSERT INTO otp_verifications (phone, role, code_hash, expires_at)
       VALUES ($1, $2, $3, NOW() + ($4 || ' seconds')::interval)`,
      [params.phone, params.role, params.codeHash, String(params.ttlSeconds)],
    );
  }

  async verifyOtpAndUpsertUser(params: {
    phone: string;
    role: UserRole;
    codeHash: string;
    fullNameFallback: string;
  }): Promise<UserEntity> {
    return this.withTx(async (client) => {
      const otpRes = await client.query(
        `SELECT id, code_hash, attempts, expires_at
         FROM otp_verifications
         WHERE phone = $1 AND role = $2 AND consumed_at IS NULL
         ORDER BY created_at DESC
         LIMIT 1
         FOR UPDATE`,
        [params.phone, params.role],
      );
      const otp = otpRes.rows[0];
      if (!otp || new Date(otp.expires_at).getTime() < Date.now()) {
        throw new UnauthorizedError('رمز التحقق غير صالح أو منتهي الصلاحية.');
      }
      if (otp.attempts >= 5) {
        throw new UnauthorizedError('تم تجاوز عدد محاولات التحقق المسموحة.');
      }
      if (otp.code_hash !== params.codeHash) {
        await client.query(
          'UPDATE otp_verifications SET attempts = attempts + 1 WHERE id = $1',
          [otp.id],
        );
        throw new UnauthorizedError('رمز التحقق غير صحيح.');
      }
      await client.query(
        'UPDATE otp_verifications SET consumed_at = NOW() WHERE id = $1',
        [otp.id],
      );

      const userRes = await client.query(
        `INSERT INTO users (full_name, phone)
         VALUES ($1, $2)
         ON CONFLICT (phone) DO UPDATE SET updated_at = NOW()
         RETURNING id, full_name, phone, passenger_rating, passenger_total_trips`,
        [params.fullNameFallback, params.phone],
      );
      const u = userRes.rows[0];

      await client.query(
        `INSERT INTO user_roles (user_id, role) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
        [u.id, params.role],
      );
      if (params.role === 'captain') {
        await client.query(
          `INSERT INTO captains (user_id) VALUES ($1) ON CONFLICT DO NOTHING`,
          [u.id],
        );
      }

      const rolesRes = await client.query(
        'SELECT role FROM user_roles WHERE user_id = $1',
        [u.id],
      );

      return {
        id: u.id,
        fullName: u.full_name,
        phone: u.phone,
        roles: rolesRes.rows.map((r) => r.role as UserRole),
        passengerRating: Number(u.passenger_rating),
        passengerTotalTrips: Number(u.passenger_total_trips),
      };
    });
  }

  async saveRefreshToken(params: {
    userId: string;
    tokenHash: string;
    expiresAt: Date;
  }): Promise<void> {
    await this.pool.query(
      `INSERT INTO refresh_tokens (user_id, token_hash, expires_at)
       VALUES ($1, $2, $3)`,
      [params.userId, params.tokenHash, params.expiresAt.toISOString()],
    );
  }

  async rotateRefreshToken(params: {
    oldTokenHash: string;
    newTokenHash: string;
    expiresAt: Date;
  }): Promise<UserEntity> {
    return this.withTx(async (client) => {
      const existing = await client.query(
        `SELECT id, user_id, expires_at, revoked_at
         FROM refresh_tokens WHERE token_hash = $1 FOR UPDATE`,
        [params.oldTokenHash],
      );
      const row = existing.rows[0];
      if (!row || row.revoked_at || new Date(row.expires_at).getTime() < Date.now()) {
        throw new UnauthorizedError('جلسة الدخول منتهية، يرجى إعادة تسجيل الدخول.');
      }
      await client.query(
        'UPDATE refresh_tokens SET revoked_at = NOW() WHERE id = $1',
        [row.id],
      );
      await client.query(
        'INSERT INTO refresh_tokens (user_id, token_hash, expires_at) VALUES ($1, $2, $3)',
        [row.user_id, params.newTokenHash, params.expiresAt.toISOString()],
      );
      const user = await this.getUserByIdWithClient(client, row.user_id);
      if (!user) throw new UnauthorizedError('الحساب غير موجود.');
      return user;
    });
  }

  async revokeRefreshToken(tokenHash: string): Promise<void> {
    await this.pool.query(
      'UPDATE refresh_tokens SET revoked_at = NOW() WHERE token_hash = $1',
      [tokenHash],
    );
  }

  async registerFcmToken(params: {
    userId: string;
    fcmToken: string;
    platform: string;
  }): Promise<void> {
    await this.pool.query(
      `INSERT INTO device_tokens (user_id, fcm_token, platform, updated_at)
       VALUES ($1, $2, $3, NOW())
       ON CONFLICT (fcm_token)
       DO UPDATE SET user_id = EXCLUDED.user_id, platform = EXCLUDED.platform, updated_at = NOW()`,
      [params.userId, params.fcmToken, params.platform],
    );
  }

  async getUserFcmTokens(userId: string): Promise<string[]> {
    const res = await this.pool.query(
      'SELECT fcm_token FROM device_tokens WHERE user_id = $1',
      [userId],
    );
    return res.rows.map((r) => String(r.fcm_token));
  }

  private async getUserByIdWithClient(
    client: PoolClient,
    userId: string,
  ): Promise<UserEntity | null> {
    const uRes = await client.query(
      'SELECT id, full_name, phone, passenger_rating, passenger_total_trips FROM users WHERE id = $1',
      [userId],
    );
    if (!uRes.rowCount) return null;
    const u = uRes.rows[0];
    const rolesRes = await client.query(
      'SELECT role FROM user_roles WHERE user_id = $1',
      [userId],
    );
    return {
      id: u.id,
      fullName: u.full_name,
      phone: u.phone,
      roles: rolesRes.rows.map((r) => r.role as UserRole),
      passengerRating: Number(u.passenger_rating),
      passengerTotalTrips: Number(u.passenger_total_trips),
    };
  }

  async getUserById(userId: string): Promise<UserEntity | null> {
    const client = await this.pool.connect();
    try {
      return await this.getUserByIdWithClient(client, userId);
    } finally {
      client.release();
    }
  }

  async getCaptainProfile(captainId: string): Promise<CaptainProfileDto> {
    const res = await this.pool.query(
      `SELECT u.id, u.full_name, u.phone,
              c.approval_status, c.is_online, c.rating, c.total_trips, c.total_earnings_iqd,
              v.model AS car_model, v.color AS car_color, v.plate_number, v.tier AS vehicle_tier
       FROM users u
       JOIN captains c ON c.user_id = u.id
       LEFT JOIN vehicles v ON v.captain_id = c.user_id AND v.is_active = TRUE
       WHERE u.id = $1`,
      [captainId],
    );
    if (!res.rowCount) throw new NotFoundError('ملف الكابتن غير موجود.');
    const row = res.rows[0];
    const docsRes = await this.pool.query(
      'SELECT doc_type, storage_key FROM captain_documents WHERE captain_id = $1',
      [captainId],
    );
    const documents: Partial<Record<DocType, string>> = {};
    for (const d of docsRes.rows) {
      documents[d.doc_type as DocType] = String(d.storage_key);
    }
    return {
      id: row.id,
      full_name: row.full_name,
      phone: row.phone,
      car_model: row.car_model ?? '',
      car_color: row.car_color ?? '',
      plate_number: row.plate_number ?? '',
      vehicle_tier: row.vehicle_tier ?? 'saver',
      approval_status: row.approval_status as CaptainApprovalStatus,
      is_online: Boolean(row.is_online),
      rating: Number(row.rating),
      total_trips: Number(row.total_trips),
      total_earnings: Number(row.total_earnings_iqd),
      documents,
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
    await this.withTx(async (client) => {
      await client.query('UPDATE users SET full_name = $1, updated_at = NOW() WHERE id = $2', [
        params.fullName,
        params.captainId,
      ]);
      await client.query(
        `INSERT INTO captains (user_id, approval_status)
         VALUES ($1, 'pending')
         ON CONFLICT (user_id) DO UPDATE
         SET approval_status = CASE
           WHEN captains.approval_status = 'unsubmitted' THEN 'pending'
           ELSE captains.approval_status
         END`,
        [params.captainId],
      );
      await client.query(
        `UPDATE vehicles SET is_active = FALSE WHERE captain_id = $1 AND plate_number <> $2`,
        [params.captainId, params.plateNumber],
      );
      await client.query(
        `INSERT INTO vehicles (captain_id, model, color, plate_number, tier, is_active)
         VALUES ($1, $2, $3, $4, $5, TRUE)
         ON CONFLICT (plate_number) DO UPDATE
         SET model = EXCLUDED.model,
             color = EXCLUDED.color,
             tier = EXCLUDED.tier,
             is_active = TRUE
         WHERE vehicles.captain_id = $1`,
        [
          params.captainId,
          params.carModel,
          params.carColor,
          params.plateNumber,
          params.vehicleTier,
        ],
      );
    });
    return this.getCaptainProfile(params.captainId);
  }

  async upsertCaptainDocument(params: {
    captainId: string;
    docType: DocType;
    storageKey: string;
    mimeType: string;
  }): Promise<CaptainProfileDto> {
    await this.withTx(async (client) => {
      await client.query(
        `INSERT INTO captain_documents (captain_id, doc_type, storage_key, mime_type, review_status, updated_at)
         VALUES ($1, $2, $3, $4, 'pending', NOW())
         ON CONFLICT (captain_id, doc_type) DO UPDATE
         SET storage_key = EXCLUDED.storage_key,
             mime_type = EXCLUDED.mime_type,
             review_status = 'pending',
             rejection_reason = NULL,
             updated_at = NOW()`,
        [params.captainId, params.docType, params.storageKey, params.mimeType],
      );
      await client.query(
        `UPDATE captains
         SET approval_status = 'pending'
         WHERE user_id = $1 AND approval_status IN ('unsubmitted', 'rejected')`,
        [params.captainId],
      );
    });
    return this.getCaptainProfile(params.captainId);
  }

  async setCaptainAvailability(params: {
    captainId: string;
    isOnline: boolean;
    lat?: number;
    lng?: number;
  }): Promise<{ is_online: boolean }> {
    const capRes = await this.pool.query(
      'SELECT approval_status FROM captains WHERE user_id = $1',
      [params.captainId],
    );
    const row = capRes.rows[0];
    if (!row) throw new NotFoundError('ملف الكابتن غير موجود.');
    if (params.isOnline && row.approval_status !== 'approved') {
      throw new ForbiddenError('لا يمكن تفعيل حالة متاح قبل اعتماد الحساب من الإدارة.');
    }
    await this.pool.query(
      `UPDATE captains
       SET is_online = $1,
           current_location = COALESCE(
             CASE WHEN $2::double precision IS NOT NULL AND $3::double precision IS NOT NULL
               THEN ST_SetSRID(ST_MakePoint($3, $2), 4326)::geography
               ELSE NULL
             END,
             current_location
           ),
           location_updated_at = CASE WHEN $2::double precision IS NOT NULL THEN NOW() ELSE location_updated_at END
       WHERE user_id = $4`,
      [params.isOnline, params.lat ?? null, params.lng ?? null, params.captainId],
    );
    return { is_online: params.isOnline };
  }

  async updateCaptainLocation(params: {
    captainId: string;
    lat: number;
    lng: number;
    heading: number;
  }): Promise<void> {
    await this.pool.query(
      `UPDATE captains
       SET current_location = ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography,
           heading = $3,
           location_updated_at = NOW()
       WHERE user_id = $4`,
      [params.lat, params.lng, params.heading, params.captainId],
    );
  }

  async listPendingCaptains(): Promise<CaptainProfileDto[]> {
    const res = await this.pool.query(
      `SELECT user_id FROM captains WHERE approval_status = 'pending'`,
    );
    return Promise.all(res.rows.map((r) => this.getCaptainProfile(String(r.user_id))));
  }

  async setCaptainApproval(params: {
    captainId: string;
    adminId: string;
    status: 'approved' | 'rejected';
    reason?: string;
  }): Promise<CaptainProfileDto> {
    await this.withTx(async (client) => {
      const updated = await client.query(
        `UPDATE captains
         SET approval_status = $1,
             is_online = CASE WHEN $1 = 'rejected' THEN FALSE ELSE is_online END,
             approved_at = CASE WHEN $1 = 'approved' THEN NOW() ELSE NULL END,
             approved_by = $2
         WHERE user_id = $3
         RETURNING user_id`,
        [params.status, params.adminId, params.captainId],
      );
      if (!updated.rowCount) throw new NotFoundError('الكابتن غير موجود.');
      await client.query(
        `UPDATE captain_documents
         SET review_status = $1, rejection_reason = $2, reviewed_by = $3, reviewed_at = NOW()
         WHERE captain_id = $4`,
        [params.status, params.reason ?? null, params.adminId, params.captainId],
      );
    });
    return this.getCaptainProfile(params.captainId);
  }

  private mapRideRow(r: Record<string, unknown>): RideDto {
    return {
      ride_id: String(r.id),
      passenger_id: String(r.passenger_id),
      passenger_name: String(r.passenger_name ?? 'زبون درب'),
      passenger_phone: String(r.passenger_phone ?? ''),
      origin_lat: Number(r.origin_lat),
      origin_lng: Number(r.origin_lng),
      origin_name: String(r.origin_name),
      destination_lat: Number(r.destination_lat),
      destination_lng: Number(r.destination_lng),
      destination_name: String(r.destination_name),
      second_destination_name: r.second_destination_name ? String(r.second_destination_name) : undefined,
      second_destination_lat: r.second_destination_lat != null ? Number(r.second_destination_lat) : undefined,
      second_destination_lng: r.second_destination_lng != null ? Number(r.second_destination_lng) : undefined,
      stop_wait_minutes: Number(r.stop_wait_minutes ?? 0),
      round_trip: Boolean(r.round_trip),
      service_category: (r.service_category as 'taxi' | 'box') ?? 'taxi',
      selected_tier: (r.selected_tier as 'saver' | 'plus' | 'box') ?? 'saver',
      fare_iqd: Number(r.fare_iqd),
      discount_iqd: Number(r.discount_iqd ?? 0),
      final_fare_iqd: Number(r.final_fare_iqd),
      distance_km: Number(r.distance_km),
      duration_min: Number(r.duration_min),
      status: r.status as RideDispatchStatus,
      captain_id: r.captain_id ? String(r.captain_id) : undefined,
      captain_name: r.captain_name ? String(r.captain_name) : undefined,
      captain_phone: r.captain_phone ? String(r.captain_phone) : undefined,
      captain_car: r.captain_car ? String(r.captain_car) : undefined,
      captain_plate: r.captain_plate ? String(r.captain_plate) : undefined,
      captain_rating: r.captain_rating != null ? Number(r.captain_rating) : undefined,
      version: Number(r.version),
      created_at: new Date(String(r.created_at)).toISOString(),
    };
  }

  private readonly rideSelectSql = `
    SELECT r.*,
      ST_Y(r.origin_point::geometry) AS origin_lat,
      ST_X(r.origin_point::geometry) AS origin_lng,
      ST_Y(r.destination_point::geometry) AS destination_lat,
      ST_X(r.destination_point::geometry) AS destination_lng,
      ST_Y(r.second_destination_point::geometry) AS second_destination_lat,
      ST_X(r.second_destination_point::geometry) AS second_destination_lng,
      pu.full_name AS passenger_name,
      pu.phone AS passenger_phone,
      cu.full_name AS captain_name,
      cu.phone AS captain_phone,
      c.rating AS captain_rating,
      TRIM(CONCAT(COALESCE(v.color, ''), ' ', COALESCE(v.model, ''))) AS captain_car,
      v.plate_number AS captain_plate
    FROM rides r
    JOIN users pu ON pu.id = r.passenger_id
    LEFT JOIN captains c ON c.user_id = r.captain_id
    LEFT JOIN users cu ON cu.id = c.user_id
    LEFT JOIN vehicles v ON v.id = r.vehicle_id
  `;

  async createRide(
    input: CreateRideInput,
  ): Promise<{ ride: RideDto; deduplicated: boolean }> {
    return this.withTx(async (client) => {
      if (input.idempotencyKey) {
        const existing = await client.query(
          `${this.rideSelectSql} WHERE r.idempotency_key = $1`,
          [input.idempotencyKey],
        );
        if (existing.rowCount && existing.rowCount > 0) {
          return { ride: this.mapRideRow(existing.rows[0]), deduplicated: true };
        }
      }

      const distanceKm = Number(
        haversineKm(
          input.originLat,
          input.originLng,
          input.destinationLat,
          input.destinationLng,
        ).toFixed(2),
      );
      const durationMin = Math.max(2, Math.round(distanceKm * 2.2));

      let promoDiscount = 0;
      let validPromo: string | null = null;
      if (input.promoCode) {
        const promoRes = await client.query(
          `SELECT code, discount_iqd FROM promo_codes
           WHERE code = $1 AND is_active = TRUE
             AND (expires_at IS NULL OR expires_at > NOW())
             AND (max_uses IS NULL OR used_count < max_uses)
           FOR UPDATE`,
          [input.promoCode.trim().toUpperCase()],
        );
        if (promoRes.rowCount && promoRes.rowCount > 0) {
          promoDiscount = Number(promoRes.rows[0].discount_iqd);
          validPromo = String(promoRes.rows[0].code);
          await client.query(
            'UPDATE promo_codes SET used_count = used_count + 1 WHERE code = $1',
            [validPromo],
          );
        }
      }

      const pricing = calculateServerFareIqd({
        distanceKm,
        selectedTier: input.selectedTier,
        stopWaitMinutes: input.stopWaitMinutes,
        roundTrip: input.roundTrip,
        discountIqd: promoDiscount,
      });

      const ins = await client.query(
        `INSERT INTO rides (
          passenger_id, idempotency_key,
          origin_point, origin_name, destination_point, destination_name,
          second_destination_point, second_destination_name,
          stop_wait_minutes, round_trip, service_category, selected_tier,
          distance_km, duration_min, fare_iqd, promo_code, discount_iqd, final_fare_iqd
        ) VALUES (
          $1, $2,
          ST_SetSRID(ST_MakePoint($4, $3), 4326)::geography, $5,
          ST_SetSRID(ST_MakePoint($7, $6), 4326)::geography, $8,
          CASE WHEN $9::double precision IS NOT NULL AND $10::double precision IS NOT NULL
            THEN ST_SetSRID(ST_MakePoint($10, $9), 4326)::geography ELSE NULL END,
          $11,
          $12, $13, $14, $15,
          $16, $17, $18, $19, $20, $21
        ) RETURNING id`,
        [
          input.passengerId,
          input.idempotencyKey ?? null,
          input.originLat,
          input.originLng,
          input.originName,
          input.destinationLat,
          input.destinationLng,
          input.destinationName,
          input.secondDestinationLat ?? null,
          input.secondDestinationLng ?? null,
          input.secondDestinationName ?? null,
          input.stopWaitMinutes,
          input.roundTrip,
          input.serviceCategory,
          input.selectedTier,
          distanceKm,
          durationMin,
          pricing.fareIqd,
          validPromo,
          pricing.discountIqd,
          pricing.finalFareIqd,
        ],
      );

      const rideId = String(ins.rows[0].id);
      await client.query(
        `INSERT INTO ride_events (ride_id, from_status, to_status, actor_id, actor_role)
         VALUES ($1, NULL, 'searching', $2, 'passenger')`,
        [rideId, input.passengerId],
      );

      const full = await client.query(`${this.rideSelectSql} WHERE r.id = $1`, [rideId]);
      return { ride: this.mapRideRow(full.rows[0]), deduplicated: false };
    });
  }

  async findNearbyEligibleCaptains(params: {
    rideId: string;
    originLat: number;
    originLng: number;
    tier: 'saver' | 'plus' | 'box';
    radiusMeters: number;
    limit: number;
  }): Promise<NearbyCaptainMatch[]> {
    const res = await this.pool.query(
      `SELECT c.user_id,
              ROUND(ST_Distance(c.current_location, ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography))::int AS dist_m,
              COALESCE(ARRAY_AGG(dt.fcm_token) FILTER (WHERE dt.fcm_token IS NOT NULL), '{}') AS tokens
       FROM captains c
       JOIN vehicles v ON v.captain_id = c.user_id AND v.is_active = TRUE
       LEFT JOIN device_tokens dt ON dt.user_id = c.user_id
       WHERE c.is_online = TRUE
         AND c.approval_status = 'approved'
         AND c.current_location IS NOT NULL
         AND c.location_updated_at > NOW() - INTERVAL '5 minutes'
         AND v.tier = $3
         AND NOT EXISTS (
           SELECT 1 FROM rides r
           WHERE r.captain_id = c.user_id AND r.status IN ('accepted', 'arrived', 'in_progress')
         )
         AND NOT EXISTS (
           SELECT 1 FROM ride_dispatch_attempts a
           WHERE a.ride_id = $4 AND a.captain_id = c.user_id
         )
         AND ST_DWithin(c.current_location, ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography, $5)
       GROUP BY c.user_id, c.current_location
       ORDER BY dist_m ASC
       LIMIT $6`,
      [
        params.originLat,
        params.originLng,
        params.tier,
        params.rideId,
        params.radiusMeters,
        params.limit,
      ],
    );

    return res.rows.map((r) => ({
      captainId: String(r.user_id),
      distanceMeters: Number(r.dist_m),
      fcmTokens: (r.tokens as string[]) ?? [],
    }));
  }

  async recordDispatchAttempts(
    rideId: string,
    matches: NearbyCaptainMatch[],
  ): Promise<void> {
    if (matches.length === 0) return;
    await this.withTx(async (client) => {
      for (const m of matches) {
        await client.query(
          `INSERT INTO ride_dispatch_attempts (ride_id, captain_id, distance_meters, response)
           VALUES ($1, $2, $3, 'sent') ON CONFLICT DO NOTHING`,
          [rideId, m.captainId, m.distanceMeters],
        );
      }
    });
  }

  async acceptRideAtomic(params: {
    rideId: string;
    captainId: string;
    expectedVersion?: number;
  }): Promise<RideDto> {
    return this.withTx(async (client) => {
      const capRes = await client.query(
        `SELECT c.approval_status, c.is_online, v.id AS vehicle_id
         FROM captains c
         LEFT JOIN vehicles v ON v.captain_id = c.user_id AND v.is_active = TRUE
         WHERE c.user_id = $1 FOR SHARE`,
        [params.captainId],
      );
      const cap = capRes.rows[0];
      if (!cap || cap.approval_status !== 'approved' || !cap.is_online) {
        throw new ForbiddenError('يجب أن يكون الكابتن معتمداً ومتاحاً لقبول الرحلة.');
      }

      const activeCheck = await client.query(
        `SELECT id FROM rides
         WHERE captain_id = $1 AND status IN ('accepted', 'arrived', 'in_progress')`,
        [params.captainId],
      );
      if (activeCheck.rowCount && activeCheck.rowCount > 0) {
        throw new ConflictError('لديك رحلة نشطة حالياً بالفعل.');
      }

      const updateRes = await client.query(
        `UPDATE rides
         SET status = 'accepted',
             captain_id = $1,
             vehicle_id = $2,
             accepted_at = NOW(),
             version = version + 1
         WHERE id = $3
           AND status = 'searching'
           AND ($4::int IS NULL OR version = $4)
         RETURNING id`,
        [
          params.captainId,
          cap.vehicle_id ?? null,
          params.rideId,
          params.expectedVersion ?? null,
        ],
      );
      if (!updateRes.rowCount) {
        throw new ConflictError('تم قبول هذا الطلب من كابتن آخر للتو.');
      }

      await client.query(
        `UPDATE ride_dispatch_attempts
         SET response = CASE WHEN captain_id = $2 THEN 'accepted' ELSE 'claimed_by_other' END,
             responded_at = NOW()
         WHERE ride_id = $1`,
        [params.rideId, params.captainId],
      );
      await client.query(
        `INSERT INTO ride_events (ride_id, from_status, to_status, actor_id, actor_role)
         VALUES ($1, 'searching', 'accepted', $2, 'captain')`,
        [params.rideId, params.captainId],
      );

      const full = await client.query(`${this.rideSelectSql} WHERE r.id = $1`, [
        params.rideId,
      ]);
      return this.mapRideRow(full.rows[0]);
    });
  }

  async rejectRide(params: { rideId: string; captainId: string }): Promise<void> {
    await this.pool.query(
      `INSERT INTO ride_dispatch_attempts (ride_id, captain_id, distance_meters, response, responded_at)
       VALUES ($1, $2, 0, 'rejected', NOW())
       ON CONFLICT (ride_id, captain_id) DO UPDATE
       SET response = 'rejected', responded_at = NOW()`,
      [params.rideId, params.captainId],
    );
  }

  async updateRideStatus(params: {
    rideId: string;
    actorId: string;
    actorRole: UserRole;
    nextStatus: RideDispatchStatus;
    cancelReason?: string;
  }): Promise<RideDto> {
    return this.withTx(async (client) => {
      const curRes = await client.query(
        'SELECT id, status, passenger_id, captain_id, final_fare_iqd FROM rides WHERE id = $1 FOR UPDATE',
        [params.rideId],
      );
      if (!curRes.rowCount) throw new NotFoundError('الرحلة غير موجودة.');
      const cur = curRes.rows[0];
      const fromStatus = cur.status as RideDispatchStatus;

      if (params.actorRole === 'passenger' && cur.passenger_id !== params.actorId) {
        throw new ForbiddenError('لا تملك صلاحية تعديل هذه الرحلة.');
      }
      if (params.actorRole === 'captain' && cur.captain_id !== params.actorId) {
        throw new ForbiddenError('هذه الرحلة غير مسندة إليك.');
      }
      if (!RideStateMachine.canTransition(fromStatus, params.nextStatus)) {
        throw new BadRequestError(`انتقال غير صالح من ${fromStatus} إلى ${params.nextStatus}.`);
      }

      const timestampCol =
        params.nextStatus === 'arrived'
          ? 'arrived_at'
          : params.nextStatus === 'in_progress'
            ? 'started_at'
            : params.nextStatus === 'completed'
              ? 'completed_at'
              : 'cancelled_at';

      await client.query(
        `UPDATE rides
         SET status = $1,
             version = version + 1,
             ${timestampCol} = NOW(),
             cancelled_by = CASE WHEN $1 = 'cancelled' THEN $2 ELSE cancelled_by END,
             cancel_reason = CASE WHEN $1 = 'cancelled' THEN $3 ELSE cancel_reason END
         WHERE id = $4`,
        [
          params.nextStatus,
          params.actorRole,
          params.cancelReason ?? null,
          params.rideId,
        ],
      );

      await client.query(
        `INSERT INTO ride_events (ride_id, from_status, to_status, actor_id, actor_role)
         VALUES ($1, $2, $3, $4, $5)`,
        [params.rideId, fromStatus, params.nextStatus, params.actorId, params.actorRole],
      );

      if (params.nextStatus === 'completed' && cur.captain_id) {
        const fare = Number(cur.final_fare_iqd);
        await client.query(
          `INSERT INTO ride_payments (ride_id, gross_fare_iqd, platform_commission_iqd, captain_net_iqd)
           VALUES ($1, $2, 0, $2) ON CONFLICT (ride_id) DO NOTHING`,
          [params.rideId, fare],
        );
        await client.query(
          `UPDATE captains
           SET total_trips = total_trips + 1,
               total_earnings_iqd = total_earnings_iqd + $1
           WHERE user_id = $2`,
          [fare, cur.captain_id],
        );
        await client.query(
          `UPDATE users SET passenger_total_trips = passenger_total_trips + 1 WHERE id = $1`,
          [cur.passenger_id],
        );
      }

      const full = await client.query(`${this.rideSelectSql} WHERE r.id = $1`, [
        params.rideId,
      ]);
      return this.mapRideRow(full.rows[0]);
    });
  }

  async getActiveRideForUser(
    userId: string,
    role: UserRole,
  ): Promise<RideDto | null> {
    const col = role === 'captain' ? 'r.captain_id' : 'r.passenger_id';
    const res = await this.pool.query(
      `${this.rideSelectSql}
       WHERE ${col} = $1 AND r.status IN ('searching', 'accepted', 'arrived', 'in_progress')
       ORDER BY r.created_at DESC LIMIT 1`,
      [userId],
    );
    if (!res.rowCount) return null;
    return this.mapRideRow(res.rows[0]);
  }

  async getRideById(rideId: string): Promise<RideDto | null> {
    const res = await this.pool.query(`${this.rideSelectSql} WHERE r.id = $1`, [
      rideId,
    ]);
    return res.rowCount ? this.mapRideRow(res.rows[0]) : null;
  }

  async listCaptainRides(captainId: string): Promise<Array<Record<string, unknown>>> {
    const res = await this.pool.query(
      `SELECT r.id AS ride_id, r.completed_at AS date, pu.full_name AS passenger_name,
              r.origin_name AS origin, r.destination_name AS destination,
              r.final_fare_iqd AS fare_iqd, r.distance_km
       FROM rides r
       JOIN users pu ON pu.id = r.passenger_id
       WHERE r.captain_id = $1 AND r.status = 'completed'
       ORDER BY r.completed_at DESC LIMIT 100`,
      [captainId],
    );
    return res.rows;
  }

  async listPassengerRides(passengerId: string): Promise<Array<Record<string, unknown>>> {
    const res = await this.pool.query(
      `SELECT r.id AS ride_id, COALESCE(r.completed_at, r.created_at) AS date,
              COALESCE(cu.full_name, 'كابتن درب') AS captain_name,
              r.origin_name AS origin, r.destination_name AS destination,
              r.final_fare_iqd AS fare_iqd, r.distance_km, r.status
       FROM rides r
       LEFT JOIN users cu ON cu.id = r.captain_id
       WHERE r.passenger_id = $1
       ORDER BY r.created_at DESC LIMIT 100`,
      [passengerId],
    );
    return res.rows;
  }

  async submitRating(params: {
    rideId: string;
    raterId: string;
    raterRole: 'passenger' | 'captain';
    stars: number;
    comment?: string;
  }): Promise<{ newRating: number }> {
    return this.withTx(async (client) => {
      const rideRes = await client.query(
        'SELECT passenger_id, captain_id, status FROM rides WHERE id = $1',
        [params.rideId],
      );
      const ride = rideRes.rows[0];
      if (!ride || ride.status !== 'completed') {
        throw new BadRequestError('يمكن تقييم الرحلة بعد اكتمالها فقط.');
      }
      const rateeId =
        params.raterRole === 'passenger' ? ride.captain_id : ride.passenger_id;
      if (!rateeId) throw new BadRequestError('لا يوجد طرف آخر لتقييمه.');

      await client.query(
        `INSERT INTO ride_ratings (ride_id, rater_id, ratee_id, rater_role, stars, comment)
         VALUES ($1, $2, $3, $4, $5, $6)
         ON CONFLICT (ride_id, rater_id) DO UPDATE SET stars = EXCLUDED.stars, comment = EXCLUDED.comment`,
        [
          params.rideId,
          params.raterId,
          rateeId,
          params.raterRole,
          params.stars,
          params.comment ?? null,
        ],
      );

      const avgRes = await client.query(
        `SELECT ROUND(AVG(stars)::numeric, 2) AS avg_stars FROM ride_ratings WHERE ratee_id = $1`,
        [rateeId],
      );
      const newRating = Number(avgRes.rows[0].avg_stars ?? 5);
      if (params.raterRole === 'passenger') {
        await client.query('UPDATE captains SET rating = $1 WHERE user_id = $2', [
          newRating,
          rateeId,
        ]);
      } else {
        await client.query('UPDATE users SET passenger_rating = $1 WHERE id = $2', [
          newRating,
          rateeId,
        ]);
      }
      return { newRating };
    });
  }

  async close(): Promise<void> {
    await this.pool.end();
  }
}
