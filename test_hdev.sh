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
# A real job died when its agent ran `kill -TERM <own pid>` while hunting what
# it believed were runaway processes. Every harness needs the warning.
eval "$(sed -n '/^PI_MODEL=/p' "$HDEV")"
for a in claude codex pi; do
  op="$(orchestrator $a)"
  check "$a is warned not to kill processes" "Do not kill processes you did not start" "$op"
  # The prompt is prose and prose has backticks. An unquoted heredoc executes
  # them: `kill` once vanished from this very warning and ran locally.
  check "$a prompt keeps its backticks"      '`kill`, `pkill` or `killall`'            "$op"
  countcheck "$a prompt has no stray placeholders" 0 "@[A-Z]*@"                        "$op"
done
check "prompt heredoc is quoted" "cat <<'MD'" "$(sed -n '/^orchestrator()/,/^}$/p' "$HDEV")"
# Measured: a real job burned 6.3M cache-read tokens for 21.5k output because
# the orchestrator worked in its own context instead of delegating.
oc="$(orchestrator claude)"
check "prompt states the cost model"    "context is the expensive thing" "$oc"
check "prompt explains turns x context" "turns multiplied by"            "$oc"
check "prompt keeps the small-task exception" "Do not delegate a one-line edit" "$oc"
check "submit warns on multi-item briefs" "work items" "$(cat "$HDEV")"
# A quota error was once reported as an "unsupported server type", confidently
# and wrongly. Show what Hetzner actually said.
bootblk="$(sed -n '/^boot()/,/^}$/p' "$HDEV")"
check "boot surfaces the real error"   "could not create \$name"  "$bootblk"
check "boot names a quota problem"     "server limit and it is full" "$bootblk"
check "type listing reads the right column" 'printf "%s ", $5'    "$bootblk"
check "submit always reports capacity" "VMs already running"      "$(cat "$HDEV")"
check "submit warns before booting N"  "later slices fail"        "$(cat "$HDEV")"
check "prompt cites the real measurement" "6,311,012"                    "$oc"
check "strict mode is available"        "HDEV_STRICT"                    "$(cat "$HDEV")"
check "strict mode removes edit tools"  "disallowed-tools Edit,Write"    "$(cat "$HDEV")"

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

# The job script is generated as a heredoc, so a syntax error in it would only
# surface on a real VM. Extract and check it here instead.
awk '/^runner\(\) \{ cat <</,/^BASH$/' "$HDEV" | sed '1d;$d' > "$HDEV_STATE_DIR/runner.sh"
if bash -n "$HDEV_STATE_DIR/runner.sh" 2>/dev/null
then echo "ok   generated job script is valid bash"
else echo "FAIL generated job script has a syntax error"; fail=1; fi

# Usage limits need different handling: session resets in hours and is worth
# waiting for; weekly resets in days; an Opus limit is bypassed by model choice.
rn="$(cat "$HDEV_STATE_DIR/runner.sh")"
check "waits on the session limit"        "hit your session limit" "$rn"
check "refuses to wait out a weekly limit" "Not waiting"           "$rn"
check "names the Opus limit separately"    "Opus usage limit"      "$rn"
check "never sleeps on an unknown reset"   "not sleeping blind"    "$rn"
check "resume uses the job's own harness"  "RESUME_CMD"            "$rn"
check "claude resume continues the session" "--continue"           "$(cat "$HDEV")"
check "reset time comes from a real clock" "ccusage"               "$rn"
countcheck "only one sleep in the runner" 1 "^ *sleep " "$rn"

# A job asleep waiting for a usage window must not be mistaken for a runaway.
check "runner marks itself while waiting" "job/waiting" "$rn"
check "status reports waiting distinctly" "waiting-on-limit" "$(sed -n '/^job_status()/,/^}/p' "$HDEV")"
check "reap spares a waiting job"         "waiting for its usage window" "$(sed -n '/^cmd_reap()/,/^}/p' "$HDEV")"

