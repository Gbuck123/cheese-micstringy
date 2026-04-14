import fs from 'fs';
import path from 'path';
import { pool, query } from './config/database';

const MIGRATIONS_DIR = path.join(__dirname, '..', 'migrations');

async function ensureMigrationsTable() {
  await query(`
    CREATE TABLE IF NOT EXISTS _migrations (
      id SERIAL PRIMARY KEY,
      name VARCHAR(255) UNIQUE NOT NULL,
      applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `);
}

async function getAppliedMigrations(): Promise<string[]> {
  const result = await query<{ name: string }>(
    'SELECT name FROM _migrations ORDER BY id'
  );
  return result.rows.map((r) => r.name);
}

async function migrate() {
  await ensureMigrationsTable();
  const applied = await getAppliedMigrations();

  const files = fs
    .readdirSync(MIGRATIONS_DIR)
    .filter((f) => f.endsWith('.sql'))
    .sort();

  let count = 0;
  for (const file of files) {
    if (applied.includes(file)) {
      console.log(`  [skip] ${file} (already applied)`);
      continue;
    }

    const sql = fs.readFileSync(path.join(MIGRATIONS_DIR, file), 'utf8');
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query(sql);
      await client.query('INSERT INTO _migrations (name) VALUES ($1)', [file]);
      await client.query('COMMIT');
      console.log(`  [applied] ${file}`);
      count++;
    } catch (error) {
      await client.query('ROLLBACK');
      console.error(`  [FAILED] ${file}:`, error);
      throw error;
    } finally {
      client.release();
    }
  }

  console.log(`\nMigrations complete. ${count} applied.`);
}

async function rollback() {
  await ensureMigrationsTable();
  const applied = await getAppliedMigrations();
  if (applied.length === 0) {
    console.log('No migrations to roll back.');
    return;
  }

  const last = applied[applied.length - 1];
  const rollbackFile = last.replace('.sql', '.rollback.sql');
  const rollbackPath = path.join(MIGRATIONS_DIR, rollbackFile);

  if (!fs.existsSync(rollbackPath)) {
    console.error(`No rollback file found: ${rollbackFile}`);
    process.exit(1);
  }

  const sql = fs.readFileSync(rollbackPath, 'utf8');
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(sql);
    await client.query('DELETE FROM _migrations WHERE name = $1', [last]);
    await client.query('COMMIT');
    console.log(`Rolled back: ${last}`);
  } catch (error) {
    await client.query('ROLLBACK');
    console.error('Rollback failed:', error);
    throw error;
  } finally {
    client.release();
  }
}

const command = process.argv[2];
if (command === 'rollback') {
  rollback().then(() => process.exit(0)).catch(() => process.exit(1));
} else {
  migrate().then(() => process.exit(0)).catch(() => process.exit(1));
}
