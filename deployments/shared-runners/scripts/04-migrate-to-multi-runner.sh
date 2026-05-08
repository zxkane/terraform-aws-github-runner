#!/bin/bash
# Migrate from the legacy single-fleet (top-level module) deployment to
# modules/multi-runner with arm64 + amd64 fleets.
#
# Strategy: destroy old fleet under old code, then apply new code. Avoids
# state-mv brittleness — SQS / Lambda names change shape under the new module
# anyway, so they'd recreate either way.
#
# Prerequisites: source ./.deploy.env (contains GITHUB_APP_ID,
# GITHUB_APP_KEY_BASE64, VPC_ID, SUBNET_IDS, TF_STATE_BUCKET).
#
# Side effects:
# - All existing runner-related AWS resources (Lambda, SQS, IAM, ASG, SSM
#   params under /gh-runner/...) are destroyed and recreated under new names.
# - GitHub-side runner registrations under all repos this App is installed
#   on are de-registered before destroy (Phase 2.5). Without this, the
#   dying scale-down Lambda leaves "tombstone" offline runner rows on each
#   repo's Settings → Actions → Runners page that nothing will ever clean
#   up. Online / busy runners are left alone.
# - GitHub App webhook URL/secret are auto-updated by the
#   modules/webhook-github-app local-exec provisioner.
# - Brief outage: workflow_job webhooks delivered between destroy completion
#   and apply completion (~5–10 min) will fail; GitHub auto-retries within
#   its redelivery window.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DEPLOY_DIR/../.." && pwd)"
cd "$DEPLOY_DIR"

# Mirror all output to a log file. Using process substitution avoids the
# classic `script.sh | tee log` pitfall where the caller's outer pipeline
# masks a non-zero script exit code from CI / shell `if` checks.
LOG_FILE="${MIGRATE_LOG:-/tmp/migrate-multi-runner-$(date -u +%Y%m%d-%H%M%S).log}"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "  Logging to: $LOG_FILE"
echo

if [ -f .deploy.env ]; then
  set -a; . ./.deploy.env; set +a
fi

: "${GITHUB_APP_ID:?Set GITHUB_APP_ID in .deploy.env}"
: "${GITHUB_APP_KEY_BASE64:?Set GITHUB_APP_KEY_BASE64 in .deploy.env}"
: "${VPC_ID:?Set VPC_ID in .deploy.env}"
: "${SUBNET_IDS:?Set SUBNET_IDS in .deploy.env (JSON array)}"
: "${TF_STATE_BUCKET:?Set TF_STATE_BUCKET in .deploy.env}"

# The pre-multi-runner commit — its main.tf is the legacy single-fleet shape
# that matches the deployed state, so destroy can plan cleanly.
LEGACY_COMMIT="${LEGACY_COMMIT:-f5e9e145}"

echo "═══════════════════════════════════════════════════════════════"
echo "  Phase 0 — Sanity checks"
echo "═══════════════════════════════════════════════════════════════"
git diff --quiet HEAD -- main.tf RUNBOOK.md outputs.tf || {
  echo "ERROR: working tree has uncommitted changes in deployments/shared-runners/"
  git diff --stat HEAD -- main.tf RUNBOOK.md outputs.tf
  exit 1
}

echo "  Current HEAD: $(git rev-parse --short HEAD)"
echo "  Legacy commit for destroy: $LEGACY_COMMIT"
echo

echo "═══════════════════════════════════════════════════════════════"
echo "  Phase 1 — Restore legacy main.tf (in working tree only)"
echo "═══════════════════════════════════════════════════════════════"
cp main.tf /tmp/multirunner_main.tf
git show "$LEGACY_COMMIT:deployments/shared-runners/main.tf" > main.tf
echo "  Restored legacy main.tf for destroy phase"
echo

# Trap to always restore the new main.tf no matter what. Preserve the
# original exit code so an error mid-script still fails the script.
restore_new_main() {
  local rc=$?
  echo "  Restoring multi-runner main.tf..."
  cp /tmp/multirunner_main.tf main.tf
  return $rc
}
trap restore_new_main EXIT

echo "═══════════════════════════════════════════════════════════════"
echo "  Phase 2 — terraform init (legacy module, existing state)"
echo "═══════════════════════════════════════════════════════════════"
terraform init -reconfigure -input=false \
  -backend-config="bucket=$TF_STATE_BUCKET"
echo

