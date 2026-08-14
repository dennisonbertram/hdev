#!/usr/bin/env bash
# Profile: browser — headless Chromium the agent can actually drive.
# Idempotent: this re-runs on every boot from the snapshot and must be a no-op.
set -euo pipefail

# Chromium plus every system library it needs. This is the slow part (minutes),
# which is exactly why it belongs in a snapshot.
if [ ! -d /opt/playwright ]; then
  PLAYWRIGHT_BROWSERS_PATH=/opt/playwright \
    npx -y playwright@latest install --with-deps chromium
fi
npm ls -g playwright >/dev/null 2>&1 || npm i -g playwright
command -v agent-browser >/dev/null || npm i -g agent-browser

# Profiles contribute environment through /etc/hdev.env, which the job sources.
grep -q PLAYWRIGHT_BROWSERS_PATH /etc/hdev.env 2>/dev/null \
  || echo 'export PLAYWRIGHT_BROWSERS_PATH=/opt/playwright' >> /etc/hdev.env
chmod 0644 /etc/hdev.env
