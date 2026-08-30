#! /bin/bash
# Shared helper for the per-app generate-*secret*.sh scripts - normally sourced
# indirectly via scripts/secretlib.sh, which sources this file first.
#
# kubeseal's output is non-deterministic (fresh random AES session key + RSA-OAEP
# padding every run), so unconditionally resealing turns every run into a git diff
# even when nothing actually changed. seal_if_needed() only reseals when the
# plaintext changed, the sealed file is missing, or the committed sealed file no
# longer validates against the live controller (e.g. new cluster/key).

SEALED_SECRETS_NAMESPACE="${SEALED_SECRETS_NAMESPACE:-kube-system}"
SEALED_SECRETS_NAME="${SEALED_SECRETS_NAME:-sealed-secrets-controller}"

_seal_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# _seal_matches_live <plain> - true (0) only if every key across every document in
# <plain> matches the value already live in the cluster, so recovering plaintext
# from a healthy cluster (e.g. after a lost secrets/ dir) is a genuine no-op rather
# than a diff. Relies on secretlib.sh's _yaml_secret_dump/live_value; returns false
# (so the caller falls back to a normal reseal) if those aren't loaded, the file
# has no parseable documents, or any key differs / can't be read from the cluster.
_seal_matches_live() {
  local plain="$1"
  declare -f _yaml_secret_dump >/dev/null 2>&1 || return 1
  declare -f live_value >/dev/null 2>&1 || return 1

  local rows_seen=0 ns name section key value live decoded
  while IFS=$'\t' read -r ns name section key value; do
    rows_seen=1
    [ -n "$ns" ] && [ -n "$name" ] || return 1
    if [ "$section" = "data" ]; then
      decoded="$(printf '%s' "$value" | base64 -d 2>/dev/null || true)"
      live="$(live_value "$ns" "$name" "$key")"
      [ "$decoded" = "$live" ] || return 1
    else
      live="$(live_value "$ns" "$name" "$key")"
      [ "$value" = "$live" ] || return 1
    fi
  done < <(_yaml_secret_dump "$plain")
  [ "$rows_seen" -eq 1 ]
}

# seal_if_needed <plaintext-path> <sealed-path>
seal_if_needed() {
  local plain="$1"
  local sealed="$2"
  local hash_file
  hash_file="$(dirname "$plain")/.$(basename "$plain").sha256"

  local needs_reseal=0

  if [ ! -f "$sealed" ] || [ ! -f "$hash_file" ]; then
    if [ -f "$sealed" ] && [ -f "$plain" ] && kubeseal \
        --controller-namespace "$SEALED_SECRETS_NAMESPACE" \
        --controller-name "$SEALED_SECRETS_NAME" \
        --validate < "$sealed" >/dev/null 2>&1 \
        && _seal_matches_live "$plain"; then
      echo "$sealed already matches the live cluster; recording hash without resealing"
      _seal_sha256 "$plain" > "$hash_file"
      return 0
    fi
    needs_reseal=1
  elif [ "$(_seal_sha256 "$plain")" != "$(cat "$hash_file")" ]; then
    needs_reseal=1
  elif ! kubeseal --controller-namespace "$SEALED_SECRETS_NAMESPACE" \
      --controller-name "$SEALED_SECRETS_NAME" \
      --validate < "$sealed" >/dev/null 2>&1; then
    needs_reseal=1
  fi

  if [ "$needs_reseal" -eq 0 ]; then
    echo "$sealed up to date, not resealing"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  kubeseal --controller-namespace "$SEALED_SECRETS_NAMESPACE" \
    --controller-name "$SEALED_SECRETS_NAME" \
    --format yaml < "$plain" > "$tmp"
  mv "$tmp" "$sealed"

  _seal_sha256 "$plain" > "$hash_file"
}
