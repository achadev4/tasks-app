import type { HttpRequest, HttpResponseInit } from "@azure/functions";
import { createTaskBodySchema, patchTaskBodySchema } from "@tasks-app/shared";
import { getOidFromRequest } from "../lib/auth.js";
import { mergeCors } from "../lib/cors.js";
import * as repo from "../repo/tasksRepo.js";

function json(request: HttpRequest, status: number, body: unknown): HttpResponseInit {
  return {
    status,
    jsonBody: body,
    headers: mergeCors(request, { "Content-Type": "application/json" }),
  };
}

export async function tasksHandler(request: HttpRequest): Promise<HttpResponseInit> {
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

  const id = request.params.id;

  if (request.method === "GET" && !id) {
    const tasks = await repo.listTasks(oid);
    return json(request, 200, tasks);
  }

  if (request.method === "POST" && !id) {
    let raw: unknown;
    try {
      raw = await request.json();
    } catch {
      return json(request, 400, { error: "Invalid JSON body" });
    }
    const parsed = createTaskBodySchema.safeParse(raw);
    if (!parsed.success) {
      return json(request, 400, { error: parsed.error.flatten() });
    }
    const body = parsed.data;
    const task = await repo.createTask(oid, {
      title: body.title,
      dueDate: body.dueDate ?? null,
      category: body.category ?? null,
      color: body.color ?? null,
    });
    return json(request, 201, task);
  }

  if (!id) {
    return json(request, 405, { error: "Method not allowed" });
  }

  if (request.method === "PATCH") {
    let raw: unknown;
    try {
      raw = await request.json();
    } catch {
      return json(request, 400, { error: "Invalid JSON body" });
    }
    const parsed = patchTaskBodySchema.safeParse(raw);
    if (!parsed.success) {
      return json(request, 400, { error: parsed.error.flatten() });
    }
    const task = await repo.updateTask(oid, id, parsed.data);
    if (!task) {
      return json(request, 404, { error: "Not found" });
    }
    return json(request, 200, task);
  }

  if (request.method === "DELETE") {
    const ok = await repo.deleteTask(oid, id);
    if (!ok) {
      return json(request, 404, { error: "Not found" });
    }
    return { status: 204, headers: mergeCors(request, {}) };
  }

  return json(request, 405, { error: "Method not allowed" });
}
