#!/bin/bash
# cli/lib/interactive-select.sh — shared numbered-menu prompt for mount/unmount when called
# with no argument. Prompts on stderr so stdout stays clean for scripting, reads one line from
# stdin, and prints the chosen 1-based index on stdout (nothing else) — or returns 1 on an
# empty line, "q"/"cancel", or an out-of-range/non-numeric reply.
set -u

# prompt_choice <count> [prompt] — <count> must be >= 1.
prompt_choice() {
  local count="$1" prompt="${2:-Enter a number, or press Enter/q to cancel: }"
  local reply
  read -r -p "$prompt" reply
  # ${var,,} (bash 4+ case conversion) isn't available on macOS's shipped bash 3.2
  # (GPLv2-only cutoff) — tr is the 3.2-compatible lowercase.
  reply="$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')"
  reply="${reply## }"
  reply="${reply%% }"
  if [[ -z "$reply" || "$reply" == "q" || "$reply" == "cancel" ]]; then
    echo "cancelled" >&2
    return 1
  fi
  if [[ ! "$reply" =~ ^[0-9]+$ ]] || (( reply < 1 || reply > count )); then
    echo "invalid selection: '$reply'" >&2
    return 1
  fi
  echo "$reply"
}
