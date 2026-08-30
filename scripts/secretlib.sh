#! /bin/bash
# Shared helper for the per-app generate-*secret*.sh scripts: value resolution,
# forced rotation, and the plaintext/sealed-file bookkeeping around them.
# Sources scripts/seal.sh itself, so a generate-*.sh only needs to source this file.
#
# Resolution order for each key, first hit wins: forced (--force/--force-key) >
# local plaintext ($PLAIN, already-committed-to-disk values) > env var > an explicit
# --from secret, or the key's own name in the cluster > --prompt > --gen/--static.
# This is what lets a script recover every value from a running cluster when the
# git-ignored secrets/ dir is missing (fresh checkout, lost laptop), rather than
# silently minting fresh random credentials that break a live install.
#
# Written against bash 3.2 (macOS's /bin/bash, the interpreter these scripts run
# under via ansible's `connection: local`): no associative arrays, no `local -n`,
# and every array expansion is length-guarded first since `${arr[@]}` on an empty
# indexed array is a hard "unbound variable" error under `set -u` in bash <4.4.

SCRIPT_DIR_SECRETLIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR_SECRETLIB/seal.sh"

FORCE_ALL=0
FORCE_KEYS=()
SECRET_ARGS=()
SECRET_KEY_NAMES=()
SECRET_GROUP_KEYS=()
SECRET_UNSAFE_KEYS=()

# secret_parse_args "$@" - consumes --force / --force-key KEY / --help; anything else
# (e.g. cloudflare's tunnel-id positional) lands in SECRET_ARGS for the caller to use.
secret_parse_args() {
  FORCE_ALL=0
  FORCE_KEYS=()
  SECRET_ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --force)
        FORCE_ALL=1
        shift
        ;;
      --force-key)
        [ $# -ge 2 ] || { echo "--force-key requires a KEY argument" >&2; exit 1; }
        FORCE_KEYS+=("$2")
        shift 2
        ;;
      --help)
        echo "Usage: $0 [--force] [--force-key KEY]... [args]"
        echo "  --force        re-roll every safe key (skips keys marked unsafe to re-roll)"
        echo "  --force-key K  re-roll exactly key K, even if it is marked unsafe"
        exit 0
        ;;
      --)
        shift
        while [ $# -gt 0 ]; do SECRET_ARGS+=("$1"); shift; done
        ;;
      *)
        SECRET_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

_secret_key_is_forced() {
  local key="$1" unsafe="$2" k
  if [ "${#FORCE_KEYS[@]}" -gt 0 ]; then
    for k in "${FORCE_KEYS[@]}"; do
      [ "$k" = "$key" ] && return 0
    done
  fi
  [ "$FORCE_ALL" -eq 1 ] && [ "$unsafe" -eq 0 ] && return 0
  return 1
}

# secret_init <plaintext-path> <sealed-path>
secret_init() {
  PLAIN="$1"
  SEALED="$2"
  mkdir -p "$(dirname "$PLAIN")"
  chmod go-rwx "$(dirname "$PLAIN")"
}

# secret_source <namespace> <secret-name> - which live/local secret `resolve` reads
# from by default. Call again mid-script for a plaintext file holding multiple
# Secrets (rallly: rallly-postgresql / rallly-garage / rallly all share one $PLAIN);
# each call starts a fresh group for secret_literal_args, so it only ever emits
# --from-literal flags for the keys resolved since the last secret_source call.
secret_source() {
  CURRENT_NS="$1"
  CURRENT_SECRET="$2"
  SECRET_GROUP_KEYS=()
}

# live_value <namespace> <secret> <key> - base64-decoded value of KEY in the live
# cluster Secret, or empty (never fails) if it's absent/unreachable/offline.
live_value() {
  local ns="$1" secret="$2" key="$3" b64
  b64="$(kubectl -n "$ns" get secret "$secret" -o "jsonpath={.data.$key}" 2>/dev/null || true)"
  [ -n "$b64" ] && printf '%s' "$b64" | base64 -d || true
}