echo "═══════════════════════════════════════════════════════════════"
echo "  Phase 2.5 — De-register GitHub runner registrations"
echo "═══════════════════════════════════════════════════════════════"
# Lessons learned: terraform destroy drops the scale-down Lambda along with
# everything else, so any runner registrations that the Lambda would normally
# de-register on idle become "tombstones" — visible on each repo's Settings
# → Actions → Runners page as offline rows that nothing ever cleans up. Fix
# it preemptively: while the legacy stack still exists (and the GitHub App is
# still wired to it), enumerate the App's installed repos and DELETE any
# runner registration whose backing EC2 instance no longer exists or has
# already been terminated. Online / busy runners are left alone.
python3 - <<'PY'
import json, os, subprocess, sys, time, urllib.error, urllib.request, base64

app_id = os.environ['GITHUB_APP_ID']
key_b64 = os.environ['GITHUB_APP_KEY_BASE64']

def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b'=').decode()

# Mint a short-lived App JWT
header = b64url(b'{"alg":"RS256","typ":"JWT"}')
now = int(time.time())
payload = b64url(json.dumps({'iat': now, 'exp': now + 540, 'iss': int(app_id)}).encode())
key_pem = base64.b64decode(key_b64)

# openssl needs the private key as a file (it can't reliably read it from stdin
# alongside the message-to-sign). Write to a tempfile, sign, then unlink.
import tempfile
with tempfile.NamedTemporaryFile(delete=False) as kf:
    kf.write(key_pem)
    pem_path = kf.name
try:
    sig = subprocess.check_output(
        ['openssl', 'dgst', '-sha256', '-sign', pem_path],
        input=f'{header}.{payload}'.encode(),
    )
finally:
    os.unlink(pem_path)
jwt_token = f"{header}.{payload}.{b64url(sig)}"

def gh(url, method='GET', auth_header=None):
    req = urllib.request.Request(url, method=method, headers={
        'Authorization': auth_header,
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
    })
    try:
        resp = urllib.request.urlopen(req)
        return None if resp.status == 204 else json.load(resp)
    except urllib.error.HTTPError as e:
        return {'_error': e.code, '_msg': e.read().decode()[:200]}

# List App installations and pick the (only) one
installs = gh('https://api.github.com/app/installations', auth_header=f'Bearer {jwt_token}')
if not isinstance(installs, list) or not installs:
    print(f"  No installations found ({installs}); skipping de-registration.")
    sys.exit(0)
installation_id = installs[0]['id']
print(f"  Installation: id={installation_id} account={installs[0]['account']['login']}")

# Trade JWT for an installation access token (needed for repos endpoints)
inst_token_resp = gh(
    f'https://api.github.com/app/installations/{installation_id}/access_tokens',
    method='POST', auth_header=f'Bearer {jwt_token}',
)
inst_token = inst_token_resp['token']
inst_auth = f'Bearer {inst_token}'

# Paginate the repo list
repos = []
page = 1
while True:
    d = gh(f'https://api.github.com/installation/repositories?per_page=100&page={page}',
           auth_header=inst_auth)
    chunk = d.get('repositories', [])
    if not chunk:
        break
    repos.extend(r['full_name'] for r in chunk)
    if len(repos) >= d.get('total_count', 0):
        break
    page += 1
print(f"  App installed on {len(repos)} repo(s)")

# For each repo, list runners, DELETE the dead ones
to_delete, kept = [], []
for repo in repos:
    d = gh(f'https://api.github.com/repos/{repo}/actions/runners?per_page=100',
           auth_header=inst_auth)
    if isinstance(d, dict) and d.get('_error'):
        # 403 here usually means the App lacks the actions:read on this repo —
        # not fatal, just means we can't see runners for this repo.
        continue
    for r in (d.get('runners') or []):
        if r['status'] == 'online' or r.get('busy'):
            kept.append((repo, r['name'], 'in-use'))
            continue
        instance_id = r['name']
        if not instance_id.startswith('i-'):
            kept.append((repo, r['name'], 'unrecognized name'))
            continue
        try:
            state = subprocess.check_output([
                'aws', 'ec2', 'describe-instances', '--region', 'us-east-1',
                '--instance-ids', instance_id,
                '--query', 'Reservations[0].Instances[0].State.Name',
                '--output', 'text',
            ], stderr=subprocess.DEVNULL).decode().strip()
        except subprocess.CalledProcessError:
            state = ''
        # 'None' / empty / terminated / shutting-down all mean: EC2 is gone
        if state in ('terminated', 'shutting-down', 'None', ''):
            to_delete.append({'repo': repo, 'id': r['id'], 'name': r['name'], 'state': state or 'gone'})
        else:
            kept.append((repo, r['name'], f'EC2 still {state}'))

