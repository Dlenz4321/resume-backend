#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — one-time setup for the Azure Cloud Resume Challenge
#
# Creates:
#   - rg-tfstate + storage account + "tfstate" container (versioning + soft delete)
#   - rg-resume-prod
#   - user-assigned managed identity id-github-resume (lives in rg-tfstate)
#   - role assignments for that identity (and for you, on the state account)
#   - federated credentials: pull_request + environment:production, per repo
#   - GitHub "production" environment (you as required reviewer) + repo variables
#
# Safe to re-run: every step either skips what exists or updates it in place.
# Run with:  bash bootstrap.sh   (Windows: in Git Bash; file must use LF line endings)
# =============================================================================

set -euo pipefail

# ----------------------------- Settings --------------------------------------
LOCATION="westus3"                 # West US 3 = Phoenix datacenter region
TFSTATE_RG="rg-tfstate"
PROD_RG="rg-resume-prod"
IDENTITY_NAME="id-github-resume"
IDENTITY_RG="$TFSTATE_RG"          # kept OUT of rg-resume-prod on purpose (see notes)
CONTAINER_NAME="tfstate"
ENV_NAME="production"
REPOS=("resume-frontend" "resume-backend")
TAGS="project=cloud-resume"

# Limit what the identity can hand out with "Role Based Access Control Administrator".
# Without this, the identity could grant itself Owner. Set to false to skip.
CONSTRAIN_RBAC_ADMIN=true
ASSIGNABLE_ROLES=(
  "Storage Blob Data Owner"          # Flex Consumption function -> its deployment storage
  "Storage Blob Data Contributor"    # pipeline uploads site files; function storage
  "Storage Queue Data Contributor"   # function host storage
  "Storage Table Data Contributor"   # function host storage
  "Monitoring Metrics Publisher"     # App Insights with Entra auth
)

# ----------------------------- Windows (Git Bash) fixes ----------------------
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    # Stop Git Bash from rewriting "/subscriptions/..." into "C:/Program Files/Git/subscriptions/..."
    export MSYS_NO_PATHCONV=1
    export MSYS2_ARG_CONV_EXCL="*"
    # Azure CLI on Windows ends lines with \r\n; strip the \r so IDs don't get corrupted.
    az() { command az "$@" | tr -d '\r'; }
    ;;
esac

# ----------------------------- Helpers ---------------------------------------
log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# assign_role <principal-object-id> <principal-type> <role-name> <scope> [condition]
assign_role() {
  local pid="$1" ptype="$2" role="$3" scope="$4" condition="${5:-}"
  local existing
  existing=$(az role assignment list --scope "$scope" --role "$role" \
    --query "[?principalId=='${pid}'] | length(@)" -o tsv)
  if [[ "$existing" != "0" ]]; then
    info "already assigned: $role"
    return 0
  fi

  local args=(--assignee-object-id "$pid" --assignee-principal-type "$ptype"
              --role "$role" --scope "$scope" -o none)
  if [[ -n "$condition" ]]; then
    args+=(--condition "$condition" --condition-version "2.0")
  fi

  # A brand-new identity can take a minute to replicate; retry a few times.
  local i
  for i in 1 2 3 4 5 6; do
    if az role assignment create "${args[@]}" 2>/dev/null; then
      info "assigned: $role"
      return 0
    fi
    info "not ready yet, retrying in 15s ($i/6)..."
    sleep 15
  done
  die "could not assign '$role' on $scope"
}

# add_fic <credential-name> <subject>
add_fic() {
  az identity federated-credential create \
    --name "$1" \
    --identity-name "$IDENTITY_NAME" \
    --resource-group "$IDENTITY_RG" \
    --issuer "https://token.actions.githubusercontent.com" \
    --subject "$2" \
    --audiences "api://AzureADTokenExchange" \
    -o none
  info "federated credential: $1  ->  $2"
}

# ----------------------------- Preflight -------------------------------------
command -v az >/dev/null || die "Azure CLI not found. Install with: winget install -e --id Microsoft.AzureCLI (then reopen the terminal)"
command -v gh >/dev/null || die "GitHub CLI not found. Install with: winget install -e --id GitHub.cli (then reopen the terminal)"
az account show -o none 2>/dev/null || die "Not logged in to Azure. Run: az login"
gh auth status >/dev/null 2>&1   || die "Not logged in to GitHub. Run: gh auth login"

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
MY_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
GH_OWNER=$(gh api user --jq .login)
GH_USER_ID=$(gh api user --jq .id)

