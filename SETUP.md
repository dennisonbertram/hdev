# Setting up hdev

Bring your own everything. `hdev` never holds credentials for you — it uses your
Hetzner account, your GitHub account and your Claude subscription, and it stores
what it needs in `~/.config/hdev` on your own machine.

Budget about 15 minutes, most of which is waiting for one image build.

## 1. What you need first

| | Why | Check it works |
| --- | --- | --- |
| macOS or Linux, bash | `hdev` is a bash script | `bash --version` |
| [`hcloud`](https://github.com/hetznercloud/cli) | talks to Hetzner | `brew install hcloud` then `hcloud version` |
| [`gh`](https://cli.github.com), authenticated | the remote agent pushes and opens PRs with it | `gh auth status` — needs `repo` scope |
| A Claude subscription | the remote agent runs on it, not on API billing | any paid plan |
| A GitHub repo to work on | `hdev` clones from the remote, so the work must be pushed | — |

Verified working with `hcloud` 1.51.0 and `gh` 2.97.0.

## 2. Get a Hetzner Cloud account and a token

1. Sign up at **https://console.hetzner.com/**.
   Expect an identity or payment verification step before you can create
   servers. I have not verified Hetzner's current policy, so treat this as
   "budget time for it", not as a documented guarantee.
2. Create a **project**. A dedicated project for this is worth it — API tokens
   are scoped to one project, so a token for this project can never touch
   anything else you run.
3. In that project: **Security** → **API tokens** → **Generate API token**.
4. Give it a description and choose **Read & Write**. Read-only cannot create
   servers.
5. Copy it immediately. Hetzner shows it once and never again.

Store it:

```bash
hcloud context create hdev     # prompts for the token
```

That writes `~/.config/hcloud/cli.toml`. Prefer this over `export HCLOUD_TOKEN=…`,
which puts the token in every process's environment.

## 3. Install hdev

```bash
git clone https://github.com/dennisonbertram/hdev ~/develop/hdev
mkdir -p ~/.local/bin && ln -sfn ~/develop/hdev/bin/hdev ~/.local/bin/hdev
~/develop/hdev/test_hdev.sh           # 192 offline checks, no Hetzner calls
```

That works if `~/.local/bin` is already on your PATH — check with
`zsh -lic 'command -v hdev'`. If it prints nothing, add it:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc   # then open a new terminal
```

**`npx skills add` installs the skill, not the CLI.** The skill tells your agent
how to do the above if `hdev` is missing, so you can also just ask it to.

Make the skill available to your agent — both Claude Code and Codex read the
same `SKILL.md` format:

```bash
ln -sfn "$PWD/skills/hetzner-dev" ~/.claude/skills/hetzner-dev
ln -sfn "$PWD/skills/hetzner-dev" ~/.codex/skills/hetzner-dev
```

An SSH key is generated at `~/.ssh/id_hdev` on first use and uploaded to your
Hetzner project. Set `HDEV_SSH_KEY` to use one you already have.

## 4. Put your subscription on the box

```bash
hdev login          # Claude: runs `claude setup-token`, opens your browser
hdev login pi       # pi: captures your OpenRouter credential (optional)
hdev login status   # confirm what landed
```

`hdev login pi` reads `~/.pi/agent/auth.json` and copies **only** the provider
your model uses — not every key you have configured. Prefer it over
`OPENROUTER_API_KEY`: `pi` itself prefers the stored file, so a stale env var
can work locally and 401 on the VM.

`claude setup-token` mints a **one-year OAuth token** that requires a
subscription and works on any machine, so this is a one-time step — every
future VM is authenticated without another login. The token is stored in
`~/.config/hdev/auth.env`, mode 0600, and shipped to each VM over SSH after
boot. It is never written into cloud-init, which Hetzner stores and serves from
the metadata service.

Run this in a normal terminal, not inside an agent session: `setup-token` prints
the token to the screen, and anything printed inside an agent session ends up in
its transcript.

**Do not set `ANTHROPIC_API_KEY`** if you want subscription billing. Inside
Claude Code it takes precedence over the subscription token. `hdev` drops it
from the job environment when a subscription token exists, but the clean thing
is not to have it set.

## 5. Build the base image (optional, but do it)

**You do not need a snapshot to start.** With none, `hdev submit` boots stock
`ubuntu-24.04` and cloud-init installs the whole toolchain — node, gh, Claude
Code, Codex, pi — before the job runs. It works; it just costs about 3 minutes
per job instead of 40 seconds, every time. Verified on a fresh boot.

Building the snapshot once removes that:

```bash
hdev image        # about 2 minutes, once
hdev images       # confirm it exists
```

This boots a throwaway VM, installs the toolchain, snapshots it, and deletes the
VM. Every later job starts from the snapshot.

## 6. Run something

From inside a git repo with a GitHub remote, on a pushed branch:

```bash
hdev submit -m "add a --version flag to the CLI and a test for it"
hdev agent             # which harness runs jobs: claude, claude-pi, pi, codex
hdev model --list      # if you use pi: which model, and the trade-offs
hdev ps                # running / done / failed
hdev status <job>      # the agent's own progress notes, costs nothing
hdev logs <job>        # raw output
hdev reap              # delete the VMs of finished jobs
```

`hdev` clones from the **GitHub remote**, so commit and push before you submit —
uncommitted local work is invisible to the remote agent.

A finished job has already pushed a branch and opened a PR. Review it; do not
assume it is right.

## 7. What it costs

| | |
| --- | --- |
| VM while a job runs | **$0.0368/hour** (`cpx22`, 2 vCPU, 4 GB, Nuremberg) |
| Snapshot storage | **$0.0199/GB/month** — the base image is 1.30 GB, about $0.026/month |
| Idle | nothing, once you `hdev reap` |

A 30-minute job costs under two cents of infrastructure. Your Claude
subscription covers the inference.

**`hdev reap` is what stops the billing.** Jobs do not delete their own VM —
that would need a Hetzner write token sitting on a box running an agent with
open permissions, and that token could delete your whole project.

`hdev ps` shows each VM's age and marks anything past `HDEV_MAX_AGE` (default
`6h`) with a `!`. To clear runaways and any VM left behind by a crashed submit:

```bash
hdev reap                  # finished jobs only; reports orphans without deleting
hdev reap --max-age 4h     # also deletes running jobs and orphans older than 4h
```

Set it and forget it — a safety net, not a schedule you have to think about:

```bash
# macOS
echo '0 * * * * PATH=/usr/local/bin:/opt/homebrew/bin:$PATH '"$PWD"'/bin/hdev reap --max-age 6h' | crontab -
```

Pick a max age longer than your longest real job. `--max-age` cannot tell a
runaway from slow honest work; it only knows the clock.

## When it does not work

| Symptom | Cause |
| --- | --- |
| `no Hetzner token` | `hcloud context active` is empty — redo step 2 |
| `no GitHub token` | `gh auth login`, or `export GH_TOKEN` |
| `could not create a <type> in <location>` | Hetzner prices server types it will not sell you. `hdev` prints what that location actually offers; pick one with `-t` |
| Job fails instantly | `hdev logs <job>`. The VM stays up on failure so the evidence survives |
| `unreachable` in `hdev ps` | The firewall allows SSH from the public IP you had at submit time. On a new network, submit anything to refresh the rule — running jobs are unaffected |
| No PR, but status `done` | The agent changed nothing, or the push worked and `gh pr create` did not. The log says which |
