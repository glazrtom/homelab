---
name: ansible-provisioning
description: This skill should be used when running or editing anything under ansible/ in this homelab repo, provisioning a fresh host, rebuilding the cluster from scratch, or validating a playbook syntax. Triggers on "ansible-playbook", "provision", "cluster.yml", "apps.yml", "fresh host", "rebuild the cluster", "--syntax-check".
---

# Ansible provisioning

`ansible/` provisions a host in two stages, each its own playbook, each component its
own role. `ansible.cfg` sets the inventory, so `-i` is never needed:

```
cd ~/projects/homelab/ansible
ansible-galaxy collection install -r requirements.yml --upgrade   # first time / fresh host
ansible-playbook playbooks/cluster.yml -K   # stage 1: host + k3s + cluster foundation
ansible-playbook playbooks/apps.yml -K      # stage 2: workload apps
```

- **`playbooks/cluster.yml`** (the "one command" for a fresh host) runs, in order:
  `server_base` (hostname + dedicated `server` user/group at uid/gid 1001, login user
  joins the group) → `longhorn_node` (Longhorn host prereqs: `open-iscsi`/`nfs-common`/
  `cryptsetup`/`dmsetup`, enables `iscsid`, persists the `iscsi_tcp`/`dm_crypt` kernel
  modules, creates `/var/lib/longhorn`) → `k3s` (installs k3s only, `--disable traefik
  --disable servicelb --disable local-storage`) → `kubeconfig` (fetches the cluster
  kubeconfig to the **control node** as `~/.kube/homelab.yaml`, renamed to the `homelab`
  context and with the API server IP rewritten — every later role in this playbook talks
  to the cluster via that dedicated file from here on — then merges just that `homelab`
  context into `~/.kube/config`, leaving every other context there untouched) → `helm` (installs Helm 3; the helm-diff plugin install is currently
  commented out) → `argocd` (namespace + upstream `install.yaml`, pinned to v3.4.5,
  applied `--server-side`, then disables internal TLS and rollout-restarts if changed)
  → `argocd_apps` (applies `applications/core.yaml`; ArgoCD then installs the Sealed
  Secrets controller from `applications/core/sealed-secrets.yaml`) → `sealed_secrets`
  (only waits for that controller to become available, since `kubeseal` needs it) →
  `cloudflare` (installs/logs in `cloudflared` if needed, creates the
  tunnel and its wildcard DNS route if missing, then runs `cloudflare/generate-secret.sh` —
  the same `scripts/seal.sh` hash-gated reseal used by the other secrets, see the `secrets`
  skill — and prompts before commit/push; any declined or failed step just skips the rest
  of the role rather than failing the play). ArgoCD deploys sealed-secrets, reflector,
  MetalLB, ingress, its own self-config, and Cloudflare (see sync-wave annotations in
  `applications/core/*.yaml`); the cloudflare Application syncs with the old sealed
  secret until the role's reseal is pushed.
- **`playbooks/apps.yml`** (stage 2) runs `secrets` (always resealing — see below) →
  `argocd_apps` (applies `applications/apps.yaml`; ArgoCD then deploys every workload
  under `applications/apps/`).
- The `secrets` role always runs, looping over the generate scripts of every app in its
  `secrets_items` list — currently 7 scripts across `authentik/`, `base/` (GHCR,
  Windscribe), `rallly/` and `dawarich/` (SMTP), and `longhorn/` (B2). It only prompts for a script's human-supplied values when that script has no local
  plaintext yet; if the plaintext is already there, it's assumed correct and just
  resealed as-is, no prompt (leave a prompt blank to skip that one and keep its
  committed sealed file instead). It then commits and pushes just the sealed files that
  changed. Run it standalone via `playbooks/secrets.yml`, which also runs `cloudflare`
  first, without redeploying anything.
- Because `helm`/`sealed_secrets`/`argocd`/`cloudflare`/`argocd_apps`/`secrets` run on
  the **control node** (not the server) against the fetched kubeconfig, that machine
  needs `kubectl`, `helm`, `kubeseal`, and `git` (with push access to this repo)
  available; `cloudflared` is optional — the `cloudflare` role installs it itself (via
  `brew`/`apt-get`) if missing and prompted for, and warns-and-skips (never fails the
  play) if it can't get a working, logged-in `cloudflared`.
- `playbooks/storage.yml` (mount a disk at `/mnt/storage`) is situational — run
  individually, on demand.
- Prompt-bearing roles/playbooks (`storage`, `secrets`, and the `cloudflare` role's
  install/login/commit/push prompts) no-op or fall back sensibly when left blank — see
  each role/playbook for specifics.
- Tunables live in each role's `defaults/main.yml`. `kubeconfig_path` (the dedicated,
  control-node `~/.kube/homelab.yaml` used from `kubeconfig` onward),
  `kubeconfig_merged_path` (the shared `~/.kube/config` that only gets the `homelab`
  context merged into it, never overwritten), `kube_context` (`homelab`), and
  `path_home` are shared via `group_vars/all.yml`.
- Provisions as the existing `glazrtom` user against the `[server]` host in `inventory.ini`
  — no separate bootstrap inventory.

`init.sh` at the repo root predates this and is a non-runnable historical template
documenting the original fully-manual setup order — reference only, not a script to run.

## Validating a playbook

`cd ansible && ansible-playbook --syntax-check playbooks/<pb>.yml` — the `--syntax-check`
flag must come **immediately** after `ansible-playbook`, since that exact prefix is what
the `@claude` GitHub Action allowlists (a full play run is deliberately not permitted in
headless runs).

If it fails with `ERROR: Ansible requires blocking IO on stdin/stdout/stderr. Non-blocking
file handles detected: <stdout>, <stderr>`, that's a sandbox pipe artifact, not a real
playbook problem — rerun as `ansible-playbook --syntax-check playbooks/<pb>.yml 2>&1 | cat`
(both streams need to go through the pipe; `| cat` alone still leaves stderr non-blocking).
