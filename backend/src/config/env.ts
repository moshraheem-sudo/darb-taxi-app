import dotenv from 'dotenv';
import { z } from 'zod';

dotenv.config();

const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().positive().default(3000),
  CORS_ORIGIN: z.string().default('*'),
  DATABASE_URL: z.string().optional(),
  JWT_ACCESS_SECRET: z.string().min(16).default('dev-only-access-secret-change-me'),
  JWT_REFRESH_SECRET: z.string().min(16).default('dev-only-refresh-secret-change-me'),
  JWT_ACCESS_EXPIRES_IN: z.string().default('30m'),
  JWT_REFRESH_EXPIRES_IN: z.string().default('30d'),
  OTP_SECRET: z.string().min(8).default('dev-only-otp-secret'),
  OTP_TTL_SECONDS: z.coerce.number().int().positive().default(300),
  OTP_DEV_ECHO: z
    .string()
    .optional()
    .transform((v) => v === 'true'),
  UPLOAD_DIR: z.string().default('./uploads_private'),
  SIGNING_SECRET: z.string().min(8).default('dev-only-file-signing-secret'),
  FIREBASE_SERVICE_ACCOUNT_PATH: z.string().optional(),
  FIREBASE_SERVICE_ACCOUNT_JSON: z.string().optional(),
});

export type AppEnv = z.infer<typeof envSchema>;

export function loadEnv(): AppEnv {
  const env = envSchema.parse(process.env);
  if (env.NODE_ENV === 'production') {
    if (env.OTP_DEV_ECHO) {
      throw new Error('OTP_DEV_ECHO must not be enabled in production.');
    }
    if (
      env.JWT_ACCESS_SECRET.startsWith('dev-only-') ||
      env.JWT_REFRESH_SECRET.startsWith('dev-only-') ||
      env.OTP_SECRET.startsWith('dev-only-') ||
      env.SIGNING_SECRET.startsWith('dev-only-')
    ) {
      throw new Error('Default development secrets are not allowed in production.');
    }
    if (!env.DATABASE_URL) {
      throw new Error('DATABASE_URL is required in production.');
    }
  }
  return env;
}
