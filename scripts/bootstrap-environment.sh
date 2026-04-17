#!/usr/bin/env bash
#
# bootstrap-environment.sh
#
# Automates the full Azure environment setup for the tasks-app:
#   1. Entra ID app registrations (API + SPA)
#   2. GitHub OIDC deployer app + federated credential
#   3. Role assignments
#   4. GitHub Actions secrets
#   5. Infrastructure deployment (Bicep)
#   6. SQL schema deployment
#   7. SWA deployment token wiring
#   8. Code deployment trigger
#
# Prerequisites:
#   - Azure CLI (`az`) installed and logged in (`az login`)
#   - GitHub CLI (`gh`) installed and authenticated (`gh auth login`)
#   - `sqlcmd` installed (for SQL schema deployment)
#   - Contributor (or higher) role on the target Azure subscription
#
# Usage:
#   ./scripts/bootstrap-environment.sh \
#     --environment dev \
#     --location eastus \
#     --resource-group rg-tasks-dev \
#     --name-prefix tasks \
#     --sql-admin-login sqladmin \
#     --sql-admin-password 'YourStr0ngP@ss!'
#
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Defaults and argument parsing
# ──────────────────────────────────────────────────────────────────────────────
ENVIRONMENT=""
LOCATION="eastus"
RESOURCE_GROUP=""
NAME_PREFIX="tasks"
SQL_ADMIN_LOGIN=""
SQL_ADMIN_PASSWORD=""
GITHUB_REPO="achadev4/tasks-app"
GITHUB_BRANCH="main"
DEPLOYER_CLIENT_ID="${AZURE_CLIENT_ID:-}"
SKIP_SQL_SCHEMA=false
SKIP_CODE_DEPLOY=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required:
  --environment       Target environment (dev, qa, stg, prod)
  --resource-group    Azure resource group name
  --sql-admin-login   SQL server admin username
  --sql-admin-password SQL server admin password

Optional:
  --location            Azure region (default: eastus)
  --name-prefix         Resource name prefix (default: tasks)
  --github-repo         GitHub owner/repo (default: achadev4/tasks-app)
  --github-branch       Branch for OIDC federation & deploy (default: main)
  --deployer-client-id  Existing deployer app client ID (defaults to \$AZURE_CLIENT_ID)
  --skip-sql-schema     Skip SQL schema deployment
  --skip-code-deploy    Skip triggering the code deployment workflow
  -h, --help            Show this help
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --environment)      ENVIRONMENT="$2"; shift 2;;
    --location)         LOCATION="$2"; shift 2;;
    --resource-group)   RESOURCE_GROUP="$2"; shift 2;;
    --name-prefix)      NAME_PREFIX="$2"; shift 2;;
    --sql-admin-login)  SQL_ADMIN_LOGIN="$2"; shift 2;;
    --sql-admin-password) SQL_ADMIN_PASSWORD="$2"; shift 2;;
    --github-repo)      GITHUB_REPO="$2"; shift 2;;
    --github-branch)    GITHUB_BRANCH="$2"; shift 2;;
    --deployer-client-id) DEPLOYER_CLIENT_ID="$2"; shift 2;;
    --skip-sql-schema)  SKIP_SQL_SCHEMA=true; shift;;
    --skip-code-deploy) SKIP_CODE_DEPLOY=true; shift;;
    -h|--help)          usage;;
    *) echo "Unknown option: $1"; usage;;
  esac
done

# Validate required args
for var in ENVIRONMENT RESOURCE_GROUP SQL_ADMIN_LOGIN SQL_ADMIN_PASSWORD; do
  if [[ -z "${!var}" ]]; then
    echo "Error: --$(echo "$var" | tr '[:upper:]' '[:lower:]' | tr '_' '-') is required."
    usage
  fi
done

if [[ -z "$DEPLOYER_CLIENT_ID" ]]; then
  echo "Error: deployer client ID is required. Pass --deployer-client-id or set AZURE_CLIENT_ID."
  usage
