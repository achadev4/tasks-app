# Tasks app

React (Vite + TypeScript + Mantine + MSAL) with an Azure Functions API (Node.js + TypeScript). Tasks support titles, due dates, categories, colors, completion, deletion, and optional file attachments stored in Azure Blob Storage. Data lives in Azure SQL (SQL Server–compatible). Infrastructure is defined in Bicep (Log Analytics, workspace-based Application Insights, Key Vault, Storage, SQL, Function App, Static Web App with a linked Functions backend). CI/CD uses GitHub Actions to deploy to **Azure Static Web Apps**.

## Repository layout

| Path | Purpose |
|------|---------|
| `client/` | Vite SPA, Mantine UI, MSAL authentication |
| `api/` | Azure Functions (programming model v4), HTTP API |
| `packages/shared/` | Shared Zod schemas and TypeScript types |
| `infra/` | `main.bicep` plus SQL schema script |
| `.github/workflows/` | SWA deploy; optional Bicep infra deploy ([`bicep-deploy.yml`](.github/workflows/bicep-deploy.yml)) |

For a **step-by-step Azure + GitHub checklist** (Entra apps, Bicep deploy, SWA deployment token, Actions secrets), see [`docs/AZURE_AND_GITHUB_SETUP.md`](docs/AZURE_AND_GITHUB_SETUP.md).

## Prerequisites

- Node.js 20+
- npm 9+
- [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local) for local API
- Azure resources (for production): Entra ID app registrations (SPA + API), Azure SQL, Storage, Key Vault, etc.

## Entra ID (Azure AD) setup

1. **SPA app registration** (for the React client): add a **Single-page application** redirect URI (e.g. `http://localhost:5173` and your production SWA URL).
2. **API app registration** (resource that issues tokens for your Functions):
   - Expose an API scope (e.g. `access_as_user` or `user_impersonation`).
   - Note the **Application (client) ID** of this API registration — the Functions app uses it as **`AZURE_AD_AUDIENCE`** when validating JWTs (`aud` claim).

The SPA requests an access token for that API scope via MSAL. Set:

- `VITE_AZURE_AD_CLIENT_ID` — SPA client ID  
- `VITE_AZURE_AD_TENANT_ID` — directory (tenant) ID  
- `VITE_AZURE_AD_API_SCOPE` — full scope value (e.g. `api://<api-app-id>/access_as_user`)

## Local development

### 1. Database

Run [`infra/sql/schema.sql`](infra/sql/schema.sql) against your SQL database (Azure SQL or local SQL Server).

### 2. API (`api/`)

Copy `api/local.settings.json.example` to `api/local.settings.json` and fill in:

- `AZURE_AD_TENANT_ID`, `AZURE_AD_AUDIENCE` (API app client ID)
- `SQL_CONNECTION_STRING`
- `AZURE_STORAGE_CONNECTION_STRING`
- `TASKS_BLOB_CONTAINER` (default `task-attachments`)

Optional for local-only testing (do **not** use in production):

- `ALLOW_LOCAL_AUTH_BYPASS` = `true`
- `LOCAL_DEV_USER_OID` = a fixed string user id (tasks are scoped by this value)

### 3. Client (`client/`)

Create `client/.env` (see `client/.env.example`):

```
VITE_AZURE_AD_CLIENT_ID=...
VITE_AZURE_AD_TENANT_ID=...
VITE_AZURE_AD_API_SCOPE=api://.../...
```

`vite.config.ts` proxies `/api` to `http://localhost:7071` so the browser calls the same origin as the dev server.

### 4. Run

From the repo root:

```bash
npm install
npm run build -w packages/shared
npm run dev
```

The root `npm run build` also runs `scripts/pack-shared-for-api.mjs`, which copies `packages/shared` into `api/node_modules/@tasks-app/shared` so the Functions project is self-contained when deployed by Static Web Apps (the `api/` folder is uploaded without the monorepo `packages/` tree).

This runs the Vite dev server and the Functions host. Open `http://localhost:5173`.

To approximate Static Web Apps routing locally after a production build:

```bash
npm run build
npx @azure/static-web-apps-cli start client/dist --api-location api
```

## API surface (Functions)

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/tasks` | List tasks for the signed-in user (`oid`) |
| `POST` | `/api/tasks` | Create task |
| `PATCH` | `/api/tasks/{id}` | Update fields |
| `DELETE` | `/api/tasks/{id}` | Delete task |
| `POST` | `/api/tasks/{taskId}/attachments` | Multipart upload (`file` field) |

All routes expect `Authorization: Bearer <access token>` unless local bypass is enabled.

## Infrastructure (Bicep)

[`infra/main.bicep`](infra/main.bicep) provisions (in the target resource group):

- Log Analytics workspace and workspace-based Application Insights  
- Storage account + blob container for attachments  
- Azure SQL server + database + firewall rule for Azure services  
- Key Vault with **SqlConnectionString** and **StorageConnectionString** secrets (operational copies; Function App settings are set from the same values at deploy time to avoid bootstrap ordering issues with Key Vault references)  
- Windows Consumption Function App (Node 20)  
- Standard Static Web App with a **linked** Function App backend  

Deploy example (replace placeholders):

```bash
az group create -n rg-tasks -l eastus
az deployment group create \
  --resource-group rg-tasks \
  --template-file infra/main.bicep \
  --parameters sqlAdminLogin='...' sqlAdminPassword='...' apiAppClientId='<API_APP_CLIENT_ID>'
```

After deployment, run `infra/sql/schema.sql` against the new database, then configure Function App settings for Entra if needed. Retrieve the Static Web Apps deployment token from the Azure portal (**Static Web App → Manage deployment token**) and store it as `AZURE_STATIC_WEB_APPS_API_TOKEN` in GitHub repository secrets.

## GitHub Actions

- [`azure-static-web-apps.yml`](.github/workflows/azure-static-web-apps.yml) — on push/PR to `main`, runs `npm ci && npm run build` and deploys `client/dist` and the `api` Functions project to SWA (`skip_app_build` / `skip_api_build` because the build runs in a prior step).
- [`bicep-deploy.yml`](.github/workflows/bicep-deploy.yml) — **workflow_dispatch** only; deploys [`infra/main.bicep`](infra/main.bicep) using Azure OIDC. Required secrets and Entra federated credential setup are documented in [`docs/AZURE_AND_GITHUB_SETUP.md`](docs/AZURE_AND_GITHUB_SETUP.md) (Phase 3, Option A).

## Security notes

- Prefer **OIDC** (`azure/login`) for Azure automation instead of long-lived client secrets where possible.
- Treat `sqlAdminPassword` and storage keys as secrets; rotate via Key Vault and pipeline variables.
- Move Function App settings to **Key Vault references** plus **managed identity** once RBAC has been applied and validated.
