# openclaw-android-bridge

A reproducible bridge for controlling a physical Android phone from a local
language model through a remote OpenClaw deployment.

The eventual request path is:

```text
Local GLM -> OpenClaw on a remote VM -> MCP over an SSH tunnel
          -> appium-mcp on a Windows laptop -> embedded UiAutomator2
          -> ADB -> physical Android phone
```

The project is progressing through independently testable milestones:

| Milestone | Scope | Status |
| --- | --- | --- |
| 1 | Windows + Android prerequisites | PASS |
| 2 | Local MCP -> Android | PASS |
| 3 | VM -> SSH -> MCP -> Android | PASS |
| 4 | OpenClaw -> MCP -> Android | NEXT |

Milestone 3 proved the VM-to-phone path through a loopback-only SSH reverse
tunnel. OpenClaw and the GLM remain out of scope until Milestone 4.

## First-stage validation

From a regular PowerShell prompt in the repository root, run:

```powershell
.\scripts\windows\doctor.ps1
```

The doctor discovers Android Studio's bundled Java runtime and the Android SDK,
then validates the host tools and the connected phone. Its environment changes
exist only in the current PowerShell process; it does not require
Administrator privileges or alter Windows settings.

For an Android-focused check, run:

```powershell
.\scripts\windows\check-device.ps1
```

## Local Appium MCP smoke test

Install the pinned repository dependencies and run the acceptance test:

```powershell
npm ci
.\scripts\windows\doctor.ps1
.\scripts\windows\test-appium-mcp.ps1
```

The test starts the repository-local `appium-mcp` over stdio, uses its embedded
UiAutomator2 driver, opens Android Settings, reads the UI hierarchy, and deletes
the session. It does not install standalone Appium or expose a TCP port.

## VM tunnel validation

Milestone 3 is exercised in three foreground processes:

```powershell
# Laptop terminal 1
.\scripts\windows\start-appium-mcp-http.ps1

# Laptop terminal 2 (replace placeholders; values are never stored)
.\scripts\windows\start-vm-tunnel.ps1 -VmHost <host> -VmUser <user>
```

Then run the bundled cross-platform client on the VM as documented in
[remote MCP tunnel](docs/remote-mcp-tunnel.md). With pinned `appium-mcp` 1.95.0,
the tested route is `/sse`; the client uses the MCP SDK's
`StreamableHTTPClientTransport`. The route name does not imply that the client
uses the SDK's legacy SSE transport. Both the laptop server and VM reverse
forward are restricted to `127.0.0.1`.

See [prerequisites](docs/prerequisites.md), [architecture](docs/architecture.md),
[Appium MCP](docs/appium-mcp.md), and [tested versions](docs/tested-versions.md)
for details. The [dependency audit](docs/dependency-audit.md) is recorded
separately from milestone implementation.
