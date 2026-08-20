#!/bin/bash
set -e

RELAY_WS="wss://cidebug-production.up.railway.app"
RELAY_HTTP="https://cidebug-production.up.railway.app"
ACTOR="${GITHUB_ACTOR}"

echo "======================================"
echo "  cidebug - Interactive CI Debugger"
echo "======================================"
echo ""
echo "A step in your pipeline failed."
echo ""

# Test relay is reachable
echo "Checking relay status..."
STATUS=$(curl -s "$RELAY_HTTP/status")
echo "Relay: $STATUS"

# Install websocat
echo "Installing websocat..."
curl -sL https://github.com/vi/websocat/releases/download/v1.13.0/websocat.x86_64-unknown-linux-musl \
  -o /tmp/websocat
chmod +x /tmp/websocat

# Fetch SSH key
echo "Fetching SSH key for @${ACTOR}..."
SSH_KEY=$(curl -s "https://api.github.com/users/${ACTOR}/keys" | \
  python3 -c "import sys,json; keys=json.load(sys.stdin); print(keys[0]['key']) if keys else print('')")

if [ -z "$SSH_KEY" ]; then
  echo "WARNING: No SSH key found for @${ACTOR}."
  echo "Please add an SSH key at github.com/settings/keys"
  exit 0
fi
echo "SSH key found for @${ACTOR}"

# Start SSH server
echo "Starting SSH server..."
sudo apt-get install -y openssh-server > /dev/null 2>&1

mkdir -p /home/runner/.ssh
echo "$SSH_KEY" > /home/runner/.ssh/authorized_keys
chmod 700 /home/runner/.ssh
chmod 600 /home/runner/.ssh/authorized_keys

sudo mkdir -p /run/sshd
sudo /usr/sbin/sshd -p 2222 \
  -o "PermitRootLogin no" \
  -o "PasswordAuthentication no" \
  -o "AuthorizedKeysFile /home/runner/.ssh/authorized_keys"
echo "SSH server started on port 2222"

# Connect to relay
echo "Connecting to relay at $RELAY_WS/runner ..."
/tmp/websocat -v -n1 "$RELAY_WS/runner" > /tmp/ws_out.txt 2>/tmp/ws_err.txt &
WS_PID=$!
sleep 5

echo "WebSocket stdout:"
cat /tmp/ws_out.txt

echo "WebSocket stderr:"
cat /tmp/ws_err.txt

TOKEN=$(grep "^TOKEN:" /tmp/ws_out.txt | head -1 | sed 's/^TOKEN://')
kill $WS_PID 2>/dev/null || true

if [ -z "$TOKEN" ]; then
  echo "Failed to get token from relay"
  exit 1
fi

echo ""
echo "======================================"
echo "  DEBUG SESSION READY"
echo "======================================"
echo ""
echo "Connect with:"
echo "  ssh -p 2222 runner@cidebug-production.up.railway.app"
echo ""
echo "Session token: $TOKEN"
echo "Session expires in 30 minutes."
echo ""

echo "cidebug-token=$TOKEN" >> "$GITHUB_OUTPUT"

echo "Waiting for debug session to end..."
sleep 1800 &
wait