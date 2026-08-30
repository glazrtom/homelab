---
name: secrets
description: This skill should be used when creating, rotating, or resealing a secret in this homelab repo, working with kubeseal/Bitnami Sealed Secrets, running or editing a generate-*-secret.sh script, or adding a new chart that needs credentials. Triggers on "seal", "kubeseal", "sealed secret", "generate-secret", "rotate credentials", "GHCR PAT", "Windscribe", "authentik-secrets".
---

# Secrets

**Bitnami Sealed Secrets** is the mechanism (controller in `kube-system`). Encrypted
secrets are committed to git (`*/templates/sealed-*.yaml`, `base/github-credentials-sealed.yaml`,
`base/windscribe-sealed.yaml`). Each service's `generate-*-secret.sh` (in `authentik/`,
`base/`, `cloudflare/`) is **idempotent**: it reuses the plaintext
already sitting in its git-ignored `secrets/` dir if present, only generating (random
values) or prompting (human-supplied values, e.g. the GHCR PAT or Windscribe creds) when
that plaintext is missing, then calls `scripts/seal.sh` (shared helper) to reseal via
`kubeseal`. Resealing is itself skipped unless the plaintext hash changed or the committed
sealed file no longer validates against the live controller — `kubeseal`'s output is
non-deterministic (fresh random session key/padding per run), so an unconditional reseal
would show as a git diff on every run even with nothing to change. Sealed secrets are
encrypted against one specific cluster's key, so re-run these after provisioning a new
cluster — `ansible/roles/secrets` does this automatically (see the `ansible-provisioning`
skill).

Plaintext lives in per-chart `secrets/` dirs, git-ignored via the root `.gitignore`'s
`/*/secrets/` (top-level charts only — a `secrets/` dir nested deeper is **not** covered,
so keep plaintext at `<chart>/secrets/`). Some bootstrap secrets (TLS, Tailscale) are
instead created imperatively — see `init.sh` (historical reference only, not runnable).

`authentik/generate-secret.sh` owns a single `authentik-secrets` secret carrying every
key the chart needs (Postgres password, Django secret key, akadmin bootstrap
password/token/email, LDAP bind key, Jellyfin OIDC client id/secrets). Each key
backfills independently — existing values are read back out of the git-ignored
plaintext and only missing keys are freshly generated — so adding a new key later
never re-rolls an existing one. **None of these are safe to regenerate on a running
install**: Postgres password / Django secret key break authentik <-> postgres auth
immediately, and the rest are pinned into the LDAP outpost provider or Jellyfin's
PVC-stored plugin config.

`base/generate-secret.sh` annotates the GHCR pull secret for **reflector**
(emberstack), which mirrors it into other namespaces. `base/generate-windscribe-secret.sh`
does the same for the `windscribe-auth` VPN credential (namespace `default`), mirroring it
into `media` (prowlarr's gluetun sidecar) and `transmission` — neither of those charts owns
the secret itself, they only reference `windscribe-auth` by name.

## If plaintext gets committed

The value is burned: rotate it at the source, re-run that app's `generate-*.sh`, and
commit the new sealed file — rewriting history alone is not enough.

## Never commit

The root `CLAUDE.md` carries the full "Never commit" list (plaintext `secrets/` dirs,
kubeconfigs, unsealed tunnel token/PAT/Windscribe/Authentik keys, inlined `.env` values,
PVC dumps) — it's short enough to stay always-loaded rather than repeated here.
