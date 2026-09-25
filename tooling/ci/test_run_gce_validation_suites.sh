#!/usr/bin/env bash
# Offline synthetic harness for run_gce_validation_suites.sh.
# Uses stub flutter/cargo/pwsh binaries. No credentials, no builds, no network.
# Set SCRIPT_UNDER_TEST to validate a copy; defaults to the sibling script.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${SCRIPT_UNDER_TEST:-$here/run_gce_validation_suites.sh}"
failures=0
note() { echo "harness: $*"; }
fail() { echo "harness FAIL: $*"; failures=$((failures + 1)); }
HARNESS_ROOT="$(mktemp -d)"
CASE_N=0
in_tree() {
  local target="$1" root="$2" p
  p="$target"
  while [[ -n "$p" && "$p" != 0 && "$p" != 1 ]]; do
    if [[ "$p" == "$root" ]]; then return 0; fi
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  done
  return 1
}
wait_proc_end() {
  local pid="$1" tries="$2" i st
  for i in $(seq 1 "$tries"); do
    st="$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)" || return 0
    if [[ "$st" == Z ]]; then return 0; fi
    sleep 2
  done
  return 1
}
pst_start() {
  local s
  s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  s="${s##*)}"
  set -- $s
  printf '%s' "${20}"
}
same_proc() {
  local pid="$1" start="$2" cur
  if [[ -z "$pid" || -z "$start" ]]; then return 1; fi
  cur="$(pst_start "$pid")" || return 1
  [[ -n "$cur" && "$cur" == "$start" ]]
}
verified_kill_file="$HARNESS_ROOT/verified_killable"
: > "$verified_kill_file"
record_verified() {
  printf '%s %s\n' "$1" "$2" >> "$verified_kill_file"
}
cleanup_case_pids() {
  local pid start
  [ -f "$verified_kill_file" ] || return 0
  while read -r pid start; do
    if same_proc "$pid" "$start"; then kill -KILL "$pid" 2>/dev/null || true; fi
  done < "$verified_kill_file"
}
trap cleanup_case_pids EXIT
make_stubs() {
  stub_dir="$1"
  mkdir -p "$stub_dir"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "stub flutter $*";' 'if [[ "${STUB_FLUTTER_EXIT:-0}" != "0" ]]; then exit "$STUB_FLUTTER_EXIT"; fi' 'if [[ -n "${STUB_FLUTTER_SLEEP:-}" ]]; then sleep "$STUB_FLUTTER_SLEEP" & stub_sleep=$!; if [[ -n "${CASE_DIR:-}" ]]; then printf "%s %s\n" "$PPID" "$stub_sleep" > "$CASE_DIR/suite.pids"; fi; wait "$stub_sleep"; fi' 'exit 0' > "$stub_dir/flutter"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "stub cargo $*";' 'if [[ "${STUB_CARGO_EXIT:-0}" != "0" ]]; then exit "$STUB_CARGO_EXIT"; fi' 'exit 0' > "$stub_dir/cargo"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "stub pwsh $*";' 'exit 0' > "$stub_dir/pwsh"
  chmod +x "$stub_dir/flutter" "$stub_dir/cargo" "$stub_dir/pwsh"
}
fresh_env() {
  CASE_N=$((CASE_N + 1))
  case_root="$HARNESS_ROOT/case$CASE_N"
  mkdir -p "$case_root"
  export CASE_DIR="$case_root"
  export RUNNER_TEMP="$case_root/temp"
  mkdir -p "$RUNNER_TEMP"
  export GITHUB_OUTPUT="$case_root/output"
  export GITHUB_STEP_SUMMARY="$case_root/summary"
  touch "$GITHUB_OUTPUT" "$GITHUB_STEP_SUMMARY"
  export VALIDATION_MODE=cloudkit-qualification
}
note "case 1: all suites succeed"
fresh_env
stubs="$case_root/stubs"
make_stubs "$stubs"
PATH="$stubs:$PATH" STUB_FLUTTER_EXIT=0 STUB_CARGO_EXIT=0 bash "$script" > "$case_root/stdout.log" 2>&1
code=$?
[ "$code" = 0 ] || fail "success case exit=$code"
[ "$(cat "$RUNNER_TEMP/gce-validation-suites/dart.status")" = success ] || fail "dart status not success"
[ "$(cat "$RUNNER_TEMP/gce-validation-suites/app_rust.status")" = success ] || fail "app_rust status not success"
grep -q "^dart=success$" "$GITHUB_OUTPUT" || fail "GITHUB_OUTPUT missing dart=success"
grep -q "Suite finished: dart outcome=success" "$case_root/stdout.log" || fail "missing dart finish notice"
note "case 2: dart suite fails, app_rust still recorded"
fresh_env
stubs="$case_root/stubs"
make_stubs "$stubs"
PATH="$stubs:$PATH" STUB_FLUTTER_EXIT=1 STUB_CARGO_EXIT=0 bash "$script" > "$case_root/stdout.log" 2>&1
code=$?
[ "$code" != 0 ] || fail "failure case exited 0"
[ "$(cat "$RUNNER_TEMP/gce-validation-suites/dart.status")" = failure ] || fail "dart status not failure"
[ "$(cat "$RUNNER_TEMP/gce-validation-suites/app_rust.status")" = success ] || fail "app_rust status not success after dart failure"
note "case 3: killed mid-run keeps completed suite evidence"
fresh_env
stubs="$case_root/stubs"
make_stubs "$stubs"
PATH="$stubs:$PATH" STUB_FLUTTER_SLEEP=60 STUB_FLUTTER_EXIT=0 STUB_CARGO_EXIT=0 timeout -s KILL 8 bash "$script" > "$case_root/stdout.log" 2>&1
code=$?
[ "$code" = 124 ] || [ "$code" = 137 ] || fail "interruption exit=$code, want timeout kill"
[ "$(cat "$RUNNER_TEMP/gce-validation-suites/app_rust.status")" = success ] || fail "completed app_rust evidence missing after kill"
 [ ! -f "$RUNNER_TEMP/gce-validation-suites/dart.status" ] || fail "pending dart must not have a final status"