# Usage reporting must survive the VM being deleted.
reapblk="$(sed -n '/^cmd_reap()/,/^}/p' "$HDEV")"
countcheck "reap captures usage before deleting" 2 "usage_row" "$reapblk"

# Every path that deletes a VM must capture its usage first, or the record dies
# with the box. This was found by a cleanup that went around reap.
check "nuke captures usage too" "usage_row" "$(sed -n '/^cmd_nuke()/,/^}/p' "$HDEV")"

# Untracked files (.env) must be explicit, validated early, and unpacked on the box.
check "--env rejects a missing file" "--env file not found" "$("$HDEV" submit -e /no/such/.env -m hi 2>&1)"
check "runner unpacks sent files"    "envfiles.tgz"         "$(cat "$HDEV_STATE_DIR/runner.sh")"
check "runner says what it restored" "restored and git-excluded" "$(cat "$HDEV_STATE_DIR/runner.sh")"
# A sent secret must never be committable, whatever the repo's .gitignore says.
rnr="$(cat "$HDEV_STATE_DIR/runner.sh")"
check "sent files are git-excluded on the box" ".git/info/exclude" "$rnr"
check "env patterns excluded as a backstop"    "'.env.*'"          "$rnr"
check "key material excluded too"              "'*.pem'"           "$rnr"
subblk="$(sed -n '/^cmd_submit()/,/^}/p' "$HDEV")"
check "sending is announced"         "sent to the VM"       "$subblk"
# macOS tar writes ._ AppleDouble sidecars; .env.local is gitignored but
# ._.env.local is not, so git add -A on the box would commit it into the PR.
check "no AppleDouble sidecars sent"  "COPYFILE_DISABLE=1"   "$subblk"
countcheck "env files are never inferred" 0 'envfiles+=.*\.env' "$subblk"

# The skill must cover the things a real run tripped over.
sk="$(cat "$(dirname "$HDEV")/../skills/hetzner-dev/SKILL.md")"
check "skill requires naming jobs"       "Always name the job"     "$sk"
check "skill asks before sending env"    "never inferred"          "$sk"
check "skill forbids printing secrets"   "Never print the contents" "$sk"
check "skill builds a profile first run" "First run in a project"  "$sk"
check "skill reads CI for dependencies"  "CI workflow"             "$sk"
check "skill warns base has no browser"  "no browser"              "$sk"
check "skill flags the pi usage gap"     "does not cover \`pi\` jobs" "$sk"
check "skill explains the DELEG column"  "DELEG"                   "$sk"
check "skill flags zero delegation"      "0/0%"                    "$sk"
# The five-part slice spec and the verification checklist come from
# fast-efficient, which measured them. Keep them in sync, not paraphrased.
check "slice spec wants a baseline"      "exact numbers it must print" "$sk"
check "slice spec wants failing tests"   "already exist and already fail" "$sk"
check "slice spec wants a closed file list" "closed list of files"     "$sk"
check "slice spec wants a verbatim contract" "not described"           "$sk"
check "slice spec respects the output limit" "16.4K maximum output"    "$sk"
check "review treats output as a claim"  "claim, not a result"         "$sk"
check "review checks tests untouched"    "never edit a test"           "$sk"
check "cerebras key is shipped"          "CEREBRAS_API_KEY"            "$(sed -n '/^ship_secrets()/,/^}/p' "$HDEV")"
# The provider choice must be the user's, explicit, and persistent.
MD_STATE="$(mktemp -d)"
check "model --list shows both providers" "cerebras"   "$("$HDEV" model --list 2>&1)"
check "model --list shows openrouter"     "openrouter" "$("$HDEV" model --list 2>&1)"
check "model --list states the trade-off" "Cerebras is fastest" "$("$HDEV" model --list 2>&1)"
check "model --list warns on output cap"  "16.4K max output"    "$("$HDEV" model --list 2>&1)"
HDEV_STATE_DIR="$MD_STATE" "$HDEV" model openrouter/qwen/qwen3-coder >/dev/null 2>&1
check "model choice persists"             "qwen3-coder" "$(HDEV_STATE_DIR="$MD_STATE" "$HDEV" model 2>&1)"
check "saving names the provider"         "provider: openrouter" "$(HDEV_STATE_DIR="$MD_STATE" "$HDEV" model openrouter/qwen/qwen3-coder 2>&1)"
rm -rf "$MD_STATE"
check "skill makes setup a user decision" "Ask; do not pick silently" "$sk"
check "skill states the provider trade-off" "OpenRouter has far more" "$sk"
# A pi-only user must not have to type -a pi on every submit, and plain
# `hdev login` must not abort just because there is no Claude subscription.
AG_STATE="$(mktemp -d)"
check "default agent is claude"        "claude" "$(HDEV_STATE_DIR="$AG_STATE" "$HDEV" agent 2>&1)"
HDEV_STATE_DIR="$AG_STATE" "$HDEV" agent pi >/dev/null 2>&1
check "agent choice persists"          "pi"     "$(HDEV_STATE_DIR="$AG_STATE" "$HDEV" agent 2>&1)"
check "saved agent is used by submit"  "agent=pi" "$(HDEV_STATE_DIR="$AG_STATE" "$HDEV" submit -m t 2>&1)"
check "bad agent name rejected"        "usage: hdev agent" "$(HDEV_STATE_DIR="$AG_STATE" "$HDEV" agent nope 2>&1)"
rm -rf "$AG_STATE"
check "login survives no subscription" "skipping Claude" "$(cat "$HDEV")"
# Resuming after a usage limit must use the harness the job actually runs.
for a in claude codex pi; do
  check "$a has a resume command" "$a" "$(sed -n '/RESUME_CMD=/p' "$HDEV")"
