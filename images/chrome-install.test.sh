#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$SCRIPT_DIR/../deployments/shared-runners/scripts/validate-ami-instance.sh"
WRAPPER="$SCRIPT_DIR/google-chrome-ci"
AMD64_TEMPLATE="$SCRIPT_DIR/ubuntu-resolute/github_agent.ubuntu.pkr.hcl"
ARM64_TEMPLATE="$SCRIPT_DIR/ubuntu-resolute-arm64/github_agent.ubuntu.pkr.hcl"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

commands_json() {
  local image_dir="$1"
  (
    cd "$image_dir"
    printf '%s\n' 'jsonencode(var.custom_shell_commands)' \
      | packer console -var-file=shared.pkrvars.hcl github_agent.ubuntu.pkr.hcl
  )
}

assert_any_contains() {
  local commands="$1"
  local expected="$2"
  local description="$3"

  if ! jq -e --arg expected "$expected" 'any(.[]; contains($expected))' <<<"$commands" >/dev/null; then
    echo "FAIL: $description" >&2
    return 1
  fi
}

assert_exact() {
  local commands="$1"
  local expected="$2"
  local description="$3"

  if ! jq -e --arg expected "$expected" 'index($expected) != null' <<<"$commands" >/dev/null; then
    echo "FAIL: $description" >&2
    return 1
  fi
}

amd64_commands="$(commands_json "$SCRIPT_DIR/ubuntu-resolute")"
arm64_commands="$(commands_json "$SCRIPT_DIR/ubuntu-resolute-arm64")"

[[ -x "$WRAPPER" ]] || fail "Chrome CI wrapper must exist and be executable"
expected_wrapper=$'#!/usr/bin/env bash\nset -euo pipefail\n\nexec /usr/bin/dbus-run-session -- /usr/bin/google-chrome-stable "$@"'
[[ "$(<"$WRAPPER")" == "$expected_wrapper" ]] ||
  fail "Chrome CI wrapper must start Chrome Stable in a user D-Bus session"

grep -Fq 'source      = "../google-chrome-ci"' "$AMD64_TEMPLATE" ||
  fail "amd64 Packer template must upload the Chrome CI wrapper"
grep -Fq 'destination = "/tmp/google-chrome-ci"' "$AMD64_TEMPLATE" ||
  fail "amd64 Packer template must stage the Chrome CI wrapper"
grep -Fq '"sudo install -o root -g root -m 0755 /tmp/google-chrome-ci /usr/local/bin/google-chrome-ci",' "$AMD64_TEMPLATE" ||
  fail "amd64 Packer template must install the Chrome CI wrapper"
grep -Fq "\"sudo sed -i '/^CHROME_PATH=/d' /opt/actions-runner/.env && echo CHROME_PATH=/usr/local/bin/google-chrome-ci | sudo tee -a /opt/actions-runner/.env\"," "$AMD64_TEMPLATE" ||
  fail "amd64 runner environment must idempotently select the Chrome CI wrapper"

if grep -Fq 'google-chrome-ci' "$ARM64_TEMPLATE"; then
  fail "arm64 Packer template must not install or select the amd64 Chrome wrapper"
fi

assert_any_contains "$amd64_commands" \
  "https://dl.google.com/linux/linux_signing_key.pub" \
  "amd64 downloads Google's Linux package signing key"
assert_any_contains "$amd64_commands" \
  "EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796" \
  "amd64 pins Google's published primary signing-key fingerprint"
assert_any_contains "$amd64_commands" \
  "arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg" \
  "amd64 restricts the signed Chrome repository to amd64"

apt_update="sudo timeout --signal=TERM --kill-after=30s 600s apt-get -o DPkg::Lock::Timeout=60 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update"
chrome_install="sudo timeout --signal=TERM --kill-after=30s 600s env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=60 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 install -y --no-install-recommends google-chrome-stable"
chrome_cleanup="sudo rm -f /etc/apt/sources.list.d/google-chrome.list /etc/apt/sources.list.d/google-chrome.sources /usr/share/keyrings/google-chrome.gpg"
chrome_version="google-chrome --version"
chrome_smoke="(chrome_profile=\"\$(mktemp -d)\" && trap 'rm -rf \"\$chrome_profile\"' EXIT && timeout --signal=TERM --kill-after=5s 90s /usr/local/bin/google-chrome-ci --headless --disable-gpu --user-data-dir=\"\$chrome_profile\" --dump-dom about:blank > /dev/null)"

