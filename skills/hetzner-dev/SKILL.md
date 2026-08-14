---
name: hetzner-dev
description: Plan work here, then hand the slices to agents running on Hetzner VMs so the work continues after the laptop closes. Use when the user asks to build, implement, fix, refactor or ship something and wants it to run remotely or in the background, says "on Hetzner", "hand it off", "run it remotely", "keep working while I'm away", or invokes /hetzner-dev.
metadata:
  author: dennisonbertram
  version: "1.0.0"
  argument-hint: <plan.md | -m "task">
allowed-tools: Bash(hdev*) Bash(hcloud*) Bash(command -v*) Bash(git clone*) Bash(mkdir -p*) Bash(ln -sfn*) Bash(zsh -lic*) Bash(bash -lic*) Bash(git status*) Bash(git fetch*) Bash(git log*) Bash(git diff*) Bash(git push*) Bash(gh pr *) Read Write Glob Grep Skill
---

# Plan here, build there

You do the thinking on this machine. A separate agent — Claude Code or Codex,
installed on a Hetzner VM — does the building. Each slice of the plan gets its
own VM, its own branch and its own PR. The job runs under systemd on the VM, so
it keeps going after the SSH session ends and after the laptop closes.

Do not use this to drive a remote machine step by step. The handoff is one-shot:
the remote agent gets a written brief and the repo, and nothing else.

## Before anything else: is `hdev` installed?

Installing this skill does **not** install the CLI it drives. Run this first,
every session, before promising the user anything:

```bash
command -v hdev
```

If that prints a path, skip to the Procedure. If it prints nothing, install it
now — do not try to work around a missing `hdev`:

```bash
git clone https://github.com/dennisonbertram/hdev ~/develop/hdev
```

Then put it on PATH. Try a directory that is already there, so no shell profile
needs editing:

```bash
mkdir -p ~/.local/bin && ln -sfn ~/develop/hdev/bin/hdev ~/.local/bin/hdev
```

That only works if `~/.local/bin` is on PATH. Check, and fall back to the shell
profile if it is not:

```bash
case ":$PATH:" in
  *":$HOME/.local/bin:"*) echo "on PATH — done" ;;
  *) echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
     echo "added to ~/.zshrc — tell the user to open a new terminal" ;;
esac
```

Confirm before continuing, in a login shell rather than the current one, because
the current shell may have a PATH the user's next terminal will not:

```bash
zsh -lic 'command -v hdev && hdev mode'
```

If the user runs bash, use `~/.bashrc` and `bash -lic` instead.

Writing to a shell profile is deliberately **not** pre-approved in this
skill's `allowed-tools`, so the user is asked before it happens. Do not work
around that prompt, and tell them which file you are editing.

## First run in a project: build it a profile

The base image has node, git, gh and the agents. It has **no browser, no Docker,
no Python, no Bun**. A job needing those will report itself blocked, and the
user finds out after waiting rather than before.

So the first time this skill is used in a repository, spend two minutes getting
the environment right. Do this once per project, not once per job.

**1. Read what the project actually needs.** Look, do not assume:

| Look at | What it tells you |
| --- | --- |
| `package.json` scripts, lockfile name | npm / pnpm / yarn / bun |
| `playwright.config.*`, `cypress.config.*`, `@playwright/test` | needs a browser |
| `Dockerfile`, `docker-compose.yml`, testcontainers | needs Docker |
| `pyproject.toml`, `requirements.txt`, `Gemfile`, `go.mod`, `Cargo.toml` | another toolchain |
| CI workflow `runs-on` and setup steps | the real answer — CI already lists the dependencies |

The CI workflow is the most reliable source. It is the list someone already had
to get right.

**2. Check what profiles exist.** `hdev images`. If one already covers it, use
it with `-p` and stop here.

**3. Otherwise build one.** For a browser or Docker, the shipped profiles cover
it. For anything else, let a job install it and capture the result:

```bash
hdev submit -k -b setup -m "Install <exact toolchain> so this project's test
suite runs. Then run the suite and report the command and the pass/fail counts.
Change no repository files."
hdev snapshot <job> <project-name>     # once it reports success
hdev submit -p <project-name> plan.md  # every later job starts there
```

`-k` keeps the VM so it can be captured. `hdev snapshot` scrubs credentials and
the work tree first, and refuses while the job is still running.

