import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { Router } from 'express';
import multer from 'multer';
import { z } from 'zod';
import { AppEnv } from '../config/env';
import { DocType } from '../domain/rideStateMachine';
import { BadRequestError, IDbStore } from '../db/types';
import { createAuthMiddleware, requireRole } from '../middleware/auth';
import { RealtimeGateway } from '../realtime/socketServer';
import { AuthService } from '../services/authService';
import { IFcmService } from '../services/fcmService';

const profileSchema = z.object({
  full_name: z.string().trim().min(2).max(120),
  car_model: z.string().trim().min(2).max(100),
  car_color: z.string().trim().max(50).optional().default(''),
  plate_number: z.string().trim().min(2).max(32),
  vehicle_tier: z.enum(['saver', 'plus', 'box']).default('saver'),
});

const availabilitySchema = z.object({
  is_online: z.boolean(),
  lat: z.number().min(-90).max(90).optional(),
  lng: z.number().min(-180).max(180).optional(),
});

const locationSchema = z.object({
  lat: z.number().min(-90).max(90),
  lng: z.number().min(-180).max(180),
  heading: z.number().optional().default(0),
  ride_id: z.string().optional(),
});

const approvalSchema = z.object({
  status: z.enum(['approved', 'rejected']),
  reason: z.string().max(500).optional(),
});

const ALLOWED_DOC_TYPES = new Set<DocType>([
  'nationalId',
  'driverLicense',
  'vehicleReg',
  'carPhoto',
]);

export function createCaptainRouter(
  store: IDbStore,
  authService: AuthService,
  realtime: RealtimeGateway,
  fcm: IFcmService,
  env: AppEnv,
): Router {
  const router = Router();
  const requireAuth = createAuthMiddleware(authService);

  fs.mkdirSync(env.UPLOAD_DIR, { recursive: true });
  const upload = multer({
    storage: multer.diskStorage({
      destination: (_req, _file, cb) => cb(null, env.UPLOAD_DIR),
      filename: (req, file, cb) => {
        const ext = path.extname(file.originalname).toLowerCase() || '.jpg';
        const safeName = `${req.auth?.sub ?? 'anon'}_${Date.now()}_${crypto.randomBytes(6).toString('hex')}${ext}`;
        cb(null, safeName);
      },
    }),
    limits: { fileSize: 5 * 1024 * 1024 },
    fileFilter: (_req, file, cb) => {
      if (['image/jpeg', 'image/png', 'image/webp', 'application/pdf'].includes(file.mimetype)) {
        cb(null, true);
      } else {
        cb(new BadRequestError('نوع الملف غير مدعوم.'));
      }
    },
  });

  router.get('/captain/profile', requireAuth, requireRole('captain'), async (req, res, next) => {
    try {
      const profile = await store.getCaptainProfile(req.auth!.sub);
      res.json(profile);
    } catch (err) {
      next(err);
    }
  });

  router.post('/captain/profile', requireAuth, requireRole('captain'), async (req, res, next) => {
    try {
      const body = profileSchema.parse(req.body);
      const profile = await store.upsertCaptainProfile({
        captainId: req.auth!.sub,
        fullName: body.full_name,
        carModel: body.car_model,
        carColor: body.car_color,
        plateNumber: body.plate_number,
        vehicleTier: body.vehicle_tier,
      });
      res.json(profile);
    } catch (err) {
      next(err);
    }
  });

  router.post(
    '/captain/documents',
    requireAuth,
    requireRole('captain'),
    upload.single('file'),
    async (req, res, next) => {
      try {
        const docType = String(req.body?.doc_type ?? '') as DocType;
        if (!ALLOWED_DOC_TYPES.has(docType)) {
          throw new BadRequestError('نوع المستمسك غير صالح.');
        }
        if (!req.file) {
          throw new BadRequestError('يرجى إرفاق ملف المستمسك.');
        }
        const profile = await store.upsertCaptainDocument({
          captainId: req.auth!.sub,
          docType,
          storageKey: req.file.filename,
          mimeType: req.file.mimetype,
        });
        res.json(profile);
      } catch (err) {
        next(err);
      }
    },
  );

  router.post('/captain/availability', requireAuth, requireRole('captain'), async (req, res, next) => {
    try {
      const body = availabilitySchema.parse(req.body);
      const result = await store.setCaptainAvailability({
        captainId: req.auth!.sub,
        isOnline: body.is_online,
        lat: body.lat,
        lng: body.lng,
      });
      res.json(result);
    } catch (err) {
      next(err);
    }
  });

  router.post('/captain/location', requireAuth, requireRole('captain'), async (req, res, next) => {
    try {
      const body = locationSchema.parse(req.body);
      await store.updateCaptainLocation({
        captainId: req.auth!.sub,
        lat: body.lat,
        lng: body.lng,
        heading: body.heading,
      });
      if (body.ride_id) {
        realtime.io.to(`ride:${body.ride_id}`).emit('driver:location_update', {
          lat: body.lat,
          lng: body.lng,
          heading: body.heading,
          ride_id: body.ride_id,
        });
      }
      res.status(204).send();
    } catch (err) {
      next(err);
    }
  });

  router.get('/captain/rides', requireAuth, requireRole('captain'), async (req, res, next) => {
    try {
      const rides = await store.listCaptainRides(req.auth!.sub);
      res.json(rides);
    } catch (err) {
      next(err);
    }
  });

  // Admin endpoints for reviewing & approving captains
  router.get('/admin/captains/pending', requireAuth, requireRole('admin'), async (_req, res, next) => {
    try {
      const pending = await store.listPendingCaptains();
      res.json(pending);
    } catch (err) {
      next(err);
    }
  });

  router.patch('/admin/captains/:id/approval', requireAuth, requireRole('admin'), async (req, res, next) => {
    try {
      const body = approvalSchema.parse(req.body);
      const updated = await store.setCaptainApproval({
        captainId: String(req.params.id),
        adminId: req.auth!.sub,
        status: body.status,
        reason: body.reason,
      });
      const tokens = await store.getUserFcmTokens(updated.id);
      if (tokens.length > 0) {
        await fcm.sendPush({
          tokens,
          title:
            body.status === 'approved'
              ? 'تمت الموافقة على حساب الكابتن'
              : 'تم رفض طلب الكابتن',
          body:
            body.status === 'approved'
              ? 'يمكنك الآن تفعيل وضع متاح واستقبال طلبات الزبائن.'
              : body.reason || 'يرجى مراجعة المستمسكات وإعادة رفعها.',
        });
      }
      res.json(updated);
    } catch (err) {
      next(err);
    }
  });

  return router;
}
