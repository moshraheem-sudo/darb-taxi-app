import { AddressInfo } from 'node:net';
import { Pool } from 'pg';
import { io as ioClient, Socket } from 'socket.io-client';
import request from 'supertest';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createBackendApp, BackendAppContext } from '../src/app';
import { loadEnv } from '../src/config/env';
import { PgStore } from '../src/db/pgStore';
import { IFcmService, PushPayload } from '../src/services/fcmService';

class MockFcm implements IFcmService {
  public sent: PushPayload[] = [];
  async sendPush(payload: PushPayload): Promise<void> {
    this.sent.push(payload);
  }
}

const dbUrl = process.env.DATABASE_URL;
const describeIfPg = dbUrl ? describe : describe.skip;

describeIfPg('PostgreSQL + PostGIS PgStore Integration', () => {
  let pool: Pool;
  let ctx: BackendAppContext;
  let fcm: MockFcm;
  let baseUrl: string;
  const openSockets: Socket[] = [];

  beforeAll(async () => {
    process.env.NODE_ENV = 'test';
    process.env.OTP_DEV_ECHO = 'true';
    const env = loadEnv();
    pool = new Pool({ connectionString: dbUrl });
    try {
      await pool.query('SELECT 1');
    } catch (err) {
      throw new Error(
        `Cannot connect to PostgreSQL at DATABASE_URL (${dbUrl}). Make sure Docker Desktop / PostgreSQL 16 + PostGIS is running and migrations are applied. Original error: ${(err as Error).message}`,
      );
    }
    fcm = new MockFcm();
    ctx = createBackendApp({ env, store: new PgStore(pool), fcm });
    await new Promise<void>((resolve) => {
      ctx.httpServer.listen(0, '127.0.0.1', () => resolve());
    });
    const addr = ctx.httpServer.address() as AddressInfo;
    baseUrl = `http://127.0.0.1:${addr.port}`;
  });

  afterAll(async () => {
    for (const s of openSockets) s.disconnect();
    if (ctx) {
      ctx.realtime.io.close();
      await new Promise<void>((resolve) =>
        ctx.httpServer.close(() => resolve()),
      );
      await ctx.store.close();
    } else if (pool) {
      await pool.end();
    }
  });

  async function auth(
    phone: string,
    role: 'passenger' | 'captain' | 'admin',
    fullName: string,
  ) {
    const r = await request(ctx.app)
      .post('/auth/otp/request')
      .send({ phone, role, full_name: fullName })
      .expect(200);
    const v = await request(ctx.app)
      .post('/auth/otp/verify')
      .send({ phone, role, code: r.body.dev_code, full_name: fullName })
      .expect(200);
    return v.body as { access_token: string; user: { id: string } };
  }

  it('runs full PostGIS geospatial dispatch, concurrent atomic accept, and lifecycle on PostgreSQL', async () => {
    const stamp = Date.now().toString().slice(-6);
    const admin = await auth(ctx.app ? `+9647801${stamp}` : '', 'admin', 'PG Admin');
    const pax = await auth(`+9647802${stamp}`, 'passenger', 'PG Passenger');
    const cap1 = await auth(`+9647803${stamp}`, 'captain', 'PG Captain 1');
    const cap2 = await auth(`+9647804${stamp}`, 'captain', 'PG Captain 2');

    for (const [idx, cap] of [cap1, cap2].entries()) {
      await request(ctx.app)
        .post('/captain/profile')
        .set('Authorization', `Bearer ${cap.access_token}`)
        .send({
          full_name: `PG Captain ${idx + 1}`,
          car_model: 'Hyundai Elantra',
          car_color: 'أسود',
          plate_number: `PG-${stamp}-${idx}`,
          vehicle_tier: 'saver',
        })
        .expect(200);

      await request(ctx.app)
        .patch(`/admin/captains/${cap.user.id}/approval`)
        .set('Authorization', `Bearer ${admin.access_token}`)
        .send({ status: 'approved' })
        .expect(200);

      await request(ctx.app)
        .post('/captain/availability')
        .set('Authorization', `Bearer ${cap.access_token}`)
        .send({ is_online: true, lat: 32.513, lng: 45.8185 })
        .expect(200);
    }

    const cap1Socket = ioClient(baseUrl, {
      auth: { token: cap1.access_token },
      transports: ['websocket'],
    });
    openSockets.push(cap1Socket);
    await new Promise<void>((r) => cap1Socket.on('connect', () => r()));

    const idemp = `pg-idemp-${stamp}`;
    const r1 = await request(ctx.app)
      .post('/rides')
      .set('Authorization', `Bearer ${pax.access_token}`)
      .set('Idempotency-Key', idemp)
      .send({
        origin_lat: 32.5128,
        origin_lng: 45.818,
        origin_name: 'الكوت، المركز',
        destination_lat: 32.522,
        destination_lng: 45.829,
        destination_name: 'جامعة واسط',
        selected_tier: 'saver',
      })
      .expect(201);

    // Idempotency check in PostgreSQL
    const r2 = await request(ctx.app)
      .post('/rides')
      .set('Authorization', `Bearer ${pax.access_token}`)
      .set('Idempotency-Key', idemp)
      .send({
        origin_lat: 32.5128,
        origin_lng: 45.818,
        origin_name: 'الكوت، المركز',
        destination_lat: 32.522,
        destination_lng: 45.829,
        destination_name: 'جامعة واسط',
        selected_tier: 'saver',
      })
      .expect(200);
    expect(r2.body.ride_id).toBe(r1.body.ride_id);

    // Concurrent accept in PostgreSQL
    const [a1, a2] = await Promise.all([
      request(ctx.app)
        .post(`/rides/${r1.body.ride_id}/accept`)
        .set('Authorization', `Bearer ${cap1.access_token}`)
        .send({ expected_version: 1 }),
      request(ctx.app)
        .post(`/rides/${r1.body.ride_id}/accept`)
        .set('Authorization', `Bearer ${cap2.access_token}`)
        .send({ expected_version: 1 }),
    ]);
    expect([a1.status, a2.status].sort()).toEqual([200, 409]);

    const winner = a1.status === 200 ? cap1.access_token : cap2.access_token;
    await request(ctx.app)
      .patch(`/rides/${r1.body.ride_id}/status`)
      .set('Authorization', `Bearer ${winner}`)
      .send({ status: 'arrived' })
      .expect(200);
    await request(ctx.app)
      .patch(`/rides/${r1.body.ride_id}/status`)
      .set('Authorization', `Bearer ${winner}`)
      .send({ status: 'in_progress' })
      .expect(200);
    await request(ctx.app)
      .patch(`/rides/${r1.body.ride_id}/status`)
      .set('Authorization', `Bearer ${winner}`)
      .send({ status: 'completed' })
      .expect(200);
  });
});
