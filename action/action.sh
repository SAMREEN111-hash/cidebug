#!/bin/bash
set -e

RELAY_HTTP="https://cidebug-production.up.railway.app"
RELAY_WS="wss://cidebug-production.up.railway.app"
ACTOR="${GITHUB_ACTOR}"

echo "======================================"
echo "  cidebug - Interactive CI Debugger"
echo "======================================"
echo ""
echo "A step in your pipeline failed."
echo ""

# Test relay is reachable
echo "Checking relay..."
curl -sf "$RELAY_HTTP/status" || { echo "Relay unreachable"; exit 1; }

# Install websocat
echo "Installing websocat..."
curl -sL https://github.com/vi/websocat/releases/download/v1.13.0/websocat.x86_64-unknown-linux-musl \
  -o /tmp/websocat
chmod +x /tmp/websocat

# Install tmate for terminal sharing
echo "Installing tmate..."
curl -sL https://github.com/tmate-io/tmate/releases/download/2.4.0/tmate-2.4.0-static-linux-amd64.tar.xz \
  -o /tmp/tmate.tar.xz
cd /tmp && tar xf tmate.tar.xz
chmod +x /tmp/tmate-2.4.0-static-linux-amd64/tmate
cp /tmp/tmate-2.4.0-static-linux-amd64/tmate /usr/local/bin/tmate
cd -

# Get session token from relay
echo "Connecting to relay..."
/tmp/websocat -v -n1 "$RELAY_WS/runner" > /tmp/ws_out.txt 2>/tmp/ws_err.txt &
WS_PID=$!
sleep 5
kill $WS_PID 2>/dev/null || true

TOKEN=$(grep "^TOKEN:" /tmp/ws_out.txt | head -1 | sed 's/^TOKEN://')

if [ -z "$TOKEN" ]; then
  echo "WebSocket output:"
  cat /tmp/ws_out.txt
  echo "WebSocket errors:"
  cat /tmp/ws_err.txt
  echo "Failed to get token - falling back to tmate"
  TOKEN="tmate-fallback"
fi

echo "Session token: $TOKEN"

# Start tmate session
echo ""
echo "Starting tmate terminal session..."
tmate -S /tmp/tmate.sock new-session -d
tmate -S /tmp/tmate.sock wait tmate-ready

# Get connection strings
TMATE_SSH=$(tmate -S /tmp/tmate.sock display -p '#{tmate_ssh}')
TMATE_WEB=$(tmate -S /tmp/tmate.sock display -p '#{tmate_web}')

echo ""
echo "======================================"
echo "  DEBUG SESSION READY"
echo "======================================"
echo ""
echo "Connect via SSH:"
echo "  $TMATE_SSH"
echo ""
echo "Connect via browser:"
echo "  $TMATE_WEB"
echo ""
echo "cidebug token: $TOKEN"
echo ""
echo "Session expires in 30 minutes."
echo "Type 'exit' in the terminal when done debugging."
echo ""

# Write to GITHUB_OUTPUT
echo "cidebug-token=$TOKEN" >> "$GITHUB_OUTPUT"
echo "tmate-ssh=$TMATE_SSH" >> "$GITHUB_OUTPUT"
echo "tmate-web=$TMATE_WEB" >> "$GITHUB_OUTPUT"

# Keep session alive for 30 minutes
echo "Waiting for debug session..."
sleep 1800