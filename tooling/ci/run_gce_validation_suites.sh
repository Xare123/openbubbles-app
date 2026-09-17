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

failed=0
for name in "${selected[@]}"; do
  if wait "${pids[$name]}"; then
    statuses["$name"]='success'
  else
    statuses["$name"]='failure'
    failed=1
  fi
  echo "::group::${name} validation suite"
  cat "$suite_dir/$name.log"
  echo '::endgroup::'
done

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
