import type { AccountInfo, IPublicClientApplication } from "@azure/msal-browser";
import type { CreateTaskBody, PatchTaskBody, Task } from "@tasks-app/shared";
import { getApiScopes } from "../authConfig";

const base = "/api";

async function authHeader(
  instance: IPublicClientApplication,
  account: AccountInfo | null
): Promise<HeadersInit> {
  const scopes = getApiScopes();
  if (scopes.length === 0 || !account) {
    return {};
  }
  const result = await instance.acquireTokenSilent({ account, scopes });
  return { Authorization: `Bearer ${result.accessToken}` };
}

export async function fetchTasks(
  instance: IPublicClientApplication,
  account: AccountInfo | null
): Promise<Task[]> {
  const headers = await authHeader(instance, account);
  const res = await fetch(`${base}/tasks`, { headers });
  if (!res.ok) {
    throw new Error(await res.text());
  }
  return res.json() as Promise<Task[]>;
}

export async function createTaskApi(
  instance: IPublicClientApplication,
  account: AccountInfo | null,
  body: CreateTaskBody
): Promise<Task> {
  const headers = {
    ...(await authHeader(instance, account)),
    "Content-Type": "application/json",
  };
  const res = await fetch(`${base}/tasks`, { method: "POST", headers, body: JSON.stringify(body) });
  if (!res.ok) {
    throw new Error(await res.text());
  }
  return res.json() as Promise<Task>;
}

export async function patchTaskApi(
  instance: IPublicClientApplication,
  account: AccountInfo | null,
  id: string,
  body: PatchTaskBody
): Promise<Task> {
  const headers = {
    ...(await authHeader(instance, account)),
    "Content-Type": "application/json",
  };
  const res = await fetch(`${base}/tasks/${id}`, {
    method: "PATCH",
    headers,
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    throw new Error(await res.text());
  }
  return res.json() as Promise<Task>;
}

export async function deleteTaskApi(
  instance: IPublicClientApplication,
  account: AccountInfo | null,
  id: string
): Promise<void> {
  const headers = await authHeader(instance, account);
  const res = await fetch(`${base}/tasks/${id}`, { method: "DELETE", headers });
  if (!res.ok) {
    throw new Error(await res.text());
  }
}

export async function uploadAttachmentApi(
  instance: IPublicClientApplication,
  account: AccountInfo | null,
  taskId: string,
  file: File
): Promise<void> {
  const headers = await authHeader(instance, account);
  const fd = new FormData();
  fd.append("file", file);
  const res = await fetch(`${base}/tasks/${taskId}/attachments`, {
    method: "POST",
    headers,
    body: fd,
  });
  if (!res.ok) {
    throw new Error(await res.text());
  }
}