note "case 4: instantly finished suites are collected under a short timeout"
fresh_env
stubs="$case_root/stubs"
make_stubs "$stubs"
PATH="$stubs:$PATH" STUB_FLUTTER_EXIT=0 STUB_CARGO_EXIT=0 timeout -s KILL 25 bash "$script" > "$case_root/stdout.log" 2>&1
code=$?
 [ "$code" = 0 ] || fail "fast suites under short timeout exit=$code"
 [ "$(cat "$RUNNER_TEMP/gce-validation-suites/dart.status")" = success ] || fail "fast dart status not success"
 [ "$(cat "$RUNNER_TEMP/gce-validation-suites/app_rust.status")" = success ] || fail "fast app_rust status not success"
note "case 5: suite killed without receipt is failure, never skip"
fresh_env
stubs="$case_root/stubs"
make_stubs "$stubs"
PATH="$stubs:$PATH" STUB_FLUTTER_SLEEP=60 STUB_FLUTTER_EXIT=0 STUB_CARGO_EXIT=0 bash "$script" > "$case_root/stdout.log" 2>&1 &
script_pid=$!
sleep 3
proceed=yes
pidfile="$case_root/suite.pids"
 [ -f "$pidfile" ] || { fail "stub did not record suite pids"; proceed=no; }
if [ "$proceed" = yes ]; then read -r sub_pid sleep_pid < "$pidfile"; [ -n "${sub_pid:-}" ] || { fail "empty suite pid record"; proceed=no; }; fi
if [ "$proceed" = yes ]; then in_tree "$sub_pid" "$script_pid" || { fail "recorded suite pid outside harness tree"; proceed=no; }; fi
if [ "$proceed" = yes ]; then sub_start="$(pst_start "$sub_pid")"; sleep_start="$(pst_start "${sleep_pid:-0}")"; [ -n "$sub_start" ] || { fail "suite pid already gone before validation"; proceed=no; }; fi
if [ "$proceed" = yes ]; then record_verified "$sub_pid" "$sub_start"; record_verified "$sleep_pid" "$sleep_start"; same_proc "$sub_pid" "$sub_start" || { fail "suite pid changed before signal"; proceed=no; }; fi
if [ "$proceed" = yes ]; then
  kill -KILL "$sub_pid"
  if wait_proc_end "$script_pid" 30; then waited=yes; else waited=no; fi
  [ "$waited" = yes ] || { fail "script did not end after suite kill"; kill -KILL "$script_pid" 2>/dev/null || true; }
  wait "$script_pid"
  code=$?
  [ "$code" != 0 ] || fail "no-receipt run exited 0"
  [ "$(cat "$RUNNER_TEMP/gce-validation-suites/dart.status")" = failure ] || fail "no-receipt dart status not failure"
  grep -q "exited without receipt" "$case_root/stdout.log" || fail "missing no-receipt notice"
  [ "$(cat "$RUNNER_TEMP/gce-validation-suites/app_rust.status")" = success ] || fail "sibling app_rust evidence missing"
else
  kill -KILL "$script_pid" 2>/dev/null || true
  wait "$script_pid" 2>/dev/null || true
fi
note "case 6: empty, missing and malformed receipts classify as failure"
classifier="$(sed -n '/^classify_suite_receipt() {/,/^}/p' "$script")"
 [ -n "$classifier" ] || fail "classifier not found in script source"
eval "$classifier"
 [ "$(classify_suite_receipt /dev/null)" = failure ] || fail "empty receipt not failure"
printf 'x' > "$HARNESS_ROOT/bad.rc"
 [ "$(classify_suite_receipt "$HARNESS_ROOT/bad.rc")" = failure ] || fail "malformed receipt not failure"
printf '0' > "$HARNESS_ROOT/good.rc"
 [ "$(classify_suite_receipt "$HARNESS_ROOT/good.rc")" = success ] || fail "zero receipt not success"
 [ "$(classify_suite_receipt "$HARNESS_ROOT/missing.rc")" = failure ] || fail "missing receipt not failure"
if [ "$failures" = 0 ]; then note "all harness cases passed"; else note "$failures harness case(s) failed"; fi
exit "$failures"
