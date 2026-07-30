region              = "us-east-1"
instance_type       = "t3.large"
root_volume_size_gb = 30

global_tags = {
  Project = "SharedInfra"
  Purpose = "GitHub Actions Runner AMI"
}

ami_tags = {
  Name = "shared-github-runner-amd64"
}

custom_shell_commands = [
  # ── Node.js 24 (Active LTS) ──
  "curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -",
  "sudo apt-get install -y nodejs",
  "echo 'Node.js version:' && node --version",

  # ── Bun (amd64 native) ──
  "curl -fsSL https://bun.sh/install | bash",
  "sudo cp /home/ubuntu/.bun/bin/bun /usr/local/bin/bun",
  "sudo ln -sf /usr/local/bin/bun /usr/local/bin/bunx",
  "echo 'Bun version:' && bun --version",

  # ── Playwright Chromium (system deps + browser binary) ──
  "sudo npm install -g playwright",
  "sudo playwright install-deps chromium",
  "playwright install chromium",
  "echo 'Playwright browsers installed'",

  # ── Google Chrome Stable (official signed amd64 repository) ──
  "curl --fail --silent --show-error --location --retry 3 --retry-all-errors --connect-timeout 10 --max-time 60 https://dl.google.com/linux/linux_signing_key.pub -o /tmp/google-linux-signing-key.pub",
  "gpg --batch --show-keys --with-colons --fingerprint /tmp/google-linux-signing-key.pub | awk -F: '$1 == \"pub\" { pubs++ } $1 == \"fpr\" && !fingerprint { fingerprint = $10 } END { exit !(pubs == 1 && fingerprint == \"EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796\") }'",
  "gpg --batch --yes --dearmor --output /tmp/google-chrome.gpg /tmp/google-linux-signing-key.pub",
  "sudo install -m 0644 /tmp/google-chrome.gpg /usr/share/keyrings/google-chrome.gpg",
  "echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main\" | sudo tee /etc/apt/sources.list.d/google-chrome.list > /dev/null",
  "sudo timeout --signal=TERM --kill-after=30s 600s apt-get -o DPkg::Lock::Timeout=60 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update",
  "sudo timeout --signal=TERM --kill-after=30s 600s env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=60 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 install -y --no-install-recommends google-chrome-stable",
  "sudo rm -f /etc/apt/sources.list.d/google-chrome.list /etc/apt/sources.list.d/google-chrome.sources /usr/share/keyrings/google-chrome.gpg",
  "rm -f /tmp/google-linux-signing-key.pub /tmp/google-chrome.gpg",

  # ── GitHub CLI (official apt repo, arch-agnostic) ──
  # Pin priority above 1000 so apt prefers cli.github.com over Ubuntu ESM, which
  # otherwise wins by distribution priority and ships an older gh (e.g. 2.45.0).
  "sudo install -m 0755 -d /etc/apt/keyrings",
  "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null",
  "sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg",
  "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null",
  "printf 'Package: gh\\nPin: origin cli.github.com\\nPin-Priority: 1001\\n' | sudo tee /etc/apt/preferences.d/github-cli > /dev/null",
  "sudo apt-get -y update",
  "sudo apt-get -y install gh",

  # ── Verify all tools ──
  "echo '=== AMI Software Verification ==='",
  "node --version",
  "bun --version",
  "aws --version",
  "docker --version",
  "playwright --version",
  "google-chrome --version",
  "timeout --signal=TERM --kill-after=5s 30s google-chrome --headless --disable-gpu --dump-dom about:blank > /dev/null",
  "gh --version",
  "echo '=== Verification Complete ==='"
]
