# Plan: an MCP server for hdev

Goal: let a cloud agent — one with no shell on your machine — drive hdev.
Self-hosted only. Every user runs their own instance with their own tokens, so
there is no credential custody and no multi-tenant liability.

## What I checked first

Everything below is from the current spec and the published packages, not memory.

| Fact | Source |
| --- | --- |
| `@modelcontextprotocol/server`, `/client`, `/node`, `/hono` are all at **2.0.0** | npm |
| `@modelcontextprotocol/sdk` (the v1 all-in-one) is at 1.30.0 and still published | npm |
| v2 uses `registerTool(name, config, handler)` with Standard Schema, not v1's variadic `tool()` | SDK migration guide |
| Streamable HTTP is the current remote transport; SSE is a separate legacy type a server may also advertise | MCP registry docs |
| `createMcpHandler` allows in-process testing with a real client and no network | SDK testing docs |
| Hetzner API rate limit is **3600 requests/hour** | `ratelimit-limit` response header |

## The capability surface, and what I am using

MCP offers more than tools. Listing all of it so the omissions are decisions,
not oversights.

| Capability | Using it? | Why |
| --- | --- | --- |
| **Tools** | Yes | The whole point. Eight of them, below. |
| **Tool annotations** (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`) | Yes | Lets a client warn before `reap` deletes VMs. Most servers ship without these. |
| **`outputSchema` + `structuredContent`** | Yes, on `ps`, `images`, `submit` | Clients get typed job lists, not prose they must re-parse. |
| **Progress notifications** | Yes, on `submit` | A submit takes ~50 s per slice across five distinct steps. Silence for a minute looks like a hang. |
| **Logging** (`sendLoggingMessage`) | Yes | Surfaces the `hcloud` and `ssh` steps for debugging. |
| **Cancellation** (request signal) | Yes | A cancelled `submit` must not leave a half-provisioned VM. |
| **Elicitation** | Yes, on `reap --max-age` | Confirm before deleting a *running* job. Client support varies, so it must degrade to refusing rather than assuming yes. |
| **Resources** (templates) | Yes | `hdev://job/{name}/status` and `hdev://job/{name}/log`. Gives a browsable surface — and completion, which tools cannot have. |
| **Completions** | Yes, but only on resource templates | **Tool arguments cannot be completed.** Verified against the spec: `completion/complete` defines exactly two reference types, `ref/prompt` and `ref/resource`. There is no `ref/tool`. Job-name autocomplete is therefore available when browsing resources, not when calling `hdev_ask`. |
| **Prompts** | No | The `hetzner-dev` skill already carries the guidance. A prompt would be a second copy to keep in sync. |
| **Sampling** | No | Nothing here needs the server to ask the client's model for a completion. |
| **Roots** | No | Considered. The server takes an explicit `repo_path` argument instead — clearer than inferring from a root, and it works identically over stdio and HTTP. |
| **OAuth 2.1** | No, deferred | See "Auth" below. This is a deliberate, documented deviation. |

## Architecture

```
cloud agent ──HTTPS──> your control-plane box ──> bin/hdev ──> Hetzner API
                       (Caddy + node, ~$8/mo)                  (your token)
local agent ──stdio──> bin/hdev directly
```

**The server shells out to `bin/hdev`. It reimplements nothing.** One source of
truth, and the 63 existing checks keep covering the behaviour. The MCP layer is
argument validation, schemas, and notifications.

Plain ESM JavaScript, no TypeScript build step. About 300 lines does not earn a
compile stage.

### Tools

| Tool | readOnly | destructive | idempotent | Notes |
| --- | --- | --- | --- | --- |
| `hdev_submit` | no | no | no | Additive: creates VMs and a branch. Emits progress. |
| `hdev_ps` | **yes** | – | – | `structuredContent`: job, status, age, branch. |
| `hdev_status` | **yes** | – | – | The orchestrator's own notes. Cheap. |
| `hdev_logs` | **yes** | – | – | Tail only; no `-f`, streams do not fit a tool call. |
| `hdev_ask` | **yes** | – | – | Forked session. Cannot change the job. |
| `hdev_tell` | no | no | no | The `-c` path. **Separate tool** because annotations are static per tool — one tool cannot be read-only for some arguments and not others. |
| `hdev_reap` | no | **yes** | yes | Elicits confirmation when `max_age` would kill a running job. |
| `hdev_images` | **yes** | – | – | Profiles available. |

`hdev ssh` is deliberately absent — it is interactive and does not map to a tool
call. It stays CLI-only.

### Auth

When serving HTTP the server **requires** a static bearer token from
`HDEV_MCP_TOKEN`, and refuses to start without one. It also validates the `Host`
header (DNS rebinding protection) and binds to loopback unless told otherwise.

The spec prefers OAuth 2.1 with protected-resource metadata. For a single-user
self-hosted server that is a lot of machinery for one user, so this is a
deliberate deviation and the README will say so plainly rather than implying
spec compliance. If anyone runs this for more than themselves, OAuth becomes
mandatory, not optional.

TLS is Caddy's job. Automatic certificates need a domain pointed at the box.
Cloudflare Tunnel is the alternative when you would rather not open ports.

## Slices

**This work is sequential, so it is a poor fit for parallel `hdev` slices.**
Slice 2 cannot start before slice 1 defines the tool surface. Run it as one job
(`hdev submit -1`) or by hand. Recording that here because the earlier lesson —
a slice's done-condition must be satisfiable from its own base commit — applies
in reverse: these cannot be.

### 1. Server core and tools
`mcp/package.json` (deps: `@modelcontextprotocol/server@2`, `zod`), `mcp/index.js`.
All seven tools, shelling out to `bin/hdev` with validated arguments. Input and
output schemas. Annotations on every tool. stdio transport only.
Done when: an in-process `createMcpHandler` test lists eight tools with correct
annotations and calls `hdev_ps` against a stubbed `hdev`.

### 2. Notifications and resources
Progress on `submit`, logging throughout, cancellation handling, the two
resource templates with job-name completion, elicitation on `hdev_reap`.
Done when: the test client observes progress notifications from a stubbed
submit, and reads `hdev://job/{name}/status`.

### 3. HTTP transport and auth
`--http [port]` using `NodeStreamableHTTPServerTransport` with session IDs,
bearer-token check, Host validation, loopback default.
Done when: a test client completes a session over HTTP, and a request with a
wrong or missing token is rejected.

### 4. The control-plane profile
`profiles/controlplane.sh`: node, Caddy, a systemd unit for the server.
Documented as the one box that legitimately holds a Hetzner token, with the
reason it is different from a job VM.
Done when: a box built from the profile serves the MCP endpoint over TLS and a
real client lists the tools.

### 5. Docs
SETUP.md gets an MCP section. README gets the architecture and the honest note
about the static-bearer deviation.

## Risks

- **Elicitation support is client-dependent.** If a client does not support it,
  `hdev_reap` with a `max_age` that would kill a running job must refuse, not
  assume consent. Test that path explicitly.
- **The control-plane box holds a Hetzner token.** That is the thing kept off
  every job VM. The difference is real — it runs fixed code, not an agent with
  open permissions executing arbitrary prompts — but it must be stated, not
  glossed over.
- **A long `submit` may exceed a client's request timeout.** Two slices take
  ~100 s today. If that turns out to be a problem, `submit` returns job names
  immediately and the client polls `hdev_ps`. Decide after measuring, not before.
- **v2 SDK is new.** Package majors moved from 1.30.0 to 2.0.0 with a different
  API shape. Pin exact versions.

## Blast radius, stated plainly

Hetzner tokens are project-scoped. The control-plane box needs a Read & Write
token for the project it provisions into, so **that project is the blast
radius** — the same exposure your laptop has today, moved to a box that is
always on and reachable from the internet.

Two things follow, and both belong in the docs rather than being discovered:

- Give the MCP box a token for a project that holds nothing else.
- The bearer token guarding the endpoint is the only thing between the internet
  and that Hetzner token. Treat losing it as losing the Hetzner token.
