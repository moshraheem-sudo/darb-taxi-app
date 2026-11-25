import { Pool } from 'pg';
import { createBackendApp } from './app';
import { loadEnv } from './config/env';
import { logger } from './config/logger';
import { MemoryStore } from './db/memoryStore';
import { PgStore } from './db/pgStore';
import { IDbStore } from './db/types';
import { FirebaseFcmService } from './services/fcmService';

async function main() {
  const env = loadEnv();
  let store: IDbStore;

  if (env.DATABASE_URL) {
    const pool = new Pool({ connectionString: env.DATABASE_URL });
    await pool.query('SELECT 1');
    store = new PgStore(pool);
    logger.info('Connected to PostgreSQL + PostGIS');
  } else {
    store = new MemoryStore();
    logger.warn(
      'DATABASE_URL not set; running with in-memory store (development only)',
    );
  }

  const fcm = new FirebaseFcmService(env);
  const { httpServer } = createBackendApp({ env, store, fcm });

  httpServer.listen(env.PORT, () => {
    logger.info({ port: env.PORT }, 'Darb Taxi Backend listening');
    logger.info(`Swagger docs available at http://localhost:${env.PORT}/api-docs`);
  });

  const shutdown = async () => {
    logger.info('Shutting down backend...');
    httpServer.close();
    await store.close();
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

main().catch((err) => {
  logger.error({ err }, 'Fatal startup error');
  process.exit(1);
});
