import { AddressInfo } from 'node:net';
import { io as ioClient, Socket } from 'socket.io-client';
import request from 'supertest';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { createBackendApp, BackendAppContext } from '../src/app';
import { loadEnv } from '../src/config/env';
import { MemoryStore } from '../src/db/memoryStore';
import { IFcmService, PushPayload } from '../src/services/fcmService';

class MockFcmService implements IFcmService {
  public sent: PushPayload[] = [];
  async sendPush(payload: PushPayload): Promise<void> {
    this.sent.push(payload);
  }
}

async function authUser(
  app: BackendAppContext['app'],
  phone: string,
  role: 'passenger' | 'captain' | 'admin',
  fullName: string,
) {
  const reqRes = await request(app)
    .post('/auth/otp/request')
    .send({ phone, role, full_name: fullName })
    .expect(200);

  const verRes = await request(app)
    .post('/auth/otp/verify')
    .send({ phone, role, code: reqRes.body.dev_code, full_name: fullName })
    .expect(200);

  return verRes.body as {
    access_token: string;
    refresh_token: string;
    user: { id: string; fullName: string; roles: string[] };
  };
}

describe('Darb Taxi Backend', () => {
  let ctx: BackendAppContext;
  let fcm: MockFcmService;
  let baseUrl: string;
  const openSockets: Socket[] = [];

  beforeEach(async () => {
    process.env.NODE_ENV = 'test';
    process.env.OTP_DEV_ECHO = 'true';
    const env = loadEnv();
    fcm = new MockFcmService();
    ctx = createBackendApp({ env, store: new MemoryStore(), fcm });
    await new Promise<void>((resolve) => {
      ctx.httpServer.listen(0, '127.0.0.1', () => resolve());
    });
    const addr = ctx.httpServer.address() as AddressInfo;
    baseUrl = `http://127.0.0.1:${addr.port}`;
  });

  afterEach(async () => {
    for (const s of openSockets) s.disconnect();
    openSockets.length = 0;
    ctx.realtime.io.close();
    await new Promise<void>((resolve) => ctx.httpServer.close(() => resolve()));
    await ctx.store.close();
  });

  it('handles OTP auth, invalid OTP rejection, and refresh token rotation', async () => {
    const reqRes = await request(ctx.app)
      .post('/auth/otp/request')
      .send({ phone: '+9647701112233', role: 'passenger', full_name: 'علي حسن' })
      .expect(200);

    expect(reqRes.body.dev_code).toMatch(/^\d{6}$/);

    await request(ctx.app)
      .post('/auth/otp/verify')
      .send({ phone: '+9647701112233', role: 'passenger', code: '000000' })
      .expect(401);

    const verRes = await request(ctx.app)
      .post('/auth/otp/verify')
      .send({
        phone: '+9647701112233',
        role: 'passenger',
        code: reqRes.body.dev_code,
      })
      .expect(200);

    expect(verRes.body.access_token).toBeTruthy();
    expect(verRes.body.refresh_token).toBeTruthy();

    const refRes = await request(ctx.app)
      .post('/auth/token/refresh')
      .send({ refresh_token: verRes.body.refresh_token, role: 'passenger' })
      .expect(200);

    expect(refRes.body.access_token).toBeTruthy();
    expect(refRes.body.refresh_token).not.toBe(verRes.body.refresh_token);
  });

  it('enforces RBAC and blocks unapproved captains from going online', async () => {
    const pax = await authUser(ctx.app, '+9647702000001', 'passenger', 'زبون');
    const cap = await authUser(ctx.app, '+9647702000002', 'captain', 'كابتن أحمد');
    const admin = await authUser(ctx.app, '+9647702000003', 'admin', 'المشرف');

    // Passenger cannot access admin endpoints
    await request(ctx.app)
      .get('/admin/captains/pending')
      .set('Authorization', `Bearer ${pax.access_token}`)
      .expect(403);

    // Unapproved captain cannot go online
    await request(ctx.app)
      .post('/captain/availability')
      .set('Authorization', `Bearer ${cap.access_token}`)
      .send({ is_online: true, lat: 32.5128, lng: 45.818 })
      .expect(403);

    // Captain submits profile -> pending -> admin approves -> captain goes online
    await request(ctx.app)
      .post('/captain/profile')
      .set('Authorization', `Bearer ${cap.access_token}`)
      .send({
        full_name: 'كابتن أحمد',
        car_model: 'Toyota Corolla',
        car_color: 'أبيض',
        plate_number: 'واسط 9988',
        vehicle_tier: 'saver',
      })
      .expect(200);

    const pendingRes = await request(ctx.app)
      .get('/admin/captains/pending')
      .set('Authorization', `Bearer ${admin.access_token}`)
      .expect(200);
    expect(pendingRes.body).toHaveLength(1);

    await request(ctx.app)
      .patch(`/admin/captains/${cap.user.id}/approval`)
      .set('Authorization', `Bearer ${admin.access_token}`)
      .send({ status: 'approved' })
      .expect(200);

    const onlineRes = await request(ctx.app)
      .post('/captain/availability')
      .set('Authorization', `Bearer ${cap.access_token}`)
      .send({ is_online: true, lat: 32.5128, lng: 45.818 })
      .expect(200);
    expect(onlineRes.body.is_online).toBe(true);
  });

  it('prevents concurrent double-acceptance (409 Conflict) and completes ride lifecycle with Socket.IO & FCM', async () => {
    const admin = await authUser(ctx.app, '+9647703000001', 'admin', 'مشرف');
    const pax = await authUser(ctx.app, '+9647703000002', 'passenger', 'زبون');
    const cap1 = await authUser(ctx.app, '+9647703000003', 'captain', 'كابتن 1');
    const cap2 = await authUser(ctx.app, '+9647703000004', 'captain', 'كابتن 2');

    for (const [idx, cap] of [cap1, cap2].entries()) {
      await request(ctx.app)
        .post('/captain/profile')
        .set('Authorization', `Bearer ${cap.access_token}`)
        .send({
          full_name: `كابتن ${idx + 1}`,
          car_model: 'Kia Optima',
          car_color: 'أبيض',
          plate_number: `واسط 100${idx}`,
          vehicle_tier: 'saver',
        })
        .expect(200);

      await request(ctx.app)
        .patch(`/admin/captains/${cap.user.id}/approval`)
        .set('Authorization', `Bearer ${admin.access_token}`)
        .send({ status: 'approved' })
        .expect(200);

      await request(ctx.app)
        .post('/notifications/fcm-token')
        .set('Authorization', `Bearer ${cap.access_token}`)
        .send({ fcm_token: `fcm-token-captain-${idx + 1}`, platform: 'android' })
        .expect(200);

      await request(ctx.app)
        .post('/captain/availability')
        .set('Authorization', `Bearer ${cap.access_token}`)
        .send({ is_online: true, lat: 32.513, lng: 45.8185 })
        .expect(200);
    }

    // Connect Socket.IO for passenger & captain 1
    const cap1Socket = ioClient(baseUrl, {
      auth: { token: cap1.access_token },
      transports: ['websocket'],
    });
    const paxSocket = ioClient(baseUrl, {
      auth: { token: pax.access_token },
      transports: ['websocket'],
    });
    openSockets.push(cap1Socket, paxSocket);

    await Promise.all([
      new Promise<void>((r) => cap1Socket.on('connect', () => r())),
      new Promise<void>((r) => paxSocket.on('connect', () => r())),
    ]);

    const receivedReqPromise = new Promise<Record<string, unknown>>((resolve) => {
      cap1Socket.once('ride:new_request', (data) => resolve(data));
    });

    // Create ride with Idempotency-Key
    const idempKey = 'ride-create-unique-key-1';
    const rideRes1 = await request(ctx.app)
      .post('/rides')
      .set('Authorization', `Bearer ${pax.access_token}`)
      .set('Idempotency-Key', idempKey)
      .send({
        origin_lat: 32.5128,
        origin_lng: 45.818,
        origin_name: 'الكوت، شارع الضفاف',
        destination_lat: 32.525,
        destination_lng: 45.83,
        destination_name: 'جامعة واسط',
        selected_tier: 'saver',
        promo_code: 'DARB500',
      })
      .expect(201);

    const rideRes2 = await request(ctx.app)
      .post('/rides')
      .set('Authorization', `Bearer ${pax.access_token}`)
      .set('Idempotency-Key', idempKey)
      .send({
        origin_lat: 32.5128,
        origin_lng: 45.818,
        origin_name: 'الكوت، شارع الضفاف',
        destination_lat: 32.525,
        destination_lng: 45.83,
        destination_name: 'جامعة واسط',
        selected_tier: 'saver',
      })
      .expect(200);

    expect(rideRes2.body.ride_id).toBe(rideRes1.body.ride_id);
    expect(rideRes1.body.discount_iqd).toBe(500);

    const socketReq = await receivedReqPromise;
    expect(socketReq.ride_id).toBe(rideRes1.body.ride_id);
    expect(fcm.sent.length).toBeGreaterThanOrEqual(2);

    // Simultaneous accept race by cap1 and cap2
    const [acc1, acc2] = await Promise.all([
      request(ctx.app)
        .post(`/rides/${rideRes1.body.ride_id}/accept`)
        .set('Authorization', `Bearer ${cap1.access_token}`)
        .send({ expected_version: 1 }),
      request(ctx.app)
        .post(`/rides/${rideRes1.body.ride_id}/accept`)
        .set('Authorization', `Bearer ${cap2.access_token}`)
        .send({ expected_version: 1 }),
    ]);

    const statuses = [acc1.status, acc2.status].sort();
    expect(statuses).toEqual([200, 409]);

    const winnerToken = acc1.status === 200 ? cap1.access_token : cap2.access_token;

    // Lifecycle transitions: arrived -> in_progress -> completed
    await request(ctx.app)
      .patch(`/rides/${rideRes1.body.ride_id}/status`)
      .set('Authorization', `Bearer ${winnerToken}`)
      .send({ status: 'arrived' })
      .expect(200);

    await request(ctx.app)
      .patch(`/rides/${rideRes1.body.ride_id}/status`)
      .set('Authorization', `Bearer ${winnerToken}`)
      .send({ status: 'in_progress' })
      .expect(200);

    await request(ctx.app)
      .patch(`/rides/${rideRes1.body.ride_id}/status`)
      .set('Authorization', `Bearer ${winnerToken}`)
      .send({ status: 'completed' })
      .expect(200);

    // Invalid transition after completion returns 400
    await request(ctx.app)
      .patch(`/rides/${rideRes1.body.ride_id}/status`)
      .set('Authorization', `Bearer ${winnerToken}`)
      .send({ status: 'cancelled' })
      .expect(400);

    // Rating
    const rateRes = await request(ctx.app)
      .post(`/rides/${rideRes1.body.ride_id}/rate`)
      .set('Authorization', `Bearer ${pax.access_token}`)
      .send({ stars: 5, comment: 'رحلة ممتازة' })
      .expect(201);
    expect(rateRes.body.ok).toBe(true);

    // History endpoints
    const capHist = await request(ctx.app)
      .get('/captain/rides')
      .set('Authorization', `Bearer ${winnerToken}`)
      .expect(200);
    expect(capHist.body).toHaveLength(1);

    const paxHist = await request(ctx.app)
      .get('/passenger/rides')
      .set('Authorization', `Bearer ${pax.access_token}`)
      .expect(200);
    expect(paxHist.body).toHaveLength(1);
  });

  it('supports captain document upload, Swagger UI, Socket.IO location tracking, and production OTP guard', async () => {
    const cap = await authUser(ctx.app, '+9647704000001', 'captain', 'كابتن مستمسكات');
    const pax = await authUser(ctx.app, '+9647704000002', 'passenger', 'زبون تتبع');
    const admin = await authUser(ctx.app, '+9647704000003', 'admin', 'مشرف');

    // Swagger / Health
    await request(ctx.app).get('/health').expect(200);
    const specRes = await request(ctx.app).get('/api-docs.json').expect(200);
    expect(specRes.body.openapi).toBe('3.0.3');
    expect(specRes.body.paths['/rides']).toBeTruthy();

    // Document upload (multipart/form-data)
    const uploadRes = await request(ctx.app)
      .post('/captain/documents')
      .set('Authorization', `Bearer ${cap.access_token}`)
      .field('doc_type', 'nationalId')
      .attach('file', Buffer.from('fake-jpeg-bytes'), {
        filename: 'id.jpg',
        contentType: 'image/jpeg',
      })
      .expect(200);
    expect(uploadRes.body.documents.nationalId).toBeTruthy();
    expect(uploadRes.body.approval_status).toBe('pending');

    // Production OTP & secret guard
    const savedEnv = { ...process.env };
    try {
      process.env.NODE_ENV = 'production';
      process.env.OTP_DEV_ECHO = 'true';
      expect(() => loadEnv()).toThrow();
    } finally {
      process.env = savedEnv;
    }

    // Admin approves & Socket.IO location update reaches passenger
    await request(ctx.app)
      .post('/captain/profile')
      .set('Authorization', `Bearer ${cap.access_token}`)
      .send({
        full_name: 'كابتن مستمسكات',
        car_model: 'Kia Cerato',
        car_color: 'رمادي',
        plate_number: 'واسط 7777',
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
      .send({ is_online: true, lat: 32.5129, lng: 45.8181 })
      .expect(200);

    const paxSocket = ioClient(baseUrl, {
      auth: { token: pax.access_token },
      transports: ['websocket'],
    });
    const capSocket = ioClient(baseUrl, {
      auth: { token: cap.access_token },
      transports: ['websocket'],
    });
    openSockets.push(paxSocket, capSocket);
    await Promise.all([
      new Promise<void>((r) => paxSocket.on('connect', () => r())),
      new Promise<void>((r) => capSocket.on('connect', () => r())),
    ]);

    const rideRes = await request(ctx.app)
      .post('/rides')
      .set('Authorization', `Bearer ${pax.access_token}`)
      .send({
        origin_lat: 32.5128,
        origin_lng: 45.818,
        origin_name: 'الكوت',
        destination_lat: 32.52,
        destination_lng: 45.825,
        destination_name: 'الشارع العام',
      })
      .expect(201);

    await request(ctx.app)
      .post(`/rides/${rideRes.body.ride_id}/accept`)
      .set('Authorization', `Bearer ${cap.access_token}`)
      .send({ expected_version: 1 })
      .expect(200);

    const locPromise = new Promise<{ lat: number; lng: number }>((resolve) => {
      paxSocket.once('driver:location_update', (d) => resolve(d));
    });
    capSocket.emit('captain:location', {
      lat: 32.515,
      lng: 45.82,
      heading: 90,
      ride_id: rideRes.body.ride_id,
    });
    const loc = await locPromise;
    expect(loc.lat).toBe(32.515);
  });
});
