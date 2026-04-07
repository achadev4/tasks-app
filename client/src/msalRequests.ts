import type { RedirectRequest } from "@azure/msal-browser";
import { getApiScopes } from "./authConfig.js";

const scopes = getApiScopes();

export const loginRequest: RedirectRequest = {
  scopes: scopes.length > 0 ? scopes : ["openid", "profile", "offline_access"],
};
