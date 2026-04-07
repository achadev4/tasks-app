import { createRemoteJWKSet, jwtVerify } from "jose";
import type { HttpRequest } from "@azure/functions";

let jwks: ReturnType<typeof createRemoteJWKSet> | null = null;

function getJwks(tenantId: string) {
  if (!jwks) {
    jwks = createRemoteJWKSet(
      new URL(`https://login.microsoftonline.com/${tenantId}/discovery/v2.0/keys`)
    );
  }
  return jwks;
}

export async function getOidFromRequest(request: HttpRequest): Promise<string | null> {
  const bypass = process.env.ALLOW_LOCAL_AUTH_BYPASS === "true";
  const devOid = process.env.LOCAL_DEV_USER_OID;
  if (bypass && devOid) {
    return devOid;
  }

  const tenantId = process.env.AZURE_AD_TENANT_ID;
  const audience = process.env.AZURE_AD_AUDIENCE;
  if (!tenantId || !audience) {
    throw new Error("AZURE_AD_TENANT_ID and AZURE_AD_AUDIENCE must be set");
  }

  const auth = request.headers.get("authorization");
  if (!auth?.startsWith("Bearer ")) {
    return null;
  }
  const token = auth.slice(7);
  const issuer = `https://login.microsoftonline.com/${tenantId}/v2.0`;

  try {
    const { payload } = await jwtVerify(token, getJwks(tenantId), {
      issuer,
      audience,
    });
    const oid = typeof payload.oid === "string" ? payload.oid : undefined;
    if (!oid) {
      return null;
    }
    return oid;
  } catch {
    return null;
  }
}