fi

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────
info()  { echo -e "\n\033[1;34m▸ $*\033[0m"; }
ok()    { echo -e "  \033[1;32m✓ $*\033[0m"; }
warn()  { echo -e "  \033[1;33m⚠ $*\033[0m"; }

# Wait for Entra ID replication of a newly created app (up to 60s)
wait_for_app() {
  local app_id="$1"
  local retries=12
  for i in $(seq 1 $retries); do
    if az ad app show --id "$app_id" --query id -o tsv &>/dev/null; then
      return 0
    fi
    sleep 5
  done
  warn "App $app_id did not appear after propagation wait"
  return 1
}

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
GITHUB_ORG=$(echo "$GITHUB_REPO" | cut -d/ -f1)
GITHUB_REPO_NAME=$(echo "$GITHUB_REPO" | cut -d/ -f2)

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          tasks-app Bootstrap Environment Script             ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Environment:    ${ENVIRONMENT}"
echo "║  Location:       ${LOCATION}"
echo "║  Resource Group: ${RESOURCE_GROUP}"
echo "║  Name Prefix:    ${NAME_PREFIX}"
echo "║  Subscription:   ${SUBSCRIPTION_ID}"
echo "║  Tenant:         ${TENANT_ID}"
echo "║  GitHub Repo:    ${GITHUB_REPO}"
echo "║  Branch:         ${GITHUB_BRANCH}"
echo "╚══════════════════════════════════════════════════════════════╝"
# ──────────────────────────────────────────────────────────────────────────────
# Phase 1: Entra ID — API app registration
# ──────────────────────────────────────────────────────────────────────────────
info "Phase 1a: Creating API app registration (${NAME_PREFIX}-api-${ENVIRONMENT})"

API_APP_NAME="${NAME_PREFIX}-api-${ENVIRONMENT}"

