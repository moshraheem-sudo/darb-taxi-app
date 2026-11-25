import fs from 'node:fs/promises';
import path from 'node:path';
import { Pool } from 'pg';
import { loadEnv } from '../config/env';
import { logger } from '../config/logger';

async function main() {
  const env = loadEnv();
  if (!env.DATABASE_URL) {
    throw new Error('DATABASE_URL is required to run seed.');
  }
  const pool = new Pool({ connectionString: env.DATABASE_URL });
  try {
    const seedPath = path.resolve(__dirname, '../../migrations/002_seed.sql');
    const sql = await fs.readFile(seedPath, 'utf8');
    await pool.query(sql);
    logger.info('Seed data applied successfully');
  } finally {
    await pool.end();
  }
}

main().catch((err) => {
  logger.error({ err }, 'Seed failed');
  process.exit(1);
});
