import type { Configuration } from "@azure/msal-browser";

const clientId = import.meta.env.VITE_AZURE_AD_CLIENT_ID ?? "";
const tenantId = import.meta.env.VITE_AZURE_AD_TENANT_ID ?? "common";

export const msalConfig: Configuration = {
  auth: {
    clientId,
    authority: `https://login.microsoftonline.com/${tenantId}`,
    redirectUri: typeof window !== "undefined" ? window.location.origin : undefined,
  },
  cache: {
    cacheLocation: "sessionStorage",
    storeAuthStateInCookie: false,
  },
};

export function getApiScopes(): string[] {
  const scope = import.meta.env.VITE_AZURE_AD_API_SCOPE;
  if (!scope) {
    return [];
  }
  return [scope];
}
