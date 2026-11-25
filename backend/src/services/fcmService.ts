import fs from 'node:fs';
import * as admin from 'firebase-admin';
import { AppEnv } from '../config/env';
import { logger } from '../config/logger';

export interface PushPayload {
  tokens: string[];
  title: string;
  body: string;
  data?: Record<string, string>;
  highPriority?: boolean;
}

export interface IFcmService {
  sendPush(payload: PushPayload): Promise<void>;
}

export class FirebaseFcmService implements IFcmService {
  private messaging: admin.messaging.Messaging | null = null;

  constructor(env: AppEnv) {
    try {
      let serviceAccount: admin.ServiceAccount | null = null;
      if (env.FIREBASE_SERVICE_ACCOUNT_JSON) {
        serviceAccount = JSON.parse(
          env.FIREBASE_SERVICE_ACCOUNT_JSON,
        ) as admin.ServiceAccount;
      } else if (
        env.FIREBASE_SERVICE_ACCOUNT_PATH &&
        fs.existsSync(env.FIREBASE_SERVICE_ACCOUNT_PATH)
      ) {
        serviceAccount = JSON.parse(
          fs.readFileSync(env.FIREBASE_SERVICE_ACCOUNT_PATH, 'utf8'),
        ) as admin.ServiceAccount;
      }

      if (serviceAccount) {
        const app =
          admin.apps.length > 0
            ? admin.app()
            : admin.initializeApp({
                credential: admin.credential.cert(serviceAccount),
              });
        this.messaging = app.messaging();
        logger.info('Firebase FCM initialized');
      } else {
        logger.info(
          'Firebase FCM credentials not configured; push notifications running in no-op log mode',
        );
      }
    } catch (err) {
      logger.warn({ err }, 'Failed to initialize Firebase FCM; falling back to no-op');
    }
  }

  async sendPush(payload: PushPayload): Promise<void> {
    if (payload.tokens.length === 0) return;
    if (!this.messaging) {
      logger.debug(
        { count: payload.tokens.length, title: payload.title },
        'FCM dry-run push',
      );
      return;
    }

    await this.messaging.sendEachForMulticast({
      tokens: payload.tokens,
      notification: {
        title: payload.title,
        body: payload.body,
      },
      data: payload.data,
      android: {
        priority: payload.highPriority ? 'high' : 'normal',
        notification: {
          channelId: payload.highPriority
            ? 'darb_captain_requests'
            : 'darb_general',
        },
      },
    });
  }
}
