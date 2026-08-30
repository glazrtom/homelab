#! /bin/bash
# authentik-secrets carries every key the chart needs. Each key backfills
# independently (see scripts/secretlib.sh's resolve()): local plaintext, then the
# live cluster, then a prompt/generator - so adding a new key never re-rolls an
# existing one, and losing the git-ignored secrets/ dir recovers from the running
# cluster instead of minting fresh values. AUTHENTIK_POSTGRESQL__PASSWORD /
# AUTHENTIK_SECRET_KEY / LDAP_BIND_KEY / both Jellyfin OIDC client secrets are
# --unsafe-force: re-rolling them breaks a running install (authentik<->postgres
# auth, all sessions, the LDAP outpost provider, Jellyfin's PVC-stored plugin
# config respectively), so --force skips them - only `--force-key NAME` rolls one.
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/secretlib.sh

secret_parse_args "$@"
secret_init secrets/secret.yaml templates/sealed-secret.yaml
secret_source authentik authentik-secrets

resolve AUTHENTIK_POSTGRESQL__PASSWORD --gen 'rand_b64 32' --unsafe-force \
  --follow-up 'ALTER USER the live Postgres role to match, then restart authentik'
resolve AUTHENTIK_SECRET_KEY --gen 'rand_b64 32' --unsafe-force \
  --follow-up 'invalidates every authentik session immediately'
resolve AUTHENTIK_BOOTSTRAP_PASSWORD --gen 'rand_b64 32'
resolve AUTHENTIK_BOOTSTRAP_TOKEN --gen 'rand_hex 32'
resolve AUTHENTIK_BOOTSTRAP_EMAIL --prompt 'Enter Authentik admin (akadmin) email' --echo
resolve LDAP_BIND_KEY --gen 'rand_hex 32' --unsafe-force \
  --follow-up 'pinned into the LDAP outpost provider - update it there too'
resolve JELLYFIN_OIDC_CLIENT_ID --gen 'rand_hex 16' --unsafe-force
resolve JELLYFIN_OIDC_CLIENT_SECRET --gen 'rand_hex 32' --unsafe-force \
  --follow-up "pinned into Jellyfin's PVC-stored plugin config"
resolve JELLYFIN_OIDC_INTERNAL_CLIENT_ID --gen 'rand_hex 16' --unsafe-force
resolve JELLYFIN_OIDC_INTERNAL_CLIENT_SECRET --gen 'rand_hex 32' --unsafe-force \
  --follow-up "pinned into Jellyfin's PVC-stored plugin config"

secret_literal_args
kubectl create secret generic authentik-secrets \
  --namespace authentik \
  "${SECRET_LITERAL_ARGS[@]}" \
  --dry-run=client -o yaml > "$PLAIN"

secret_finish
