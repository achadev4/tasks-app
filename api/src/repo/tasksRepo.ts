import sql from "mssql";
import { randomUUID } from "node:crypto";
import type { Task } from "@tasks-app/shared";
import { getPool } from "../lib/db.js";

function mapRow(r: Record<string, unknown>): Task {
  const due = r.DueDate as Date | null | undefined;
  return {
    id: String(r.Id),
    userId: String(r.UserId),
    title: String(r.Title),
    completed: Boolean(r.Completed),
    dueDate: due ? due.toISOString().slice(0, 10) : null,
    category: r.Category != null ? String(r.Category) : null,
    color: r.Color != null ? String(r.Color) : null,
    createdAt: (r.CreatedAt as Date).toISOString(),
    updatedAt: (r.UpdatedAt as Date).toISOString(),
  };
}

export async function listTasks(userId: string): Promise<Task[]> {
  const pool = await getPool();
  const result = await pool
    .request()
    .input("userId", sql.NVarChar(128), userId)
    .query(
      `SELECT Id, UserId, Title, Completed, DueDate, Category, Color, CreatedAt, UpdatedAt
       FROM dbo.Tasks WHERE UserId = @userId ORDER BY UpdatedAt DESC`
    );
  return (result.recordset as Record<string, unknown>[]).map(mapRow);
}

export async function createTask(
  userId: string,
  input: { title: string; dueDate: string | null; category: string | null; color: string | null }
): Promise<Task> {
  const pool = await getPool();
  const id = randomUUID();
  await pool
    .request()
    .input("id", sql.UniqueIdentifier, id)
    .input("userId", sql.NVarChar(128), userId)
    .input("title", sql.NVarChar(500), input.title)
    .input("dueDate", sql.Date, input.dueDate ? new Date(input.dueDate + "Z") : null)
    .input("category", sql.NVarChar(200), input.category)
    .input("color", sql.NVarChar(32), input.color)
    .query(
      `INSERT INTO dbo.Tasks (Id, UserId, Title, Completed, DueDate, Category, Color)
       VALUES (@id, @userId, @title, 0, @dueDate, @category, @color)`
    );
  const row = await pool.request().input("id", sql.UniqueIdentifier, id).query(
    `SELECT Id, UserId, Title, Completed, DueDate, Category, Color, CreatedAt, UpdatedAt FROM dbo.Tasks WHERE Id = @id`
  );
  return mapRow((row.recordset as Record<string, unknown>[])[0]);
}

export async function updateTask(
  userId: string,
  taskId: string,
  patch: {
    title?: string;
    completed?: boolean;
    dueDate?: string | null;
    category?: string | null;
    color?: string | null;
  }
): Promise<Task | null> {
  const pool = await getPool();
  const existing = await pool
    .request()
    .input("id", sql.UniqueIdentifier, taskId)
    .input("userId", sql.NVarChar(128), userId)
    .query(
      `SELECT Id, UserId, Title, Completed, DueDate, Category, Color, CreatedAt, UpdatedAt
       FROM dbo.Tasks WHERE Id = @id AND UserId = @userId`
    );
  if ((existing.recordset as unknown[]).length === 0) {
    return null;
  }

  const parts: string[] = [];
  const req = pool
    .request()
    .input("id", sql.UniqueIdentifier, taskId)
    .input("userId", sql.NVarChar(128), userId);

  if (patch.title !== undefined) {
    parts.push("Title = @title");
    req.input("title", sql.NVarChar(500), patch.title);
  }
  if (patch.completed !== undefined) {
    parts.push("Completed = @completed");
    req.input("completed", sql.Bit, patch.completed ? 1 : 0);
  }
  if (patch.dueDate !== undefined) {
    parts.push("DueDate = @dueDate");
    req.input(
      "dueDate",
      sql.Date,
      patch.dueDate ? new Date(patch.dueDate + "Z") : null
    );
  }
  if (patch.category !== undefined) {
    parts.push("Category = @category");
    req.input("category", sql.NVarChar(200), patch.category);
  }
  if (patch.color !== undefined) {
    parts.push("Color = @color");
    req.input("color", sql.NVarChar(32), patch.color);
  }

  if (parts.length === 0) {
    return mapRow((existing.recordset as Record<string, unknown>[])[0]);
  }

  parts.push("UpdatedAt = SYSUTCDATETIME()");
  await req.query(`UPDATE dbo.Tasks SET ${parts.join(", ")} WHERE Id = @id AND UserId = @userId`);

  const row = await pool.request().input("id", sql.UniqueIdentifier, taskId).query(
    `SELECT Id, UserId, Title, Completed, DueDate, Category, Color, CreatedAt, UpdatedAt FROM dbo.Tasks WHERE Id = @id`
  );
  return mapRow((row.recordset as Record<string, unknown>[])[0]);
}

export async function deleteTask(userId: string, taskId: string): Promise<boolean> {
  const pool = await getPool();
  const result = await pool
    .request()
    .input("id", sql.UniqueIdentifier, taskId)
    .input("userId", sql.NVarChar(128), userId)
    .query(`DELETE FROM dbo.Tasks WHERE Id = @id AND UserId = @userId`);
  return (result.rowsAffected[0] ?? 0) > 0;
}
