import { BlobServiceClient, ContainerClient } from "@azure/storage-blob";
import { DefaultAzureCredential } from "@azure/identity";

let containerClient: ContainerClient | null = null;

function getBlobServiceClient(): BlobServiceClient {
  const conn = process.env.AZURE_STORAGE_CONNECTION_STRING;
  if (conn) {
    return BlobServiceClient.fromConnectionString(conn);
  }
  const account = process.env.AZURE_STORAGE_ACCOUNT_NAME;
  if (!account) {
    throw new Error("Configure AZURE_STORAGE_CONNECTION_STRING or AZURE_STORAGE_ACCOUNT_NAME");
  }
  const cred = new DefaultAzureCredential();
  return new BlobServiceClient(`https://${account}.blob.core.windows.net`, cred);
}

export function getAttachmentsContainer(): ContainerClient {
  if (containerClient) {
    return containerClient;
  }
  const name = process.env.TASKS_BLOB_CONTAINER ?? "task-attachments";
  const svc = getBlobServiceClient();
  containerClient = svc.getContainerClient(name);
  return containerClient;
}

export async function ensureContainer(): Promise<void> {
  const c = getAttachmentsContainer();
  await c.createIfNotExists();
}
