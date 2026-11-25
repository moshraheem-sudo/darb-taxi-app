import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { z } from 'zod';
import { IDbStore } from '../db/types';
import { AuthService } from '../services/authService';
import { createAuthMiddleware } from '../middleware/auth';

const requestOtpSchema = z.object({
  full_name: z.string().trim().min(2).max(120).optional().default('مستخدم درب'),
  phone: z.string().trim().min(7).max(24),
  role: z.enum(['passenger', 'captain', 'admin']).default('passenger'),
});

const verifyOtpSchema = z.object({
  phone: z.string().trim().min(7).max(24),
  code: z.string().trim().min(4).max(10),
  role: z.enum(['passenger', 'captain', 'admin']).default('passenger'),
  full_name: z.string().trim().min(2).max(120).optional(),
});

const refreshSchema = z.object({
  refresh_token: z.string().min(16),
  role: z.enum(['passenger', 'captain', 'admin']).default('passenger'),
});

const fcmSchema = z.object({
  fcm_token: z.string().min(10).max(512),
  platform: z.enum(['android', 'ios', 'web']).default('android'),
});

export function createAuthRouter(store: IDbStore, authService: AuthService): Router {
  const router = Router();
  const requireAuth = createAuthMiddleware(authService);

  const otpLimiter = rateLimit({
    windowMs: 10 * 60 * 1000,
    max: 30,
    standardHeaders: true,
    legacyHeaders: false,
    skip: () => process.env.NODE_ENV === 'test',
  });

  router.post('/auth/otp/request', otpLimiter, async (req, res, next) => {
    try {
      const body = requestOtpSchema.parse(req.body);
      const out = await authService.requestOtp({
        fullName: body.full_name,
        phone: body.phone,
        role: body.role,
      });
      res.json(out);
    } catch (err) {
      next(err);
    }
  });

  router.post('/auth/otp/verify', otpLimiter, async (req, res, next) => {
    try {
      const body = verifyOtpSchema.parse(req.body);
      const out = await authService.verifyOtp({
        phone: body.phone,
        code: body.code,
        role: body.role,
        fullNameFallback: body.full_name,
      });
      res.json(out);
    } catch (err) {
      next(err);
    }
  });

  router.post('/auth/token/refresh', async (req, res, next) => {
    try {
      const body = refreshSchema.parse(req.body);
      const out = await authService.refresh(body.refresh_token, body.role);
      res.json(out);
    } catch (err) {
      next(err);
    }
  });

  router.post('/auth/logout', async (req, res, next) => {
    try {
      const refreshToken =
        typeof req.body?.refresh_token === 'string'
          ? req.body.refresh_token
          : undefined;
      await authService.logout(refreshToken);
      res.status(204).send();
    } catch (err) {
      next(err);
    }
  });

  router.post('/notifications/fcm-token', requireAuth, async (req, res, next) => {
    try {
      const body = fcmSchema.parse(req.body);
      await store.registerFcmToken({
        userId: req.auth!.sub,
        fcmToken: body.fcm_token,
        platform: body.platform,
      });
      res.json({ ok: true });
    } catch (err) {
      next(err);
    }
  });

  return router;
}