API_APP_ID=$(az ad app list --display-name "$API_APP_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)

if [[ -z "$API_APP_ID" || "$API_APP_ID" == "None" ]]; then
  API_APP_ID=$(az ad app create \
    --display-name "$API_APP_NAME" \
    --sign-in-audience "AzureADMyOrg" \
    --query appId -o tsv)
  ok "Created API app: $API_APP_ID"
  wait_for_app "$API_APP_ID"
else
  ok "API app already exists: $API_APP_ID"
fi

# Set the Application ID URI (retry — newly created apps have replication lag)
API_ID_URI="api://${API_APP_ID}"
for i in 1 2 3 4 5; do
  if az ad app update --id "$API_APP_ID" --identifier-uris "$API_ID_URI" --output none 2>/dev/null; then
    break
  fi
  sleep 5
done
ok "API identifier URI set: ${API_ID_URI}"

# Expose the access_as_user scope
SCOPE_ID=$(az ad app show --id "$API_APP_ID" \
  --query "api.oauth2PermissionScopes[?value=='access_as_user'].id" -o tsv 2>/dev/null || true)

if [[ -z "$SCOPE_ID" ]]; then
  SCOPE_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
  az ad app update --id "$API_APP_ID" \
    --set api="{\"oauth2PermissionScopes\":[{\"id\":\"${SCOPE_ID}\",\"adminConsentDescription\":\"Access tasks API as the signed-in user\",\"adminConsentDisplayName\":\"Access as user\",\"isEnabled\":true,\"type\":\"User\",\"userConsentDescription\":\"Access tasks API on your behalf\",\"userConsentDisplayName\":\"Access as user\",\"value\":\"access_as_user\"}]}"
  ok "Exposed scope: access_as_user"
else
  ok "Scope access_as_user already exists"
fi

API_SCOPE_URL="${API_ID_URI}/access_as_user"

# Ensure a service principal exists for the API app
az ad sp show --id "$API_APP_ID" &>/dev/null || az ad sp create --id "$API_APP_ID" --output none
ok "API service principal ready"

# ──────────────────────────────────────────────────────────────────────────────
# Phase 1b: Entra ID — SPA app registration
# ──────────────────────────────────────────────────────────────────────────────
info "Phase 1b: Creating SPA app registration (${NAME_PREFIX}-spa-${ENVIRONMENT})"

SPA_APP_NAME="${NAME_PREFIX}-spa-${ENVIRONMENT}"

SPA_APP_ID=$(az ad app list --display-name "$SPA_APP_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)

if [[ -z "$SPA_APP_ID" || "$SPA_APP_ID" == "None" ]]; then
  SPA_APP_ID=$(az ad app create \
    --display-name "$SPA_APP_NAME" \
    --sign-in-audience "AzureADMyOrg" \
    --web-redirect-uris "http://localhost:5173" \
    --enable-id-token-issuance true \
    --enable-access-token-issuance true \
    --query appId -o tsv)
  ok "Created SPA app: $SPA_APP_ID"
  wait_for_app "$SPA_APP_ID"
else
  ok "SPA app already exists: $SPA_APP_ID"
fi

# Configure as SPA platform (not web — needed for PKCE auth code flow)
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$(az ad app show --id "$SPA_APP_ID" --query id -o tsv)" \
  --headers 'Content-Type=application/json' \
  --body "{\"spa\":{\"redirectUris\":[\"http://localhost:5173\"]}}" \
  --output none
ok "SPA platform redirect URI set"

# Add API permission to the SPA
API_OBJECT_ID=$(az ad app show --id "$API_APP_ID" --query id -o tsv)
az ad app permission add \
  --id "$SPA_APP_ID" \
  --api "$API_APP_ID" \
  --api-permissions "${SCOPE_ID}=Scope" \
  --output none 2>/dev/null || true
ok "SPA API permission added (access_as_user)"

# Pre-authorize the SPA on the API (so users don't see a consent prompt)
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/${API_OBJECT_ID}" \
  --headers 'Content-Type=application/json' \
  --body "{\"api\":{\"preAuthorizedApplications\":[{\"appId\":\"${SPA_APP_ID}\",\"delegatedPermissionIds\":[\"${SCOPE_ID}\"]}]}}" \
  --output none
ok "SPA pre-authorized on API app"

# ──────────────────────────────────────────────────────────────────────────────
# Phase 2: Ensure federated credential for this environment on the deployer
# ──────────────────────────────────────────────────────────────────────────────
info "Phase 2: Ensuring OIDC federated credential on existing deployer (${DEPLOYER_CLIENT_ID})"

DEPLOYER_OBJECT_ID=$(az ad app show --id "$DEPLOYER_CLIENT_ID" --query id -o tsv)

ENV_CRED_NAME="github-env-${ENVIRONMENT}"
EXISTING_ENV_CRED=$(az ad app federated-credential list --id "$DEPLOYER_OBJECT_ID" \
  --query "[?name=='${ENV_CRED_NAME}'].name" -o tsv 2>/dev/null || true)

if [[ -z "$EXISTING_ENV_CRED" ]]; then
  az ad app federated-credential create --id "$DEPLOYER_OBJECT_ID" \
    --parameters "{
      \"name\": \"${ENV_CRED_NAME}\",
      \"issuer\": \"https://token.actions.githubusercontent.com\",
      \"subject\": \"repo:${GITHUB_REPO}:environment:${ENVIRONMENT}\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }" --output none
  ok "Federated credential created for environment '${ENVIRONMENT}'"
else
  ok "Federated credential '${ENV_CRED_NAME}' already exists"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Phase 3: Resource group + role assignment
# ──────────────────────────────────────────────────────────────────────────────
info "Phase 3: Resource group + Contributor role assignment"

az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
ok "Resource group '${RESOURCE_GROUP}' ready"

RG_ID=$(az group show --name "$RESOURCE_GROUP" --query id -o tsv)

# Assign Contributor on the resource group to the deployer SP
EXISTING_ROLE=$(az role assignment list \
  --assignee "$DEPLOYER_CLIENT_ID" \
  --scope "$RG_ID" \
  --role "Contributor" \
  --query "[0].id" -o tsv 2>/dev/null || true)

if [[ -z "$EXISTING_ROLE" ]]; then
  az role assignment create \
    --assignee "$DEPLOYER_CLIENT_ID" \
    --role "Contributor" \
    --scope "$RG_ID" \
    --output none
  ok "Contributor role assigned to deployer on ${RESOURCE_GROUP}"
else
  ok "Contributor role already assigned"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Phase 4: Create Azure SQL server + database (free tier)
# ──────────────────────────────────────────────────────────────────────────────
info "Phase 4: Azure SQL server + database"

SQL_SERVER_NAME="${NAME_PREFIX}-sql-${ENVIRONMENT}"

EXISTING_SQL=$(az sql server list --resource-group "$RESOURCE_GROUP" \
  --query "[?name=='${SQL_SERVER_NAME}'].name" -o tsv 2>/dev/null || true)

if [[ -z "$EXISTING_SQL" ]]; then
  az sql server create \
    --name "$SQL_SERVER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --admin-user "$SQL_ADMIN_LOGIN" \
    --admin-password "$SQL_ADMIN_PASSWORD" \
    --output none
  ok "SQL server '${SQL_SERVER_NAME}' created"
else
  ok "SQL server '${SQL_SERVER_NAME}' already exists"
fi

SQL_FQDN=$(az sql server show --name "$SQL_SERVER_NAME" --resource-group "$RESOURCE_GROUP" \
  --query fullyQualifiedDomainName -o tsv)

# Allow Azure services to connect
az sql server firewall-rule create \
  --server "$SQL_SERVER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --name "AllowAzureServices" \
  --start-ip-address 0.0.0.0 \
  --end-ip-address 0.0.0.0 \
  --output none 2>/dev/null || true
ok "Firewall: AllowAzureServices"

# Allow current client IP for schema deployment
MY_IP=$(curl -s https://api.ipify.org)
az sql server firewall-rule create \
  --server "$SQL_SERVER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --name "BootstrapClient" \
  --start-ip-address "$MY_IP" \
  --end-ip-address "$MY_IP" \
  --output none 2>/dev/null || true
ok "Firewall: current IP ($MY_IP) allowed temporarily"

# Create database
DB_NAME="tasks"
EXISTING_DB=$(az sql db list --server "$SQL_SERVER_NAME" --resource-group "$RESOURCE_GROUP" \
  --query "[?name=='${DB_NAME}'].name" -o tsv 2>/dev/null || true)

if [[ -z "$EXISTING_DB" ]]; then
  az sql db create \
    --server "$SQL_SERVER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --name "$DB_NAME" \
    --edition GeneralPurpose \
    --compute-model Serverless \
    --family Gen5 \
    --capacity 1 \
    --auto-pause-delay 60 \
    --output none
  ok "Database '${DB_NAME}' created (serverless)"
else
  ok "Database '${DB_NAME}' already exists"
fi

SQL_CONNECTION_STRING="Server=tcp:${SQL_FQDN},1433;Initial Catalog=${DB_NAME};Persist Security Info=False;User ID=${SQL_ADMIN_LOGIN};Password=${SQL_ADMIN_PASSWORD};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

# ──────────────────────────────────────────────────────────────────────────────
# Phase 5: Deploy SQL schema
# ──────────────────────────────────────────────────────────────────────────────
if [[ "$SKIP_SQL_SCHEMA" == "false" ]]; then
  info "Phase 5: Deploying SQL schema"

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SCHEMA_FILE="${SCRIPT_DIR}/../infra/sql/schema.sql"

  if ! command -v sqlcmd &>/dev/null; then
    warn "sqlcmd not found — skipping schema deployment."
    warn "Run manually: sqlcmd -S ${SQL_FQDN} -d ${DB_NAME} -U ${SQL_ADMIN_LOGIN} -P '***' -i infra/sql/schema.sql"
  else
    sqlcmd -S "$SQL_FQDN" -d "$DB_NAME" \
      -U "$SQL_ADMIN_LOGIN" -P "$SQL_ADMIN_PASSWORD" \
      -i "$SCHEMA_FILE" \
      -b
    ok "SQL schema deployed"
  fi
else
  info "Phase 5: Skipping SQL schema (--skip-sql-schema)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Phase 6: Set GitHub secrets
# ──────────────────────────────────────────────────────────────────────────────
info "Phase 6: Setting GitHub Actions secrets"

# Create the GitHub environment if it doesn't exist
gh api --method PUT "repos/${GITHUB_REPO}/environments/${ENVIRONMENT}" --silent 2>/dev/null || true
ok "GitHub environment '${ENVIRONMENT}' ready"

# Environment-level secrets (used by workflows with `environment:`)
set_env_secret() {
  local name="$1" value="$2"
  echo "$value" | gh secret set "$name" --repo "$GITHUB_REPO" --env "$ENVIRONMENT"
  ok "Set env secret: ${name}"
}

set_env_secret "SQL_CONNECTION_STRING"        "$SQL_CONNECTION_STRING"
set_env_secret "API_APP_CLIENT_ID"            "$API_APP_ID"
set_env_secret "VITE_AZURE_AD_TENANT_ID"      "$TENANT_ID"
set_env_secret "VITE_AZURE_AD_CLIENT_ID"      "$SPA_APP_ID"
set_env_secret "VITE_AZURE_AD_API_SCOPE"      "$API_SCOPE_URL"

ok "All environment secrets set for '${ENVIRONMENT}'"

# ──────────────────────────────────────────────────────────────────────────────
# Phase 7: Deploy infrastructure (Bicep) via GitHub Actions
# ──────────────────────────────────────────────────────────────────────────────
info "Phase 7: Triggering Bicep infrastructure deployment"

gh workflow run "bicep-deploy.yml" \
  --repo "$GITHUB_REPO" \
  --ref "$GITHUB_BRANCH" \
  --field environment="$ENVIRONMENT" \
  --field resource_group="$RESOURCE_GROUP" \
  --field location="$LOCATION" \
  --field name_prefix="$NAME_PREFIX"
ok "Bicep workflow triggered"

echo ""
info "Waiting for Bicep deployment to complete..."
sleep 5

# Poll for the workflow run to complete
BICEP_RUN_ID=""
for i in $(seq 1 12); do
  BICEP_RUN_ID=$(gh run list --repo "$GITHUB_REPO" \
    --workflow "bicep-deploy.yml" --limit 1 --json databaseId --jq '.[0].databaseId')
  STATUS=$(gh run view "$BICEP_RUN_ID" --repo "$GITHUB_REPO" --json status --jq '.status')
  if [[ "$STATUS" == "completed" ]]; then
    CONCLUSION=$(gh run view "$BICEP_RUN_ID" --repo "$GITHUB_REPO" --json conclusion --jq '.conclusion')
    if [[ "$CONCLUSION" == "success" ]]; then
      ok "Bicep deployment succeeded (run #${BICEP_RUN_ID})"
      break
    else
      echo ""
      echo "ERROR: Bicep deployment failed. Check: https://github.com/${GITHUB_REPO}/actions/runs/${BICEP_RUN_ID}"
      exit 1
    fi
  fi
  echo "  …still running (attempt ${i}/12, waiting 30s)"
  sleep 30
done

if [[ "$STATUS" != "completed" ]]; then
  warn "Bicep deployment still in progress after 6 minutes."
  warn "Check: https://github.com/${GITHUB_REPO}/actions/runs/${BICEP_RUN_ID}"
  warn "Continuing — some remaining steps may fail if infra isn't ready."
fi

# ──────────────────────────────────────────────────────────────────────────────
# Phase 8: Retrieve SWA deployment token + set secret
# ──────────────────────────────────────────────────────────────────────────────
info "Phase 8: Wiring Static Web App deployment token"

# Find the SWA resource name from the deployment outputs
SWA_NAME=$(az deployment group show \
  --resource-group "$RESOURCE_GROUP" \
  --name "bicep-$(gh run view "$BICEP_RUN_ID" --repo "$GITHUB_REPO" --json databaseId --jq '.databaseId')" \
  --query "properties.outputs.staticWebAppName.value" -o tsv 2>/dev/null || true)

# Fallback: find the SWA by listing resources in the RG
if [[ -z "$SWA_NAME" ]]; then
  SWA_NAME=$(az staticwebapp list --resource-group "$RESOURCE_GROUP" \
    --query "[0].name" -o tsv 2>/dev/null || true)
fi

if [[ -n "$SWA_NAME" ]]; then
  SWA_TOKEN=$(az staticwebapp secrets list --name "$SWA_NAME" --resource-group "$RESOURCE_GROUP" \
    --query "properties.apiKey" -o tsv)
  set_env_secret "AZURE_STATIC_WEB_APPS_API_TOKEN" "$SWA_TOKEN"

  # Also get the Function App name for the deploy workflow
  FUNC_NAME=$(az functionapp list --resource-group "$RESOURCE_GROUP" \
    --query "[0].name" -o tsv 2>/dev/null || true)
  if [[ -n "$FUNC_NAME" ]]; then
    set_env_secret "AZURE_FUNCTIONAPP_NAME" "$FUNC_NAME"
  fi

  # Add the SWA hostname as a redirect URI to the SPA app
  SWA_HOSTNAME=$(az staticwebapp show --name "$SWA_NAME" --resource-group "$RESOURCE_GROUP" \
    --query "defaultHostname" -o tsv)
  SPA_OBJECT_ID=$(az ad app show --id "$SPA_APP_ID" --query id -o tsv)
  az rest --method PATCH \
    --uri "https://graph.microsoft.com/v1.0/applications/${SPA_OBJECT_ID}" \
    --headers 'Content-Type=application/json' \
    --body "{\"spa\":{\"redirectUris\":[\"http://localhost:5173\",\"https://${SWA_HOSTNAME}\"]}}" \
    --output none
  ok "SPA redirect URI updated: https://${SWA_HOSTNAME}"
else
  warn "Could not find Static Web App — set AZURE_STATIC_WEB_APPS_API_TOKEN manually."
fi

# ──────────────────────────────────────────────────────────────────────────────
# Phase 9: Trigger code deployment
# ──────────────────────────────────────────────────────────────────────────────
if [[ "$SKIP_CODE_DEPLOY" == "false" ]]; then
  info "Phase 9: Triggering code deployment"
  gh workflow run "azure-static-web-apps.yml" \
    --repo "$GITHUB_REPO" \
    --ref "$GITHUB_BRANCH"
  ok "Code deployment workflow triggered"
  echo ""
  echo "  Monitor at: https://github.com/${GITHUB_REPO}/actions"
else
  info "Phase 9: Skipping code deployment (--skip-code-deploy)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Phase 10: Clean up temporary firewall rule
# ──────────────────────────────────────────────────────────────────────────────
info "Phase 10: Removing temporary SQL firewall rule"
az sql server firewall-rule delete \
  --server "$SQL_SERVER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --name "BootstrapClient" \
  --output none 2>/dev/null || true
ok "Temporary firewall rule removed"

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    Bootstrap Complete!                      ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  API App Client ID:  ${API_APP_ID}"
echo "║  SPA App Client ID:  ${SPA_APP_ID}"
echo "║  Deployer Client ID: ${DEPLOYER_CLIENT_ID}"
echo "║  SQL Server:         ${SQL_FQDN}"
if [[ -n "${SWA_HOSTNAME:-}" ]]; then
echo "║  SWA URL:            https://${SWA_HOSTNAME}"
fi
if [[ -n "${FUNC_NAME:-}" ]]; then
echo "║  Function App:       ${FUNC_NAME}"
fi
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Next steps:                                                ║"
echo "║  1. Verify the app at the SWA URL above                    ║"
echo "║  2. Grant admin consent for API permissions if needed       ║"
echo "║     az ad app permission admin-consent --id ${SPA_APP_ID}  ║"
echo "║  3. For local dev, copy .env.example files and fill in:    ║"
echo "║     VITE_AZURE_AD_TENANT_ID=${TENANT_ID}"
echo "║     VITE_AZURE_AD_CLIENT_ID=${SPA_APP_ID}"
echo "║     VITE_AZURE_AD_API_SCOPE=${API_SCOPE_URL}"
echo "╚══════════════════════════════════════════════════════════════╝"