# _yaml_secret_dump <file> - one row per key across every document in <file>:
# "<namespace>\t<name>\t<section>\t<key>\t<value>" (value verbatim as written -
# `section` is `data` or `stringData`, telling the caller whether it still needs
# base64-decoding). Handles kubectl's single-doc `-o yaml` dumps (where `data:`
# is alphabetically ahead of `metadata:`, i.e. the name arrives *after* the keys)
# and hand-written multi-doc `---`-separated files alike, by buffering each
# document and scanning it twice - once for the name, once for the keys - rather
# than assuming field order. Assumes no value contains a literal tab.
_yaml_secret_dump() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    function flush_doc(   i, section, name, ns, k, key, val, l, line) {
      section = ""; name = ""; ns = ""
      for (i = 0; i < n; i++) {
        line = doclines[i]
        if (line ~ /^[A-Za-z]/) {
          k = line; sub(/:.*/, "", k)
          section = (k == "metadata") ? "metadata" : ""
          continue
        }
        if (section == "metadata" && line ~ /^  name:/) {
          l = line; sub(/^  name:[[:space:]]*/, "", l); name = l
        }
        if (section == "metadata" && line ~ /^  namespace:/) {
          l = line; sub(/^  namespace:[[:space:]]*/, "", l); ns = l
        }
      }
      section = ""
      for (i = 0; i < n; i++) {
        line = doclines[i]
        if (line ~ /^[A-Za-z]/) {
          k = line; sub(/:.*/, "", k)
          if (k == "data") section = "data"
          else if (k == "stringData") section = "stringData"
          else section = ""
          continue
        }
        if (section == "data" || section == "stringData") {
          l = line; sub(/^  /, "", l)
          key = l; sub(/:.*/, "", key)
          val = l; sub(/^[^:]+:[[:space:]]*/, "", val)
          gsub(/^"|"$/, "", val)
          printf "%s\t%s\t%s\t%s\t%s\n", ns, name, section, key, val
        }
      }
    }
    /^---[[:space:]]*$/ { flush_doc(); n = 0; next }
    { doclines[n++] = $0 }
    END { flush_doc() }
  ' "$file"
}

# local_value <secret-name> <key> - value already sitting in $PLAIN, or empty.
local_value() {
  local secret="$1" key="$2" ns name section rkey value
  while IFS=$'\t' read -r ns name section rkey value; do
    if [ "$name" = "$secret" ] && [ "$rkey" = "$key" ]; then
      if [ "$section" = "data" ]; then
        printf '%s' "$value" | base64 -d 2>/dev/null || true
      else
        printf '%s' "$value"
      fi
      return 0
    fi
  done < <(_yaml_secret_dump "$PLAIN")
}

rand_b64()  { openssl rand -base64 "$1"; }
rand_hex()  { openssl rand -hex "$1"; }
rand_alnum() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1"; }

# reflector_annotations ns1,ns2,... - the four reflector.v1.k8s.emberstack.com
# annotations, one per line so `kubectl annotate --local -f - $(reflector_annotations ...)`
# word-splits them correctly.
reflector_annotations() {
  local namespaces="$1"
  printf 'reflector.v1.k8s.emberstack.com/reflection-allowed=true\n'
  if [ -n "$namespaces" ]; then
    printf 'reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces=%s\n' "$namespaces"
    printf 'reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true\n'
    printf 'reflector.v1.k8s.emberstack.com/reflection-auto-namespaces=%s\n' "$namespaces"
  fi
}

