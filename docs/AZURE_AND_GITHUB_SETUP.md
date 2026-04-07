# Azure and GitHub setup checklist

Use this document in order. You already have a GitHub repository; the steps below cover Microsoft Entra (Azure AD), Azure resources (including deploying [`infra/main.bicep`](../infra/main.bicep)), database initialization, and wiring GitHub Actions to Azure Static Web Apps.

---

## Phase 1 — Microsoft Entra ID (do this first)

Identity must exist before the API can validate tokens and before you finalize redirect URIs for production.

### 1.1 Register the API (resource) application

1. In the [Azure portal](https://portal.azure.com), open **Microsoft Entra ID** → **App registrations** → **New registration**.
2. **Name**: e.g. `tasks-api` (any name).
3. **Supported account types**: choose what your organization needs (often *Accounts in this organizational directory only*).
4. **Redirect URI**: leave empty for this registration (the API does not use a SPA redirect).
5. Register. Note:
   - **Application (client) ID** → this value is your **`apiAppClientId`** for Bicep and maps to **`AZURE_AD_AUDIENCE`** on the Function App (JWT `aud` claim).
   - **Directory (tenant) ID** → your tenant; used as **`VITE_AZURE_AD_TENANT_ID`** and **`AZURE_AD_TENANT_ID`**.

6. **Expose an API**:
   - **Application ID URI**: set to `api://<API_APP_CLIENT_ID>` (or another URI your team prefers; the SPA scope string must match what you configure in MSAL).
   - **Add a scope**: e.g. `access_as_user`, **Admins and users** enabled. Note the full scope value, e.g. `api://<API_APP_CLIENT_ID>/access_as_user` — this is **`VITE_AZURE_AD_API_SCOPE`** in the React app.

7. **Authorized client applications** (so the SPA can request tokens for this API):
   - Add the **SPA app registration’s client ID** (from step 1.2 below) and select the delegated scope you created.

### 1.2 Register the SPA (frontend) application

1. **App registrations** → **New registration**.
2. **Name**: e.g. `tasks-spa`.
3. **Redirect URI**: platform **Single-page application**. Add:
   - `http://localhost:5173` (local Vite)
   - Later: `https://<your-static-web-app-hostname>` (from Azure Static Web Apps after deploy; you can add this in a second pass).
4. Register. Note **Application (client) ID** → **`VITE_AZURE_AD_CLIENT_ID`**.

5. **Authentication** → ensure **Access tokens** and **ID tokens** are enabled if shown for implicit/hybrid (MSAL PKCE uses authorization code flow; options vary by portal version).

6. **API permissions** → **Add a permission** → **My APIs** → select `tasks-api` → delegated → select `access_as_user` (or your scope name) → **Grant admin consent** if your tenant requires it.

### 1.3 Collect these values (you will reuse them everywhere)

| Value | Where it goes |
|--------|----------------|
| Tenant (directory) ID | `VITE_AZURE_AD_TENANT_ID`, `AZURE_AD_TENANT_ID`, Bicep `tenantId` (default uses subscription tenant) |
| SPA client ID | `VITE_AZURE_AD_CLIENT_ID`, `client/.env` |
| API app client ID | Bicep parameter **`apiAppClientId`**, `api/local.settings.json` **`AZURE_AD_AUDIENCE`** |
| Full API scope URL | `VITE_AZURE_AD_API_SCOPE` (e.g. `api://<api-client-id>/access_as_user`) |

---

## Phase 2 — Azure subscription and resource group

1. Ensure you have an Azure **subscription** and a role that can create resources (e.g. **Contributor** on a resource group or subscription).
2. Install tools (on your machine):
   - [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (`az`)
   - [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install) (often `az bicep install` / `az bicep upgrade`)

3. Sign in and set subscription:

```bash
az login
az account show
az account set --subscription "<subscription-id-or-name>"
```

4. Create a resource group (pick region, e.g. `eastus`):

```bash
az group create --name rg-tasks --location eastus
```

---

## Phase 3 — Deploy infrastructure (Bicep)

[`infra/main.bicep`](../infra/main.bicep) deploys Log Analytics, Application Insights, Storage (including blob container for attachments), Key Vault (secrets for operational copies), Azure SQL server + database, Windows Consumption Function App (Node 20), and a Standard Static Web App with a **linked** Function App backend.

Choose **one** of the options below (GitHub Actions is best for repeatable, audited deploys).

### Option A — GitHub Actions workflow (recommended)

Workflow: [`.github/workflows/bicep-deploy.yml`](../.github/workflows/bicep-deploy.yml). It uses [OpenID Connect (OIDC)](https://learn.microsoft.com/azure/developer/github/connect-from-azure) so GitHub can authenticate to **Azure without a long-lived client secret** in the repository.

#### A.1 — Entra app registration for the deployer (GitHub → Azure)

This is **separate** from your tasks **SPA** and **API** app registrations. It represents “GitHub Actions is allowed to deploy to this subscription/RG.”

1. **Entra ID** → **App registrations** → **New registration** → name e.g. `github-actions-tasks-infra`.
2. Note **Application (client) ID** → will be **`AZURE_CLIENT_ID`** in GitHub.
3. **Certificates & secrets** is **not** required if you use federated credentials (OIDC).
4. **Federated credentials** → **Add credential** → **GitHub Actions deploying Azure resources** (or **Other issuer** if your portal differs):
   - **Organization**: your GitHub org or user name.
   - **Repository**: your repo name (e.g. `tasks-app`).
   - **Entity type**: *Branch* → **Branch name** `main` (or whichever branch may run the workflow).  
   - Alternatively use **Pull request** / **Environment** if you standardize on those; the **subject** must match what GitHub sends in the OIDC token (see [Microsoft’s table](https://learn.microsoft.com/azure/developer/github/connect-from-azure?tabs=azure-portal%2Clinux#use-the-azure-login-action-with-openid-connect)).
5. **Azure subscription** → **Access control (IAM)** → **Add role assignment** → **Contributor** (or a custom role limited to resource group deployment) → assign to the **app registration** you just created (search by name). Scope can be the **subscription** or the **target resource group** (least privilege: **Contributor** on that resource group only).

#### A.2 — GitHub repository secrets

In the repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**, add:

| Secret | Description |
|--------|-------------|
| `AZURE_CLIENT_ID` | Deployer app registration **Application (client) ID** |
| `AZURE_TENANT_ID` | Directory (tenant) ID |
| `AZURE_SUBSCRIPTION_ID` | Target Azure subscription ID |
| `SQL_ADMIN_LOGIN` | SQL server administrator login (Bicep `sqlAdminLogin`) |
| `SQL_ADMIN_PASSWORD` | Strong password for that SQL login |
| `API_APP_CLIENT_ID` | From Phase 1 — **API** app registration client ID (JWT audience / Bicep `apiAppClientId`) |

#### A.3 — Run the workflow

1. **Actions** → **Deploy infrastructure (Bicep)** → **Run workflow**.
2. Fill **resource group** (e.g. `rg-tasks`), **location** (e.g. `eastus`), **name prefix** (default `tasks`). The workflow creates the resource group if it does not exist.
3. Confirm the job succeeds and review **Show deployment outputs** for Static Web App name, Function App name, etc.

#### A.4 — After the workflow

Continue with the same post-deploy steps as Option B (schema, redirect URI, etc.) — steps 3–6 below.

---

### Option B — Deploy from your machine (Azure CLI)

1. Choose a strong SQL admin password and a SQL admin **login** name (SQL authentication).

2. Deploy (replace placeholders):

```bash
az deployment group create \
  --resource-group rg-tasks \
  --template-file infra/main.bicep \
  --parameters \
    sqlAdminLogin='<sql-user>' \
    sqlAdminPassword='<sql-password>' \
    apiAppClientId='<API_APP_CLIENT_ID_FROM_PHASE_1>'
```

3. When deployment finishes, note outputs (portal **Deployment** or `az deployment group show`). You care especially about:
   - Static Web App name
   - Function App name
   - SQL server FQDN (for connecting tools / running schema)

4. **Apply database schema** — connect to the **`tasks`** database on the new server (Azure portal **Query editor**, Azure Data Studio, or `sqlcmd`) and run [`infra/sql/schema.sql`](../infra/sql/schema.sql).

5. **Confirm Function App settings** in the portal (**Configuration**): `AZURE_AD_TENANT_ID`, `AZURE_AD_AUDIENCE` (API client ID), `SQL_CONNECTION_STRING`, `AZURE_STORAGE_CONNECTION_STRING`, `TASKS_BLOB_CONTAINER`, Application Insights connection string, etc. Bicep sets these; adjust only if your Entra or naming differs.

6. **Production redirect URI**: In the **SPA** app registration, add redirect URI `https://<SWA-default-hostname>` (from Static Web App **Overview**).

*(If you used Option A, steps 3–6 apply the same way after the workflow completes.)*

---

## Phase 4 — GitHub repository and Actions

The workflow [`.github/workflows/azure-static-web-apps.yml`](../.github/workflows/azure-static-web-apps.yml) expects:

- Branch **`main`** (adjust the workflow file if your default branch differs).
- Secret **`AZURE_STATIC_WEB_APPS_API_TOKEN`**.

### 4.1 Connect the repo to Azure Static Web Apps (deployment token)

The Bicep template creates the Static Web App resource but does **not** register your GitHub repo inside Azure for you. You still need a **deployment token** so GitHub Actions can push builds.

**Option A — Portal (simplest)**

1. Portal → your **Static Web App** → **Manage deployment token**.
2. Copy the token.
3. GitHub → your repository → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**.
4. Name: **`AZURE_STATIC_WEB_APPS_API_TOKEN`**, value: paste the token → Save.

**Option B — Azure CLI**

```bash
az staticwebapp secrets list --name "<static-web-app-name>" --resource-group rg-tasks
```

Use the appropriate secret property as the deployment token (portal is usually clearer).

### 4.2 Push application code

1. Ensure this project’s code is on **`main`** (or change the workflow `branches`).
2. Commit and push so the workflow runs.

### 4.3 Verify the pipeline

1. GitHub → **Actions** → open the latest **Azure Static Web Apps CI/CD** run.
2. Confirm **Install and build** and **Deploy** succeed.
3. Open the Static Web App URL from the Azure portal and test sign-in and `/api` calls.

### 4.4 Pull requests (optional)

The same workflow deploys **preview** environments for PRs to `main` when the token and SWA SKU support it (Standard tier supports staging). Closed PRs run the **close** job to tear down the preview.

---

## Phase 5 — Local development files (not in GitHub secrets)

These stay on developer machines (see root [README](../README.md)):

| File | Purpose |
|------|---------|
| `api/local.settings.json` | Copied from `api/local.settings.json.example`; SQL, storage, Entra IDs |
| `client/.env` | Copied from `client/.env.example`; SPA Entra IDs and API scope |

Do **not** commit real secrets.

---

## Phase 6 — Optional hardening (after everything works)

- Tighten **SQL firewall** (remove wide rules; use private endpoint / selected IPs if required).
- Move Function App settings to **Key Vault references** + **managed identity** (see plan and README security notes).
- Add **diagnostic settings** for SQL or Static Web Apps to the same Log Analytics workspace if you need more platform logs in one place.
- If you did not use OIDC for infra deploy, consider switching the deployer app to **federated credentials only** and removing any client secrets.

---

## Quick order summary

1. Entra: API app + expose scope + authorize SPA client.  
2. Entra: SPA app + redirect URIs + API permissions.  
3. Azure: subscription; create resource group (or let the Bicep workflow create it).  
4. **Either** set up GitHub OIDC deployer app + Action secrets and run **Deploy infrastructure (Bicep)**, **or** `az login` and deploy Bicep locally.  
5. Run `infra/sql/schema.sql` on the `tasks` database.  
6. Add SPA production redirect URI with SWA URL.  
7. GitHub: secret `AZURE_STATIC_WEB_APPS_API_TOKEN`.  
8. Push to `main` and verify Actions + site.
