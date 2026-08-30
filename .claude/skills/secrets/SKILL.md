---
name: secrets
description: This skill should be used when creating, rotating, or resealing a secret in this homelab repo, working with kubeseal/Bitnami Sealed Secrets, running or editing a generate-*-secret.sh script, or adding a new chart that needs credentials. Triggers on "seal", "kubeseal", "sealed secret", "generate-secret", "rotate credentials", "GHCR PAT", "Windscribe", "authentik-secrets".
---

# Secrets

**Bitnami Sealed Secrets** is the mechanism (controller in `kube-system`). Encrypted
secrets are committed to git (`*/templates/sealed-*.yaml`, `base/github-credentials-sealed.yaml`,
`base/windscribe-sealed.yaml`, `base/smtp-sealed.yaml`). Every `generate-*-secret.sh`
(`authentik/`, `base/` ×3, `cloudflare/`, `gatus/`, `longhorn/`, `rallly/`) sources
`scripts/secretlib.sh` (which itself sources `scripts/seal.sh`) and declares its keys via
`resolve KEY [--gen ...] [--prompt ...] [--static ...] [--from secret/ns] [--unsafe-force]
[--follow-up ...]`. Each key resolves independently, in order: the git-ignored local
`secrets/` plaintext, then an env var, then the value already live in the cluster
(`kubectl get secret ... -o jsonpath`), then `--prompt`, then `--gen`/`--static`. That
live-cluster fallback is what lets a script recover every value after the plaintext is
lost (fresh checkout, new laptop) instead of silently minting fresh random credentials
that break a running install — on a healthy cluster, re-running after losing `secrets/`
is a no-op, not a rotation. `seal_if_needed` (in `scripts/seal.sh`) then reseals via
`kubeseal`, itself skipped unless the plaintext hash changed or the committed sealed file
no longer validates against the live controller — `kubeseal`'s output is non-deterministic
(fresh random session key/padding per run), so an unconditional reseal would show as a git
diff on every run even with nothing to change; recovering plaintext that matches the live
cluster byte-for-byte skips resealing the same way. Sealed secrets are encrypted against
one specific cluster's key, so re-run these after provisioning a new cluster —
`ansible/roles/secrets` does this automatically (see the `ansible-provisioning` skill).

**Rotating a leaked credential**: `--force` re-rolls every key the script marks *safe*
to re-roll and skips the rest; `--force-key NAME` re-rolls exactly one key, even one
marked unsafe, and prints its required manual follow-up. A key is marked
`--unsafe-force` when re-rolling it breaks a running install without a manual fixup
(authentik's Postgres password and Django secret key, its LDAP bind key, Jellyfin's OIDC
client secrets) — see `authentik/generate-secret.sh` for the concrete follow-ups.

Plaintext lives in per-chart `secrets/` dirs, git-ignored via the root `.gitignore`'s
`/*/secrets/` (top-level charts only — a `secrets/` dir nested deeper is **not** covered,
so keep plaintext at `<chart>/secrets/`). Some bootstrap secrets (TLS, Tailscale) are
instead created imperatively — see `init.sh` (historical reference only, not runnable).

`authentik/generate-secret.sh` owns a single `authentik-secrets` secret carrying every
key the chart needs (Postgres password, Django secret key, akadmin bootstrap
password/token/email, LDAP bind key, Jellyfin OIDC client id/secrets). **None of these
are safe to regenerate on a running install** without the matching manual follow-up:
Postgres password / Django secret key break authentik <-> postgres auth immediately, and
the rest are pinned into the LDAP outpost provider or Jellyfin's PVC-stored plugin config.

`base/generate-secret.sh` annotates the GHCR pull secret for **reflector**
(emberstack), which mirrors it into other namespaces; it recovers its three inputs back
out of the live/local `.dockerconfigjson` blob via `jq`. `base/generate-windscribe-secret.sh`
does the same for the `windscribe-auth` VPN credential (namespace `default`), mirroring it
into `media` (prowlarr's gluetun sidecar) and `transmission` — neither of those charts owns
the secret itself, they only reference `windscribe-auth` by name. `base/generate-smtp-secret.sh`
also checks the `rallly`/`rallly` Secret (`--from rallly/rallly`, its pre-migration source
of truth) before falling back to a prompt. `rallly/generate-secret.sh` is the one script
covering three Secrets (`rallly-postgresql`, `rallly-garage`, `rallly`) out of one
plaintext file — see its `secret_source` calls.

## If plaintext gets committed

The value is burned: rotate it at the source, re-run that app's `generate-*.sh`, and
commit the new sealed file — rewriting history alone is not enough.

## Never commit

The root `CLAUDE.md` carries the full "Never commit" list (plaintext `secrets/` dirs,
kubeconfigs, unsealed tunnel token/PAT/Windscribe/Authentik keys, inlined `.env` values,
PVC dumps) — it's short enough to stay always-loaded rather than repeated here.
