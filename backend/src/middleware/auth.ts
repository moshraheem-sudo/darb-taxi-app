import { NextFunction, Request, Response } from 'express';
import { ZodError } from 'zod';
import { UserRole } from '../domain/rideStateMachine';
import {
  BadRequestError,
  ConflictError,
  ForbiddenError,
  NotFoundError,
  UnauthorizedError,
} from '../db/types';
import { AccessTokenClaims, AuthService } from '../services/authService';
import { logger } from '../config/logger';

declare global {
  namespace Express {
    interface Request {
      auth?: AccessTokenClaims;
    }
  }
}

export function createAuthMiddleware(authService: AuthService) {
  return (req: Request, _res: Response, next: NextFunction) => {
    const header = req.headers.authorization;
    if (!header || !header.startsWith('Bearer ')) {
      return next(new UnauthorizedError('مطلوب رمز دخول صالح.'));
    }
    try {
      req.auth = authService.verifyAccessToken(header.slice(7).trim());
      return next();
    } catch (err) {
      return next(err);
    }
  };
}

export function requireRole(...allowed: UserRole[]) {
  return (req: Request, _res: Response, next: NextFunction) => {
    const auth = req.auth;
    if (!auth) return next(new UnauthorizedError('غير مصرح.'));
    if (!allowed.includes(auth.role) && !auth.roles.some((r) => allowed.includes(r))) {
      return next(new ForbiddenError('لا تملك الصلاحية المطلوبة لهذا الإجراء.'));
    }
    return next();
  };
}

export function errorHandler(
  err: unknown,
  _req: Request,
  res: Response,
  _next: NextFunction,
) {
  if (err instanceof ZodError) {
    return res.status(400).json({
      error: 'validation_error',
      message: 'بيانات المدخلات غير صالحة.',
      details: err.issues.map((i) => ({ path: i.path.join('.'), message: i.message })),
    });
  }
  if (
    err instanceof BadRequestError ||
    err instanceof UnauthorizedError ||
    err instanceof ForbiddenError ||
    err instanceof NotFoundError ||
    err instanceof ConflictError
  ) {
    return res.status(err.statusCode).json({
      error: err.constructor.name,
      message: err.message,
    });
  }
  logger.error({ err }, 'Unhandled API error');
  return res.status(500).json({
    error: 'internal_error',
    message: 'حدث خطأ غير متوقع في الخادم.',
  });
}
