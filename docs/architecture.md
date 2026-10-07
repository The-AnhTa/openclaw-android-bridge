# Architecture

## Intended end state

```text
Local GLM
  -> OpenClaw on a remote VM
  -> MCP transported through an SSH tunnel
  -> appium-mcp on the Windows laptop
  -> Appium's embedded UiAutomator2 driver
  -> Android Debug Bridge (ADB)
  -> physical Android phone connected over USB
```

The Windows laptop is the hardware boundary: it owns the USB connection and
runs the Android automation components. The remote VM does not receive direct
USB access and does not need Java, Android Studio, the Android SDK, ADB, or
Appium.

## Current scope

- Milestone 0 establishes the repository and documentation.
- Milestone 1 validates Windows tools, Android Studio's bundled JBR, the Android
  SDK, ADB, and exactly one authorized physical device.
- Milestone 2 validates a local MCP-to-Android path over stdio using the pinned
  repository-local Appium MCP and its embedded UiAutomator2 driver.
- Milestone 3 validates a VM-side Node MCP client connected to Appium MCP
  through an SSH reverse forward and loopback-only HTTP endpoints.
- Milestone 4 validates replacing that standalone client with the VM's existing
  OpenClaw agent and OpenClaw-managed `android` MCP server definition.

Milestone 3 introduces the first network listener, but constrains it to laptop
loopback and validates the actual Windows socket after startup. The reverse
forward explicitly binds VM loopback and targets laptop loopback:

```text
VM 127.0.0.1:8765 -> SSH reverse forwarding -> laptop 127.0.0.1:8765
```

The complete tested path is:

```text
VM Node MCP client
  -> VM 127.0.0.1:8765
  -> SSH reverse tunnel
  -> laptop 127.0.0.1:8765/sse
  -> appium-mcp 1.95.0
  -> embedded UiAutomator2
  -> ADB
  -> Samsung Android device
```

The client uses the MCP TypeScript SDK's `StreamableHTTPClientTransport`.
`/sse` is the effective route exposed by the pinned Appium MCP CLI; its path
name does not change the SDK transport class or its Streamable HTTP semantics.
The tested device was a Samsung SM-A155F running Android 16 / API 36, but no
script or client behavior depends on that model.

No LAN listener or firewall rule is part of the architecture. Scripts make
process-local environment changes only and do not edit the registry or
persistent environment variables.

## Milestone status

| Milestone | Scope | Status |
| --- | --- | --- |
| 1 | Windows + Android prerequisites | PASS |
| 2 | Local MCP -> Android | PASS |
| 3 | VM -> SSH -> MCP -> Android | PASS |
| 4 | OpenClaw -> MCP -> Android | PASS |

Milestone 4 scripts configure and test this target path:

```text
Local GLM
  -> OpenClaw
  -> OpenClaw-managed android MCP server
  -> VM 127.0.0.1:8765/sse
  -> SSH reverse tunnel
  -> laptop appium-mcp 1.95.0
  -> embedded UiAutomator2
  -> ADB
  -> physical Android phone
```

Milestone 4 passed when the automated acceptance validator confirmed the exact
successful OpenClaw session directly from the per-agent SQLite runtime
trajectory store. The evidence proves that the actual agent turn invoked the
four allowed Android tools, retrieved non-empty Settings page source, and
deleted its Appium session. The existing model/provider and the proven lower
stack were not changed by this milestone.
