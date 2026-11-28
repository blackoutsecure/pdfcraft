#!/usr/bin/env bash
#
# Configure the Microsoft Entra side of Storytold's Microsoft Purview/MIP desktop
# integration. The script is idempotent: it creates a registration only when no
# existing client ID is supplied, then reconciles its public/native settings and
# required delegated permissions.
#
# Interactive inputs may also be supplied without prompts:
#
#   PURVIEW_HOME_TENANT_ID          Required. Workforce tenant that owns the app.
#   PURVIEW_APP_ID                  Optional. Existing client ID; blank creates one.
#   PURVIEW_CREATE_APP              Required in non-interactive mode when no app ID.
#   PURVIEW_APP_DISPLAY_NAME        Optional. Required when creating an app.
#   PURVIEW_TARGET_TENANT_IDS       Optional. Comma/space-separated workforce tenants
#                                   that should consent to the multitenant app.
#   PURVIEW_REDIRECT_URI            Optional. Default: http://localhost.
#   PURVIEW_CONFIRM                 Optional. Set to yes for non-interactive runs.
#   PURVIEW_NONINTERACTIVE          Optional. Set to yes to forbid interactive input.
#   PURVIEW_SKIP_LOGIN              Optional. Set to yes to use the current az context.
#   PURVIEW_SKIP_ROLE_CHECK         Optional. Set to yes only for a controlled CI
#                                   identity whose role cannot be inspected by az rest.
#
# This script never creates or stores a client secret. It does not automate Partner
# Center publisher verification or the Microsoft MIP IPIA; those remain release gates.
set -euo pipefail

readonly RMS_API_ID="00000012-0000-0000-c000-000000000000"
readonly MIP_SYNC_API_ID="870c4f2e-85b6-4d43-bdda-6ed9a579b725"
readonly GRAPH_API_ID="00000003-0000-0000-c000-000000000000"
readonly RMS_SCOPE="user_impersonation"
readonly MIP_SYNC_SCOPE="UnifiedPolicy.User.Read"
readonly DEFAULT_REDIRECT_URI="http://localhost"

DRY_RUN=0
case "${1:-}" in
  --dry-run)
    DRY_RUN=1
    ;;
  -h | --help)
    cat <<'EOF'
Usage: tools/configure-storytold-purview-entra.sh [--dry-run]

Interactively configures, or reconciles, a multitenant public/native Microsoft Entra
application for Storytold Craft's delegated Microsoft Purview/MIP integration.

The script can create or update the application in its home workforce tenant, grant
home-tenant admin consent, and optionally install and consent it in resource/test
workforce tenants. It refuses to use consumer/CIAM configuration and never requests a
client secret.

Set PURVIEW_* environment variables to run without prompts. See the header comment for
the supported variables. Required non-interactive variables are:

  PURVIEW_HOME_TENANT_ID
  PURVIEW_CONFIRM=yes
  PURVIEW_APP_ID=<existing-client-id> or PURVIEW_CREATE_APP=yes

Examples:

  PURVIEW_HOME_TENANT_ID=... \
  PURVIEW_APP_ID=... \
  PURVIEW_TARGET_TENANT_IDS='...' \
  PURVIEW_CONFIRM=yes \
  tools/configure-storytold-purview-entra.sh

  PURVIEW_HOME_TENANT_ID=... \
  PURVIEW_CREATE_APP=yes \
  PURVIEW_APP_DISPLAY_NAME='Storytold Craft Applications' \
  PURVIEW_CONFIRM=yes \
  tools/configure-storytold-purview-entra.sh
EOF
    exit 0
    ;;
  "")
    ;;
  *)
    echo "error: unknown argument: $1" >&2
    echo "usage: $0 [--dry-run]" >&2
    exit 2
    ;;
esac

die() {
  echo "error: $*" >&2
  exit 1
}

