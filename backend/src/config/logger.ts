import pino from 'pino';

export const logger = pino({
  level: process.env.NODE_ENV === 'test' ? 'silent' : 'info',
  redact: {
    paths: [
      'req.headers.authorization',
      'password',
      'access_token',
      'refresh_token',
      'fcm_token',
      'code',
    ],
    censor: '[REDACTED]',
  },
});
