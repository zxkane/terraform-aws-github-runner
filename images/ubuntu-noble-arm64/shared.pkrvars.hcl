region              = "us-east-1"
instance_type       = "t4g.large"
root_volume_size_gb = 30

global_tags = {
  Project = "SharedInfra"
  Purpose = "GitHub Actions Runner AMI"
}

ami_tags = {
  Name = "shared-github-runner-arm64"
}

custom_shell_commands = [
  # ── Node.js 24 (Active LTS) ──
  "curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -",
  "sudo apt-get install -y nodejs",
  "echo 'Node.js version:' && node --version",

  # ── Bun (arm64 native) ──
  "curl -fsSL https://bun.sh/install | bash",
  "sudo cp /home/ubuntu/.bun/bin/bun /usr/local/bin/bun",
  "sudo ln -sf /usr/local/bin/bun /usr/local/bin/bunx",
  "echo 'Bun version:' && bun --version",

  # ── Playwright Chromium (system deps + browser binary) ──
  "sudo npx playwright install-deps chromium",
  "npx playwright install chromium",
  "echo 'Playwright browsers installed'",

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
  "npx playwright --version",
  "gh --version",
  "echo '=== Verification Complete ==='"
]