done
check "resume is passed to the job"    "setenv=RESUME_CMD" "$(cat "$HDEV")"
check "boot waits for the right harness" "WAIT_FOR" "$(cat "$HDEV")"
# claude-pi is a strategy, not a binary — waiting for `command -v claude-pi`
# stranded a VM that never became reachable.
check "readiness probe uses a real binary" 'WAIT_FOR="${agent%%-*}"' "$(cat "$HDEV")"
# claude-pi: frontier model plans and reviews, pi writes the code.
check "claude-pi runs a claude command" "cmd=claude" "$("$HDEV" submit -a claude-pi -m t 2>&1)"
check "claude-pi gets the subagents"    "agents.json" "$("$HDEV" submit -a claude-pi -m t 2>&1)"
ocp="$(orchestrator claude-pi)"
check "claude-pi delegates code to pi"  "pi -p --model"          "$ocp"
check "claude-pi reserves subagents"    "never for writing code" "$ocp"
# Code shipped without docs once already; assert every harness is documented.
for h in claude-pi pi codex; do
  check "skill documents $h"  "$h" "$sk"
  check "readme documents $h" "$h" "$(cat "$(dirname "$HDEV")/../README.md")"
done
countcheck "claude-pi prompt is not mangled" 0 "the slice>. " "$ocp"
# pi on an anthropic model authenticates with the Claude subscription token.
ss="$(sed -n '/^ship_secrets()/,/^}/p' "$HDEV")"
check "pi+anthropic uses the subscription" "CLAUDE_CODE_OAUTH_TOKEN" "$ss"
# Setting ANTHROPIC_API_KEY in a claude-pi job overrides the ORCHESTRATOR's
# subscription token and produced a live "401 API key is invalid".
check "pure pi gets ANTHROPIC_API_KEY"     "pi/anthropic*)"          "$ss"
check "claude-pi gets a separate variable" "PI_ANTHROPIC_KEY"        "$ss"
countcheck "claude-pi never exports ANTHROPIC_API_KEY" 1 "claude-pi/anthropic" "$ss"
check "prompt passes the key inline"       "PI_ANTHROPIC_KEY pi -p" "$ocp"
check "prompt forbids exporting it"        "never export it"         "$ocp"
psb="$(sed -n '/^cmd_ps()/,/^}$/p' "$HDEV")"
check "ps has a delegation column"       "DELEG"                   "$psb"
check "ps skips deleg for dead jobs"     "gone|unreachable"        "$psb"
check "delegation probe recurses subagents" "recursive=True"       "$(sed -n '/^job_delegation()/,/^}$/p' "$HDEV")"
# A finished job is still usable: reaping is the last step, not the first.
check "skill keeps finished jobs alive"  "still a collaborator"     "$sk"
check "skill reaps last, not first"      "Reap last, not first"     "$sk"
check "skill warns -c can be acted on"   "for the work, not for the machine" "$sk"
check "skill defines idle enough"        "idle enough"              "$sk"
# ps must expose idle so a loop can judge when a job is safe to close out.
psblk="$(sed -n '/^cmd_ps()/,/^}$/p' "$HDEV")"
check "ps has an idle column"            "IDLE"                     "$psblk"
check "idle is only asked for settled jobs" "running|starting|gone|unreachable" "$psblk"
check "idle survives a failed probe"     "|| true"                  "$psblk"

