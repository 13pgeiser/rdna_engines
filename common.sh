#!/bin/bash
# common.sh -- shared model-selection menu for run_*.sh launchers.
#
# Each launcher defines its own CHOICES array ("label|value" pairs) and calls
# select_model to resolve which one. The selection mechanism is identical across
# engines; only the choices (and how a value maps to files/serve command) differ
# per engine, so each script keeps its own list here:
#
#   # in run_<engine>.sh:
#     CHOICES=( "label|value" ... )
#     MODEL_DEFAULT_INDEX=1
#     . "$(dirname "$0")/common.sh"
#     MENU_TITLE="..."            # optional, per-engine header
#     select_model "$MODEL_DEFAULT_INDEX" "${1:-}" "${OFLM_MODEL:-}"
#     # -> MODEL_TAG (the value after the |) is set
#
# Priority for the chosen model: override tag > numeric first arg > interactive
# prompt (when attached to a terminal) > default index.

# select_model <default_index> <arg1> <override_tag>
# Resolves the model and sets global MODEL_TAG to the value (after the |) of the
# CHOICES entry it selects. An empty override means "no explicit tag given".
select_model() {
  local default_index="$1"
  local arg="${2:-}"
  local override="${3:-}"
  local n="${#CHOICES[@]}"

  # An explicit override tag (e.g. OFLM_MODEL=... on the command line) wins outright.
  if [ -n "$override" ]; then
    MODEL_TAG="$override"
    echo "Selected model: $MODEL_TAG"
    return 0
  fi

  local choice
  # Prefer a valid numeric first argument; otherwise prompt (if interactive).
  if [[ "$arg" =~ ^[0-9]+$ ]] && [ "$arg" -ge 1 ] && [ "$arg" -le "$n" ]; then
    choice="$arg"
  elif [ -t 0 ]; then
    echo "${MENU_TITLE:-Model selection}"
    for idx in "${!CHOICES[@]}"; do
      printf "  %d) %s\n" "$((idx+1))" "${CHOICES[idx]%|*}"
    done
    read -rp "Choose a model [1-$n] (default $default_index): " choice
    choice="${choice:-$default_index}"
  else
    choice="$default_index"
  fi

  # Reject anything still invalid; fall back to the default index.
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$n" ]; then
    echo "Invalid choice '$choice'; using default" >&2
    choice="$default_index"
  fi

  MODEL_TAG="${CHOICES[$((choice-1))]#*|}"
  echo "Selected model: $MODEL_TAG"
}