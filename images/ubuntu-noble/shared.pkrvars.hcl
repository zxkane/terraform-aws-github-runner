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
  "sudo npx playwright install-deps chromium",
  "npx playwright install chromium",
  "echo 'Playwright browsers installed'",

  # ── Verify all tools ──
  "echo '=== AMI Software Verification ==='",
  "node --version",
  "bun --version",
  "aws --version",
  "docker --version",
  "npx playwright --version",
  "echo '=== Verification Complete ==='"
]