is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes | y | on) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_required() {
  local variable="$1" prompt="$2" default="${3:-}"
  local value="${!variable:-}"
  if [[ -z "$value" ]]; then
    if [[ ! -t 0 ]] || is_true "${PURVIEW_NONINTERACTIVE:-0}"; then
      [[ -n "$default" ]] || die "$variable is required for a non-interactive run"
      value="$default"
    else
      read -r -p "$prompt${default:+ [$default]}: " value
      value="${value:-$default}"
    fi
  fi
  [[ -n "$value" ]] || die "$variable cannot be empty"
  printf -v "$variable" '%s' "$value"
}

prompt_optional() {
  local variable="$1" prompt="$2" default="${3:-}"
  local value="${!variable:-}"
  if [[ -z "$value" && -t 0 ]] && ! is_true "${PURVIEW_NONINTERACTIVE:-0}"; then
    read -r -p "$prompt${default:+ [$default]}: " value
  fi
  value="${value:-$default}"
  printf -v "$variable" '%s' "$value"
}

prompt_confirm() {
  local prompt="$1" default="${2:-no}" answer
  if is_true "${PURVIEW_NONINTERACTIVE:-0}"; then
    is_true "${PURVIEW_CONFIRM:-0}"
    return
  fi
  read -r -p "$prompt [$([ "$default" = "yes" ] && echo "Y/n" || echo "y/N")]: " answer
  answer="${answer:-$default}"
  is_true "$answer"
}

require_uuid() {
  local label="$1" value="$2"
  [[ "$value" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] ||
    die "$label is not a GUID: $value"
}

require_azure_cli() {
  command -v az >/dev/null 2>&1 || die "Azure CLI (az) is required"
}

login_tenant() {
  local tenant_id="$1" current_tenant
  current_tenant="$(az account show --query tenantId -o tsv 2>/dev/null || true)"
  if [[ "$current_tenant" != "$tenant_id" ]] && ! is_true "${PURVIEW_SKIP_LOGIN:-0}"; then
    echo "==> Signing in to tenant $tenant_id"
    az login --tenant "$tenant_id" --allow-no-subscriptions --only-show-errors --output none
  fi
  current_tenant="$(az account show --query tenantId -o tsv 2>/dev/null || true)"
  [[ "$current_tenant" = "$tenant_id" ]] ||
    die "Azure CLI is in tenant ${current_tenant:-none}, not $tenant_id; sign in again or omit PURVIEW_SKIP_LOGIN"
}

require_active_admin_role() {
  local tenant_id="$1" roles
  if is_true "${PURVIEW_SKIP_ROLE_CHECK:-0}"; then
    return
  fi
  roles="$(
    az rest --method GET \
      --url "https://graph.microsoft.com/v1.0/me/memberOf/microsoft.graph.directoryRole?\$select=displayName" \
      --query 'value[].displayName' -o tsv 2>/dev/null || true
  )"
  if ! grep -Fq -e 'Global Administrator' -e 'Cloud Application Administrator' -e 'Application Administrator' <<<"$roles"; then
    die "tenant $tenant_id requires an active Global Administrator, Cloud Application Administrator, or Application Administrator role; activate PIM if applicable"
  fi
}

ensure_service_principal() {
  local app_id="$1" service_principal_id
  service_principal_id="$(az ad sp show --id "$app_id" --query id -o tsv 2>/dev/null || true)"
  if [[ -z "$service_principal_id" ]]; then
    echo "==> Creating enterprise application for $app_id" >&2
    service_principal_id="$(az ad sp create --id "$app_id" --query id -o tsv)"
  fi
  [[ -n "$service_principal_id" ]] || die "could not resolve service principal for $app_id"
  printf '%s\n' "$service_principal_id"
}

scope_id() {
  local api_id="$1" scope="$2" id
  id="$(
    az ad sp show --id "$api_id" \
      --query "oauth2PermissionScopes[?value=='$scope'] | [0].id" -o tsv
  )"
  [[ -n "$id" && "$id" != "None" ]] || die "scope $scope was not found on API $api_id"
  printf '%s\n' "$id"
}