print(f"  Tombstones to delete: {len(to_delete)}")
print(f"  Live registrations kept: {len(kept)}")
for k in kept:
    print(f"    KEEP  {k[0]:40s}  {k[1]:24s}  {k[2]}")

ok = fail = 0
for d in to_delete:
    res = gh(f"https://api.github.com/repos/{d['repo']}/actions/runners/{d['id']}",
             method='DELETE', auth_header=inst_auth)
    if res is None:
        ok += 1
        print(f"    ✓     {d['repo']:40s}  {d['name']}  (was {d['state']})")
    else:
        fail += 1
        print(f"    ✗     {d['repo']:40s}  {d['name']}  err={res}")
print(f"  De-registered: {ok}  failed: {fail}")
if fail and ok == 0:
    sys.exit(1)
PY
echo

echo "═══════════════════════════════════════════════════════════════"
echo "  Phase 3 — terraform destroy (drops ~98 resources)"
echo "═══════════════════════════════════════════════════════════════"
terraform destroy -auto-approve -input=false \
  -var "github_app_id=$GITHUB_APP_ID" \
  -var "github_app_key_base64=$GITHUB_APP_KEY_BASE64" \
  -var "vpc_id=$VPC_ID" \
  -var "subnet_ids=$SUBNET_IDS"
echo

echo "═══════════════════════════════════════════════════════════════"
echo "  Phase 4 — Switch to multi-runner main.tf"
echo "═══════════════════════════════════════════════════════════════"
cp /tmp/multirunner_main.tf main.tf
trap - EXIT  # don't run restore_new_main on success path
echo "  Restored multi-runner main.tf"
echo

echo "═══════════════════════════════════════════════════════════════"
echo "  Phase 5 — terraform init -upgrade (multi-runner module)"
echo "═══════════════════════════════════════════════════════════════"
terraform init -reconfigure -upgrade -input=false \
  -backend-config="bucket=$TF_STATE_BUCKET"
echo

echo "═══════════════════════════════════════════════════════════════"
echo "  Phase 6 — terraform apply (creates arm64 + amd64 fleets)"
echo "═══════════════════════════════════════════════════════════════"
terraform apply -auto-approve -input=false \
  -var "github_app_id=$GITHUB_APP_ID" \
  -var "github_app_key_base64=$GITHUB_APP_KEY_BASE64" \
  -var "vpc_id=$VPC_ID" \
  -var "subnet_ids=$SUBNET_IDS"
echo

echo "═══════════════════════════════════════════════════════════════"
echo "  Phase 7 — Verify GitHub webhook auto-update"
echo "═══════════════════════════════════════════════════════════════"
NEW_ENDPOINT=$(terraform output -raw webhook_endpoint)
echo "  New webhook endpoint: $NEW_ENDPOINT"

# Generate JWT to query GitHub App's current webhook config
HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '\n=' | tr '/+' '_-')
PAYLOAD=$(echo -n "{\"iat\":$(date +%s),\"exp\":$(( $(date +%s) + 540 )),\"iss\":$GITHUB_APP_ID}" | base64 | tr -d '\n=' | tr '/+' '_-')
SIGNATURE=$(echo -n "$HEADER.$PAYLOAD" | openssl dgst -sha256 -sign <(echo "$GITHUB_APP_KEY_BASE64" | base64 -d) | base64 | tr -d '\n=' | tr '/+' '_-')
JWT="$HEADER.$PAYLOAD.$SIGNATURE"

GH_WEBHOOK_URL=$(curl -sS \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/app/hook/config | python3 -c "import json,sys;print(json.load(sys.stdin).get('url',''))")

echo "  GitHub-side webhook URL: $GH_WEBHOOK_URL"
if [ "$GH_WEBHOOK_URL" = "$NEW_ENDPOINT" ]; then
  echo "  ✓ Webhook URL synced correctly"
else
  echo "  ⚠️  Webhook URL mismatch — manually update GitHub App settings:"
  echo "      Settings → GitHub Apps → your app → Webhook URL"
  echo "      Set to: $NEW_ENDPOINT"
  echo "      Set secret to value of: terraform output -raw webhook_secret"
  exit 2
fi

echo
echo "═══════════════════════════════════════════════════════════════"
echo "  ✓ Migration complete"
echo "═══════════════════════════════════════════════════════════════"
echo "  arm64 jobs: runs-on: [self-hosted, linux, arm64]"
echo "  amd64 jobs: runs-on: [self-hosted, linux, x64]"
