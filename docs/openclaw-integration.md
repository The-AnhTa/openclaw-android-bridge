# OpenClaw integration

## Milestone status

Milestone 4 is `PASS`. The live OpenClaw-to-Android workflow completed on the
Windows VM, and the automated read-only SQLite validator confirmed the exact
successful session and all required acceptance evidence.

| Milestone | Scope | Status |
| --- | --- | --- |
| 1 | Windows + Android prerequisites | PASS |
| 2 | Local MCP -> Android | PASS |
| 3 | VM -> SSH -> MCP -> Android | PASS |
| 4 | OpenClaw -> MCP -> Android | PASS |

## Architecture

```text
Local GLM
  -> OpenClaw on the VM
  -> OpenClaw-managed android MCP server
  -> VM http://127.0.0.1:8765/sse
  -> SSH reverse tunnel
  -> laptop http://127.0.0.1:8765/sse
  -> appium-mcp 1.95.0
  -> embedded UiAutomator2
  -> ADB
  -> physical Android phone
```

Nothing below the VM MCP endpoint changes. The VM does not need Java, Android
Studio, ADB, Appium, UiAutomator2, a new MCP proxy, or npm package installation.

## OpenClaw MCP definition

The scripts use the OpenClaw-managed outbound MCP registry rather than editing
an assumed config path. The intended saved definition is equivalent to:

```json
{
  "url": "http://127.0.0.1:8765/sse",
  "transport": "streamable-http",
  "connectionTimeoutMs": 10000,
  "requestTimeoutMs": 240000,
  "toolFilter": {
    "include": [
      "select_device",
      "appium_session_management",
      "appium_app_lifecycle",
      "appium_get_page_source"
    ],
    "exclude": []
  }
}
```

