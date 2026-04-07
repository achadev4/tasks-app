import Busboy from "busboy";
import { randomUUID } from "node:crypto";
import { Readable } from "node:stream";
import type { HttpRequest, HttpResponseInit } from "@azure/functions";
import { getOidFromRequest } from "../lib/auth.js";
import { mergeCors } from "../lib/cors.js";
import { ensureContainer, getAttachmentsContainer } from "../lib/blob.js";
import * as attRepo from "../repo/attachmentsRepo.js";

function json(request: HttpRequest, status: number, body: unknown): HttpResponseInit {
  return {
    status,
    jsonBody: body,
    headers: mergeCors(request, { "Content-Type": "application/json" }),
  };
}

export async function attachmentsHandler(request: HttpRequest): Promise<HttpResponseInit> {
  if (request.method === "OPTIONS") {
    return { status: 204, headers: mergeCors(request, {}) };
  }

  let oid: string | null;
  try {
    oid = await getOidFromRequest(request);
  } catch (e) {
    const msg = e instanceof Error ? e.message : "Configuration error";
    return json(request, 500, { error: msg });
  }
  if (!oid) {
    return json(request, 401, { error: "Unauthorized" });
  }

  const taskId = request.params.taskId;
  if (!taskId || request.method !== "POST") {
    return json(request, 405, { error: "Method not allowed" });
  }

  const owned = await attRepo.assertTaskOwned(oid, taskId);
  if (!owned) {
    return json(request, 404, { error: "Task not found" });
  }

  const contentType = request.headers.get("content-type");
  if (!contentType?.startsWith("multipart/form-data")) {
    return json(request, 400, { error: "Expected multipart/form-data" });
  }

  const buf = Buffer.from(await request.arrayBuffer());
  const file = await parseMultipart(contentType, buf);
  if (!file) {
    return json(request, 400, { error: "Missing file field" });
  }

  await ensureContainer();
  const container = getAttachmentsContainer();
  const blobName = `${oid}/${taskId}/${randomUUID()}-${sanitizeName(file.filename)}`;
  const block = container.getBlockBlobClient(blobName);
  await block.uploadData(file.data, {
    blobHTTPHeaders: { blobContentType: file.mimeType || "application/octet-stream" },
  });

  const meta = await attRepo.insertAttachment({
    userId: oid,
    taskId,
    blobPath: blobName,
    fileName: file.filename,
    contentType: file.mimeType,
    sizeBytes: file.data.length,
  });

  return json(request, 201, meta);
}

function sanitizeName(name: string): string {
  return name.replace(/[^a-zA-Z0-9._-]/g, "_").slice(0, 200) || "file";
}

type ParsedFile = { filename: string; mimeType: string; data: Buffer };

function parseMultipart(contentType: string, buffer: Buffer): Promise<ParsedFile | null> {
  return new Promise((resolve, reject) => {
    const bb = Busboy({
      headers: { "content-type": contentType },
      limits: { fileSize: 50 * 1024 * 1024 },
    });
    let settled = false;
    let sawFile = false;

    bb.on("file", (_field, file, info) => {
      sawFile = true;
      const chunks: Buffer[] = [];
      file.on("data", (d: Buffer) => chunks.push(d));
      file.on("limit", () => reject(new Error("File too large")));
      file.on("end", () => {
        if (settled) return;
        settled = true;
        resolve({
          filename: info.filename || "upload.bin",
          mimeType: info.mimeType || "application/octet-stream",
          data: Buffer.concat(chunks),
        });
      });
    });

    bb.on("finish", () => {
      if (!settled && !sawFile) {
        settled = true;
        resolve(null);
      }
    });
    bb.on("error", reject);
    Readable.from(buffer).pipe(bb);
  });
}
