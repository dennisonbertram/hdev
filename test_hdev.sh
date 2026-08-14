#!/usr/bin/env bash
# Smallest check that fails if hdev's argument parsing, plan slicing, branch
# naming or agent-command selection breaks. No Hetzner calls — HDEV_DRY_RUN=1.
set -uo pipefail
HDEV="$(cd "$(dirname "$0")" && pwd)/bin/hdev"
export HDEV_DRY_RUN=1
export HDEV_STATE_DIR="$(mktemp -d)"
export HDEV_MODE_FILE="$HDEV_STATE_DIR/mode"
fail=0
check() { # check <name> <expected-substring> <output>
  case "$3" in *"$2"*) echo "ok   $1" ;; *) echo "FAIL $1: want '$2' in: $3"; fail=1 ;; esac ; }
countcheck() { # countcheck <name> <expected-count> <pattern> <output>
  local got; got="$(printf '%s\n' "$4" | grep -c -e "$3")"
  [ "$got" = "$2" ] && echo "ok   $1" || { echo "FAIL $1: want $2 matches of '$3', got $got"; fail=1; } ; }

plan="$HDEV_STATE_DIR/plan.md"
cat > "$plan" <<'EOF'
# Rate limiting rollout

## Slice: Add the token bucket
Implement it in lib/ratelimit.ts.

## Slice: Wire /api/send
Call the bucket before the handler runs.

## Slice: Tests
Cover burst and refill.
EOF

out="$("$HDEV" submit "$plan" 2>&1)"
check      "slice count reported" "3 slice(s)"        "$out"
countcheck "one job per slice" 3 '^job='             "$out"
check      "slice title in branch" "-add-the-token-bucket" "$out"
check      "slice 2 in branch"     "-wire-api-send"       "$out"
check      "claude is default"     "claude --dangerously-skip-permissions" "$out"

out="$("$HDEV" submit -1 "$plan" 2>&1)"
countcheck "-1 collapses to one job" 1 '^job='       "$out"
check      "-1 uses the H1 title"    "-rate-limiting-rollout" "$out"

out="$("$HDEV" submit -a codex -m "raise the timeout" 2>&1)"
countcheck "-m is one job" 1 '^job='                 "$out"
check      "codex agent"   "codex exec --dangerously-bypass-approvals" "$out"
check      "-m title used" "-raise-the-timeout"      "$out"

out="$("$HDEV" submit -b fix -m "hi" 2>&1)"; check "branch prefix" "branch=fix/" "$out"

# Orchestration wiring: the remote agent must be told to delegate.
out="$("$HDEV" submit -m "test" 2>&1)"
check "claude gets orchestrator prompt" '--append-system-prompt "$(cat $HOME/job/orchestrator.md)"' "$out"
check "claude gets subagents"           '--agents "$(cat $HOME/job/agents.json)"'                   "$out"
check "brief goes in on stdin"          '-p < $HOME/job/task.md'                                    "$out"
out="$("$HDEV" submit -a codex -m "test" 2>&1)"
check "codex gets orchestrator prompt"  'cat $HOME/job/orchestrator.md $HOME/job/task.md |' "$out"
countcheck "codex has no --agents flag" 0 '--agents'                                   "$out"

# The remote agent must be told to load the skills we ship it.
eval "$(sed -n '/^RUSER=/,/^RHOME=/p;/^orchestrator()/,/^}/p' "$HDEV")"
check "claude prompt loads efficient-fable" "efficient-fable" "$(orchestrator claude)"
check "codex prompt loads efficient-fable"  "efficient-fable" "$(orchestrator codex)"
check "claude delegates via Agent tool"     "Agent tool"      "$(orchestrator claude)"
check "codex delegates via codex exec"      "codex exec"      "$(orchestrator codex)"
check "status notes live in the job user home" "/home/agent/job/status.md" "$(orchestrator claude)"
check "efficient-fable is shipped by default" "efficient-fable" \
      "$(sed -n 's/^SKILLS=.*:-\(.*\)}"/\1/p' "$HDEV")"

# $HOME inside a double-quoted local string expands on THIS machine, not the VM.
# Remote paths must come from $RHOME, which is a local variable holding the
# remote path.
if grep -nE 'rssh [^|]*"[^"]*\$HOME' "$HDEV" >/dev/null
then echo "FAIL a double-quoted rssh command uses \$HOME (expands locally, not on the VM)"; fail=1
else echo "ok   no locally-expanding \$HOME in remote commands"; fi

# Claude Code refuses --dangerously-skip-permissions as root, so every remote
# agent invocation must drop to the job user.
if [ "$(grep -c "su - \$RUSER -c" "$HDEV")" -ge 2 ]
then echo "ok   ask runs as the job user, not root"
else echo "FAIL a remote agent invocation still runs as root"; fail=1; fi

# Non-root is forced by Claude Code, so the job user must get sudo back --
# otherwise the agent silently cannot install a system dependency.
check "job user gets passwordless sudo" "NOPASSWD:ALL" "$(sed -n '/^prepare_box()/,/^}/p' "$HDEV")"
check "sudoers file is validated"       "visudo -cf"   "$(sed -n '/^prepare_box()/,/^}/p' "$HDEV")"
check "agent is told it has sudo"       "passwordless sudo" "$(orchestrator claude)"

