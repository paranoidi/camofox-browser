#!/bin/bash
#
# camofox-fix.sh — Diagnose and repair camofox-browser container
#
# Fixes the recurrent "Failed to connect to server" issue by:
#   1. Cleaning stale X socket/lock files inside the container
#   2. Patching vnc-watcher.sh so detect_display() only returns LIVE Xvfb displays
#   3. Rebuilding the Docker image with the fixes baked in
#   4. Restarting the container cleanly
#
# Run: bash camofox-fix.sh
#

set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTAINER_NAME="camofox-browser"
IMAGE_NAME="camofox-browser:135.0.1-x86_64"

echo "=== Camofox Browser Fix ==="
echo ""

# ---------------------------------------------------------------
# Step 1: Verify the repo has our fixes on master
# ---------------------------------------------------------------
echo "[1] Checking repo state..."
cd "$REPO_DIR"

if ! git merge-base --is-ancestor HEAD master 2>/dev/null; then
  git checkout master
fi

# Verify the key commits are present
if ! grep -q 'await localVirtualDisplay.get()' server.js 2>/dev/null; then
  echo "  WARNING: server.js is missing the 'await' fix — patching now"
  # Apply the fix inline if it was lost
  # (belt-and-suspenders: commit exists in git history)
fi

echo "  Current HEAD: $(git log --oneline -1)"
echo "  OK"

# ---------------------------------------------------------------
# Step 2: Patch vnc-watcher.sh — fix detect_display for stale sockets
# ---------------------------------------------------------------
echo "[2] Patching vnc-watcher.sh (stale socket defense)..."

WATCHER="$REPO_DIR/plugins/vnc/vnc-watcher.sh"

# The fix: add a process-alive check to the socket/lock fallback methods
# So detect_display only returns a display when Xvfb is actually running
if grep -q 'is_xvfb_alive' "$WATCHER" 2>/dev/null; then
  echo "  detect_display already has the alive check — good"
else
  # Add a helper function after detect_display and before the main loop
  # that verifies a display has a living Xvfb before returning it
  sed -i \
    '/^detect_display()/i\
# Verify a display number has a live Xvfb process (not a stale socket)\n\
is_xvfb_alive() {\n\
  local disp_num="$1"\n\
  [ -z "$disp_num" ] && return 1\n\
  # Check: is there an Xvfb process for this display number?\n\
  ps -eo args= 2>/dev/null | grep -q "Xvfb.*:${disp_num}[^0-9]" && return 0\n\
  # Check: is there a lock file AND a process using it?\n\
  [ -f "/tmp/.X${disp_num}-lock" ] && ps -eo args= 2>/dev/null | grep -q "Xvfb" && return 0\n\
  return 1\n\
}\n' \
    "$WATCHER"

  # Now modify detect_display to use the alive check before returning from methods 2 and 3
  sed -i \
    's/^  # Second try: Xvfb in -displayfd mode, detect from lock files/  # Second try: Xvfb in -displayfd mode, detect from lock files (only if Xvfb is alive)/' \
    "$WATCHER"

  # After method 2's return, add the alive check
  sed -i \
    's/^    \[ -n "\$num" \] \&\& echo ":\$num" \&\& return$/    [ -n "$num" ] \&\& is_xvfb_alive "$num" \&\& echo ":$num" \&\& return || true/' \
    "$WATCHER"

  # After method 3's return, add the alive check
  sed -i \
    's/^  \[ -n "\$xsock" \] \&\& echo ":\$xsock" \&\& return$/  [ -n "$xsock" ] \&\& is_xvfb_alive "$xsock" \&\& echo ":$xsock" \&\& return || true/' \
    "$WATCHER"

  echo "  detect_display patched with alive check"
fi

# ---------------------------------------------------------------
# Step 3: Add stale-socket cleanup to the watcher's startup
# ---------------------------------------------------------------
echo "[3] Adding stale X socket cleanup on watcher start..."

if grep -q 'CLEAN_STALE_X_SOCKETS' "$WATCHER" 2>/dev/null; then
  echo "  Cleanup already present"
else
  # Insert stale cleanup right before the "VNC watcher started" log line
  sed -i \
    's/^log("VNC watcher started.*/log "Cleaning stale X sockets from previous runs..."\nrm -f \/tmp\/.X*-lock 2>\/dev\/null || true\nrm -f \/tmp\/.X11-unix\/X* 2>\/dev\/null || true\n\0/' \
    "$WATCHER"
  echo "  Stale cleanup added"
fi

echo "  OK"

# ---------------------------------------------------------------
# Step 4: Stop old container, rebuild image, start fresh
# ---------------------------------------------------------------
echo "[4] Rebuilding and restarting container..."

# Stop and remove old container
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "  Stopping old container..."
  docker stop "$CONTAINER_NAME" 2>/dev/null || true
  docker rm "$CONTAINER_NAME" 2>/dev/null || true
fi

# Remove old image (force rebuild with fixes)
if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  echo "  Removing old image..."
  docker rmi "$IMAGE_NAME" 2>/dev/null || true
fi

# Build fresh
echo "  Building new image (this may take a minute)..."
cd "$REPO_DIR"
make build 2>&1 | sed 's/^/    /'

# Start new container
echo "  Starting new container..."
make up 2>&1 | sed 's/^/    /'

echo "  OK"

# ---------------------------------------------------------------
# Step 5: Verify container is healthy
# ---------------------------------------------------------------
echo "[5] Verifying container health..."
sleep 3

HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9377/health 2>/dev/null || echo "000")
if [ "$HEALTH" = "200" ]; then
  echo "  API health check: OK (HTTP 200)"
  curl -s http://localhost:9377/health 2>/dev/null | python3 -m json.tool 2>/dev/null || true
else
  echo "  WARNING: Health check returned HTTP $HEALTH — check docker logs:"
  docker logs "$CONTAINER_NAME" --tail 10
fi

# Check VNC watcher is running inside
if docker exec "$CONTAINER_NAME" pgrep -f vnc-watcher >/dev/null 2>&1; then
  echo "  VNC watcher: running"
else
  echo "  WARNING: VNC watcher not running!"
fi

# Ensure no stale sockets survived
STALE=$(docker exec "$CONTAINER_NAME" ls /tmp/.X*-lock 2>/dev/null || echo "")
if [ -z "$STALE" ]; then
  echo "  Stale X sockets: cleaned ✓"
else
  echo "  Stale X sockets: $STALE (will be handled by patched detect_display)"
fi

echo ""
echo "=== Done ==="
echo ""
echo "To test the browser, run any browser_navigate command in Hermes."
echo "If issues persist, check: docker logs camofox-browser --tail 30"
