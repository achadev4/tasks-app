import sql from "mssql";

let pool: sql.ConnectionPool | null = null;

export async function getPool(): Promise<sql.ConnectionPool> {
  if (pool?.connected) {
    return pool;
  }
  const cs = process.env.SQL_CONNECTION_STRING;
  if (!cs) {
    throw new Error("SQL_CONNECTION_STRING is not configured");
  }
  pool = await sql.connect(cs);
  return pool;
}

export async function closePool(): Promise<void> {
  if (pool) {
    await pool.close();
    pool = null;
  }
}
