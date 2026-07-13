#!/bin/bash
# cli/lib/validate-device.sh — 2-device-validation (PLAN.md §6, L6).
# One function, sourced by every shell-out path that touches a device string. No caller
# gets to write its own regex.
set -u

# validate_device <device> — accepts only "diskNsM" (e.g. disk2s1). Rejects everything
# else, including a leading "/dev/" and shell-metacharacter payloads, with a stderr
# message and non-zero exit.
validate_device() {
  local device="${1:-}"
  if [[ ! "$device" =~ ^disk[0-9]+s[0-9]+$ ]]; then
    echo "validate-device: rejected device string: '$device' (must match ^disk[0-9]+s[0-9]+\$)" >&2
    return 1
  fi
  return 0
}