**4. Tell the user what you built and what it does not cover.** Name the
profile and say which of their suites still cannot run on it.

Do not skip to submitting real work on the base image and then report a pile of
"could not verify" results. Getting the environment right first is cheaper than
a job that runs for ten minutes and verifies nothing.

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

### Always name the job

**Pass `-b <short-name>` on every submit.** Without it, jobs are named from the
first words of the task and become unreadable — `hdev-agent-0814-1357-add-src-t`
tells you nothing when four are running. The name flows into the job name, the
branch and the PR.

```bash
hdev submit -b epic473 plan.md      # → hdev-epic473-…, branch epic473/…
```

Use whatever the user already calls the work: a ticket id, an epic number, a
feature name. Short, lowercase, no spaces. When you submit several slices at
once give them one shared prefix so they read as a set. Tell the user the names
you chose — they need them for `hdev status`, `hdev ask` and `hdev logs`.

Other flags: `-t cpx32` for a bigger VM, `-p <profile>` to boot from a snapshot
that already has the toolchain, `-e <file>` to send an untracked file.

Check `hdev images` before submitting. If the work needs a browser, submit with
`-p browser` rather than letting the agent install Chromium on every job. If it
needs Docker, use `-p docker`. Naming a profile that has not been built fails,
so list them first.

`submit` returns as soon as the jobs start. Tell the user they can close the
laptop, and give them the job names. Then offer to watch the jobs for them —
see "Watching jobs without babysitting them" below.

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

## Choosing the agent

Three harnesses. Pick per job, and say why you picked it.

```bash
hdev submit -b epic1 plan.md            # Claude Code (default)
hdev submit -a pi -b epic1 plan.md      # pi harness, DeepSeek V4 Flash
hdev submit -a codex -b epic1 plan.md   # Codex
```

| | Claude Code | pi |
| --- | --- | --- |
| Model | your Claude subscription | any, via OpenRouter — default DeepSeek V4 Flash |
| Cost | subscription window | metered, roughly $0.14/M in and $0.28/M out |
| Subagents | real, enforced by `--agents` | none — it delegates by invoking itself |
| Ask a running job | safe, forks the session | not safe; `hdev ask` refuses until it finishes |
| Usage limits | shares your 5-hour window | none |

**Use `pi` when** the work is mechanical and well-specified — a scripted
migration, a rename across many files, adding tests to existing code, a
repetitive fix. Also use it when your Claude session window is nearly spent and
the work can wait no longer, since pi does not touch that window at all.

**Use Claude when** the job needs judgement: ambiguous briefs, architecture,
anything where a wrong-but-plausible answer is expensive. Its enforced
subagents and safe mid-run questioning matter most exactly there.

**Say which you chose and why.** "This is a mechanical rename across 40 files,
so I sent it to pi on DeepSeek — it will not touch your Claude window" is the
kind of sentence the user wants.

Override the model with `HDEV_PI_MODEL`, which takes any OpenRouter id:

```bash
HDEV_PI_MODEL=openrouter/qwen/qwen3-coder hdev submit -a pi plan.md
```

`pi` needs `OPENROUTER_API_KEY`. `hdev` refuses to submit without it rather
than booting a VM that cannot work.

## A finished job is still a collaborator

**`done` does not mean disposable.** The VM stays up, the agent's session is
intact, and the work tree is exactly as it left it. Until you reap, you can send
it back for changes — and it still has all its context, which a fresh job never
would.

So the lifecycle is not submit → done → reap. It is:

```
submit → done → review the PR → ask for changes → review again → reap
```

**Reap last, not first.** Once the VM is gone the agent is gone with it, and a
follow-up means a new job that has to rediscover everything.

### Sending work back

```bash
hdev ask <job>  "why did you skip the error path in send()?"   # question, safe
hdev ask -c <job> "add the missing error path and push again"  # instruction
```

`-c` continues the real conversation, so the agent acts: it edits, commits and
pushes to the same branch, and the PR updates. That is the whole point — it is
cheaper and better than opening a second job, because it remembers the reasoning
behind what it wrote.

Review the diff yourself before asking for changes. `gh pr diff <n>`. Do not
relay the agent's own summary back to the user as if you had checked it.

### One hazard, learned the hard way

