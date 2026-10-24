#!/bin/bash
# Per-mount PF/route hardening for the vmnet NFS transport.
#
# This is an Option-A rollout: a mount remains usable when hardening cannot be proven, but every
# outcome is written as a non-ambiguous state/reason pair. State is per device so concurrent mounts
# never share an anchor, PF enable token, or owned route.
set -u

SECURITY_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck source=pf-anchor.sh
# shellcheck disable=SC1091
source "$SECURITY_LIB_DIR/pf-anchor.sh"
# shellcheck source=route-guard.sh
# shellcheck disable=SC1091
source "$SECURITY_LIB_DIR/route-guard.sh"
# shellcheck source=run-with-progress.sh
# shellcheck disable=SC1091
source "$SECURITY_LIB_DIR/run-with-progress.sh"

SECURITY_STATE_DIR="${NTFSMAC_SECURITY_STATE_DIR:-/var/run/ntfsmac/security}"
SECURITY_PFCTL_BIN="${NTFSMAC_PFCTL_BIN:-/sbin/pfctl}"
SECURITY_MOUNT_BIN="${NTFSMAC_MOUNT_BIN:-/sbin/mount}"
SECURITY_NFSSTAT_BIN="${NTFSMAC_NFSSTAT_BIN:-/usr/bin/nfsstat}"
SECURITY_DSCACHEUTIL_BIN="${NTFSMAC_DSCACHEUTIL_BIN:-/usr/bin/dscacheutil}"
SECURITY_IFCONFIG_BIN="${NTFSMAC_IFCONFIG_BIN:-/sbin/ifconfig}"
SECURITY_PS_BIN="${NTFSMAC_PS_BIN:-/bin/ps}"
SECURITY_ANYLINUXFS_BIN="${NTFSMAC_ANYLINUXFS_BIN:-${ANYLINUXFS_BIN:-}}"
SECURITY_ANCHOR_PREFIX="com.apple/ntfsmac-"

# A VPN can capture the vmnet guest endpoint before anylinuxfs performs its host-side NFS
# readiness check. These globals carry the exact PF token/host-route ownership acquired while
# the mount process is still starting into security_apply_for_mount(), which performs the final
# soft-NFS and mount-table proof. They never cross process boundaries or become shared state.
SECURITY_PREPARED_ACTIVE="0"
SECURITY_PREPARED_SESSION=""
SECURITY_PREPARED_BASELINE=""
SECURITY_PREPARED_ENDPOINT=""
SECURITY_PREPARED_SUBNET=""
SECURITY_PREPARED_INTERFACE=""
SECURITY_PREPARED_ANCHOR=""
SECURITY_PREPARED_PF_TOKEN=""
SECURITY_PREPARED_PF_STATE="unknown"
SECURITY_PREPARED_PF_REASON="PF_UNMEASURED"
SECURITY_PREPARED_ROUTE_OWNED="0"
SECURITY_PREPARED_ROUTE_STATE="unknown"
SECURITY_PREPARED_ROUTE_REASON="ROUTE_UNMEASURED"

security_valid_session() {
  [[ "${1:-}" =~ ^disk[0-9]+(s[0-9]+)?$ ]]
}

security_state_path() {
  security_valid_session "${1:-}" || return 1
  [[ ! -L "$SECURITY_STATE_DIR" ]] || return 1
  printf '%s/%s.state\n' "$SECURITY_STATE_DIR" "$1"
}

security_state_value() {
  local file="$1" key="$2"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  local k v
  while IFS='=' read -r k v || [[ -n "$k" ]]; do
    if [[ "$k" == "$key" ]]; then
      printf '%s\n' "$v"
      return 0
    fi
  done < "$file"
  return 1
}

security_status_output() {
  local status_tmp
  if [[ -n "${NTFSMAC_SECURITY_STATUS_OUTPUT+x}" ]]; then
    printf '%s\n' "$NTFSMAC_SECURITY_STATUS_OUTPUT"
    return 0
  fi
  [[ -n "$SECURITY_ANYLINUXFS_BIN" && -x "$SECURITY_ANYLINUXFS_BIN" ]] || return 1
  status_tmp="$(mktemp "${TMPDIR:-/tmp}/ntfsmac-security-status.XXXXXX")" || return 1
  trap 'rm -f -- "$status_tmp"; trap - INT; kill -INT $$' INT
  trap 'rm -f -- "$status_tmp"; trap - TERM; kill -TERM $$' TERM
  if run_with_progress "${NTFSMAC_SECURITY_STATUS_TIMEOUT:-5}" 10 "security-status" \
    "$status_tmp" "$SECURITY_ANYLINUXFS_BIN" status; then
    /bin/cat "$status_tmp"
    rm -f "$status_tmp"
    trap - INT TERM
    return 0
  fi
  rm -f "$status_tmp"
  trap - INT TERM
  return 1
}

