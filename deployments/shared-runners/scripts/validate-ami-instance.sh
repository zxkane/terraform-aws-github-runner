#!/usr/bin/env bash
set -euo pipefail

expected_architecture="${1:?expected architecture is required}"

fail() {
  echo "AMI validation failed: $*" >&2
  exit 1
}

case "$expected_architecture" in
  amd64 | arm64) ;;
  *) fail "unsupported architecture" ;;
esac

cloud_init_status=0
cloud-init status --wait || cloud_init_status=$?
[[ "$cloud_init_status" == "0" || "$cloud_init_status" == "2" ]] ||
  fail "cloud-init did not finish"

[[ "$(dpkg --print-architecture)" == "$expected_architecture" ]] ||
  fail "dpkg architecture mismatch"

if curl --fail --silent --max-time 2 http://169.254.169.254/latest/meta-data/instance-id >/dev/null 2>&1; then
  fail "IMDS accepted a tokenless request"
fi

token="$(
  curl --fail --silent --show-error --max-time 2 \
    -X PUT \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
    http://169.254.169.254/latest/api/token
)" || fail "could not obtain an IMDSv2 token"

validation_tag="$(
  curl --fail --silent --show-error --max-time 2 \
    -H "X-aws-ec2-metadata-token: $token" \
    http://169.254.169.254/latest/meta-data/tags/instance/ghr:ami_validation
)" || fail "validation metadata tag is unavailable"
[[ "$validation_tag" == "true" ]] || fail "validation metadata tag is not true"

[[ "$(node --version)" =~ ^v24\. ]] || fail "Node.js major version is not 24"
command -v bun >/dev/null || fail "Bun is missing"
bun --version >/dev/null
command -v aws >/dev/null || fail "AWS CLI is missing"
aws --version >/dev/null
command -v gh >/dev/null || fail "GitHub CLI is missing"
gh --version >/dev/null
command -v playwright >/dev/null || fail "Playwright CLI is missing"
playwright --version >/dev/null

systemctl is-active --quiet docker || fail "Docker service is not active"
docker info >/dev/null || fail "Docker daemon is unavailable"

[[ -x /opt/actions-runner/bin/Runner.Listener ]] || fail "runner listener is missing"
[[ -x /opt/actions-runner/bin/Runner.Worker ]] || fail "runner worker is missing"
[[ -x /opt/actions-runner/bin/is-ami-validation.sh ]] || fail "validation boot guard is missing"
[[ -x /var/lib/cloud/scripts/per-boot/start-runner.sh ]] || fail "runner startup script is missing"

sudo -u ubuntu -H timeout --signal=TERM --kill-after=5s 60s \
  playwright screenshot --browser chromium about:blank /tmp/playwright-validation.png >/dev/null ||
  fail "Playwright Chromium did not start"
rm -f /tmp/playwright-validation.png

if [[ "$expected_architecture" == "amd64" ]]; then
  command -v google-chrome >/dev/null || fail "Google Chrome is missing"
  [[ -x /usr/local/bin/google-chrome-ci ]] || fail "Chrome CI wrapper is missing"
  chrome_path_lines="$(grep '^CHROME_PATH=' /opt/actions-runner/.env || true)"
  [[ "$chrome_path_lines" == "CHROME_PATH=/usr/local/bin/google-chrome-ci" ]] ||
    fail "runner must select the Chrome CI wrapper with one exact CHROME_PATH"
  chrome_profile="$(sudo -u ubuntu -H mktemp -d)" || fail "could not create Chrome profile"
  trap 'rm -rf -- "$chrome_profile"' EXIT
  sudo -u ubuntu -H timeout --signal=TERM --kill-after=5s 30s \
    /usr/local/bin/google-chrome-ci --headless --disable-gpu \
    --user-data-dir="$chrome_profile" --dump-dom about:blank >/dev/null ||
    fail "Google Chrome did not start"
  rm -rf -- "$chrome_profile"
  trap - EXIT
elif command -v google-chrome >/dev/null; then
  fail "Google Chrome must be absent on arm64"
fi

if find /var/lib/apt/lists -type f -print -quit | grep -q .; then
  fail "apt package index is not empty"
fi

grep -q "AMI validation mode detected" /var/log/runner-startup.log ||
  fail "runner startup did not stop in validation mode"

echo "AMI validation passed"
