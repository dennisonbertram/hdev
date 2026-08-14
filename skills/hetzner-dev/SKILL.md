---
name: hetzner-dev
description: Plan work here, then hand the slices to agents running on Hetzner VMs so the work continues after the laptop closes. Use when the user asks to build, implement, fix, refactor or ship something and wants it to run remotely or in the background, says "on Hetzner", "hand it off", "run it remotely", "keep working while I'm away", or invokes /hetzner-dev.
metadata:
  author: dennisonbertram
  version: "1.0.0"
  argument-hint: <plan.md | -m "task">
allowed-tools: Bash(hdev *) Bash(git status*) Bash(git fetch*) Bash(git log*) Bash(git diff*) Bash(git push*) Bash(gh pr *) Read Write Glob Grep
---

# Plan here, build there

You do the thinking on this machine. A separate agent — Claude Code or Codex,
installed on a Hetzner VM — does the building. Each slice of the plan gets its
own VM, its own branch and its own PR. The job runs under systemd on the VM, so
it keeps going after the SSH session ends and after the laptop closes.

Do not use this to drive a remote machine step by step. The handoff is one-shot:
the remote agent gets a written brief and the repo, and nothing else.

## Procedure

### 1. Plan on this machine

Explore the codebase here, where it is cheap, and write the plan to a file.
This is the normal planning work — read the code, find the real seams, decide
the approach.

### 2. Slice the plan

Write the plan with one `## Slice:` heading per independently shippable piece:

```markdown
# Rate limiting rollout

## Slice: Add the token bucket
Implement a token bucket in `lib/ratelimit.ts`. 60 requests per minute per key.
Done when: `npm test lib/ratelimit.test.ts` passes.

## Slice: Wire /api/send
Call the bucket in `app/api/send/route.ts` before the handler. Return 429 with
a Retry-After header when the bucket is empty.
Done when: the new integration test passes.
```

Rules for slices:

- **Each slice is a self-contained brief.** The remote agent has no memory of
  this conversation. Name the files, state the approach, state what "done"
  means. A slice that says "as discussed" will fail.
- **Slices must not depend on each other.** They run in parallel on separate
  VMs from the same base commit and produce separate PRs. Work that must be
  sequential belongs in one slice, or in a later submit after the first merges.
- **No secrets in the text.** Tokens reach the VM over SSH separately.

### 3. Check the repo state, then submit

`hdev` clones from the GitHub remote, so anything uncommitted here is invisible
to the remote agent. Run `git status` first and tell the user if the tree is
dirty or the branch is unpushed.

```bash
hdev submit plan.md                 # one VM per slice, Claude Code
hdev submit -a codex plan.md        # same, using Codex
hdev submit -1 plan.md              # whole file as one job
hdev submit -m "raise the upstream timeout to 30s"   # no plan file
```

Flags: `-b <prefix>` to prefix branch names, `-t cpx32` for a bigger VM,
`-p <profile>` to boot from a snapshot that already has the toolchain.

Check `hdev images` before submitting. If the work needs a browser, submit with
`-p browser` rather than letting the agent install Chromium on every job. If it
needs Docker, use `-p docker`. Naming a profile that has not been built fails,
so list them first.

`submit` returns as soon as the jobs start. Tell the user they can close the
laptop, and give them the job names.

### 4. Talk to the remote agent while it works

The remote agent runs as an orchestrator: it delegates to `implementer`,
`tester` and `reviewer` subagents and keeps its own progress notes. You can
reach it at any time.

```bash
hdev status <job>                    # the orchestrator's own notes, cheapest
hdev ask <job> "<question>"          # ask it, with its full context
hdev ask -c <job> "<instruction>"    # tell it something; it acts on this
hdev logs [-f] <job>                 # raw output, when the above is not enough
```

Reach for these in that order. `hdev status` costs nothing and usually answers
"how is it going". `hdev ask` forks the job's conversation, so the remote agent
answers with everything it knows and its own thread is untouched — safe to use
while the job is running. `hdev ask -c` continues the real thread instead, so
use it only to change what the agent is doing.

When the user asks how remote work is going, run `hdev ps` first, then
`hdev status` on the job they care about. Quote the agent's own words; do not
paraphrase progress you have not read.

### 5. Collect the result

```bash
hdev ps                # running / done / failed, per job
hdev ssh <job>         # get on the box, repo is at /work
hdev reap              # delete the VMs of finished jobs
```

A finished job has already pushed its branch and opened a PR. Review the PR,
do not assume it is correct. `hdev reap` is what stops the VMs from billing —
say so when reporting that jobs are done.

## Failure handling

- `hdev ps` shows `failed` — read `hdev logs <job>`. The VM stays up so the
  evidence survives. Fix the brief and submit a new job; do not try to resume
  the old one.
- No PR appeared but the job says `done` — the agent made no changes, or the
  push worked and `gh pr create` did not. `hdev logs <job>` says which.
- `unreachable` — the firewall allows SSH only from the public IP you had at
  submit time. On a new network, `hdev submit` anything to refresh the rule.

## Turning a job's box into a reusable profile

When a project needs a toolchain no existing profile has, do not make every job
install it. Set one box up, then capture it:

```bash
hdev submit -k -m "install <the toolchain> and prove each part works"
hdev snapshot <job> <profile-name>
hdev submit -p <profile-name> plan.md
```

`-k` keeps the VM after the job. `hdev snapshot` scrubs credentials and the work
tree before capturing, and refuses while the job is still running.

Hetzner allows 30 snapshots across all projects, so retire profiles you no
longer use rather than accumulating them.

## Setup checks

If `hdev submit` fails immediately:

- `hcloud context active` — needs a Hetzner API token.
- `gh auth status` — needs `repo` scope; the remote agent pushes with it.
- `hdev login status` — shows whether subscription credentials are captured.
  `hdev login` captures them; the remote agents then bill the subscription
  rather than the API.
- `hdev image` builds the base snapshot once. Without it every job installs the
  toolchain at boot: about 3 minutes per VM instead of about 40 seconds (measured 39 s, n=1).

Do not set `ANTHROPIC_API_KEY` if you want subscription billing — inside Claude
Code it takes precedence over the subscription token. `hdev` drops it from the
job environment when a subscription token exists.
