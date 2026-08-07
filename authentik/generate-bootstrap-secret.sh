#! /bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/seal.sh

PLAIN=secrets/bootstrap.yaml
SEALED=templates/sealed-bootstrap-secret.yaml

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
# keys (e.g. a later Jellyfin OIDC client) backfill onto an existing install without
# re-rolling AUTHENTIK_BOOTSTRAP_* or LDAP_BIND_KEY, which must never change under a
# running install (the former only applies on first migrate; the latter is the
# LDAP bind password already persisted in Jellyfin's PVC-stored plugin config).
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

# AUTHENTIK_BOOTSTRAP_* only apply to the first migrate against an empty DB, so a
# fresh cluster comes up with a usable akadmin instead of the initial-setup flow.
# LDAP_BIND_KEY is deliberately unprefixed - authentik parses AUTHENTIK_* as config
# paths. The access blueprint reads it via !Env. Split out of generate-secret.sh so
# these can be (re)generated independently of the Postgres password / Django secret
# key, which must never be re-rolled on a running install.
kubectl create secret generic authentik-bootstrap \
  --namespace authentik \
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
unset EMAIL BOOTSTRAP_PASSWORD BOOTSTRAP_TOKEN LDAP_BIND_KEY \
  JELLYFIN_OIDC_CLIENT_ID JELLYFIN_OIDC_CLIENT_SECRET \
  JELLYFIN_OIDC_INTERNAL_CLIENT_ID JELLYFIN_OIDC_INTERNAL_CLIENT_SECRET

seal_if_needed "$PLAIN" "$SEALED"