remove_graph_required_permission() {
  local app_id="$1" graph_user_read_scope_id="$2"
  local configured
  configured="$(
    az ad app permission list --id "$app_id" --query "[].resourceAccess[].id" -o tsv |
      grep -Fx "$graph_user_read_scope_id" || true
  )"
  if [[ -n "$configured" ]]; then
    echo "==> Removing unnecessary Microsoft Graph User.Read"
    az ad app permission delete \
      --id "$app_id" \
      --api "$GRAPH_API_ID" \
      --api-permissions "$graph_user_read_scope_id"
  fi
}

revoke_graph_grants() {
  local client_service_principal_id="$1" graph_service_principal_id grant_id
  graph_service_principal_id="$(az ad sp show --id "$GRAPH_API_ID" --query id -o tsv 2>/dev/null || true)"
  [[ -n "$graph_service_principal_id" ]] || return 0
  while IFS= read -r grant_id; do
    [[ -n "$grant_id" ]] || continue
    echo "==> Revoking obsolete Microsoft Graph delegated consent grant $grant_id"
    az rest --method DELETE \
      --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$grant_id" \
      --output none
  done < <(
    az rest --method GET \
      --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?\$filter=clientId%20eq%20'$client_service_principal_id'%20and%20resourceId%20eq%20'$graph_service_principal_id'&\$select=id" \
      --query 'value[].id' -o tsv
  )
}

grant_required_permissions() {
  local app_id="$1" client_service_principal_id="$2"
  az ad app permission grant \
    --id "$app_id" \
    --api "$RMS_API_ID" \
    --scope "$RMS_SCOPE" \
    --consent-type AllPrincipals \
    --output none
  az ad app permission grant \
    --id "$app_id" \
    --api "$MIP_SYNC_API_ID" \
    --scope "$MIP_SYNC_SCOPE" \
    --consent-type AllPrincipals \
    --output none
  revoke_graph_grants "$client_service_principal_id"
}

verify_tenant_grants() {
  local app_id="$1" grants
  grants="$(az ad app permission list-grants --id "$app_id" --query '[].scope' -o tsv)"
  grep -Fq "$RMS_SCOPE" <<<"$grants" || die "tenant consent is missing $RMS_SCOPE"
  grep -Fq "$MIP_SYNC_SCOPE" <<<"$grants" || die "tenant consent is missing $MIP_SYNC_SCOPE"
}

verify_home_app() {
  local app_id="$1" redirect_uri="$2"
  [[ "$(az ad app show --id "$app_id" --query signInAudience -o tsv)" = "AzureADMultipleOrgs" ]] ||
    die "the application is not limited to multitenant organizational directories"
  [[ "$(az ad app show --id "$app_id" --query isFallbackPublicClient -o tsv)" = "true" ]] ||
    die "Allow public client flows is not enabled"
  [[ "$(az ad app show --id "$app_id" --query "contains(publicClient.redirectUris, '$redirect_uri')" -o tsv)" = "true" ]] ||
    die "the public-client redirect URI is not $redirect_uri"
  [[ "$(az ad app show --id "$app_id" --query 'length(web.redirectUris)' -o tsv)" = "0" ]] ||
    die "the application still contains a Web redirect URI"
  [[ "$(az ad app show --id "$app_id" --query 'length(spa.redirectUris)' -o tsv)" = "0" ]] ||
    die "the application still contains a SPA redirect URI"
  [[ "$(az ad app show --id "$app_id" --query 'web.implicitGrantSettings.enableIdTokenIssuance' -o tsv | tr '[:upper:]' '[:lower:]')" = "false" ]] ||
    die "ID token implicit issuance is still enabled"
  [[ "$(az ad app show --id "$app_id" --query 'web.implicitGrantSettings.enableAccessTokenIssuance' -o tsv | tr '[:upper:]' '[:lower:]')" = "false" ]] ||
    die "access token implicit issuance is still enabled"

  local password_count key_count
  password_count="$(az ad app show --id "$app_id" --query 'length(passwordCredentials)' -o tsv)"
  key_count="$(az ad app show --id "$app_id" --query 'length(keyCredentials)' -o tsv)"
  [[ "$password_count" = "0" && "$key_count" = "0" ]] ||
    die "the public/native app unexpectedly contains a client secret or certificate; remove it before release"
}

