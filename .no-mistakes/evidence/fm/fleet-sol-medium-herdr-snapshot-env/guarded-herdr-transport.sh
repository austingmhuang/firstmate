#!/usr/bin/env bash
set -eu
args=("$@")
n=${#args[@]}
[ "$n" -ge 3 ] && [ "${args[n-2]}" = --session ] && [ "${args[n-1]}" = "$LAB_SESSION" ] || { echo 'refused non-lab routing' >&2; exit 90; }
set -- "${args[@]:0:n-2}"
export PATH="$LAB_ORIGINAL_PATH"
if [ "$1" = server ]; then
  [ "$#" -eq 1 ] || exit 91
  printf 'provision %s\n' "$LAB_SESSION" >> "$LAB_CALLS"
  exec "$LAB_HELPER" provision "$LAB_SESSION"
fi
exec "$LAB_HELPER" run "$LAB_SESSION" "$@"