# Resuming without re-passing --agents silently drops the custom subagent roles.
askblock="$(sed -n '/^cmd_ask()/,/^}/p' "$HDEV")"
check "ask re-passes the subagents"      "agents.json"      "$askblock"
check "ask re-passes the system prompt"  "orchestrator.md"  "$askblock"

# Profiles: the generated cloud-init must stay valid YAML and must actually
# include the profile script, or the box silently boots without the toolchain.
eval "$(sed -n '/^PROFILE=/,/^PROFILES=/p;/^userdata()/,/^}$/p' "$HDEV")"
PROFILES="$(dirname "$HDEV")/../profiles"
for prof in base browser docker; do
  PROFILE=$prof
  yaml="$(userdata)"
  if printf '%s' "$yaml" | python3 -c "import sys,yaml; d=yaml.safe_load(sys.stdin); sys.exit(0 if d.get('runcmd') and d.get('write_files') else 1)" 2>/dev/null
  then echo "ok   cloud-init for '$prof' is valid YAML"
  else echo "FAIL cloud-init for '$prof' is not valid YAML"; fail=1; fi
done
PROFILE=browser; check "browser profile is embedded" "playwright" "$(userdata)"
PROFILE=docker;  check "docker profile is embedded"  "get.docker.com" "$(userdata)"
PROFILE=base;    countcheck "base profile adds nothing" 0 "profile.sh" "$(userdata)"
PROFILE=base

# A snapshot must never bake in the subscription token or the checked-out repo.
capblock="$(sed -n '/^capture()/,/^}/p' "$HDEV")"
check "capture scrubs the env file"  ".hdev-env" "$capblock"
check "capture scrubs the work tree" "work"      "$capblock"
check "capture removes the job user" "userdel"   "$capblock"
check "capture aborts if scrub fails" "refusing to capture" "$capblock"
check "snapshot refuses a running job" "still running" "$(sed -n '/^cmd_snapshot()/,/^}/p' "$HDEV")"
# capture() scrubs over SSH and then powers down; a shutdown before it makes the
# scrub unreachable and the capture aborts.
countcheck "image does not shut down before capture" 0 "shutdown" "$(sed -n '/^cmd_image()/,/^}/p' "$HDEV")"

# A forgotten VM bills forever, so the age maths must be right.
eval "$(sed -n '/^secs()/,/^}/p;/^human_age()/,/^}/p' "$HDEV")"
check "secs parses days"    "172800" "$(secs 2d)"
check "secs parses hours"   "14400"  "$(secs 4h)"
check "secs parses minutes" "1800"   "$(secs 30m)"
check "secs parses seconds" "45"     "$(secs 45s)"
check "secs passes bare numbers" "90" "$(secs 90)"
check "human_age formats hours" "2h5m"  "$(human_age 7500)"
check "human_age formats days"  "1d3h"  "$(human_age 97200)"
check "human_age formats minutes" "9m"  "$(human_age 570)"
reapblock="$(sed -n '/^cmd_reap()/,/^}/p' "$HDEV")"
check "reap accepts --max-age"        "--max-age"  "$reapblock"
check "reap kills runaway running jobs" "runaway"  "$reapblock"
check "reap finds untracked VMs"      "untracked"  "$reapblock"
check "ps flags over-age VMs"         "older than" "$(sed -n '/^cmd_ps()/,/^}/p' "$HDEV")"

# Firewall rules must be valid JSON built by a real function, not by a
# multi-line process substitution (bash expands that once per line).
eval "$(sed -n '/^fw_rules()/p' "$HDEV")"
rules="$(fw_rules 203.0.113.7)"
if printf '%s' "$rules" | jq -e '.[0].source_ips[0] == "203.0.113.7/32" and .[0].port == "22"' >/dev/null 2>&1
then echo "ok   fw_rules emits valid JSON for the caller IP"
else echo "FAIL fw_rules JSON is wrong: $rules"; fail=1; fi
if grep -q '<(cat <<' "$HDEV"
then echo "FAIL multi-line process substitution reintroduced (expands once per line)"; fail=1
else echo "ok   no multi-line process substitution"; fi

# The inline subagent definitions must stay valid JSON with all three roles.
agents="$(sed -n '/^agents_json() { cat <<.JSON./,/^JSON$/p' "$HDEV" | sed '1d;$d')"
if printf '%s' "$agents" | jq -e '.implementer.prompt and .tester.prompt and .reviewer.prompt' >/dev/null 2>&1
then echo "ok   agents.json is valid and has 3 roles"
else echo "FAIL agents.json is not valid JSON with implementer/tester/reviewer"; fail=1; fi

check "mode defaults to local" "local"             "$("$HDEV" mode 2>&1)"
"$HDEV" mode hetzner >/dev/null 2>&1
check "mode persists"          "hetzner"           "$("$HDEV" mode 2>&1)"
check "bad mode rejected"      "usage: hdev mode"  "$("$HDEV" mode sideways 2>&1)"

check "bad agent rejected"   "must be claude or codex" "$("$HDEV" submit -a bogus -m hi 2>&1)"
check "empty submit rejected" "usage: hdev submit"     "$("$HDEV" submit 2>&1)"
check "bad flag rejected"     "unknown flag"           "$("$HDEV" submit --nope -m hi 2>&1)"
check "missing plan rejected" "plan file not found"    "$("$HDEV" submit /no/such/plan.md 2>&1)"

rm -rf "$HDEV_STATE_DIR"
exit $fail