security_mount_output() {
  if [[ -n "${NTFSMAC_SECURITY_MOUNT_OUTPUT+x}" ]]; then
    printf '%s\n' "$NTFSMAC_SECURITY_MOUNT_OUTPUT"
  else
    "$SECURITY_MOUNT_BIN" -t nfs 2>/dev/null
  fi
}

security_nfsstat_output() {
  if [[ -n "${NTFSMAC_SECURITY_NFSSTAT_OUTPUT+x}" ]]; then
    printf '%s\n' "$NTFSMAC_SECURITY_NFSSTAT_OUTPUT"
  else
    "$SECURITY_NFSSTAT_BIN" -m 2>/dev/null
  fi
}

security_mount_point_for_session() {
  local session="$1" line status_output
  status_output="$(security_status_output)" || return 1
  while IFS= read -r line; do
    case "$line" in
      "/dev/$session on "*)
        line="${line#"/dev/$session on "}"
        printf '%s\n' "${line%% (*}"
        return 0
        ;;
    esac
  done <<< "$status_output"
  return 1
}

security_session_for_target() {
  local target="${1:-}" line status_output prefix remainder
  if security_valid_session "$target"; then
    printf '%s\n' "$target"
    return 0
  fi
  [[ "$target" == /Volumes/* && "$target" != *..* ]] || return 1
  status_output="$(security_status_output)" || return 1
  while IFS= read -r line; do
    [[ "$line" == /dev/disk*s*" on "* ]] || continue
    prefix="${line%% on *}"
    remainder="${line#* on }"
    [[ "${remainder%% (*}" == "$target" ]] || continue
    prefix="${prefix#/dev/}"
    security_valid_session "$prefix" || return 1
    printf '%s\n' "$prefix"
    return 0
  done <<< "$status_output"
  return 1
}

security_source_for_mount_point() {
  local mount_point="$1" line source remainder
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    source="${line%% on *}"
    [[ "$source" != "$line" ]] || continue
    remainder="${line#* on }"
    [[ "${remainder%% (nfs*}" == "$mount_point" ]] || continue
    printf '%s\n' "$source"
    return 0
  done <<< "$(security_mount_output)"
  return 1
}

security_resolve_host() {
  local host="$1" resolved
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    resolved="$host"
  elif [[ -n "${NTFSMAC_SECURITY_RESOLVED_IP_OVERRIDE-}" ]]; then
    resolved="$NTFSMAC_SECURITY_RESOLVED_IP_OVERRIDE"
  else
    resolved="$("$SECURITY_DSCACHEUTIL_BIN" -q host -a name "$host" 2>/dev/null \
      | awk '/^ip_address: / { print $2; exit }')"
  fi
  route_guard_valid_endpoint "$resolved" || return 1
  printf '%s\n' "$resolved"
}

security_bridge_interface() {
  local subnet="$1" interface ifconfig_output
  interface="${NTFSMAC_SECURITY_BRIDGE_INTERFACE_OVERRIDE-${NTFSMAC_SECURITY_ROUTE_INTERFACE_OVERRIDE-}}"
  if [[ -z "$interface" ]]; then
    ifconfig_output="$("$SECURITY_IFCONFIG_BIN" 2>/dev/null)" || return 1
    interface="$(awk -v wanted="$subnet" '
      /^[^[:space:]]/ {
        interface = $1
        sub(/:$/, "", interface)
      }
      interface ~ /^bridge[0-9]+$/ && $1 == "inet" {
        netmask = ""
        for (field = 1; field <= NF; field++) {
          if ($field == "netmask" && field < NF) netmask = $(field + 1)
        }
        if (netmask != "0xfffffffc") next
        split($2, octet, ".")
        network = octet[1] "." octet[2] "." octet[3] "." (int(octet[4] / 4) * 4) "/30"
        if (network == wanted) { print interface; exit }
      }
    ' <<< "$ifconfig_output")"
  fi
  [[ "$interface" =~ ^bridge[0-9]+$ ]] || return 1
  printf '%s\n' "$interface"
}

security_subnet_for_ip() {
  local ip="$1" a b c d network
  route_guard_valid_endpoint "$ip" || return 1
  IFS=. read -r a b c d <<< "$ip"
  a=$((10#$a)); b=$((10#$b)); c=$((10#$c)); d=$((10#$d))
  network=$((d / 4 * 4))
  printf '%s.%s.%s.%s/30\n' "$a" "$b" "$c" "$network"
}

# Emits fixed-shape, validated bridge|endpoint|subnet records for active anylinuxfs vmnet /30s.
# vmnet-helper assigns the first usable address to the host bridge and the second to the guest.
# The optional file is a deterministic test seam; production always measures live ifconfig.
security_vmnet_bridge_candidates() {
  local ifconfig_output
  if [[ -n "${NTFSMAC_SECURITY_BRIDGE_CANDIDATES_FILE-}" ]]; then
    [[ -f "$NTFSMAC_SECURITY_BRIDGE_CANDIDATES_FILE" ]] || return 0
    /bin/cat "$NTFSMAC_SECURITY_BRIDGE_CANDIDATES_FILE"
    return 0
  fi
  ifconfig_output="$("$SECURITY_IFCONFIG_BIN" 2>/dev/null)" || return 1
  awk '
    /^[^[:space:]]/ {
      interface = $1
      sub(/:$/, "", interface)
    }
    interface ~ /^bridge[0-9]+$/ && $1 == "inet" {
      netmask = ""
      for (field = 1; field <= NF; field++) {
        if ($field == "netmask" && field < NF) netmask = $(field + 1)
      }
      if (netmask != "0xfffffffc") next
      split($2, octet, ".")
      a = int(octet[1]); b = int(octet[2]); c = int(octet[3]); d = int(octet[4])
      network = int(d / 4) * 4
      if (a != 172 || b < 16 || b > 31 || c < 0 || c > 255 || d != network + 1) next
      printf "%s|%d.%d.%d.%d|%d.%d.%d.%d/30\n", interface, a, b, c, network + 2, a, b, c, network
    }
  ' <<< "$ifconfig_output"
}

security_reset_prepared_mount() {
  SECURITY_PREPARED_ACTIVE="0"
  SECURITY_PREPARED_SESSION=""
  SECURITY_PREPARED_BASELINE=""
  SECURITY_PREPARED_ENDPOINT=""
  SECURITY_PREPARED_SUBNET=""
  SECURITY_PREPARED_INTERFACE=""
  SECURITY_PREPARED_ANCHOR=""
  SECURITY_PREPARED_PF_TOKEN=""
  SECURITY_PREPARED_PF_STATE="unknown"
  SECURITY_PREPARED_PF_REASON="PF_UNMEASURED"
  SECURITY_PREPARED_ROUTE_OWNED="0"
  SECURITY_PREPARED_ROUTE_STATE="unknown"
  SECURITY_PREPARED_ROUTE_REASON="ROUTE_UNMEASURED"
}

# Snapshot existing private bridges immediately before anylinuxfs starts. The new exact /30 is
# then unambiguous for the serialized GUI/helper mount path, without trusting a configured pool
# or assuming bridge100. Direct concurrent mounts still receive independently measured state
# after completion; this early hook exists only to break a VPN route-capture deadlock.
security_begin_prepared_mount() {
  local session="$1"
  security_valid_session "$session" || return 1
  security_reset_prepared_mount
  SECURITY_PREPARED_SESSION="$session"
  SECURITY_PREPARED_BASELINE="$(security_vmnet_bridge_candidates 2>/dev/null || true)"
}

security_mount_job_running() {
  local pid="$1" state
  kill -0 "$pid" 2>/dev/null || return 1
  state="$("$SECURITY_PS_BIN" -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$state" && "$state" != Z* ]]
}

# Called while run_with_progress/anylinuxfs is alive in a background job. As soon as its new
# vmnet /30 appears, load the per-session evaluated PF policy and repair only an exact VPN-
# captured guest route. This occurs before anylinuxfs's NFS port check, not after it times out.
security_prepare_mount_transport() {
  local session="$1" mount_pid="$2" timeout start candidates candidate
  local interface endpoint subnet anchor
  security_valid_session "$session" || return 1
  [[ "$mount_pid" =~ ^[0-9]+$ ]] || return 1
  timeout="${NTFSMAC_SECURITY_PREPARE_TIMEOUT:-30}"
  [[ "$timeout" =~ ^[0-9]+$ && "$timeout" -gt 0 ]] || timeout="30"
  start=$SECONDS

  while kill -0 "$mount_pid" 2>/dev/null && security_mount_job_running "$mount_pid" && (( SECONDS - start < timeout )); do
    candidates="$(security_vmnet_bridge_candidates 2>/dev/null || true)"
    candidate=""
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] || continue
      if ! grep -Fqx "$candidate" <<< "$SECURITY_PREPARED_BASELINE"; then
        break
      fi
      candidate=""
    done <<< "$candidates"
    if [[ -n "$candidate" ]]; then
      IFS='|' read -r interface endpoint subnet <<< "$candidate"
      anchor="$SECURITY_ANCHOR_PREFIX$session"
      if [[ "$interface" =~ ^bridge[0-9]+$ ]] \
        && route_guard_valid_endpoint "$endpoint" \
        && valid_vmnet_subnet "$subnet" \
        && [[ "$(security_subnet_for_ip "$endpoint" 2>/dev/null || true)" == "$subnet" ]]; then
        SECURITY_PREPARED_ACTIVE="1"
        SECURITY_PREPARED_ENDPOINT="$endpoint"
        SECURITY_PREPARED_SUBNET="$subnet"
        SECURITY_PREPARED_INTERFACE="$interface"
        SECURITY_PREPARED_ANCHOR="$anchor"

        security_apply_pf "$session" "$subnet" "$interface" "$anchor"
        SECURITY_PREPARED_PF_STATE="$SECURITY_PF_STATE"
        SECURITY_PREPARED_PF_REASON="$SECURITY_PF_REASON"
        SECURITY_PREPARED_PF_TOKEN="$SECURITY_PF_TOKEN"

        apply_vpn_bypass "$endpoint" "$interface" || true
        SECURITY_PREPARED_ROUTE_STATE="$VPN_ROUTE_STATE"
        SECURITY_PREPARED_ROUTE_REASON="$VPN_ROUTE_REASON"
        SECURITY_PREPARED_ROUTE_OWNED="$VPN_ROUTE_OWNED"
        printf 'security_prepare=%s reason=%s\n' \
          "$([[ ( "$SECURITY_PREPARED_PF_STATE" == "enforced" \
                || "$SECURITY_PREPARED_PF_STATE" == "notRequired" ) \
              && ( "$SECURITY_PREPARED_ROUTE_STATE" == "enforced" \
                || "$SECURITY_PREPARED_ROUTE_STATE" == "notRequired" ) ]] \
              && printf enforced || printf notEnforced)" \
          "PREMOUNT_TRANSPORT_MEASURED"
        return 0
      fi
    fi
    sleep 0.25
  done
  printf 'security_prepare=unknown reason=PREMOUNT_BRIDGE_UNOBSERVED\n'
  return 0
}

# If the backend fails after the early PF/route acquisition, release only this session's owned
# resources. A failed release is persisted rather than forgotten so normal reconcile/uninstall
# can retry it safely.
security_abort_prepared_mount() {
  local session="$1" failed="0" token route_owned
  [[ "$SECURITY_PREPARED_ACTIVE" == "1" && "$SECURITY_PREPARED_SESSION" == "$session" ]] \
    || return 0
  token="$SECURITY_PREPARED_PF_TOKEN"
  route_owned="$SECURITY_PREPARED_ROUTE_OWNED"

  if [[ -n "$token" ]]; then
    if security_release_pf "$SECURITY_PREPARED_ANCHOR" "$token"; then
      token=""
    else
      failed="1"
    fi
  fi
  if [[ "$route_owned" == "1" ]]; then
    if remove_vpn_bypass "$SECURITY_PREPARED_ENDPOINT" "$SECURITY_PREPARED_INTERFACE"; then
      route_owned="0"
    else
      failed="1"
    fi
  fi

  if [[ "$failed" == "0" ]]; then
    security_reset_prepared_mount
    printf 'security_prepare_cleanup=enforced reason=PREMOUNT_RESOURCES_RELEASED\n'
    return 0
  fi

  SECURITY_PREPARED_PF_TOKEN="$token"
  SECURITY_PREPARED_ROUTE_OWNED="$route_owned"
  security_write_state "$session" "$SECURITY_PREPARED_ENDPOINT" "$SECURITY_PREPARED_SUBNET" \
    "$SECURITY_PREPARED_INTERFACE" "$SECURITY_PREPARED_ANCHOR" "$token" "$route_owned" \
    "unknown" "PREMOUNT_ABORTED" "$SECURITY_PREPARED_ROUTE_STATE" \
    "PREMOUNT_CLEANUP_PENDING" "$SECURITY_PREPARED_PF_STATE" \
    "PREMOUNT_CLEANUP_PENDING" "notEnforced" "PREMOUNT_CLEANUP_PENDING" || true
  printf 'security_prepare_cleanup=notEnforced reason=PREMOUNT_CLEANUP_PENDING\n'
  return 1
}

security_mount_is_soft() {
  local source="$1" mount_point="$2" parameters
  parameters="$(security_nfsstat_output)"
  awk -v header="$mount_point from $source" '
    $0 == header { in_mount = 1; next }
    in_mount && $0 !~ /^[[:space:]]/ { exit }
    in_mount && /NFS parameters:/ {
      value = $0
      gsub(/[[:space:]]/, "", value)
      if (value ~ /(^|,)soft(,|$)/) soft = 1
    }
    END { exit soft ? 0 : 1 }
  ' <<< "$parameters"
}

security_write_state() {
  local session="$1" endpoint="$2" subnet="$3" interface="$4" anchor="$5" token="$6"
  local route_owned="$7" private_state="$8" private_reason="$9"
  shift 9
  local route_state="$1" route_reason="$2" pf_state="$3" pf_reason="$4" overall="$5" overall_reason="$6"
  local state_file state_tmp

  [[ ! -L "$SECURITY_STATE_DIR" ]] || return 1
  mkdir -p "$SECURITY_STATE_DIR" || return 1
  [[ -d "$SECURITY_STATE_DIR" && ! -L "$SECURITY_STATE_DIR" ]] || return 1
  chmod 700 "$SECURITY_STATE_DIR" 2>/dev/null || return 1
  state_file="$(security_state_path "$session")" || return 1
  state_tmp="$(mktemp "$SECURITY_STATE_DIR/.${session}.XXXXXX")" || return 1
  trap 'rm -f -- "$state_tmp"; trap - INT; kill -INT $$' INT
  trap 'rm -f -- "$state_tmp"; trap - TERM; kill -TERM $$' TERM
  chmod 600 "$state_tmp" 2>/dev/null || {
    rm -f "$state_tmp"
    trap - INT TERM
    return 1
  }
  {
    printf 'schema=1\n'
    printf 'session=%s\n' "$session"
    printf 'endpoint=%s\n' "$endpoint"
    printf 'subnet=%s\n' "$subnet"
    printf 'interface=%s\n' "$interface"
    printf 'anchor=%s\n' "$anchor"
    printf 'pf_token=%s\n' "$token"
    printf 'route_owned=%s\n' "$route_owned"
    printf 'private_link=%s\n' "$private_state"
    printf 'private_reason=%s\n' "$private_reason"
    printf 'vpn_route=%s\n' "$route_state"
    printf 'vpn_route_reason=%s\n' "$route_reason"
    printf 'pf_policy=%s\n' "$pf_state"
    printf 'pf_reason=%s\n' "$pf_reason"
    printf 'overall=%s\n' "$overall"
    printf 'overall_reason=%s\n' "$overall_reason"
  } > "$state_tmp"
  mv -f "$state_tmp" "$state_file"
  trap - INT TERM
}

security_print_state() {
  local private_state="$1" private_reason="$2" route_state="$3" route_reason="$4"
  local pf_state="$5" pf_reason="$6" overall="$7" overall_reason="$8"
  printf 'security_private_link=%s reason=%s\n' "$private_state" "$private_reason"
  printf 'security_vpn_route=%s reason=%s\n' "$route_state" "$route_reason"
  printf 'security_pf_policy=%s reason=%s\n' "$pf_state" "$pf_reason"
  printf 'security_overall=%s reason=%s\n' "$overall" "$overall_reason"
}

security_release_pf() {
  local anchor="$1" token="$2" session failed="0"
  [[ "$anchor" == "$SECURITY_ANCHOR_PREFIX"* ]] || return 1
  session="${anchor#"$SECURITY_ANCHOR_PREFIX"}"
  security_valid_session "$session" || return 1
  "$SECURITY_PFCTL_BIN" -a "$anchor" -F rules >/dev/null 2>&1 || failed="1"
  if [[ -n "$token" ]]; then
    if [[ "$token" =~ ^[[:xdigit:]]+$ ]]; then
      "$SECURITY_PFCTL_BIN" -X "$token" >/dev/null 2>&1 || failed="1"
    else
      # `pfctl -E` succeeded but its ownership token could not be parsed. Clear this anchor's
      # rules, but never claim the enable reference was released or discard retryable state.
      failed="1"
    fi
  fi
  [[ "$failed" == "0" ]]
}

security_apply_pf() {
  local session="$1" subnet="$2" interface="$3" anchor="$4"
  local rules_file root_rules enable_output loaded_rules
  SECURITY_PF_STATE="notEnforced"
  SECURITY_PF_REASON="PF_UNAVAILABLE"
  SECURITY_PF_TOKEN=""

  if [[ "${NTFSMAC_PRESERVE_PRIVATE_RELAY:-0}" == "1" ]]; then
    SECURITY_PF_STATE="notRequired"
    SECURITY_PF_REASON="PF_PRESERVED_PRIVATE_RELAY"
    return 0
  fi

  root_rules="$("$SECURITY_PFCTL_BIN" -sr 2>/dev/null)" || {
    SECURITY_PF_REASON="PF_ROOT_INSPECTION_FAILED"
    return 0
  }
  grep -F 'anchor "com.apple/*"' <<< "$root_rules" >/dev/null 2>&1 || {
    SECURITY_PF_REASON="PF_EVALUATED_PATH_MISSING"
    return 0
  }

  rules_file="$(mktemp "${TMPDIR:-/tmp}/ntfsmac-pf.XXXXXX")" || {
    SECURITY_PF_REASON="PF_RULE_RENDER_FAILED"
    return 0
  }
  trap 'rm -f -- "$rules_file"; trap - INT; kill -INT $$' INT
  trap 'rm -f -- "$rules_file"; trap - TERM; kill -TERM $$' TERM
  if ! render_pf_anchor "$subnet" "$interface" "$session" > "$rules_file"; then
    rm -f "$rules_file"
    trap - INT TERM
    SECURITY_PF_REASON="PF_RULE_RENDER_FAILED"
    return 0
  fi

  enable_output="$("$SECURITY_PFCTL_BIN" -E 2>&1)" || {
    rm -f "$rules_file"
    trap - INT TERM
    SECURITY_PF_REASON="PF_ENABLE_FAILED"
    return 0
  }
  SECURITY_PF_TOKEN="$(awk -F': *' '/[Tt]oken/ { print $2; exit }' <<< "$enable_output")"
  if [[ ! "$SECURITY_PF_TOKEN" =~ ^[[:xdigit:]]+$ ]]; then
    rm -f "$rules_file"
    trap - INT TERM
    SECURITY_PF_TOKEN="unavailable"
    SECURITY_PF_REASON="PF_ENABLE_TOKEN_MISSING_CLEANUP_PENDING"
    return 0
  fi

  if ! "$SECURITY_PFCTL_BIN" -a "$anchor" -f "$rules_file" >/dev/null 2>&1; then
    rm -f "$rules_file"
    trap - INT TERM
    if security_release_pf "$anchor" "$SECURITY_PF_TOKEN"; then
      SECURITY_PF_TOKEN=""
      SECURITY_PF_REASON="PF_LOAD_FAILED"
    else
      SECURITY_PF_REASON="PF_LOAD_FAILED_CLEANUP_PENDING"
    fi
    return 0
  fi
  rm -f "$rules_file"
  trap - INT TERM

  loaded_rules="$("$SECURITY_PFCTL_BIN" -a "$anchor" -sr 2>/dev/null)" || true
  if ! grep -Eq "label[[:space:]]+\\\"?ntfsmac-${session}-nfs\\\"?([[:space:]]|$)" <<< "$loaded_rules" \
    || ! grep -Eq "label[[:space:]]+\\\"?ntfsmac-${session}-egress-block\\\"?([[:space:]]|$)" <<< "$loaded_rules" \
    || ! grep -Eq "label[[:space:]]+\\\"?ntfsmac-${session}-ingress-block\\\"?([[:space:]]|$)" <<< "$loaded_rules"; then
    if security_release_pf "$anchor" "$SECURITY_PF_TOKEN"; then
      SECURITY_PF_TOKEN=""
      SECURITY_PF_REASON="PF_MEASUREMENT_FAILED"
    else
      SECURITY_PF_REASON="PF_MEASUREMENT_FAILED_CLEANUP_PENDING"
    fi
    return 0
  fi

  SECURITY_PF_STATE="enforced"
  SECURITY_PF_REASON="PF_EVALUATED"
}

security_apply_for_mount() {
  local session="$1" mount_point source host endpoint interface subnet anchor
  local private_state="unknown" private_reason="PRIVATE_LINK_UNRESOLVED"
  local route_state="unknown" route_reason="ROUTE_UNMEASURED" route_owned="0"
  local pf_state="unknown" pf_reason="PF_UNMEASURED" token=""
  local overall="unknown" overall_reason="SECURITY_UNMEASURED" prepared_match="0"
  local prepared_cleanup_failed="0"

  security_valid_session "$session" || return 1
  # macOS's root `anchor "com.apple/*"` evaluates direct children only. Keep every session
  # directly below `com.apple`; an extra `ntfsmac/` level would load rules that never run.
  anchor="$SECURITY_ANCHOR_PREFIX$session"
  mount_point="$(security_mount_point_for_session "$session")" || mount_point=""
  source="$(security_source_for_mount_point "$mount_point")" || source=""
  host="${source%%:*}"
  endpoint="$(security_resolve_host "$host")" || endpoint=""
  subnet="$(security_subnet_for_ip "$endpoint")" || subnet=""
  interface="$(security_bridge_interface "$subnet")" || interface=""

  if [[ -n "$mount_point" && -n "$source" && -n "$endpoint" && -n "$interface" && -n "$subnet" ]]; then
    if security_mount_is_soft "$source" "$mount_point"; then
      private_state="enforced"
      private_reason="PRIVATE_VMNET_SOFT"

      if [[ "$SECURITY_PREPARED_ACTIVE" == "1" ]]; then
        if [[ "$SECURITY_PREPARED_SESSION" == "$session" \
          && "$SECURITY_PREPARED_ENDPOINT" == "$endpoint" \
          && "$SECURITY_PREPARED_SUBNET" == "$subnet" \
          && "$SECURITY_PREPARED_INTERFACE" == "$interface" \
          && "$SECURITY_PREPARED_ANCHOR" == "$anchor" ]]; then
          prepared_match="1"
          route_state="$SECURITY_PREPARED_ROUTE_STATE"
          route_reason="$SECURITY_PREPARED_ROUTE_REASON"
          route_owned="$SECURITY_PREPARED_ROUTE_OWNED"
          pf_state="$SECURITY_PREPARED_PF_STATE"
          pf_reason="$SECURITY_PREPARED_PF_REASON"
          token="$SECURITY_PREPARED_PF_TOKEN"
        else
          security_abort_prepared_mount "$SECURITY_PREPARED_SESSION" >/dev/null \
            || prepared_cleanup_failed="1"
        fi
      fi

      if [[ "$prepared_match" == "0" && "$prepared_cleanup_failed" == "0" ]]; then
        apply_vpn_bypass "$endpoint" "$interface" || true
        route_state="$VPN_ROUTE_STATE"
        route_reason="$VPN_ROUTE_REASON"
        route_owned="$VPN_ROUTE_OWNED"

        security_apply_pf "$session" "$subnet" "$interface" "$anchor"
        pf_state="$SECURITY_PF_STATE"
        pf_reason="$SECURITY_PF_REASON"
        token="$SECURITY_PF_TOKEN"
      elif [[ "$prepared_cleanup_failed" == "1" ]]; then
        route_state="$SECURITY_PREPARED_ROUTE_STATE"
        route_reason="PREMOUNT_CLEANUP_PENDING"
        route_owned="$SECURITY_PREPARED_ROUTE_OWNED"
        pf_state="$SECURITY_PREPARED_PF_STATE"
        pf_reason="PREMOUNT_CLEANUP_PENDING"
        token="$SECURITY_PREPARED_PF_TOKEN"
      fi
    else
      private_state="notEnforced"
      private_reason="NFS_SOFT_UNPROVEN"
      route_state="unknown"
      route_reason="ROUTE_SKIPPED_UNSAFE_MOUNT"
      pf_state="notEnforced"
      pf_reason="PF_SKIPPED_UNSAFE_MOUNT"
    fi
  fi

  if [[ "$private_state" == "enforced" && "$pf_state" == "enforced" \
    && ( "$route_state" == "enforced" || "$route_state" == "notRequired" ) ]]; then
    overall="enforced"
    overall_reason="SECURITY_ENFORCED"
  elif [[ "$private_state" == "unknown" ]]; then
    overall="unknown"
    overall_reason="PRIVATE_LINK_UNRESOLVED"
  else
    overall="notEnforced"
    overall_reason="SECURITY_INCOMPLETE"
  fi

  security_write_state "$session" "$endpoint" "$subnet" "$interface" "$anchor" "$token" \
    "$route_owned" "$private_state" "$private_reason" "$route_state" "$route_reason" \
    "$pf_state" "$pf_reason" "$overall" "$overall_reason" || {
      [[ -n "$token" ]] && security_release_pf "$anchor" "$token"
      [[ "$route_owned" == "1" && -n "$endpoint" ]] && remove_vpn_bypass "$endpoint" "$interface" || true
      security_print_state "$private_state" "$private_reason" "$route_state" "$route_reason" \
        "notEnforced" "STATE_WRITE_FAILED" "notEnforced" "STATE_WRITE_FAILED"
      return 0
    }
  security_print_state "$private_state" "$private_reason" "$route_state" "$route_reason" \
    "$pf_state" "$pf_reason" "$overall" "$overall_reason"
  security_reset_prepared_mount
  return 0
}

security_teardown_session() {
  local session="$1" state_file anchor token endpoint interface route_owned failed="0"
  security_valid_session "$session" || return 1
  state_file="$(security_state_path "$session")" || return 1
  if [[ -L "$state_file" || ( -e "$state_file" && ! -f "$state_file" ) ]]; then
    printf 'security_teardown=notEnforced reason=STATE_ENTRY_UNSAFE\n'
    return 1
  fi
  [[ -f "$state_file" ]] || {
    printf 'security_teardown=notRequired reason=NO_SESSION_STATE\n'
    return 0
  }
  anchor="$(security_state_value "$state_file" anchor 2>/dev/null || true)"
  token="$(security_state_value "$state_file" pf_token 2>/dev/null || true)"
  endpoint="$(security_state_value "$state_file" endpoint 2>/dev/null || true)"
  interface="$(security_state_value "$state_file" interface 2>/dev/null || true)"
  route_owned="$(security_state_value "$state_file" route_owned 2>/dev/null || true)"

  if [[ "$anchor" != "$SECURITY_ANCHOR_PREFIX$session" ]]; then
    failed="1"
  elif [[ -n "$token" ]]; then
    security_release_pf "$anchor" "$token" || failed="1"
  fi
  if [[ "$route_owned" == "1" ]] && route_guard_valid_endpoint "$endpoint"; then
    remove_vpn_bypass "$endpoint" "$interface" || failed="1"
  elif [[ "$route_owned" != "0" ]]; then
    failed="1"
  fi
  if [[ "$failed" != "0" ]]; then
    printf 'security_teardown=notEnforced reason=TEARDOWN_INCOMPLETE\n'
    return 1
  fi
  rm -f "$state_file" || {
    printf 'security_teardown=notEnforced reason=STATE_REMOVE_FAILED\n'
    return 1
  }
  printf 'security_teardown=enforced reason=SESSION_REMOVED\n'
}

security_reconcile() {
  local status_output state_file session has_state="0" failed="0"
  if [[ -L "$SECURITY_STATE_DIR" ]]; then
    printf 'security_reconcile=unknown reason=STATE_DIR_UNSAFE\n'
    return 0
  fi
  [[ -d "$SECURITY_STATE_DIR" ]] || return 0
  for state_file in "$SECURITY_STATE_DIR"/*.state; do
    [[ -e "$state_file" || -L "$state_file" ]] || continue
    if [[ -L "$state_file" || ! -f "$state_file" ]]; then
      printf 'security_reconcile=unknown reason=STATE_ENTRY_UNSAFE\n'
      return 0
    fi
    has_state="1"
    break
  done
  if [[ "$has_state" == "0" ]]; then
    printf 'security_reconcile=notRequired reason=NO_SESSION_STATE\n'
    return 0
  fi
  status_output="$(security_status_output)" || {
    printf 'security_reconcile=unknown reason=STATUS_UNAVAILABLE\n'
    return 0
  }
  for state_file in "$SECURITY_STATE_DIR"/*.state; do
    [[ -e "$state_file" || -L "$state_file" ]] || continue
    if [[ -L "$state_file" || ! -f "$state_file" ]]; then
      failed="1"
      continue
    fi
    session="$(basename "$state_file" .state)"
    if ! security_valid_session "$session"; then
      failed="1"
      continue
    fi
    if ! grep -F "/dev/$session on " <<< "$status_output" >/dev/null 2>&1; then
      security_teardown_session "$session" >/dev/null || failed="1"
    fi
  done
  if [[ "$failed" != "0" ]]; then
    printf 'security_reconcile=notEnforced reason=STALE_TEARDOWN_INCOMPLETE\n'
    return 1
  fi
  printf 'security_reconcile=enforced reason=STALE_SESSIONS_REMOVED\n'
}

security_teardown_all() {
  local state_file session failed="0"
  if [[ -L "$SECURITY_STATE_DIR" ]]; then
    printf 'security_teardown=notEnforced reason=STATE_DIR_UNSAFE\n'
    return 1
  fi
  [[ -d "$SECURITY_STATE_DIR" ]] || {
    printf 'security_teardown=notRequired reason=NO_SESSION_STATE\n'
    return 0
  }
  for state_file in "$SECURITY_STATE_DIR"/*.state; do
    [[ -e "$state_file" || -L "$state_file" ]] || continue
    if [[ -L "$state_file" || ! -f "$state_file" ]]; then
      failed="1"
      continue
    fi
    session="$(basename "$state_file" .state)"
    if security_valid_session "$session"; then
      security_teardown_session "$session" >/dev/null || failed="1"
    else
      failed="1"
    fi
  done
  if [[ "$failed" != "0" ]]; then
    printf 'security_teardown=notEnforced reason=ALL_TEARDOWN_INCOMPLETE\n'
    return 1
  fi
  printf 'security_teardown=enforced reason=ALL_SESSIONS_REMOVED\n'
}