Pinned `appium-mcp` 1.95.0 exposes the tested endpoint at `/sse`, but the path
name does not determine the protocol. Milestone 3 proved this endpoint with the
MCP SDK's `StreamableHTTPClientTransport`, so OpenClaw's canonical transport is
`streamable-http`, not `sse`. OpenClaw documents `streamable-http` as a distinct
transport and uses that canonical spelling in saved config. See the official
[MCP transport reference](https://docs.openclaw.ai/cli/mcp/transports).

The 10-second connection timeout bounds initialization and discovery. The
240-second request timeout accommodates first-time embedded UiAutomator2
session startup without disabling timeouts.

The four-tool include filter is the smallest surface needed for acceptance.
It omits installation, shell execution, file transfer, app-data clearing,
permission, text-entry, and device-configuration tools. OpenClaw applies this
filter before MCP tools reach eligible agent runtimes. It does not globally
relax tool policy or alter unrelated agents, servers, plugins, or approvals.
See the official [MCP registry reference](https://docs.openclaw.ai/cli/mcp/registry).

## Prerequisites and startup order

Before running Milestone 4, the operator must already have:

Laptop:

1. One physical Android phone connected, unlocked, and authorized in ADB.
2. `scripts/windows/start-appium-mcp-http.ps1` running.
3. `scripts/windows/start-vm-tunnel.ps1` running with loopback bindings.

VM:

4. A listener present only on `127.0.0.1:8765`.
5. The existing OpenClaw installation, Gateway, agent, and local GLM working.
6. Node.js 22 or newer available for the existing OpenClaw installation.

The VM scripts detect missing prerequisites. They do not start or reconfigure
the SSH server, recreate the lower stack, open firewall ports, install packages,
or change persistent environment variables.

## Runbook

Run from a regular PowerShell prompt in the repository root on the VM.

### 1. Preflight

```powershell
.\scripts\vm\check-openclaw-android.ps1
```

The preflight records `openclaw --version`, checks Node, validates OpenClaw
config, requires a healthy read-scope Gateway RPC check, discovers a
unique/default agent, inspects its existing model/provider, performs an
independent tool-free `openclaw-model-ok` inference turn, and proves that port
8765 is loopback-only. If multiple agents exist
without a unique default, pass the intended existing ID explicitly:

```powershell
.\scripts\vm\check-openclaw-android.ps1 -AgentId <EXISTING_AGENT_ID>
```

### 2. Configure and probe

```powershell
.\scripts\vm\configure-openclaw-android.ps1 -AgentId <EXISTING_AGENT_ID>
```

The script checks the installed CLI help before writing, then adds `android` or
treats an exact existing definition as idempotent. A conflicting definition is
never overwritten silently. Inspect it first and use `-Replace` only when that
specific definition may be replaced:

```powershell
.\scripts\vm\configure-openclaw-android.ps1 `
  -AgentId <EXISTING_AGENT_ID> `
  -Replace
```

After configuration the script runs:

```text
openclaw config validate --json
openclaw mcp reload
openclaw mcp status --verbose
openclaw mcp doctor android
openclaw mcp doctor android --probe
openclaw mcp probe android --json
```

The live probe must expose exactly the four allowed tools. It runs before any
Android agent turn. The official OpenClaw documentation notes that `probe` and
`doctor --probe` open live MCP connections; ordinary status and static doctor
do not. `mcp reload` clears only the invoking CLI process's cache; the test uses
a fresh agent session, and OpenClaw invalidates affected session runtimes when
the saved server definition changes.

### 3. Acceptance test

```powershell
.\scripts\vm\test-openclaw-android.ps1 -AgentId <EXISTING_AGENT_ID>
```

The test repeats preflight and the live MCP probe, then invokes the normal
Gateway-backed `openclaw agent` path with
`scripts/vm/openclaw-android-acceptance-prompt.txt`. It does not invoke the old
Node smoke client.

The prompt instructs the agent to select the sole device, create a no-reset
UiAutomator2 session, activate `com.android.settings`, retrieve and inspect
non-empty page source, avoid changing the phone, and delete the session.

The test does not use the model's final text as acceptance evidence. It creates
one fully qualified session key, passes that exact key to `openclaw agent`, and
validates that same key in OpenClaw's authoritative per-agent SQLite store. It
resolves the physical store path with
`openclaw sessions --agent <agent-id> --json`; it never guesses a path, chooses
the latest session, or selects a session by timestamp.

Acceptance requires the SQLite runtime trajectory to contain, in order:

- paired successful `tool.call` and `tool.result` events for device selection;
- paired session-management events containing the create action;
- paired lifecycle events activating `com.android.settings`;
- paired page-source events with a non-empty Android Settings hierarchy;
- paired session-management events containing the delete action;
- `model.completed` with a successful done state; and
- `session.ended` with `status=success`.

Tool calls are classified from their raw stored names before normalization.
Only raw `android__...` calls participate in the exact Android tool-set check;
their normalized names must equal the four-tool allowlist. OpenClaw broker
calls such as `tool_search`, `tool_describe`, and `tool_call` remain available
as internal diagnostics but do not count as Android calls. Any additional raw
`android__...` name still fails acceptance. Claims in the agent's natural-
language or JSON-formatted reply cannot replace any of this evidence.

The reader is pinned to the OpenClaw 2026.9.7 schema used by `sessions tail`:
the exact key resolves through `session_nodes.current_session_id`, then
`trajectory_runtime_events` is read in `seq` order. Node 26's built-in
`node:sqlite` opens the database with `readOnly: true` and enables connection-
local `PRAGMA query_only`. The reader checks `sqlite_schema` and the expected
columns before querying; a mismatch fails with
`Unsupported OpenClaw trajectory SQLite schema.` There is no JSONL fallback.
The evidence projection contains booleans and correlation metadata only; page
source, tool result bodies, device identifiers, and credentials are not
printed.

The older JSONL parser and its narrowly scoped OpenClaw 2026.9.7 redaction
compatibility test remain diagnostic-only. `export-trajectory`, `events.jsonl`,
and JSON repair do not run in or determine normal Milestone 4 acceptance.

If the acceptance turn created a session but did not prove deletion, the script
asks the same OpenClaw session to make one cleanup-only session-deletion call.
It reports whether trajectory evidence confirmed that cleanup. The external
SSH tunnel and laptop Appium MCP server remain running.

The static regressions do not contact OpenClaw or Android:

```powershell
.\scripts\vm\test-openclaw-json-shapes.ps1
.\scripts\vm\test-openclaw-trajectory.ps1
.\scripts\vm\test-openclaw-sqlite.ps1
```

They cover scalar, null, one-element, and four-element collection shapes;
exact SQLite session selection; unrelated-session isolation; storage order;
call/result correlation; successful and failed results; session create/delete;
Settings activation and page source; unsuccessful terminal states; missing
events; schema rejection; and read-only database access. Diagnostic JSONL tests
continue to cover strict parsing and retained support-bundle behavior.

Validate an already-successful session without another model or Android run by
supplying its fully qualified exact session key:

```powershell
.\scripts\vm\test-openclaw-android.ps1 `
  -ExistingSessionKey <EXACT_FULL_SESSION_KEY>
```

This mode calls only `openclaw sessions --agent <agent-id> --json` to resolve
the physical store and then reads that database directly. It does not invoke
`openclaw agent`, MCP tools, Appium, Android, or trajectory export. It prints
the four milestone `PASS` lines only after every authoritative SQLite evidence
requirement passes. The legacy `-TrajectoryBundlePath` and
`-TrajectorySessionKey` pair remains optional diagnostic support and never
prints `M4 PASS`.

## Tool policy

The configuration script changes only `mcp.servers.android`. It does not change
global or agent tool profiles. OpenClaw's `coding` and `messaging` profiles can
project managed MCP tools; `minimal`, explicit denials, provider policies, or a
sandbox tool gate may intentionally hide them. Adding the registry entry does
not edit any agent's policy. Consequently, another agent already permitted to
use managed MCP tools may also see this server's same four filtered tools; the
scripts do not rewrite unrelated agents merely to change that pre-existing
policy. See the official
[tool-policy reference](https://docs.openclaw.ai/gateway/config-tools/tool-policy).

If the probe succeeds but the selected agent cannot see the Android tools,
inspect the existing policy rather than setting an unrestricted global profile:

```powershell
openclaw config get tools --json
openclaw agents list --json --bindings
openclaw doctor --lint --severity-min warning
```

Make only the smallest agent- or sandbox-scoped correction supported by the
installed configuration. Do not modify policy automatically merely to make the
acceptance test pass.

## Troubleshooting

- **SSH tunnel absent:** preflight reports no listener on VM port 8765. Start
  the existing laptop reverse-tunnel script; do not open a VM firewall port.
- **Non-loopback listener:** stop the unsafe listener. Both tunnel endpoints
  must remain on `127.0.0.1`; do not use `0.0.0.0` or `GatewayPorts`.
- **MCP probe fails:** keep the laptop server and SSH process running, confirm
  `/sse`, and review `openclaw mcp doctor android --probe`. Do not substitute
  `/mcp`, `sse`, stdio, or a laptop network address.
- **Wrong transport:** inspect `openclaw mcp show android --json`. The saved
  transport must be `streamable-http` even though the path ends in `/sse`.
- **No Android device:** run the laptop doctor, reconnect/unlock the phone, and
  authorize USB debugging. The VM must not receive Android tooling.
- **UiAutomator2 session timeout:** verify `requestTimeoutMs` is 240000 and that
  the phone is responsive. Do not disable timeouts or install another driver.
- **Probe sees tools but the agent does not:** inspect the selected agent's
  profile, denies, provider-specific policy, and sandbox `bundle-mcp` gate. Do
  not globally enable unrestricted tools.
- **GLM does not invoke tools:** confirm the independent inference check passes,
  inspect the exact current-session SQLite trajectory, and retry with the same
  narrow prompt. A textual success claim is not acceptance evidence.
- **Textual claim without a tool call:** the acceptance script fails because it
  requires paired current-session trajectory `tool.call` and `tool.result`
  records plus successful terminal model/session events.
- **SQLite schema mismatch:** the acceptance reader fails closed with
  `Unsupported OpenClaw trajectory SQLite schema.` Inspect the installed
  OpenClaw version and schema before changing the pinned reader; do not fall
  back to a redacted JSONL export.
- **Diagnostic JSONL parsing failure:** the optional support-bundle diagnostic
  identifies the exact failing line. It cannot determine Milestone 4 status.
- **Agent timeout:** retain the 240-second MCP request timeout and increase only
  the bounded `-AgentTimeoutSeconds` value if the model needs longer overall.
- **Appium session not cleaned up:** review the cleanup warning. The script
  attempts one cleanup-only OpenClaw turn when creation is proven without
  deletion; do not perform unrelated recovery actions.
- **CLI option missing:** the installed OpenClaw version is older or different
  from the documented registry surface. The scripts fail before mutation; do
  not edit the config file directly or guess a replacement option.

## Security invariants

- The only saved MCP URL is `http://127.0.0.1:8765/sse`.
- Laptop and VM MCP listeners remain loopback-only.
- No MCP firewall port, public listener, `GatewayPorts`, proxy, or credential is
  added.
- Remote app URLs remain disabled in the pinned Appium MCP process.
- Appium MCP remains pinned at 1.95.0 with embedded UiAutomator2.
- Existing model/provider selection is inspected and tested, never changed.
- Existing global and per-agent tool policy is never broadened or rewritten by
  these scripts.
- No OpenClaw config path, VM address, username, Android serial, or credential
  is hard-coded in the repository.