# The pi harness: a third agent on a model-agnostic backend.
out="$("$HDEV" submit -a pi -m "test" 2>&1)"
check "pi uses the configured model"  "openrouter/deepseek/deepseek-v4-flash" "$out"
check "pi loads the shipped skill"    "--skill \$HOME/.claude/skills/efficient-fable" "$out"
check "pi takes the brief on stdin"   "< \$HOME/job/task.md"     "$out"
out="$(HDEV_PI_MODEL=openrouter/anthropic/claude-sonnet-4 "$HDEV" submit -a pi -m t 2>&1)"
check "pi model is overridable"       "openrouter/anthropic/claude-sonnet-4" "$out"
check "three agents are offered"      "claude, claude-pi, codex or pi" "$("$HDEV" submit -a bogus -m t 2>&1)"
eval "$(sed -n '/^PI_MODEL=/p;/^orchestrator()/,/^}$/p' "$HDEV")"
check "pi is told it has no subagent tool" "no subagent tool" "$(orchestrator pi)"
check "pi delegates via subprocess"        "pi -p --model"    "$(orchestrator pi)"
check "openrouter key is shipped"     "OPENROUTER_API_KEY" "$(sed -n '/^ship_secrets()/,/^}/p' "$HDEV")"
check "pi is installed on the box"    "pi-coding-agent"    "$(sed -n '/^userdata()/,/^}$/p' "$HDEV")"
# pi prefers its own auth.json over the env var, so a stale env var wins locally
# and 401s on the box. Capture the real credential, and only for one provider.
whole="$(cat "$HDEV")"
check "login captures pi credentials"  "PIAUTH"             "$whole"
check "only one provider is shipped"   "that provider only" "$whole"
check "pi auth is shipped to the box"  ".pi/agent/auth.json" "$(sed -n '/^ship_secrets()/,/^}/p' "$HDEV")"