require_azure_cli

HOME_TENANT_ID="${PURVIEW_HOME_TENANT_ID:-}"
prompt_required HOME_TENANT_ID "Application home workforce tenant ID"
require_uuid "home tenant ID" "$HOME_TENANT_ID"

APP_ID="${PURVIEW_APP_ID:-}"
prompt_optional APP_ID "Existing application client ID (leave blank to create a new app)"
if [[ -z "$APP_ID" ]]; then
  if is_true "${PURVIEW_CREATE_APP:-0}"; then
    :
  elif [[ -t 0 ]] && ! is_true "${PURVIEW_NONINTERACTIVE:-0}"; then
    prompt_confirm "No existing client ID was supplied. Create a new registration?" yes ||
      die "no existing client ID was supplied and app creation was declined"
  else
    die "set PURVIEW_APP_ID or PURVIEW_CREATE_APP=yes"
  fi
  CREATE_APP=1
else
  require_uuid "application client ID" "$APP_ID"
  CREATE_APP=0
fi

APP_DISPLAY_NAME="${PURVIEW_APP_DISPLAY_NAME:-}"
if [[ "$CREATE_APP" = 1 ]]; then
  prompt_required APP_DISPLAY_NAME "Application display name" "Storytold Craft Applications"
fi

REDIRECT_URI="${PURVIEW_REDIRECT_URI:-}"
prompt_required REDIRECT_URI "Public/native redirect URI" "$DEFAULT_REDIRECT_URI"
[[ "$REDIRECT_URI" = "$DEFAULT_REDIRECT_URI" ]] ||
  die "PdfCraft's setup standard requires the exact redirect URI $DEFAULT_REDIRECT_URI"

TARGET_TENANT_IDS="${PURVIEW_TARGET_TENANT_IDS:-}"
if [[ -z "$TARGET_TENANT_IDS" && -t 0 ]] && ! is_true "${PURVIEW_NONINTERACTIVE:-0}"; then
  prompt_optional TARGET_TENANT_IDS "Optional resource/test workforce tenant IDs, separated by commas or spaces"
fi

echo
echo "Storytold Purview Entra setup"
echo "  Home tenant:      $HOME_TENANT_ID"
echo "  App client ID:    ${APP_ID:-<new registration>}"
echo "  Display name:     ${APP_DISPLAY_NAME:-<unchanged>}"
echo "  Account types:    AzureADMultipleOrgs"
echo "  Redirect URI:     $REDIRECT_URI"
echo "  Target tenants:   ${TARGET_TENANT_IDS:-<home tenant only>}"
echo "  Delegated scopes: $RMS_SCOPE, $MIP_SYNC_SCOPE"
echo "  Client secrets:   none allowed"
echo

if [[ "$DRY_RUN" = 1 ]]; then
  echo "Dry run only; no Microsoft Entra resources were changed."
  exit 0
fi

prompt_confirm "Apply this configuration and grant admin consent in the listed tenants?" no ||
  die "configuration cancelled"

login_tenant "$HOME_TENANT_ID"
require_active_admin_role "$HOME_TENANT_ID"

if [[ "$CREATE_APP" = 1 ]]; then
  echo "==> Creating app registration $APP_DISPLAY_NAME"
  APP_ID="$(
    az ad app create \
      --display-name "$APP_DISPLAY_NAME" \
      --sign-in-audience AzureADMultipleOrgs \
      --is-fallback-public-client true \
      --public-client-redirect-uris "$REDIRECT_URI" \
      --query appId -o tsv
  )"
  require_uuid "created application client ID" "$APP_ID"
else
  echo "==> Updating app registration $APP_ID"
fi

UPDATE_ARGS=(
  --id "$APP_ID"
  --sign-in-audience AzureADMultipleOrgs
  --is-fallback-public-client true
  --public-client-redirect-uris "$REDIRECT_URI"
)
if [[ -n "$APP_DISPLAY_NAME" ]]; then
  UPDATE_ARGS+=(--display-name "$APP_DISPLAY_NAME")