# resolve KEY [--gen 'cmd'] [--prompt "text"] [--echo] [--from secret[/ns]]
#             [--static value] [--unsafe-force] [--follow-up "text"] [--env NAME]
#
# Sets a real shell variable named KEY (readable as "$KEY", exactly like the
# hand-written scripts did) plus SECRET_SOURCE_<KEY> for the end-of-run summary.
resolve() {
  local key="$1"; shift
  local gen="" prompt="" echo_flag=0 from_secret="" from_ns="" static_val=""
  local unsafe=0 followup="" env_name="$key"

  while [ $# -gt 0 ]; do
    case "$1" in
      --gen) gen="$2"; shift 2 ;;
      --prompt) prompt="$2"; shift 2 ;;
      --echo) echo_flag=1; shift ;;
      --from)
        from_secret="${2%%/*}"
        case "$2" in */*) from_ns="${2#*/}" ;; *) from_ns="$CURRENT_NS" ;; esac
        shift 2
        ;;
      --static) static_val="$2"; shift 2 ;;
      --unsafe-force) unsafe=1; shift ;;
      --follow-up) followup="$2"; shift 2 ;;
      --env) env_name="$2"; shift 2 ;;
      *) echo "resolve: unknown option '$1'" >&2; exit 1 ;;
    esac
  done

  SECRET_KEY_NAMES+=("$key")
  SECRET_GROUP_KEYS+=("$key")
  [ "$unsafe" -eq 1 ] && SECRET_UNSAFE_KEYS+=("$key")
  [ -n "$followup" ] && printf -v "SECRET_FOLLOWUP_${key}" '%s' "$followup"

  local value="" source_desc="" forced=0
  _secret_key_is_forced "$key" "$unsafe" && forced=1

  if [ "$forced" -eq 0 ]; then
    value="$(local_value "$CURRENT_SECRET" "$key")"
    [ -n "$value" ] && source_desc="local plaintext"

    if [ -z "$value" ] && [ -n "${!env_name+x}" ] && [ -n "${!env_name}" ]; then
      value="${!env_name}"
      source_desc="env var \$${env_name}"
    fi

    if [ -z "$value" ] && [ -n "$from_secret" ]; then
      value="$(live_value "$from_ns" "$from_secret" "$key")"
      [ -n "$value" ] && source_desc="live cluster ($from_ns/$from_secret)"
    fi

    # Always try the secret's own live value too (not just when --from is unset):
    # an explicit --from is a *migration* source (e.g. smtp's pre-migration
    # rallly secret), which shouldn't stop this secret's own already-live copy of
    # itself from being found once it exists.
    if [ -z "$value" ]; then
      value="$(live_value "$CURRENT_NS" "$CURRENT_SECRET" "$key")"
      [ -n "$value" ] && source_desc="live cluster"
    fi
  fi

  if [ -z "$value" ] && [ -n "$prompt" ]; then
    if [ "$echo_flag" -eq 1 ]; then
      read -r -p "${prompt}: " value
    else
      read -r -s -p "${prompt}: " value
      echo
    fi
    [ -n "$value" ] && source_desc="prompted"
  fi

  if [ -z "$value" ] && [ -n "$static_val" ]; then
    value="$static_val"
    source_desc="static"
  fi

  if [ -z "$value" ] && [ -n "$gen" ]; then
    value="$(eval "$gen")"
    [ "$forced" -eq 1 ] && source_desc="re-rolled (forced)" || source_desc="generated"
  fi

  if [ -z "$value" ]; then
    echo "Error: no value could be resolved for $key" >&2
    exit 1
  fi

  printf -v "$key" '%s' "$value"
  printf -v "SECRET_SOURCE_${key}" '%s' "$source_desc"
}

# secret_literal_args - builds SECRET_LITERAL_ARGS, an array of --from-literal=KEY=val
# flags for the keys resolved since the last secret_source call, for the common
# `kubectl create secret generic` case.
secret_literal_args() {
  local k
  SECRET_LITERAL_ARGS=()
  if [ "${#SECRET_GROUP_KEYS[@]}" -gt 0 ]; then
    for k in "${SECRET_GROUP_KEYS[@]}"; do
      SECRET_LITERAL_ARGS+=("--from-literal=${k}=${!k}")
    done
  fi
}

# secret_finish - lock down $PLAIN, print what happened to each key, unset every
# resolved value from the shell's environment, and reseal (sha-gated, so a run with
# nothing forced and nothing missing is a no-op both on disk and in git).
secret_finish() {
  chmod go-rwx "$PLAIN"

  local k srcvar unsafe_list=""
  if [ "${#SECRET_KEY_NAMES[@]}" -gt 0 ]; then
    for k in "${SECRET_KEY_NAMES[@]}"; do
      srcvar="SECRET_SOURCE_${k}"
      echo "  $k: ${!srcvar}"
    done
  fi

  if [ "$FORCE_ALL" -eq 1 ] && [ "${#SECRET_UNSAFE_KEYS[@]}" -gt 0 ]; then
    for k in "${SECRET_UNSAFE_KEYS[@]}"; do
      _secret_key_is_forced "$k" 1 || unsafe_list="$unsafe_list $k"
    done
    [ -n "$unsafe_list" ] && echo "skipped (unsafe to re-roll, use --force-key):$unsafe_list"
  fi

  if [ "${#SECRET_UNSAFE_KEYS[@]}" -gt 0 ]; then
    for k in "${SECRET_UNSAFE_KEYS[@]}"; do
      if _secret_key_is_forced "$k" 1; then
        local followupvar followup
        followupvar="SECRET_FOLLOWUP_${k}"
        followup="${!followupvar:-}"
        [ -n "$followup" ] && echo "!! follow-up required for $k: $followup"
      fi
    done
  fi

  if [ "${#SECRET_KEY_NAMES[@]}" -gt 0 ]; then
    for k in "${SECRET_KEY_NAMES[@]}"; do
      unset "$k"
    done
  fi

  seal_if_needed "$PLAIN" "$SEALED"
}
