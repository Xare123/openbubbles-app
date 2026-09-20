# Direct source-only GCE runs

The primary Muse task owns this workflow end to end under the user's standing
authorization. The supervisor reviews meaningful integration/release checkpoints;
it is not the routine Git, dispatch, monitoring, or cleanup operator.

## Established configuration

Verified on September 18, 2026. Recheck remote state before each dispatch.

| Setting | Value |
| --- | --- |
| Repository | `Xare123/openbubbles-app` |
| Workflow | `GCE runner pilot`, ID `345678579` |
| Workflow file | `.github/workflows/gce-runner-pilot.yml` |
| Workflow ref | `agent/gce-runner-pilot` |
| Reviewed workflow commit | `fab604fc7119b7d489caf39e96619d59d3c3e697` |
| Trusted source branch | `agent/cloudkit-v2-received-origin-20260916` |
| Machine / provisioning | `n2d-standard-16` / `spot` |
| Zone / lane | `us-west1-b` / `primary` |
| Validation / flavor | `cloudkit-qualification` / `beta` |
| Writer / automatic uploads | `false` / `false` |
| VM lifetime | Existing workflow's 75-minute maximum |

The selected mode runs Dart/Flutter/PowerShell plus app Rust and the workflow's
generated-binding checks. It does not select rustpush or protector suites and
does not build an APK or run signing. The inherited job title "Build beta APK on
GCE" is not proof that an APK was built; report the actual selected steps.

## Tools and permissions

Use the existing authenticated GitHub CLI. Its verified Windows executable is
`C:/Program Files/GitHub CLI/gh.exe`; a missing PATH entry is not a missing tool.
Git is `C:/Program Files/Git/cmd/git.exe`. GCloud is available through
`C:/Users/ramia/google-cloud-sdk/bin/gcloud.ps1` for read-only cleanup inventory.
Use GitHub's existing workflow identity for runner creation/deletion; do not
copy credentials into a runner or set up another cloud identity.

Run commands in the relevant checkout. Where Git reports ownership differences,
first verify the checkout belongs to Rami, then use a command-scoped
`-c safe.directory=<exact-checkout>` option. Do not use a wildcard trust rule.
In a sandboxed session, request the declared shell tool's scoped approval for
authorized Git/network operations. In a full-access session omit
`sandbox_permissions`; do not pass an option prohibited by the current tool.

## Preflight and publication

1. Select an immutable, reviewed 40-character source commit. Preserve unrelated
   edits and staged work. Commit only the intended reviewed files when needed.
   Uncommitted integration work is not part of a frozen-source qualification.
2. Resolve the workflow ref and trusted source branch with `git ls-remote fork`.
   Stop if the workflow differs from the reviewed commit until its change has
   been examined. If publication is required, prove the remote source head is
   an ancestor of the chosen commit, then push that exact commit by normal
   fast-forward. Never force-push or substitute a different branch to bypass
   the workflow's trusted-source check.
3. Re-read the remote source branch and require its head to equal the selected
   source SHA. The workflow enforces this equality as well.
4. Inspect this workflow's active/queued runs. Adopt and monitor a run already
   covering the same revision. Do not dispatch while a prior owned run is
   active, and do not cancel its cleanup. A completed green run is not a reason
   to dispatch the same revision again without a new failure or concrete need.
5. Check the actual tests in the frozen source. Select one appropriate batch;
   do not imply that suites excluded by the chosen mode will run.

Useful read-only commands:

```powershell
$gh = 'C:\Program Files\GitHub CLI\gh.exe'
& $gh api repos/Xare123/openbubbles-app --jq '.permissions'
& $gh run list -R Xare123/openbubbles-app --workflow 345678579 --limit 100 --json databaseId,status,conclusion,headSha,url
& $gh workflow view 345678579 -R Xare123/openbubbles-app --ref agent/gce-runner-pilot --yaml
```

## Dispatch once

After the checks above pass, substitute the reviewed full source SHA below.
The placeholder deliberately fails validation. This command creates a billable
ephemeral run, so execute it only for a warranted batch within the standing scope.

```powershell
$gh = 'C:\Program Files\GitHub CLI\gh.exe'
$sourceSha = '<reviewed-full-40-character-source-SHA>'
if ($sourceSha -cnotmatch '^[0-9a-f]{40}$') { throw 'Select the reviewed full source SHA first.' }
& $gh workflow run 345678579 -R Xare123/openbubbles-app --ref agent/gce-runner-pilot -f machine_type=n2d-standard-16 -f provisioning_model=spot -f runner_zone=us-west1-b -f source_ref=$sourceSha -f source_branch=agent/cloudkit-v2-received-origin-20260916 -f flavor=beta -f validation_mode=cloudkit-qualification -f outbound_writer=false -f automatic_uploads=false -f runner_lane=primary
if ($LASTEXITCODE -ne 0) { throw 'Dispatch failed. Inspect the response and existing runs before retrying.' }
```

Capture the returned run URL/ID. If the response is uncertain, inspect recent runs
and their source input before another dispatch. A lost CLI connection does not
mean GitHub failed to create the run. No automatic retry, alternate lane, machine
upgrade, or provisioning fallback is authorized by this guide.

## Monitor, report, and close out

- Read the same run with `gh run view <run-id> -R Xare123/openbubbles-app --json status,conclusion,headSha,jobs,url`.
  Preserve the ID across interruptions. Use bounded polling and report meaningful
  changes; avoid long shell loops that prevent task interaction.
- Confirm the workflow SHA and the job's exact checked-out source SHA. Read
  suite logs and named tests. Report actual pass/fail/skip counts and suites not
  run. A green workflow alone is not proof of live CloudKit behavior.
- Inspect/download only relevant artifacts to a task evidence folder. Use
  `gh run view <run-id> --job <job-id> --log` for the selected job's logs.
- Verify the cleanup job succeeded, the run's exact `gce-<run-id>-<attempt>`
  instance was deleted, and its GitHub runner registration is absent. Use the
  workflow's project/zone and exact runner name for inventory; never delete an
  unrelated VM or runner. Preserve and report concrete cleanup failures.
- Send one evidence checkpoint to the supervisor after the batch. Routine
  operation does not wait for another task to execute these steps. Keep any
  broader release, signing, live-account, and device requirements unchanged.

At handoff, run `35381852807` for source
`5d4d121faff33c0108eb81bb0517fa853a4bdb36` was already completed successfully,
including its deletion job. Inspect/adopt that evidence rather than rerunning it.
Future changes need their own immutable source revision and justified test scope.
