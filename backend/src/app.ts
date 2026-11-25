import http from 'node:http';
import cors from 'cors';
import express from 'express';
import helmet from 'helmet';
import swaggerUi from 'swagger-ui-express';
import { AppEnv } from './config/env';
import { IDbStore } from './db/types';
import { openApiSpec } from './docs/openapi';
import { errorHandler } from './middleware/auth';
import { RealtimeGateway } from './realtime/socketServer';
import { createAuthRouter } from './routes/authRoutes';
import { createCaptainRouter } from './routes/captainRoutes';
import { createRideRouter } from './routes/rideRoutes';
import { AuthService } from './services/authService';
import { DispatchService } from './services/dispatchService';
import { IFcmService } from './services/fcmService';

export interface BackendAppContext {
  app: express.Express;
  httpServer: http.Server;
  realtime: RealtimeGateway;
  store: IDbStore;
}

export function createBackendApp(params: {
  env: AppEnv;
  store: IDbStore;
  fcm: IFcmService;
}): BackendAppContext {
  const { env, store, fcm } = params;
  const app = express();
  const httpServer = http.createServer(app);

  app.use(helmet());
  app.use(
    cors({
      origin: env.CORS_ORIGIN === '*' ? true : env.CORS_ORIGIN.split(','),
    }),
  );
  app.use(express.json({ limit: '1mb' }));

  const authService = new AuthService(store, env);
  const realtime = new RealtimeGateway(httpServer, env.CORS_ORIGIN, authService, store);
  const dispatchService = new DispatchService(store, realtime, fcm);

  app.get('/health', (_req, res) => {
    res.json({ status: 'ok', service: 'darb-taxi-backend' });
  });

  app.get('/api-docs.json', (_req, res) => res.json(openApiSpec));
  app.use('/api-docs', swaggerUi.serve, swaggerUi.setup(openApiSpec));

  app.use(createAuthRouter(store, authService));
  app.use(createCaptainRouter(store, authService, realtime, fcm, env));
  app.use(createRideRouter(store, authService, dispatchService, realtime, fcm));

  app.use(errorHandler);

  return { app, httpServer, realtime, store };
}
