#! /bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/seal.sh

PLAIN=secrets/secret.yaml
SEALED=templates/sealed-secret.yaml

mkdir -p secrets
chmod go-rwx secrets

# Read a key already present in $PLAIN (a `kubectl create secret ... -o yaml` dump),
# decoding its base64 value. Empty if $PLAIN doesn't exist yet or lacks the key.
_existing_value() {
  local key="$1"
  [ -f "$PLAIN" ] || return 0
  awk -v k="$key" '$1 == k":" { print $2; exit }' "$PLAIN" | base64 -d 2>/dev/null || true
}

# Every key this secret carries, generated only the first time it's missing - added
# keys backfill onto an existing install without re-rolling any existing value. None
# of these are safe to re-roll on a running install: AUTHENTIK_POSTGRESQL__PASSWORD/
# AUTHENTIK_SECRET_KEY break authentik <-> postgres auth immediately;
# AUTHENTIK_BOOTSTRAP_* only apply to the first migrate against an empty DB but are
# still worth preserving; LDAP_BIND_KEY and the JELLYFIN_OIDC_* secrets are pinned
# into the LDAP outpost provider / Jellyfin's PVC-stored plugin config respectively.
POSTGRESQL_PASSWORD="$(_existing_value AUTHENTIK_POSTGRESQL__PASSWORD)"
[ -n "$POSTGRESQL_PASSWORD" ] || POSTGRESQL_PASSWORD="$(openssl rand -base64 32)"

SECRET_KEY="$(_existing_value AUTHENTIK_SECRET_KEY)"
[ -n "$SECRET_KEY" ] || SECRET_KEY="$(openssl rand -base64 32)"

EMAIL="$(_existing_value AUTHENTIK_BOOTSTRAP_EMAIL)"
if [ -z "$EMAIL" ]; then
  EMAIL="${AUTHENTIK_BOOTSTRAP_EMAIL:-}"
  [ -n "$EMAIL" ] || read -r -p "Enter Authentik admin (akadmin) email: " EMAIL
  [ -n "$EMAIL" ] || { echo "Error: Authentik admin email must be provided"; exit 1; }
fi

BOOTSTRAP_PASSWORD="$(_existing_value AUTHENTIK_BOOTSTRAP_PASSWORD)"
[ -n "$BOOTSTRAP_PASSWORD" ] || BOOTSTRAP_PASSWORD="$(openssl rand -base64 32)"

BOOTSTRAP_TOKEN="$(_existing_value AUTHENTIK_BOOTSTRAP_TOKEN)"
[ -n "$BOOTSTRAP_TOKEN" ] || BOOTSTRAP_TOKEN="$(openssl rand -hex 32)"

LDAP_BIND_KEY="$(_existing_value LDAP_BIND_KEY)"
[ -n "$LDAP_BIND_KEY" ] || LDAP_BIND_KEY="$(openssl rand -hex 32)"

# JELLYFIN_OIDC_*_CLIENT_ID isn't a secret in itself, but it's kept alongside the
# secret it's paired with so both are generated and read back together. Public and
# internal are separate OAuth2 clients - not just separate redirect URIs - because the
# Jellyfin plugin picks an issuer host per provider config, and auth.internal /
# auth.glazrtom.cz don't share a session cookie, so each host needs its own hop.
JELLYFIN_OIDC_CLIENT_ID="$(_existing_value JELLYFIN_OIDC_CLIENT_ID)"
[ -n "$JELLYFIN_OIDC_CLIENT_ID" ] || JELLYFIN_OIDC_CLIENT_ID="$(openssl rand -hex 16)"

JELLYFIN_OIDC_CLIENT_SECRET="$(_existing_value JELLYFIN_OIDC_CLIENT_SECRET)"
[ -n "$JELLYFIN_OIDC_CLIENT_SECRET" ] || JELLYFIN_OIDC_CLIENT_SECRET="$(openssl rand -hex 32)"

JELLYFIN_OIDC_INTERNAL_CLIENT_ID="$(_existing_value JELLYFIN_OIDC_INTERNAL_CLIENT_ID)"
[ -n "$JELLYFIN_OIDC_INTERNAL_CLIENT_ID" ] || JELLYFIN_OIDC_INTERNAL_CLIENT_ID="$(openssl rand -hex 16)"

JELLYFIN_OIDC_INTERNAL_CLIENT_SECRET="$(_existing_value JELLYFIN_OIDC_INTERNAL_CLIENT_SECRET)"
[ -n "$JELLYFIN_OIDC_INTERNAL_CLIENT_SECRET" ] || JELLYFIN_OIDC_INTERNAL_CLIENT_SECRET="$(openssl rand -hex 32)"

kubectl create secret generic authentik-secrets \
  --namespace authentik \
  --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="$POSTGRESQL_PASSWORD" \
  --from-literal=AUTHENTIK_SECRET_KEY="$SECRET_KEY" \
  --from-literal=AUTHENTIK_BOOTSTRAP_PASSWORD="$BOOTSTRAP_PASSWORD" \
  --from-literal=AUTHENTIK_BOOTSTRAP_TOKEN="$BOOTSTRAP_TOKEN" \
  --from-literal=AUTHENTIK_BOOTSTRAP_EMAIL="$EMAIL" \
  --from-literal=LDAP_BIND_KEY="$LDAP_BIND_KEY" \
  --from-literal=JELLYFIN_OIDC_CLIENT_ID="$JELLYFIN_OIDC_CLIENT_ID" \
  --from-literal=JELLYFIN_OIDC_CLIENT_SECRET="$JELLYFIN_OIDC_CLIENT_SECRET" \
  --from-literal=JELLYFIN_OIDC_INTERNAL_CLIENT_ID="$JELLYFIN_OIDC_INTERNAL_CLIENT_ID" \
  --from-literal=JELLYFIN_OIDC_INTERNAL_CLIENT_SECRET="$JELLYFIN_OIDC_INTERNAL_CLIENT_SECRET" \
  --dry-run=client -o yaml > "$PLAIN"
chmod go-rwx "$PLAIN"
unset POSTGRESQL_PASSWORD SECRET_KEY EMAIL BOOTSTRAP_PASSWORD BOOTSTRAP_TOKEN LDAP_BIND_KEY \
  JELLYFIN_OIDC_CLIENT_ID JELLYFIN_OIDC_CLIENT_SECRET \
  JELLYFIN_OIDC_INTERNAL_CLIENT_ID JELLYFIN_OIDC_INTERNAL_CLIENT_SECRET

seal_if_needed "$PLAIN" "$SEALED"
