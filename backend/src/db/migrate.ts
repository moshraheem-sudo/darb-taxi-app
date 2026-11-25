import fs from 'node:fs/promises';
import path from 'node:path';
import { Pool } from 'pg';
import { loadEnv } from '../config/env';
import { logger } from '../config/logger';

async function main() {
  const env = loadEnv();
  if (!env.DATABASE_URL) {
    throw new Error('DATABASE_URL is required to run migrations.');
  }
  const pool = new Pool({ connectionString: env.DATABASE_URL });
  try {
    const migrationsDir = path.resolve(__dirname, '../../migrations');
    const files = (await fs.readdir(migrationsDir))
      .filter((f) => f.endsWith('.sql') && f.startsWith('001_'))
      .sort();

    await pool.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version VARCHAR(64) PRIMARY KEY,
        applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      );
    `);

    for (const file of files) {
      const exists = await pool.query(
        'SELECT 1 FROM schema_migrations WHERE version = $1',
        [file],
      );
      if (exists.rowCount && exists.rowCount > 0) {
        logger.info({ file }, 'Migration already applied');
        continue;
      }
      const sql = await fs.readFile(path.join(migrationsDir, file), 'utf8');
      await pool.query('BEGIN');
      await pool.query(sql);
      await pool.query('INSERT INTO schema_migrations (version) VALUES ($1)', [
        file,
      ]);
      await pool.query('COMMIT');
      logger.info({ file }, 'Migration applied');
    }
  } catch (err) {
    await pool.query('ROLLBACK').catch(() => {});
    throw err;
  } finally {
    await pool.end();
  }
}

main().catch((err) => {
  logger.error({ err }, 'Migration failed');
  process.exit(1);
});