# Storage account names are global, 3-24 lowercase letters/digits.
# Derive a stable suffix from the subscription ID so re-runs get the same name.
if command -v sha1sum >/dev/null; then HASH_CMD=sha1sum; else HASH_CMD=shasum; fi
SUFFIX=$(printf '%s' "$SUBSCRIPTION_ID" | "$HASH_CMD" | cut -c1-8)
STATE_SA="${STATE_SA:-sttfstate${SUFFIX}}"

cat <<EOF

About to bootstrap:
  Subscription : $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)
  Tenant       : $TENANT_ID
  Location     : $LOCATION
  State storage: $TFSTATE_RG / $STATE_SA / $CONTAINER_NAME
  Prod RG      : $PROD_RG
  Identity     : $IDENTITY_RG / $IDENTITY_NAME
  GitHub repos : ${REPOS[*]/#/${GH_OWNER}/}
EOF
read -r -p "Continue? [y/N] " answer
[[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

# ----------------------------- 1. Resource providers -------------------------
log "Registering resource providers"
# Needed right now — wait for these.
for ns in Microsoft.Storage Microsoft.ManagedIdentity; do
  az provider register --namespace "$ns" --wait -o none
  info "$ns registered"
done
# Needed later by Terraform — register in the background.
for ns in Microsoft.Web Microsoft.DocumentDB Microsoft.Cdn Microsoft.Insights Microsoft.OperationalInsights; do
  az provider register --namespace "$ns" -o none
  info "$ns registration started"
done

# ----------------------------- 2. Resource groups ----------------------------
log "Creating resource groups"
az group create -n "$TFSTATE_RG" -l "$LOCATION" --tags "$TAGS" -o none && info "$TFSTATE_RG"
az group create -n "$PROD_RG"    -l "$LOCATION" --tags "$TAGS" -o none && info "$PROD_RG"

# ----------------------------- 3. State storage ------------------------------
log "Creating Terraform state storage account: $STATE_SA"
if az storage account show -n "$STATE_SA" -g "$TFSTATE_RG" -o none 2>/dev/null; then
  info "already exists"
else
  available=$(az storage account check-name -n "$STATE_SA" --query nameAvailable -o tsv)
  [[ "$available" == "true" ]] || die "Name $STATE_SA is taken. Re-run with: STATE_SA=<new-name> bash bootstrap.sh"
  az storage account create \
    -n "$STATE_SA" -g "$TFSTATE_RG" -l "$LOCATION" \
    --sku Standard_LRS --kind StorageV2 \
    --https-only true --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --allow-shared-key-access false \
    --tags "$TAGS" -o none
  info "created"
fi

log "Enabling blob versioning and soft delete"
az storage account blob-service-properties update \
  --account-name "$STATE_SA" -g "$TFSTATE_RG" \
  --enable-versioning true \
  --enable-delete-retention true --delete-retention-days 14 \
  --enable-container-delete-retention true --container-delete-retention-days 14 \
  -o none
info "versioning on, 14-day soft delete for blobs and containers"

log "Creating container: $CONTAINER_NAME"
# container-rm goes through Azure Resource Manager, so it works even with keys disabled
exists=$(az storage container-rm exists --storage-account "$STATE_SA" -g "$TFSTATE_RG" \
  -n "$CONTAINER_NAME" --query exists -o tsv)
if [[ "$exists" == "true" ]]; then
  info "already exists"
else
  az storage container-rm create --storage-account "$STATE_SA" -g "$TFSTATE_RG" \
    -n "$CONTAINER_NAME" --public-access off -o none
  info "created"
fi

# ----------------------------- 4. Managed identity ---------------------------
log "Creating user-assigned managed identity: $IDENTITY_NAME"
az identity create -n "$IDENTITY_NAME" -g "$IDENTITY_RG" -l "$LOCATION" --tags "$TAGS" -o none
CLIENT_ID=$(az identity show -n "$IDENTITY_NAME" -g "$IDENTITY_RG" --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show -n "$IDENTITY_NAME" -g "$IDENTITY_RG" --query principalId -o tsv)
info "clientId:    $CLIENT_ID"
info "principalId: $PRINCIPAL_ID"

# ----------------------------- 5. Role assignments ---------------------------
PROD_RG_ID=$(az group show -n "$PROD_RG" --query id -o tsv)
STATE_SA_ID=$(az storage account show -n "$STATE_SA" -g "$TFSTATE_RG" --query id -o tsv)

CONDITION=""
if [[ "$CONSTRAIN_RBAC_ADMIN" == "true" ]]; then
  GUIDS=""
  for role in "${ASSIGNABLE_ROLES[@]}"; do
    guid=$(az role definition list --name "$role" --query "[0].name" -o tsv)
    [[ -n "$guid" ]] || die "Could not look up role: $role"
    GUIDS="${GUIDS:+$GUIDS, }$guid"
  done
  CONDITION="((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$GUIDS})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$GUIDS}))"
fi

log "Assigning roles to $IDENTITY_NAME"
assign_role "$PRINCIPAL_ID" ServicePrincipal "Contributor" "$PROD_RG_ID"
assign_role "$PRINCIPAL_ID" ServicePrincipal "Role Based Access Control Administrator" "$PROD_RG_ID" "$CONDITION"
assign_role "$PRINCIPAL_ID" ServicePrincipal "Storage Blob Data Contributor" "$STATE_SA_ID"

log "Assigning Storage Blob Data Contributor on state account to you (for local terraform)"
assign_role "$MY_OBJECT_ID" User "Storage Blob Data Contributor" "$STATE_SA_ID"

# ----------------------------- 6. Federated credentials ----------------------
log "Adding federated credentials (GitHub OIDC)"
for repo in "${REPOS[@]}"; do
  add_fic "gh-${repo}-pr"          "repo:${GH_OWNER}/${repo}:pull_request"
  add_fic "gh-${repo}-${ENV_NAME}" "repo:${GH_OWNER}/${repo}:environment:${ENV_NAME}"
done

# ----------------------------- 7. GitHub environments + variables ------------
log "Configuring GitHub repos"
for repo in "${REPOS[@]}"; do
  full="${GH_OWNER}/${repo}"
  info "--- $full"

  # Environment with you as required reviewer, deployable only from main.
  if gh api --method PUT "repos/${full}/environments/${ENV_NAME}" --input - >/dev/null 2>&1 <<EOF
{
  "wait_timer": 0,
  "prevent_self_review": false,
  "reviewers": [ { "type": "User", "id": ${GH_USER_ID} } ],
  "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true }
}
EOF
  then
    info "environment '$ENV_NAME' with required reviewer: $GH_OWNER"
    gh api --method POST "repos/${full}/environments/${ENV_NAME}/deployment-branch-policies" \
      -f name=main -f type=branch >/dev/null 2>&1 || true
    info "deployments restricted to branch: main"
  else
    # Required reviewers need a public repo or a paid GitHub plan.
    gh api --method PUT "repos/${full}/environments/${ENV_NAME}" >/dev/null
    info "WARNING: environment created WITHOUT required reviewers."
    info "         Private repos need GitHub Pro for this. Make the repo public or upgrade, then re-run."
  fi

  gh variable set AZURE_CLIENT_ID       --repo "$full" --body "$CLIENT_ID"
  gh variable set AZURE_TENANT_ID       --repo "$full" --body "$TENANT_ID"
  gh variable set AZURE_SUBSCRIPTION_ID --repo "$full" --body "$SUBSCRIPTION_ID"
  info "variables set: AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID"
done

# ----------------------------- Summary ---------------------------------------
cat <<EOF

==============================================================================
Bootstrap complete.

Terraform backend block (use key = "frontend.tfstate" / "backend.tfstate"):

  terraform {
    backend "azurerm" {
      resource_group_name  = "$TFSTATE_RG"
      storage_account_name = "$STATE_SA"
      container_name       = "$CONTAINER_NAME"
      key                  = "frontend.tfstate"
      use_azuread_auth     = true
    }
  }

In GitHub Actions also set: ARM_USE_OIDC=true, ARM_CLIENT_ID, ARM_TENANT_ID,
ARM_SUBSCRIPTION_ID (from the repo variables), and permissions: id-token: write.
==============================================================================
EOF
