<img src="docs/banner.jpg" alt="hdev — coding agents on throwaway machines" width="100%">

# hdev

Hand a coding task to an agent on a throwaway Hetzner VM. Close your laptop.
It comes back as a pull request.

## Install

```bash
npx skills add dennisonbertram/hdev          # the skill, for any agent
git clone https://github.com/dennisonbertram/hdev && cd hdev
export PATH="$PWD/bin:$PATH"                 # add to ~/.zshrc to keep it

hcloud context create hdev                   # your Hetzner token
hdev login                                   # your Claude subscription, once
hdev image                                   # base snapshot, once (~2 min)

hdev submit -m "add a --version flag and a test for it"
```

[**Full setup guide →**](SETUP.md) — getting a Hetzner account and token, from scratch.

[![skills.sh](https://skills.sh/b/dennisonbertram/hdev)](https://skills.sh/dennisonbertram/hdev)
[dennisonbertram.github.io/hdev](https://dennisonbertram.github.io/hdev) · MIT

## What it does

`hdev` does not drive a remote machine from here. It installs Claude Code and
Codex on a Hetzner VM, hands one of them a written brief plus the repo, and
starts it under systemd. The job survives the SSH session ending, the terminal
closing and the laptop sleeping. When it finishes it has pushed a branch and
opened a PR.

**One slice of a plan → one VM → one branch → one PR.**

`npx skills add` works with Claude Code, Codex, Cursor and 70-odd other agents.
To wire the skill up by hand instead:

```bash
ln -sfn "$PWD/skills/hetzner-dev" ~/.claude/skills/hetzner-dev
ln -sfn "$PWD/skills/hetzner-dev" ~/.codex/skills/hetzner-dev
```

Run `./test_hdev.sh` for 63 offline checks that make no Hetzner calls.

## Credentials

Two things you set once:

| Variable | Needed for | Where to get it |
| --- | --- | --- |
| `HCLOUD_TOKEN` | creating VMs | Hetzner Cloud Console → your project → Security → API tokens → **Read & Write** |
| `GH_TOKEN` | pushing the branch, opening the PR | optional — falls back to `gh auth token` |

An SSH key is generated at `~/.ssh/id_hdev` on first use and uploaded to your
Hetzner project. Set `HDEV_SSH_KEY` to point at one you already have.

### Using your subscription, not the API

```bash
hdev login            # both agents
hdev login status     # what is captured
```

- **Claude.** `claude setup-token` mints a one-year OAuth token that requires a
  subscription and works on any machine. `hdev login` runs it here, your browser
  opens here, and the token is stored in `~/.config/hdev/auth.env`. There is no
  URL to relay — the token is portable, so every future VM is authenticated
  without another login.
- **Codex.** The credentials are the `~/.codex/auth.json` file that any
  successful login writes. `hdev login` copies yours to
  `~/.config/hdev/codex-auth.json` and ships it per job.

Setting `ANTHROPIC_API_KEY` defeats this: inside Claude Code it takes precedence
over the subscription token, so the job would bill the API. `hdev` drops it from
the job environment whenever a subscription token exists.

### Logging in on the VM instead

For a box authenticated independently of this laptop:

```bash
hdev login codex  --on <job>     # device code flow
hdev login claude --on <job>     # prints a URL
```

Codex prints a verification URL and a short code; open the URL in your browser
here, enter the code, and the VM is logged in. `hdev` then copies the resulting
credentials back so later jobs reuse them. This is the flow `codex login
--device-auth` exists for.

### How secrets travel

Secrets go to the VM over SSH after boot, never through cloud-init user-data —
Hetzner stores user-data and serves it from the metadata service. On the VM the
GitHub token lives in a git credential helper, so it never appears in a remote
URL or in `git config`.

## Use

```bash
hdev image                      # once: build the base snapshot
hdev submit plan.md             # one VM per '## Slice:' heading
hdev submit -a codex plan.md
hdev submit -1 plan.md          # whole file as one job
hdev submit -m "raise the upstream timeout to 30s"
```

Then close the laptop. Later:

```bash
hdev ps                # running / done / failed / gone, per job
hdev status <job>      # the orchestrator's own progress notes
hdev logs -f <job>     # raw output
hdev ssh <job>         # repo is at /work
hdev cancel <job>
hdev reap              # delete the VMs of finished jobs
hdev reap --max-age 4h # plus runaways and VMs left by a crashed submit
```

`hdev ps` marks any VM past `HDEV_MAX_AGE` (default `6h`) with a `!`. Put
`hdev reap --max-age 6h` in cron as a safety net — see [SETUP.md](SETUP.md).

## Choosing the agent

```bash
hdev submit plan.md            # Claude Code, on your subscription
hdev submit -a pi plan.md      # pi harness, DeepSeek V4 Flash via OpenRouter
hdev submit -a codex plan.md   # Codex
```

| | Claude Code | pi |
| --- | --- | --- |
| Model | your Claude subscription | anything on OpenRouter |
| Cost | subscription window | ~$0.14/M in, $0.28/M out on DeepSeek V4 Flash |
| Subagents | real, enforced by `--agents` | none; delegates by invoking itself |
| Ask a running job | safe — forks the session | refused until the job finishes |
| Usage limits | shares your 5-hour window | none |

`pi` suits mechanical, well-specified work and does not consume your Claude
window. Claude suits ambiguous work where a plausible-but-wrong answer is
expensive. `HDEV_PI_MODEL` takes any OpenRouter model id.

Needs `OPENROUTER_API_KEY`; `hdev` refuses to submit without it rather than
booting a VM that cannot work.

## What it cost

```bash
hdev usage
```

Output tokens per job, read from each box's own transcript, plus this machine's
current 5-hour block. The dollar figure is **API-equivalent** — what those
tokens would have cost on the API. On a subscription it is a size comparison,
not a bill.

A job's usage record lives on its VM, so `reap` captures it before deleting and
`hdev usage` still shows reaped jobs.

**This does not cover `pi` jobs** — it reads Claude Code's transcript format,
which pi does not write, so a pi job shows `-`. That is missing data, not zero.
Read the OpenRouter dashboard for pi spend.

## When a job hits the usage limit

| Limit | What the job does |
| --- | --- |
| Session (5-hour) | Sleeps until the window rolls over, then **resumes the same conversation** — no work lost. Twice by default (`HDEV_LIMIT_RETRIES`). |
| Weekly | Stops. Waiting would idle a billing VM for days. |
| Opus | Stops. A model-specific limit is cleared by changing model, not by sleeping. |

The reset time comes from `ccusage`'s machine-readable block end, not from
parsing an error string. **If it cannot be determined, the job stops rather
than sleeping blind** on a VM that bills by the hour.

A waiting job shows as `waiting-on-limit` in `hdev ps`, and `hdev reap` will not
delete it — including `--max-age`, which would otherwise mistake a long sleep
for a runaway.

## Snapshot profiles

A profile is a snapshot with a toolchain already installed, so the slow part of
provisioning happens once instead of on every job.

```bash
hdev image browser              # build it once
hdev images                     # what you have
hdev submit -p browser plan.md  # boot jobs from it
```

A profile is one shell script in `profiles/<name>.sh`. It is appended to the
base provisioning and runs on every boot, so **it must be idempotent** — on a
snapshot boot it should find its work already done and exit. Drop a new file in
that directory and it becomes a profile; nothing else needs editing.

| Profile | What it adds | Snapshot | Build time |
| --- | --- | --- | --- |
| `base` | node 22, npm, git, gh, ripgrep, build-essential, claude, codex | 1.30 GB | 2 m 02 s |
| `docker` | Docker CE, daemon enabled, job user in the `docker` group | 1.58 GB | 1 m 51 s |
| `browser` | Playwright Chromium with system deps, `playwright`, `agent-browser` | 1.89 GB | 2 m 50 s |

Snapshot size is the occupied size Hetzner bills for, not disk usage — the
browser profile uses 4.1 GB on disk and stores as 1.89 GB. All three cost under
$0.04/month each.

Profiles contribute environment by appending to `/etc/hdev.env`, which every
job sources. That is how the browser profile points Playwright at
`/opt/playwright`.

### Letting the agent build a profile

The VM never holds a Hetzner token — an agent with open permissions and a
read-write token could delete your whole project. So the agent sets a box up,
and you decide when that becomes reusable:

```bash
hdev submit -k -m "install the toolchain this project needs and prove it works"
hdev snapshot <job> myprofile     # capture that box
hdev submit -p myprofile plan.md  # every later job starts there
```

`hdev snapshot` refuses while the job is still running, and **scrubs before it
captures**: the subscription token, the Codex and Claude state, the checked-out
repo, the sudoers drop-in and the job user are all removed first. A job box
holds your credentials; a snapshot of one unscrubbed would bake them into an
image that anyone with project access can boot. If the scrub fails, the capture
aborts rather than proceeding.

### Limits worth knowing

- Hetzner allows **30 snapshots across all projects** by default.
- Snapshot storage is **$0.0199 per GB per month** — the 1.30 GB base profile
  costs about $0.026/month. Cost is not the constraint; the snapshot count is.
- A snapshot's architecture is fixed. An x86 snapshot cannot boot an ARM `cax`
  server.
- Hetzner stores a snapshot in a different location from the server it came
  from, chosen randomly within the same network zone, and the API exposes no
  location field. You can still boot it in any location.

## Skills on the remote agent

`hdev` copies skills from `~/.claude/skills` into the job user's own skill
directory on every submit, and the orchestrator prompt tells the agent to load
them before it plans anything.

```bash
HDEV_SKILLS="efficient-fable my-other-skill" hdev submit plan.md
```

`efficient-fable` ships by default. Copying per submit rather than baking the
skills into the snapshot means editing a skill here takes effect on the next
job, with no image rebuild.

Verified on a real run: the skill directory arrives on the box, the agent calls
the Skill tool once, and the transcript shows three delegations with
`subagent_type` values `implementer`, `tester` and `reviewer` — the subagents
`hdev` defines through `--agents`.

## Pointing a job at a different model

`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_MODEL` are passed
through to the job when set, and ignored when unset. That is the hook for
running jobs against a cheaper Anthropic-compatible endpoint. It is a
passthrough only — nothing here has been tested against a non-Anthropic
provider.

## Talking to the remote agent

The remote agent is an orchestrator. It does not type code — it delegates to
three subagents (`implementer`, `tester`, `reviewer`) and keeps running notes in
`/root/job/status.md`, rewritten after each delegation.

```bash
hdev status <job>                    # read the notes — costs nothing
hdev ask <job> "why did you skip the cache layer?"
hdev ask -c <job> "stop after the tests pass, do not open the PR"
```

`hdev ask` resumes the job's own conversation with `--fork-session`, so the
answer comes from the agent that did the work, with its full context, and the
job's thread is not disturbed. Safe to use while the job is running.

`hdev ask -c` continues the real thread, so the agent acts on what you say. Use
it to redirect the work, not to ask questions.

Codex has no fork: `hdev ask` on a Codex job resumes the session with `codex
exec resume --last`, and refuses while the job is still running. Codex also has
no subagent primitive, so its orchestration is instruction-only — the brief
tells it to shell out to `codex exec` for isolated sub-tasks. Claude's
delegation is enforced by `--agents`; Codex's is not.

`hdev` clones from the GitHub remote, so **commit and push before you submit** —
uncommitted local work is not sent.

### Plan format

```markdown
# Rate limiting rollout

## Slice: Add the token bucket
Implement a token bucket in `lib/ratelimit.ts`. 60 requests per minute per key.
Done when: `npm test lib/ratelimit.test.ts` passes.

## Slice: Wire /api/send
Call the bucket in `app/api/send/route.ts` before the handler. Return 429 with a
Retry-After header when the bucket is empty.
Done when: the new integration test passes.
```

Each slice must stand alone. The remote agent has no conversation history — it
gets the slice text and the repo, nothing else. Slices run in parallel from the
same base commit, so they must not depend on each other.

## The mode switch

```bash
hdev mode              # prints "local" or "hetzner"
hdev mode hetzner      # flip it
```

Nothing reads this yet. It becomes the always-on switch when you add one line to
`~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`:

> Before implementing, run `hdev mode`. If it prints `hetzner`, plan locally and
> hand the slices off with the `hetzner-dev` skill instead of implementing here.

Add that line after a real `hdev submit` has worked end to end, not before.

## Cost

A VM runs from `hdev submit` until you delete it. Jobs do not delete their own
VM — that would need a Hetzner write token on a box running an agent with open
permissions, which is a worse trade. `hdev ps` lists what exists with ages,
`hdev reap` deletes the finished ones, `hdev reap --max-age 4h` also takes
runaways and untracked VMs, and `hdev nuke` deletes everything.

Verified: `reap` on its own keeps a running job and merely reports an untracked
VM; `reap --max-age 1s` deleted both.

## Design notes

- **systemd, not nohup.** `systemd-run --unit=hdev-job` gives detachment,
  `systemctl is-active` as the status check and `journalctl` as the log, with no
  status file or PID handling to write. The unit runs with `--uid=agent` and an
  explicit `HOME`: systemd hands a unit a minimal environment with no `HOME`,
  which makes every `git config --global` fail, and Claude Code refuses
  `--dangerously-skip-permissions` when it is running as root.
- **Jobs run as an unprivileged user**, created per submit rather than baked
  into the snapshot, so the plain-Ubuntu path works the same way. That user has
  **passwordless sudo**, and the orchestrator is told so. This is not a weaker
  boundary than running as root: the boundary is the throwaway VM, which holds
  exactly one job and is then deleted. Without sudo the only thing the agent
  actually loses is installing system packages, which it would then quietly
  work around instead of fixing.
- **The job script runs under `set -e` except around the agent call.** Without
  that, a failed clone let every later step run in the wrong directory and the
  job printed "pushed" for a push that never happened.
- **VM per slice, not a container host.** Stronger isolation, one code path, no
  image registry, and parallel slices cannot collide.
- **Cloud-init is idempotent**, so the same user-data works on plain Ubuntu
  (installs the toolchain, about 3 minutes) and on the snapshot (no-op, about
  40 seconds, measured 39 s with n=1).
- **The firewall allows inbound SSH from your current public IP only**, and is
  reapplied on every `submit`. Change networks and existing jobs show
  `unreachable` until the next submit refreshes the rule. The jobs keep running.
