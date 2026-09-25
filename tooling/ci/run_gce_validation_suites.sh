#!/usr/bin/env bash

# Run only independent validation suites concurrently. Flutter packaging stays
# in its own later step so runner secrets are not exposed to test processes and
# multiple Flutter commands never race over the same SDK/build state.

set -uo pipefail

: "${VALIDATION_MODE:?VALIDATION_MODE is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

suite_dir="$RUNNER_TEMP/gce-validation-suites"
mkdir -p "$suite_dir"

declare -a selected=()
declare -A pids=()
declare -A statuses=(
  [dart]='skipped'
  [app_rust]='skipped'
  [rustpush]='skipped'
  [protector]='skipped'
)

classify_suite_receipt() {
  local receipt_path="$1"
  local receipt=""
  receipt="$(cat "$receipt_path" 2>/dev/null)" || receipt="UNREADABLE"
  if [[ "$receipt" == '0' ]]; then
    printf 'success'
  else
    printf 'failure'
  fi
}
run_dart_suite() {
  flutter test &&
    pwsh -NoProfile -File tooling/windows/test_cloudkit_semantic_outbox_contract.ps1
}

run_app_rust_suite() {
  cargo test --manifest-path rust/Cargo.toml --lib
}

run_rustpush_suite() {
  cargo test --manifest-path rustpush/Cargo.toml --lib \
    --features remote-anisette-v3 -- --test-threads=1
}

run_protector_suite() {
  cargo test --locked --manifest-path rust/cloud_sync_protector_harness/Cargo.toml
}

start_suite() {
  local name="$1"
  local command="$2"
  selected+=("$name")
  (
    started="$(date +%s)"
    "$command"
    result=$?
    finished="$(date +%s)"
    printf '%s\n' "$((finished - started))" > "$suite_dir/$name.seconds"
    printf '%s\n' "$result" > "$suite_dir/$name.rc.tmp"
    mv -f "$suite_dir/$name.rc.tmp" "$suite_dir/$name.rc"
    exit "$result"
  ) > "$suite_dir/$name.log" 2>&1 &
  pids["$name"]=$!
}

case "$VALIDATION_MODE" in
  full)
    start_suite dart run_dart_suite
    start_suite app_rust run_app_rust_suite
    start_suite rustpush run_rustpush_suite
    start_suite protector run_protector_suite
    ;;
  app-rust-only)
    start_suite app_rust run_app_rust_suite
    ;;
  cloudkit-qualification)
    start_suite dart run_dart_suite
    start_suite app_rust run_app_rust_suite
    ;;
  dart-only)
    start_suite dart run_dart_suite
    ;;
  *)
    echo "Parallel suite runner does not support validation mode: $VALIDATION_MODE" >&2
    exit 1
    ;;
esac

for name in "${selected[@]}"; do
  echo "Suite started: $name (log: $suite_dir/$name.log)"
done
progress_ticker() {
  while true; do
    sleep 300
    for tick_name in "${selected[@]}"; do
      if [[ ! -f "$suite_dir/$tick_name.status" ]]; then
        tick_elapsed=$(( $(date +%s) - tick_start ))
        echo "Suite progress: $tick_name still running after ${tick_elapsed}s; last log lines:"
        tail -n 3 "$suite_dir/$tick_name.log" 2>/dev/null || true
      fi
    done
  done
}
tick_start="$(date +%s)"
progress_ticker &
ticker_pid=$!
failed=0
declare -A recorded=()
remaining=${#selected[@]}
while (( remaining > 0 )); do
  sleep 5
  for name in "${selected[@]}"; do
    if [[ -n "${recorded[$name]:-}" ]]; then
      continue
    fi
    outcome_note=""
    if [[ -f "$suite_dir/$name.rc" ]]; then
      recorded[$name]=1
      if [[ "$(classify_suite_receipt "$suite_dir/$name.rc")" == 'success' ]]; then
        statuses["$name"]='success'
      else
        statuses["$name"]='failure'
        failed=1
      fi
    else
      proc_state=""
      if [[ -d /proc && -d "/proc/${pids[$name]}" ]]; then
        proc_state="$(awk '{print $3}' "/proc/${pids[$name]}/stat" 2>/dev/null)"
      elif [[ -d /proc ]]; then
        proc_state="gone"
      fi
      if [[ "$proc_state" == gone || "$proc_state" == Z ]]; then
        if [[ -f "$suite_dir/$name.rc" ]]; then
          continue
        fi
        recorded[$name]=1
        statuses["$name"]='failure'
        failed=1
        outcome_note=" (exited without receipt)"
      else
        continue
      fi
    fi
    printf '%s\n' "${statuses[$name]}" > "$suite_dir/$name.status"
    echo "Suite finished: $name outcome=${statuses[$name]}$outcome_note"
    echo "::group::${name} validation suite"
    cat "$suite_dir/$name.log"
    echo '::endgroup::'
    remaining=$((remaining - 1))
  done
done
kill "$ticker_pid" 2>/dev/null || true

for name in dart app_rust rustpush protector; do
  printf '%s=%s\n' "$name" "${statuses[$name]}" >> "$GITHUB_OUTPUT"
done

{
  echo '### Parallel validation suites'
  echo
  echo '| Suite | Outcome | Seconds |'
  echo '|---|---:|---:|'
  for name in dart app_rust rustpush protector; do
    seconds='-'
    if [[ -f "$suite_dir/$name.seconds" ]]; then
      seconds="$(<"$suite_dir/$name.seconds")"
    fi
    printf '| `%s` | `%s` | `%s` |\n' "$name" "${statuses[$name]}" "$seconds"
  done
} >> "$GITHUB_STEP_SUMMARY"

exit "$failed"