`-c` injects an instruction into a working agent, and the agent may act on it in
ways you did not intend. A real job died this way: an operator note prompted the
agent to investigate what it thought were runaway processes, and it ran
`kill -TERM` on its own pid. The job ended mid-work.

So: **`-c` is for the work, not for the machine.** Ask for code changes. Never
ask an agent to inspect, clean up, or kill processes. `hdev ask` without `-c`
and `hdev status` cannot change anything and are always safe.

## Watching jobs and closing them out

Offer the user a loop that runs the whole cycle, not just a status poll:

```
/loop 10m check my hdev jobs, review anything new, and close out what is done
```

**Each tick:**

1. `hdev ps` — status, VM age, and **idle**: how long since anyone last spoke to
   that agent.
2. **Still running?** Nothing to do. Say nothing if nothing changed.
3. **Newly `done`?** Read the PR diff. Say what landed and what is missing. If
   the user wants changes, `hdev ask -c` and keep the job alive.
4. **`failed`?** `hdev logs <job>`. The VM stays up so the evidence survives.
5. **Done, reviewed, no changes pending, and idle for a while?** Only then
   `hdev reap`. Tell the user which VMs you are deleting and that their agents
   go with them.

**What "idle enough" means.** Idle counts from the last interaction, so asking a
question resets it. Do not reap a job the user is still talking to. Twenty
minutes idle with the PR reviewed and nothing outstanding is a reasonable bar;
when in doubt ask, because reaping is irreversible and keeping a VM costs about
four cents an hour.

**Stop the loop** once every job is reaped. A loop ticking over an empty job
list is pure noise.

## Interval guidance

Once jobs are submitted the user should not have to keep asking. For reference:

```
/loop 10m check my hdev jobs and tell me what changed
```

Dynamic mode is better when the job length is unknown, because it wakes on the
event rather than on a timer:

```
/loop check my hdev jobs and tell me when they finish
```

**What to do on each tick:**

1. `hdev ps` — every job, its status, its VM age.
2. For any job whose status changed since the last tick, `hdev status <job>`
   and summarise what moved.
3. **Say nothing new when nothing changed.** A tick that reports "still
   running" for the third time is noise. Report the change, or stay quiet.
4. When every job has settled: give the PR links, say whether the branches were
   pushed, and remind the user that `hdev reap` is what stops the billing.
   Then stop the loop — do not keep ticking over finished work.

**Never call `hdev ask` on a tick.** `ps` and `status` are free: one SSH round
trip and a file read. `ask` is a model call on the remote box, and it gets
slower as the job's context grows — measured at 4.6 s early in a job and
1 minute 1 second late in the same job. Use `ask` when the user actually has a
question, not on a schedule.

**Interval:** most jobs finish in 2–15 minutes. `10m` is a sensible default and
`5m` is a reasonable floor. Below that you are paying SSH round trips to learn
nothing. A `/loop` runs only until the session closes; for anything longer the
user wants `/schedule`.

## Untracked files the VM will not have

`hdev` clones from GitHub, so anything untracked or gitignored — `.env`,
`.env.local`, local certs, fixture data — **is not on the VM**. A suite that
needs them will fail there and the agent will report itself blocked.

You can send them explicitly:

```bash
hdev submit -e .env.local -e .env.test plan.md
```

Paths are relative to the repo root, the flag repeats, and the files land in
the work tree after the clone.

**Sending is deliberate, never inferred. Ask every time.**

1. Name the exact files, one per line, and say which suite needs each one.
2. Say what is in them if you know — "this holds your Stripe test key".
3. Wait for an explicit yes. A previous yes does not carry to the next submit.
4. Never add `-e` because a test failed. Never guess at `.env` from a filename.
5. Never print the contents of these files, to the user or into a brief.

These usually hold real credentials — database passwords, payment keys,
production tokens — and the VM runs an agent with permissions fully open and a
live network.

On the VM, every sent file is added to `.git/info/exclude` along with `.env`,
`.env.*`, `*.pem` and `*.key`. That is per-clone and never committed, so a sent
secret cannot be staged by `git add -A` and end up in the PR — even if the
repository's own `.gitignore` does not cover it.

If the user declines, that is a fine outcome: tell the agent in the brief which
suites it cannot run, and have it report them as unverified rather than
guessing or stubbing them out.

Two things that are already safe: the files travel over SSH after boot, never
through cloud-init; and `hdev snapshot` scrubs the whole work tree before
capturing, so a sent `.env` cannot end up baked into a profile image.