fi
az ad app update \
  "${UPDATE_ARGS[@]}" \
  --enable-id-token-issuance false \
  --enable-access-token-issuance false

APP_OBJECT_ID="$(az ad app show --id "$APP_ID" --query id -o tsv)"
az rest --method PATCH \
  --url "https://graph.microsoft.com/v1.0/applications/$APP_OBJECT_ID" \
  --headers Content-Type=application/json \
  --body '{"web":{"redirectUris":[],"implicitGrantSettings":{"enableIdTokenIssuance":false,"enableAccessTokenIssuance":false}},"spa":{"redirectUris":[]}}' \
  --output none

CLIENT_SP_ID="$(ensure_service_principal "$APP_ID")"
ensure_service_principal "$RMS_API_ID" >/dev/null
ensure_service_principal "$MIP_SYNC_API_ID" >/dev/null
RMS_SCOPE_ID="$(scope_id "$RMS_API_ID" "$RMS_SCOPE")"
MIP_SYNC_SCOPE_ID="$(scope_id "$MIP_SYNC_API_ID" "$MIP_SYNC_SCOPE")"

echo "==> Adding the two delegated Purview/MIP permissions"
az ad app permission add \
  --id "$APP_ID" \
  --api "$RMS_API_ID" \
  --api-permissions "$RMS_SCOPE_ID=Scope"
az ad app permission add \
  --id "$APP_ID" \
  --api "$MIP_SYNC_API_ID" \
  --api-permissions "$MIP_SYNC_SCOPE_ID=Scope"

remove_graph_required_permission "$APP_ID" "e1fe6dd8-ba31-4d61-89e7-88639da4683d"
echo "==> Granting home-tenant delegated admin consent"
grant_required_permissions "$APP_ID" "$CLIENT_SP_ID"
verify_home_app "$APP_ID" "$REDIRECT_URI"
verify_tenant_grants "$APP_ID"

if [[ -n "$TARGET_TENANT_IDS" ]]; then
  IFS=$' ,\n\t' read -r -a TARGET_TENANTS <<<"$(printf '%s' "$TARGET_TENANT_IDS" | tr ',' ' ')"
  for TARGET_TENANT_ID in "${TARGET_TENANTS[@]}"; do
    [[ -n "$TARGET_TENANT_ID" ]] || continue
    require_uuid "target tenant ID" "$TARGET_TENANT_ID"
    [[ "$TARGET_TENANT_ID" != "$HOME_TENANT_ID" ]] || continue

    echo "==> Configuring multitenant consent in $TARGET_TENANT_ID"
    login_tenant "$TARGET_TENANT_ID"
    require_active_admin_role "$TARGET_TENANT_ID"
    TARGET_CLIENT_SP_ID="$(ensure_service_principal "$APP_ID")"
    ensure_service_principal "$RMS_API_ID" >/dev/null
    ensure_service_principal "$MIP_SYNC_API_ID" >/dev/null
    grant_required_permissions "$APP_ID" "$TARGET_CLIENT_SP_ID"
    verify_tenant_grants "$APP_ID"
  done
fi

echo
echo "Storytold Purview Entra setup complete."
echo "  Application client ID: $APP_ID"
echo "  Home tenant ID:        $HOME_TENANT_ID"
echo "  Build configuration:   PDFCRAFT_PURVIEW_APP_ID=$APP_ID"
echo
echo "Manual production gates not automated by this script:"
echo "  - Configure publisher branding and a verified custom publisher domain."
echo "  - Associate the production app-owning tenant with the verified Partner Global Account."
echo "  - Add the Partner One ID and complete Microsoft publisher verification."
echo "  - Complete/update the Microsoft MIP IPIA for this public App ID."
echo "  - Configure Purview licenses, labels, policies, recipients, and test fixtures per tenant."
echo
echo "No client secret or certificate was created."