assert_exact "$amd64_commands" "$apt_update" \
  "amd64 bounds the apt repository update"
assert_exact "$amd64_commands" "$chrome_install" \
  "amd64 installs the latest stable package with bounded waits"
assert_exact "$amd64_commands" "$chrome_cleanup" \
  "amd64 removes both Chrome repository formats and the keyring"
assert_exact "$amd64_commands" "$chrome_version" \
  "amd64 verifies the installed Chrome executable"
assert_exact "$amd64_commands" "$chrome_smoke" \
  "amd64 launches the D-Bus wrapper headlessly with an ephemeral profile"

if ! jq -e \
  --arg update "$apt_update" \
  --arg install "$chrome_install" \
  --arg cleanup "$chrome_cleanup" \
  --arg version "$chrome_version" \
  --arg smoke "$chrome_smoke" \
  'index($update) < index($install)
    and index($install) < index($cleanup)
    and index($cleanup) < index($version)
    and index($version) < index($smoke)' \
  <<<"$amd64_commands" >/dev/null; then
  echo "FAIL: amd64 must update apt, install Chrome, remove its repository, then run unprivileged verification" >&2
  exit 1
fi

if jq -e 'any(.[]; contains("google-chrome-stable_current_amd64.deb"))' <<<"$amd64_commands" >/dev/null; then
  echo "FAIL: amd64 must install Chrome from the signed apt repository" >&2
  exit 1
fi

if jq -e 'any(.[]; contains("google-chrome"))' <<<"$arm64_commands" >/dev/null; then
  echo "FAIL: arm64 must not install the amd64-only Google Chrome package" >&2
  exit 1
fi

grep -Fq '[[ -x /usr/local/bin/google-chrome-ci ]] || fail "Chrome CI wrapper is missing"' "$VALIDATOR" ||
  fail "amd64 validator must require the installed Chrome CI wrapper"
# shellcheck disable=SC2016 # Match the literal shell variable in the validator.
validator_chrome_path='[[ "$chrome_path_lines" == "CHROME_PATH=/usr/local/bin/google-chrome-ci" ]]'
grep -Fq "$validator_chrome_path" "$VALIDATOR" ||
  fail "amd64 validator must require one exact runner CHROME_PATH"
# shellcheck disable=SC2016 # Match the literal shell variable in the validator.
validator_profile_create='chrome_profile="$(sudo -u ubuntu -H mktemp -d)" || fail "could not create Chrome profile"'
grep -Fq "$validator_profile_create" "$VALIDATOR" ||
  fail "amd64 validator must create an ephemeral Chrome profile as the runner user"
validator_chrome_command="$(
  sed -n \
    '/^  sudo -u ubuntu -H timeout --signal=TERM --kill-after=5s 90s \\$/,+2p' \
    "$VALIDATOR"
)"
expected_validator_chrome_command=$'  sudo -u ubuntu -H timeout --signal=TERM --kill-after=5s 90s \\\n    /usr/local/bin/google-chrome-ci --headless --disable-gpu \\\n    --user-data-dir="$chrome_profile" --dump-dom about:blank >/dev/null ||'
[[ "$validator_chrome_command" == "$expected_validator_chrome_command" ]] ||
  fail "amd64 validator must run the D-Bus wrapper with an ephemeral profile and a 90-second timeout"

if grep -q -- '--no-sandbox' "$WRAPPER" "$AMD64_TEMPLATE" "$VALIDATOR"; then
  fail "Chrome build and validation must exercise the sandbox used by runner jobs"
fi

echo "PASS: Google Chrome AMI provisioning assertions"