## Keeping jobs cheap

Two things drive cost, and only one of them is about delegation.

**1. One job per unit of work.** Cost is turns multiplied by context size, and
context only grows. A measured job here carried ten issues in one brief, ran
169 turns, and spent 6,311,012 cache-read tokens for 21,529 output tokens. Ten
slices would have been ten small contexts running in parallel — cheaper and
faster. `hdev submit` warns when a single brief looks like several work items.
Slice by issue unless the pieces genuinely cannot be separated.

**2. The workers are already cheap; leave them that way.** `hdev` defines four
subagents and sets their models: `implementer`, `tester` and `researcher` run on
haiku, `reviewer` on sonnet, because judgement is worth paying for and reading
files is not. Override with `HDEV_WORKER_MODEL` and `HDEV_REVIEWER_MODEL`. Tools
are scoped per role too — `researcher` is read-only and cannot modify anything.

You do not need to tell the agent to use `efficient-fable` or to delegate; the
job already ships with the skill and the cheap subagents configured. What you
control is the size of the brief.

### When a job still feels expensive

Measure before theorising:

```bash
hdev ssh <job>
f=$(ls -t ~/.claude/projects/*/*.jsonl | head -1)
grep -c '"role":"assistant"' "$f"                       # turns
grep -o '"name":"[A-Za-z]*"' "$f" | sort | uniq -c | sort -rn | head
```

Many turns and no `Agent` calls means the orchestrator did everything itself.
The lever is a smaller brief first. If that is not enough:

```bash
HDEV_STRICT=1 hdev submit -b epic1 plan.md
```

Strict mode removes `Edit`, `Write` and `NotebookEdit` from the orchestrator so
it cannot write code itself. Reach for it after slicing, not instead of it.

## Seeing what the jobs cost

```bash
hdev usage
```

Per-job output tokens read from each box's own transcript, plus this machine's
current 5-hour block. Report the figure as **API-equivalent** — what those
tokens would have cost on the API. On a subscription it is a size comparison,
not a bill. Never call it a charge.

A job's usage record lives on its VM, so `hdev reap` would destroy it. `reap`
captures the figure before deleting, into `~/.config/hdev/usage.tsv`, and
`hdev usage` shows those reaped jobs too.

**`hdev usage` does not cover `pi` jobs.** It reads Claude Code's transcript
format, which `pi` does not write, so a pi job shows `-` rather than a number.
That is missing data, not a zero — never report a pi job as having cost
nothing. For pi spend, read the OpenRouter dashboard.

## When a job hits the usage limit

Claude Code emits three different limit messages and they need different
responses. The job script already handles this — do not try to work around it:

- **Session limit** (the 5-hour window) — the job sleeps until the window rolls
  over, then **resumes the same conversation** rather than restarting, so no
  work is lost. Up to `HDEV_LIMIT_RETRIES` times, default 2.
- **Weekly limit** — the job stops. Waiting would idle a billing VM for days.
  Tell the user to resubmit after it resets.
- **Opus limit** — the job stops. Sleeping cannot clear a model-specific limit;
  a different model would.

A waiting job reports `waiting-on-limit` in `hdev ps`, and `hdev reap` refuses
to delete it. **The VM keeps billing while it waits** — say so when you report
that a job is waiting, and give the user the option to cancel instead.

If the reset time cannot be determined, the job stops rather than sleeping
blind. That is deliberate.

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

If `hdev` itself is not found, see "Before anything else" at the top — the CLI
is a separate install from this skill.

If `hdev submit` fails immediately:

- `hcloud context active` — needs a Hetzner API token. `hcloud context create
  <name>` prompts for it; never ask the user to paste a token into the chat.
- `gh auth status` — needs `repo` scope; the remote agent pushes with it.
- `hdev login status` — shows whether subscription credentials are captured.
  `hdev login` captures them; the remote agents then bill the subscription
  rather than the API.
- `hdev image` builds the base snapshot once. Without it every job installs the
  toolchain at boot: about 3 minutes per VM instead of about 40 seconds (measured 39 s, n=1).

Do not set `ANTHROPIC_API_KEY` if you want subscription billing — inside Claude
Code it takes precedence over the subscription token. `hdev` drops it from the
job environment when a subscription token exists.
