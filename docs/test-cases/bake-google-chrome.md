# Bake Google Chrome into the amd64 runner AMI

## Acceptance criteria

| ID | Scenario | Expected result |
| --- | --- | --- |
| TC-CHROME-001 | Configure Chrome packages | The build pins Google's published primary key fingerprint and uses an amd64-only `signed-by` apt repository. |
| TC-CHROME-002 | Install Chrome during provisioning | Installation is noninteractive, excludes recommended packages, retries transient downloads, and has bounded lock/download/command waits; the temporary repository and keyring are removed afterward. |
| TC-CHROME-003 | Verify the amd64 toolchain | `google-chrome --version` succeeds before Packer creates the AMI. |
| TC-CHROME-004 | Smoke-test Chrome | Chrome starts headlessly as the unprivileged Packer build user. |
| TC-CHROME-005 | Build the arm64 runner AMI | No Google Chrome amd64 package command is present. |
| TC-CHROME-006 | Validate the Packer templates in CI | Formatting, shared variables, and Chrome provisioning assertions pass for both runner architectures. |
| TC-CHROME-007 | Complete a real amd64 build | Packer reports the Chrome version and creates an available AMI. |
| TC-CHROME-008 | Launch Chrome from a non-login runner session | The amd64 AMI provides an executable wrapper that starts Chrome Stable inside `dbus-run-session`. |
| TC-CHROME-009 | Configure `chrome-launcher` discovery | The amd64 runner environment contains exactly one `CHROME_PATH` entry selecting `/usr/local/bin/google-chrome-ci`; arm64 does not set it. |
| TC-CHROME-010 | Smoke-test the installed wrapper | Packer and the release validator launch the wrapper as the unprivileged runner user with a temporary profile and browser sandboxing enabled; each cold-start smoke has a 90-second hard timeout. |
