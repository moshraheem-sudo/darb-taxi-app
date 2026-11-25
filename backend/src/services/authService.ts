import crypto from 'node:crypto';
import jwt from 'jsonwebtoken';
import { AppEnv } from '../config/env';
import { UserRole } from '../domain/rideStateMachine';
import { IDbStore, UnauthorizedError, UserEntity } from '../db/types';

export interface AccessTokenClaims {
  sub: string;
  phone: string;
  role: UserRole;
  roles: UserRole[];
}

export class AuthService {
  constructor(
    private readonly store: IDbStore,
    private readonly env: AppEnv,
  ) {}

  hashOtp(phone: string, code: string): string {
    return crypto
      .createHmac('sha256', this.env.OTP_SECRET)
      .update(`${phone}:${code}`)
      .digest('hex');
  }

  hashToken(token: string): string {
    return crypto.createHash('sha256').update(token).digest('hex');
  }

  async requestOtp(params: {
    fullName: string;
    phone: string;
    role: UserRole;
  }): Promise<{ message: string; expires_in_sec: number; dev_code?: string }> {
    const code = String(crypto.randomInt(100000, 999999));
    await this.store.createOtp({
      phone: params.phone,
      role: params.role,
      codeHash: this.hashOtp(params.phone, code),
      ttlSeconds: this.env.OTP_TTL_SECONDS,
    });
    return {
      message: 'تم إرسال رمز التحقق بنجاح.',
      expires_in_sec: this.env.OTP_TTL_SECONDS,
      ...(this.env.OTP_DEV_ECHO && this.env.NODE_ENV !== 'production'
        ? { dev_code: code }
        : {}),
    };
  }

  async verifyOtp(params: {
    phone: string;
    code: string;
    role: UserRole;
    fullNameFallback?: string;
  }) {
    const user = await this.store.verifyOtpAndUpsertUser({
      phone: params.phone,
      role: params.role,
      codeHash: this.hashOtp(params.phone, params.code),
      fullNameFallback: params.fullNameFallback?.trim() || 'مستخدم درب',
    });
    const tokens = await this.issueTokens(user, params.role);
    return { ...tokens, user, roles: user.roles };
  }

  async refresh(refreshToken: string, activeRole: UserRole) {
    const oldHash = this.hashToken(refreshToken);
    const nextRefresh = crypto.randomBytes(48).toString('hex');
    const expiresAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);
    const user = await this.store.rotateRefreshToken({
      oldTokenHash: oldHash,
      newTokenHash: this.hashToken(nextRefresh),
      expiresAt,
    });
    const role = user.roles.includes(activeRole) ? activeRole : user.roles[0];
    const accessToken = this.signAccessToken(user, role);
    return { access_token: accessToken, refresh_token: nextRefresh };
  }

  async logout(refreshToken?: string): Promise<void> {
    if (!refreshToken) return;
    await this.store.revokeRefreshToken(this.hashToken(refreshToken));
  }

  private signAccessToken(user: UserEntity, activeRole: UserRole): string {
    const claims: AccessTokenClaims = {
      sub: user.id,
      phone: user.phone,
      role: activeRole,
      roles: user.roles,
    };
    return jwt.sign(claims, this.env.JWT_ACCESS_SECRET, {
      expiresIn: this.env.JWT_ACCESS_EXPIRES_IN as jwt.SignOptions['expiresIn'],
    });
  }

  private async issueTokens(user: UserEntity, activeRole: UserRole) {
    const accessToken = this.signAccessToken(user, activeRole);
    const refreshToken = crypto.randomBytes(48).toString('hex');
    const expiresAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);
    await this.store.saveRefreshToken({
      userId: user.id,
      tokenHash: this.hashToken(refreshToken),
      expiresAt,
    });
    return { access_token: accessToken, refresh_token: refreshToken };
  }

  verifyAccessToken(token: string): AccessTokenClaims {
    try {
      return jwt.verify(token, this.env.JWT_ACCESS_SECRET) as AccessTokenClaims;
    } catch {
      throw new UnauthorizedError('رمز الدخول غير صالح أو منتهي الصلاحية.');
    }
  }
}
