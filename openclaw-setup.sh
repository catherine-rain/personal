#!/usr/bin/env bash
# OpenClaw on DigitalOcean — setup script
# Usage:
#   export DO_TOKEN="dop_v1_..."
#   export ANTHROPIC_API_KEY="sk-ant-..."
#   bash openclaw-setup.sh
set -euo pipefail

: "${DO_TOKEN:?Set DO_TOKEN to your DigitalOcean personal access token}"
: "${ANTHROPIC_API_KEY:?Set ANTHROPIC_API_KEY to your Anthropic API key}"

# ── 0. Prereqs ────────────────────────────────────────────────────────────────
[ -f ~/.ssh/id_ed25519.pub ] || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
if ! command -v doctl &>/dev/null; then
  echo "doctl not found. Install it: https://docs.digitalocean.com/reference/doctl/how-to/install/"
  exit 1
fi

doctl auth init --access-token "$DO_TOKEN"

# ── 1. SSH key + droplet ──────────────────────────────────────────────────────
KEY_COUNT=$(doctl compute ssh-key list --format ID --no-header | wc -l)
[ "$KEY_COUNT" -eq 0 ] && doctl compute ssh-key import openclaw-key --public-key-file ~/.ssh/id_ed25519.pub

doctl compute droplet create openclaw1 \
  --region nyc1 \
  --size s-1vcpu-2gb \
  --image ubuntu-24-04-x64 \
  --ssh-keys "$(doctl compute ssh-key list --format ID --no-header | head -1)" \
  --wait \
  --format ID,Name,PublicIPv4 \
  --no-header

DROPLET_IP=$(doctl compute droplet get openclaw1 --format PublicIPv4 --no-header)
echo "Droplet IP: $DROPLET_IP"

until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new root@"$DROPLET_IP" 'echo ready' 2>/dev/null; do
  sleep 5
done

# ── 2. Swap ───────────────────────────────────────────────────────────────────
ssh root@"$DROPLET_IP" 'bash -s' <<'SWAP'
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo "/swapfile none swap sw 0 0" >> /etc/fstab
echo "Swap: $(swapon --show)"
SWAP

# ── 3. Node.js ────────────────────────────────────────────────────────────────
ssh root@"$DROPLET_IP" 'bash -s' <<'NODE'
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm install --lts
node --version && npm --version
NODE

# ── 4. OpenClaw install ───────────────────────────────────────────────────────
ssh root@"$DROPLET_IP" 'bash -s' <<'INSTALL'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
curl -fsSL https://openclaw.ai/install.sh | OPENCLAW_SKIP_SETUP=1 bash || true
openclaw --version
INSTALL

# ── 5. Onboard (Anthropic) ────────────────────────────────────────────────────
ssh root@"$DROPLET_IP" "bash -s" <<ONBOARD
export NODE_OPTIONS="--max-old-space-size=1536"
openclaw onboard --non-interactive \
  --mode local \
  --auth-choice apiKey \
  --anthropic-api-key "$ANTHROPIC_API_KEY" \
  --secret-input-mode plaintext \
  --accept-risk \
  --gateway-port 18789 \
  --gateway-bind loopback \
  --install-daemon \
  --daemon-runtime node \
  --skip-skills
ONBOARD

# ── 6. Verify ─────────────────────────────────────────────────────────────────
ssh root@"$DROPLET_IP" 'openclaw status && openclaw doctor --non-interactive && openclaw gateway status'

# ── 7. SSH tunnel + dashboard URL ─────────────────────────────────────────────
lsof -i :18789 &>/dev/null && LOCAL_PORT=18790 || LOCAL_PORT=18789
ssh -f -N -L "${LOCAL_PORT}:localhost:18789" root@"$DROPLET_IP"

GATEWAY_TOKEN=$(ssh root@"$DROPLET_IP" \
  "python3 -c \"import json; print(json.load(open('/root/.openclaw/openclaw.json'))['auth']['token'])\"")

echo ""
echo "════════════════════════════════════════════"
echo " OpenClaw is ready!"
echo " Dashboard : http://localhost:${LOCAL_PORT}/chat?session=main"
echo " Token     : $GATEWAY_TOKEN"
echo " Droplet IP: $DROPLET_IP"
echo "════════════════════════════════════════════"

# ── 8. AgentCash ──────────────────────────────────────────────────────────────
ssh root@"$DROPLET_IP" 'npx agentcash@latest onboard'
echo ""
echo "Visit https://agentcash.dev to get free credits and manage your balance."
