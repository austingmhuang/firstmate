#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
MODE=${1:?fixed or baseline}
DIR="$ROOT/.snapshot-validation/$MODE"
EVIDENCE=/Users/yuti/.no-mistakes/evidence/01M57W3W1FE1KTZJZ781D841A2
mkdir -p "$DIR/home/state" "$DIR/snapshot" "$DIR/work"
export LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh" LAB_ORIGINAL_PATH="$PATH"
export FM_HERDR_LAB_STATE_DIR="$ROOT/.snapshot-validation/lab-state"
export LAB_SESSION=$("$LAB_HELPER" name "snapshot-$MODE")
export LAB_CALLS="$DIR/launches"
: > "$LAB_CALLS"
rm -f "$DIR/pane-env" "$DIR/crew-state"
lab() { PATH="$LAB_ORIGINAL_PATH" "$LAB_HELPER" run "$LAB_SESSION" "$@"; }
cleanup() {
  rc=$?
  trap - EXIT
  if [ -f "$FM_HERDR_LAB_STATE_DIR/$LAB_SESSION.fleet-state.json" ]; then
    PATH="$LAB_ORIGINAL_PATH" "$LAB_HELPER" teardown "$LAB_SESSION" || exit 95
    printf 'TEARDOWN: lab removed; default-session tripwire unchanged\n'
  fi
  exit "$rc"
}
trap cleanup EXIT
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
unset FM_GATE_REFUSE_BYPASS
export FM_CREW_STATE_META_OVERRIDE="$DIR/snapshot/task.meta"
export FM_CREW_STATE_STATUS_OVERRIDE="$DIR/snapshot/task.status"
printf 'kind=secondmate\nworktree=%s\n' "$DIR/work" > "$FM_CREW_STATE_META_OVERRIDE"
printf 'paused: captured generation\n' > "$FM_CREW_STATE_STATUS_OVERRIDE"
export FM_HERDR_SENTINEL=kept
export PATH="$ROOT/.snapshot-validation:$PATH"
if [ "$MODE" = baseline ]; then
  . "$ROOT/.snapshot-validation/baseline/bin/backends/herdr.sh"
else
  . "$ROOT/bin/backends/herdr.sh"
fi
printf 'MODE=%s SESSION=%s\n' "$MODE" "$LAB_SESSION"
# The real launch adapter invokes a transport-only wrapper: server -> guarded
# provision (which owns prepare); every other command -> guarded run. No fake
# Herdr responses or environment scrubbing are supplied by the wrapper.
fm_backend_herdr_server_ensure "$LAB_SESSION"
lab status --json | tee "$DIR/status-before.json"
printf 'CALLER meta=%s status=%s\n' "$FM_CREW_STATE_META_OVERRIDE" "$FM_CREW_STATE_STATUS_OVERRIDE"
[ "$FM_CREW_STATE_META_OVERRIDE" = "$DIR/snapshot/task.meta" ]
[ "$FM_CREW_STATE_STATUS_OVERRIDE" = "$DIR/snapshot/task.status" ]
# Captured task generation disappears while the real Herdr server stays up.
rm "$FM_CREW_STATE_META_OVERRIDE" "$FM_CREW_STATE_STATUS_OVERRIDE"
printf 'Removed snapshot files before creating a later pane\n'
created=$(lab workspace create --cwd "$ROOT" --label "snapshot-$MODE" --no-focus)
printf '%s\n' "$created"
printf '%s\n' "$created" > "$DIR/workspace.json"
pane=$(printf '%s' "$created" | jq -er '.result.root_pane.pane_id')
printf 'kind=secondmate\nworktree=%s\nbackend=herdr\nwindow=%s:%s\nherdr_session=%s\nherdr_pane_id=%s\n' "$DIR/work" "$LAB_SESSION" "$pane" "$LAB_SESSION" "$pane" > "$DIR/home/state/task.meta"
printf 'paused: durable task status survives snapshot cleanup\n' > "$DIR/home/state/task.status"
# This script executes inside the real pane; it does not alter the two overrides.
printf '#!/usr/bin/env bash\nset -eu\nprintf "meta=%%s\\nstatus=%%s\\nsentinel=%%s\\nsession=%%s\\n" "${FM_CREW_STATE_META_OVERRIDE-<unset>}" "${FM_CREW_STATE_STATUS_OVERRIDE-<unset>}" "$FM_HERDR_SENTINEL" "$HERDR_SESSION" > %q\nFM_HOME=%q bash %q task > %q\nprintf "pane check completed\\n"\n' "$DIR/pane-env" "$DIR/home" "$ROOT/bin/fm-crew-state.sh" "$DIR/crew-state" > "$DIR/pane-check.sh"
lab pane run "$pane" "bash '$DIR/pane-check.sh'"
for i in $(seq 1 100); do [ ! -s "$DIR/crew-state" ] || break; sleep 0.2; done
printf '\nLATER PANE ENVIRONMENT:\n'; cat "$DIR/pane-env"
printf '\nFIRSTMATE CREW STATE AFTER SNAPSHOT CLEANUP:\n'; cat "$DIR/crew-state"
if [ "$MODE" = fixed ]; then
  grep -Fx 'meta=<unset>' "$DIR/pane-env"
  grep -Fx 'status=<unset>' "$DIR/pane-env"
  grep -F 'state: paused' "$DIR/crew-state"
  grep -F 'durable task status survives snapshot cleanup' "$DIR/crew-state"
else
  grep -Fx "meta=$DIR/snapshot/task.meta" "$DIR/pane-env"
  grep -Fx "status=$DIR/snapshot/task.status" "$DIR/pane-env"
  grep -F 'no metadata for task' "$DIR/crew-state"
fi
# Re-ensure under different caller env: no restart and no startup-env rewrite.
export FM_HERDR_SENTINEL=changed
# Always use the fixed implementation for reuse, including when the old
# implementation launched an already-polluted server.
. "$ROOT/bin/backends/herdr.sh"
fm_backend_herdr_server_ensure "$LAB_SESSION"
lab status --json | tee "$DIR/status-after.json"
[ "$(wc -l < "$LAB_CALLS" | tr -d ' ')" = 1 ]
printf 'REUSE: only one server provision; changed caller sentinel did not relaunch it\n'
lab pane run "$pane" "bash '$DIR/pane-check.sh'"
sleep 1
grep -Fx 'sentinel=kept' "$DIR/pane-env"
grep -Fx "session=$LAB_SESSION" "$DIR/pane-env"
if [ "$MODE" = baseline ]; then
  grep -Fx "meta=$DIR/snapshot/task.meta" "$DIR/pane-env"
  grep -Fx "status=$DIR/snapshot/task.status" "$DIR/pane-env"
  printf 'FIXED ADAPTER REUSE: pre-existing polluted lab server preserved, not restarted or repaired\n'
fi
lab pane read "$pane" --lines 200
printf 'ALL %s assertions satisfied\n' "$MODE"
