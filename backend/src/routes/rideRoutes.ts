import { Router } from 'express';
import { z } from 'zod';
import { RideDispatchStatus } from '../domain/rideStateMachine';
import { IDbStore } from '../db/types';
import { createAuthMiddleware, requireRole } from '../middleware/auth';
import { RealtimeGateway } from '../realtime/socketServer';
import { AuthService } from '../services/authService';
import { DispatchService } from '../services/dispatchService';
import { IFcmService } from '../services/fcmService';

const createRideSchema = z.object({
  origin_lat: z.number().min(-90).max(90),
  origin_lng: z.number().min(-180).max(180),
  origin_name: z.string().trim().min(1).max(255),
  destination_lat: z.number().min(-90).max(90),
  destination_lng: z.number().min(-180).max(180),
  destination_name: z.string().trim().min(1).max(255),
  second_destination_name: z.string().trim().max(255).optional(),
  second_destination_lat: z.number().min(-90).max(90).optional(),
  second_destination_lng: z.number().min(-180).max(180).optional(),
  stop_wait_minutes: z.number().int().min(0).max(180).optional().default(0),
  round_trip: z.boolean().optional().default(false),
  service_category: z.enum(['taxi', 'box']).optional().default('taxi'),
  selected_tier: z.enum(['saver', 'plus', 'box']).optional().default('saver'),
  promo_code: z.string().trim().max(32).optional(),
});

const acceptRideSchema = z.object({
  expected_version: z.number().int().positive().optional(),
});

const updateStatusSchema = z.object({
  status: z.enum(['arrived', 'in_progress', 'completed', 'cancelled']),
  cancel_reason: z.string().max(300).optional(),
});

const ratingSchema = z.object({
  stars: z.number().int().min(1).max(5),
  comment: z.string().max(500).optional(),
});

export function createRideRouter(
  store: IDbStore,
  authService: AuthService,
  dispatchService: DispatchService,
  realtime: RealtimeGateway,
  fcm: IFcmService,
): Router {
  const router = Router();
  const requireAuth = createAuthMiddleware(authService);

  router.post('/rides', requireAuth, requireRole('passenger'), async (req, res, next) => {
    try {
      const body = createRideSchema.parse(req.body);
      const idempotencyKey =
        typeof req.headers['idempotency-key'] === 'string'
          ? req.headers['idempotency-key'].trim()
          : undefined;

      const { ride, deduplicated } = await store.createRide({
        passengerId: req.auth!.sub,
        idempotencyKey,
        originLat: body.origin_lat,
        originLng: body.origin_lng,
        originName: body.origin_name,
        destinationLat: body.destination_lat,
        destinationLng: body.destination_lng,
        destinationName: body.destination_name,
        secondDestinationName: body.second_destination_name,
        secondDestinationLat: body.second_destination_lat,
        secondDestinationLng: body.second_destination_lng,
        stopWaitMinutes: body.stop_wait_minutes,
        roundTrip: body.round_trip,
        serviceCategory: body.service_category,
        selectedTier: body.selected_tier,
        promoCode: body.promo_code,
      });

      if (!deduplicated) {
        await dispatchService.dispatchRideToNearbyCaptains(ride);
      }
      res.status(deduplicated ? 200 : 201).json(ride);
    } catch (err) {
      next(err);
    }
  });

  router.get('/rides/active', requireAuth, async (req, res, next) => {
    try {
      const active = await store.getActiveRideForUser(req.auth!.sub, req.auth!.role);
      res.json(active);
    } catch (err) {
      next(err);
    }
  });

  router.post('/rides/:rideId/accept', requireAuth, requireRole('captain'), async (req, res, next) => {
    try {
      const body = acceptRideSchema.parse(req.body ?? {});
      const updated = await store.acceptRideAtomic({
        rideId: String(req.params.rideId),
        captainId: req.auth!.sub,
        expectedVersion: body.expected_version,
      });
      realtime.emitRideClaimed(updated.ride_id);
      realtime.emitRideStatusChanged(updated);

      const paxTokens = await store.getUserFcmTokens(updated.passenger_id);
      if (paxTokens.length > 0) {
        await fcm.sendPush({
          tokens: paxTokens,
          title: 'تم قبول رحلتك',
          body: `الكابتن ${updated.captain_name ?? 'درب'} في طريقه إليك`,
          data: { ride_id: updated.ride_id, status: updated.status },
        });
      }
      res.json(updated);
    } catch (err) {
      next(err);
    }
  });

  router.post('/rides/:rideId/reject', requireAuth, requireRole('captain'), async (req, res, next) => {
    try {
      await store.rejectRide({
        rideId: String(req.params.rideId),
        captainId: req.auth!.sub,
      });
      res.status(204).send();
    } catch (err) {
      next(err);
    }
  });

  router.patch('/rides/:rideId/status', requireAuth, async (req, res, next) => {
    try {
      const body = updateStatusSchema.parse(req.body);
      const updated = await store.updateRideStatus({
        rideId: String(req.params.rideId),
        actorId: req.auth!.sub,
        actorRole: req.auth!.role,
        nextStatus: body.status as RideDispatchStatus,
        cancelReason: body.cancel_reason,
      });
      realtime.emitRideStatusChanged(updated);
      res.json(updated);
    } catch (err) {
      next(err);
    }
  });

  router.post('/rides/:rideId/rate', requireAuth, async (req, res, next) => {
    try {
      const body = ratingSchema.parse(req.body);
      const raterRole = req.auth!.role === 'captain' ? 'captain' : 'passenger';
      const result = await store.submitRating({
        rideId: String(req.params.rideId),
        raterId: req.auth!.sub,
        raterRole,
        stars: body.stars,
        comment: body.comment,
      });
      res.status(201).json({ ok: true, new_rating: result.newRating });
    } catch (err) {
      next(err);
    }
  });

  router.get('/passenger/rides', requireAuth, requireRole('passenger'), async (req, res, next) => {
    try {
      const rides = await store.listPassengerRides(req.auth!.sub);
      res.json(rides);
    } catch (err) {
      next(err);
    }
  });

  return router;
}
