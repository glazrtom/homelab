#! /bin/bash
# Shared helper for the per-app generate-*secret*.sh scripts.
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

# seal_if_needed <plaintext-path> <sealed-path>
seal_if_needed() {
  local plain="$1"
  local sealed="$2"
  local hash_file
  hash_file="$(dirname "$plain")/.$(basename "$plain").sha256"

  local needs_reseal=0

  if [ ! -f "$sealed" ] || [ ! -f "$hash_file" ]; then
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
