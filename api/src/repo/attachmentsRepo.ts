import sql from "mssql";
import { randomUUID } from "node:crypto";
import type { TaskAttachment } from "@tasks-app/shared";
import { getPool } from "../lib/db.js";

function mapAttachment(r: Record<string, unknown>): TaskAttachment {
  return {
    id: String(r.Id),
    taskId: String(r.TaskId),
    fileName: String(r.FileName),
    contentType: r.ContentType != null ? String(r.ContentType) : null,
    sizeBytes: Number(r.SizeBytes),
    blobPath: String(r.BlobPath),
    createdAt: (r.CreatedAt as Date).toISOString(),
  };
}

export async function insertAttachment(input: {
  userId: string;
  taskId: string;
  blobPath: string;
  fileName: string;
  contentType: string | null;
  sizeBytes: number;
}): Promise<TaskAttachment> {
  const pool = await getPool();
  const id = randomUUID();
  await pool
    .request()
    .input("id", sql.UniqueIdentifier, id)
    .input("taskId", sql.UniqueIdentifier, input.taskId)
    .input("userId", sql.NVarChar(128), input.userId)
    .input("blobPath", sql.NVarChar(1024), input.blobPath)
    .input("fileName", sql.NVarChar(500), input.fileName)
    .input("contentType", sql.NVarChar(200), input.contentType)
    .input("sizeBytes", sql.BigInt, input.sizeBytes)
    .query(
      `INSERT INTO dbo.TaskAttachments (Id, TaskId, UserId, BlobPath, FileName, ContentType, SizeBytes)
       VALUES (@id, @taskId, @userId, @blobPath, @fileName, @contentType, @sizeBytes)`
    );
  const row = await pool.request().input("id", sql.UniqueIdentifier, id).query(
    `SELECT Id, TaskId, FileName, ContentType, SizeBytes, BlobPath, CreatedAt FROM dbo.TaskAttachments WHERE Id = @id`
  );
  return mapAttachment((row.recordset as Record<string, unknown>[])[0]);
}

export async function assertTaskOwned(userId: string, taskId: string): Promise<boolean> {
  const pool = await getPool();
  const r = await pool
    .request()
    .input("id", sql.UniqueIdentifier, taskId)
    .input("userId", sql.NVarChar(128), userId)
    .query(`SELECT 1 FROM dbo.Tasks WHERE Id = @id AND UserId = @userId`);
  return (r.recordset as unknown[]).length > 0;
}
