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
make_stubs() {
  stub_dir="$1"
  mkdir -p "$stub_dir"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "stub flutter $*";' 'if [[ "${STUB_FLUTTER_EXIT:-0}" != "0" ]]; then exit "$STUB_FLUTTER_EXIT"; fi' 'if [[ -n "${STUB_FLUTTER_SLEEP:-}" ]]; then sleep "$STUB_FLUTTER_SLEEP"; fi' 'exit 0' > "$stub_dir/flutter"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "stub cargo $*";' 'if [[ "${STUB_CARGO_EXIT:-0}" != "0" ]]; then exit "$STUB_CARGO_EXIT"; fi' 'exit 0' > "$stub_dir/cargo"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "stub pwsh $*";' 'exit 0' > "$stub_dir/pwsh"
  chmod +x "$stub_dir/flutter" "$stub_dir/cargo" "$stub_dir/pwsh"
}
fresh_env() {
  case_root="$(mktemp -d)"
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
sleeper_pid="$(pgrep -f 'sleep 60' | head -n 1)"
if [ -z "$sleeper_pid" ]; then fail "no sleeping stub found"; else stub_pid="$(ps -o ppid= -p "$sleeper_pid" | tr -d ' ')"; sub_pid="$(ps -o ppid= -p "$stub_pid" | tr -d ' ')"; kill -KILL "$sub_pid"; fi
wait "$script_pid"
code=$?
 [ "$code" != 0 ] || fail "no-receipt run exited 0"
 [ "$(cat "$RUNNER_TEMP/gce-validation-suites/dart.status")" = failure ] || fail "no-receipt dart status not failure"
grep -q "exited without receipt" "$case_root/stdout.log" || fail "missing no-receipt notice"
 [ "$(cat "$RUNNER_TEMP/gce-validation-suites/app_rust.status")" = success ] || fail "sibling app_rust evidence missing"
if [ "$failures" = 0 ]; then note "all harness cases passed"; else note "$failures harness case(s) failed"; fi
exit "$failures"
