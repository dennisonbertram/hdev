#!/usr/bin/env bash
# Profile: docker — a working Docker daemon at boot.
# Idempotent: this re-runs on every boot from the snapshot and must be a no-op.
set -euo pipefail

command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

# The job user is created per submit, so hdev adds it to this group later.
getent group docker >/dev/null || groupadd docker