# A new user has no snapshot, so the cold path is the FIRST thing they hit.
# It referenced an unassigned $SNAPSHOT and crashed under `set -u`.
bootsrc="$(sed -n '/^boot()/,/^}$/p' "$HDEV")"
countcheck "cold path uses no unassigned vars" 0 'SNAPSHOT' "$bootsrc"
check "cold path names the profile"    "no snapshot for profile" "$bootsrc"
check "cold path says it still works"  "provisioning from scratch" "$bootsrc"
# Every variable the script reads must be assigned somewhere.
for v in $(grep -oE '\$\{?[A-Z][A-Z0-9_]{2,}' "$HDEV" | tr -d '${' | sort -u); do
  case "$v" in HOME|PATH|PWD|BASH_SOURCE|PIPESTATUS|IFS|OLDPWD|SHELL|USER|TERM|LANG|LC_ALL|COPYFILE_DISABLE|GH_TOKEN|OPENAI_API_KEY|OPENROUTER_API_KEY|CEREBRAS_API_KEY|SAVED_PI_MODEL|SAVED_AGENT|PI_ANTHROPIC_KEY|WAIT_FOR|RESUME_CMD|ANTHROPIC_API_KEY|ANTHROPIC_BASE_URL|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_MODEL|CLAUDE_CODE_OAUTH_TOKEN|HCLOUD_TOKEN|HDEV_*|PLAYWRIGHT_BROWSERS_PATH|NODE_PATH|JOB_IDLE|MD|JSON|YAML|BASH|PY) continue ;; esac
  # injected into the remote job by systemd-run --setenv, so they are
  # deliberately not assigned on this side
  case "$v" in BRANCH|TITLE|BASE_REF|AGENT_CMD|NWO|REPO_URL|OUT|LIMIT_RETRIES|PI_PROVIDER) continue ;; esac
  case "$v" in HDEV*) continue ;; esac
  grep -qE "^ *(local +)?$v=|^ *$v=" "$HDEV" || { echo "FAIL \$$v is read but never assigned"; fail=1; }
done
echo "ok   every uppercase variable read is also assigned"

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
{ sed -n '/^WORKER_MODEL=/p;/^REVIEWER_MODEL=/p' "$HDEV"
  awk '/^agents_json\(\) \{ cat <</,/^JSON$/' "$HDEV"; echo '}'; echo 'agents_json'
} > "$HDEV_STATE_DIR/aj.sh"
agents="$(bash "$HDEV_STATE_DIR/aj.sh" 2>/dev/null)"
if printf '%s' "$agents" | jq -e '.implementer.prompt and .tester.prompt and .reviewer.prompt and .researcher.prompt' >/dev/null 2>&1
then echo "ok   agents.json is valid with all four roles"
else echo "FAIL agents.json is not valid JSON with the expected roles"; fail=1; fi
# Delegation has to be cheaper per token, not just smaller per context.
if printf '%s' "$agents" | jq -e '[.implementer,.tester,.researcher|.model]|all(.=="haiku")' >/dev/null 2>&1
then echo "ok   workers run on the cheap model"
else echo "FAIL workers are not on the cheap model"; fail=1; fi
if printf '%s' "$agents" | jq -e '.reviewer.model=="sonnet"' >/dev/null 2>&1
then echo "ok   reviewer keeps a capable model"
else echo "FAIL reviewer model is wrong"; fail=1; fi
if printf '%s' "$agents" | jq -e '(.researcher.tools|index("Edit"))==null and (.researcher.tools|index("Write"))==null' >/dev/null 2>&1
then echo "ok   researcher is read-only"
else echo "FAIL researcher can modify files"; fail=1; fi
check "worker model is overridable"   "HDEV_WORKER_MODEL"   "$(cat "$HDEV")"
check "reviewer model is overridable" "HDEV_REVIEWER_MODEL" "$(cat "$HDEV")"

check "mode defaults to local" "local"             "$("$HDEV" mode 2>&1)"
"$HDEV" mode hetzner >/dev/null 2>&1
check "mode persists"          "hetzner"           "$("$HDEV" mode 2>&1)"
check "bad mode rejected"      "usage: hdev mode"  "$("$HDEV" mode sideways 2>&1)"

check "bad agent rejected"   "must be claude, claude-pi, codex or pi" "$("$HDEV" submit -a bogus -m hi 2>&1)"
check "empty submit rejected" "usage: hdev submit"     "$("$HDEV" submit 2>&1)"
check "bad flag rejected"     "unknown flag"           "$("$HDEV" submit --nope -m hi 2>&1)"
check "missing plan rejected" "plan file not found"    "$("$HDEV" submit /no/such/plan.md 2>&1)"

rm -rf "$HDEV_STATE_DIR"
exit $fail
