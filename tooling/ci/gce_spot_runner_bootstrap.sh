#!/usr/bin/env bash

# Bootstrap a one-job GitHub Actions runner from GCE instance metadata.
# The registration token is short-lived and is removed from instance metadata
# by the provisioning job as soon as the runner reports online.

set -Eeuo pipefail

exec > >(tee -a /var/log/gce-actions-runner-bootstrap.log) 2>&1

metadata() {
  curl --fail --silent --show-error \
    --header 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"
}

runner_name="$(metadata runner-name)"
runner_repository="$(metadata runner-repository)"
runner_token="$(metadata runner-token)"
runner_version="$(metadata runner-version)"
provisioning_model="$(metadata provisioning-model)"

if [[ ! "$runner_name" =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
  echo "Invalid runner name from instance metadata: $runner_name" >&2
  exit 1
fi
if [[ ! "$runner_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo 'Invalid GitHub repository from instance metadata.' >&2
  exit 1
fi
if [[ -z "$runner_token" ]]; then
  echo 'Runner registration token is missing from instance metadata.' >&2
  exit 1
fi
if [[ "$provisioning_model" != 'spot' && "$provisioning_model" != 'standard' ]]; then
  echo "Unexpected provisioning model: $provisioning_model" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends curl git gzip jq tar

case "$(uname -m)" in
  amd64|x86_64) runner_arch='x64' ;;
  *)
    echo 'This pilot requires an x64 runner because its pinned build tools are x64-only.' >&2
    exit 1
    ;;
esac

if [[ "$runner_version" == 'latest' ]]; then
  runner_version="$(
    curl --fail --silent --show-error --location \
      https://api.github.com/repos/actions/runner/releases/latest \
      | jq -er '.tag_name | sub("^v"; "")'
  )"
fi
if [[ ! "$runner_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid GitHub Actions runner version: $runner_version" >&2
  exit 1
fi

runner_dir='/actions-runner'
archive="actions-runner-linux-${runner_arch}-${runner_version}.tar.gz"
mkdir -p "$runner_dir"
cd "$runner_dir"
curl --fail --location --show-error --retry 5 --retry-all-errors \
  "https://github.com/actions/runner/releases/download/v${runner_version}/${archive}" \
  --output "$archive"
tar -xzf "$archive"
rm -f "$archive"
./bin/installdependencies.sh

export RUNNER_ALLOW_RUNASROOT=1
./config.sh \
  --unattended \
  --ephemeral \
  --url "https://github.com/${runner_repository}" \
  --token "$runner_token" \
  --name "$runner_name" \
  --labels "${runner_name},gcp,${provisioning_model}" \
  --no-default-labels \
  --disableupdate

unset runner_token
exec ./run.sh
