#!/bin/bash
set -e

RELAY_URL="wss://cidebug-production.up.railway.app/runner"
ACTOR="${GITHUB_ACTOR}"

echo "======================================"
echo "  cidebug - Interactive CI Debugger"
echo "======================================"
echo ""
echo "A step in your pipeline failed."
echo "Connecting to cidebug relay..."
echo ""

# Install websocat - a command line websocket client
curl -sL https://github.com/vi/websocat/releases/download/v1.13.0/websocat.x86_64-unknown-linux-musl \
  -o /tmp/websocat
chmod +x /tmp/websocat

# Fetch developer's SSH public key from GitHub
echo "Fetching SSH key for @${ACTOR}..."
SSH_KEY=$(curl -s "https://api.github.com/users/${ACTOR}/keys" | \
  python3 -c "import sys,json; keys=json.load(sys.stdin); print(keys[0]['key']) if keys else print('')")

if [ -z "$SSH_KEY" ]; then
  echo "WARNING: No SSH key found for @${ACTOR} on GitHub."
  echo "Please add an SSH key at github.com/settings/keys"
  echo "Session will not be available."
  exit 0
fi

echo "SSH key found for @${ACTOR}"

# Start SSH server
echo "Starting SSH server..."
apt-get install -y openssh-server > /dev/null 2>&1

mkdir -p /home/runner/.ssh
echo "$SSH_KEY" > /home/runner/.ssh/authorized_keys
chmod 700 /home/runner/.ssh
chmod 600 /home/runner/.ssh/authorized_keys

mkdir -p /run/sshd
/usr/sbin/sshd -p 2222 -o "PermitRootLogin no" \
  -o "PasswordAuthentication no" \
  -o "AuthorizedKeysFile /home/runner/.ssh/authorized_keys"

echo "SSH server started on port 2222"

# Connect to relay and get token
echo "Connecting to relay..."
TOKEN=$(/tmp/websocat --no-close -n1 "$RELAY_URL" 2>/dev/null | \
  grep "^TOKEN:" | head -1 | sed 's/^TOKEN://')

if [ -z "$TOKEN" ]; then
  echo "Failed to connect to relay"
  exit 1
fi

echo ""
echo "======================================"
echo "  DEBUG SESSION READY"
echo "======================================"
echo ""
echo "Connect with:"
echo ""
echo "  ssh -p 2222 runner@cidebug-production.up.railway.app -t TOKEN=$TOKEN"
echo ""
echo "Session expires in 30 minutes."
echo "Type 'exit' when done debugging."
echo ""

# Write token to GITHUB_OUTPUT
echo "cidebug-token=$TOKEN" >> "$GITHUB_OUTPUT"
echo "cidebug-ssh-user=runner" >> "$GITHUB_OUTPUT"

# Keep the runner alive while developer debugs
echo "Waiting for developer to connect and disconnect..."
/tmp/websocat --no-close "$RELAY_URL/$TOKEN/wait" 2>/dev/null || true

echo ""
echo "Debug session ended."