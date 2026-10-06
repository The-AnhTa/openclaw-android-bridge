# Remote MCP tunnel

## Architecture

Milestone 3 targets this path without involving OpenClaw:

```text
VM Node MCP client
  -> http://127.0.0.1:8765/sse
  -> SSH encrypted reverse forward
  -> laptop 127.0.0.1:8765/sse
  -> appium-mcp 1.95.0
  -> embedded UiAutomator2
  -> ADB
  -> physical Android phone
```

Appium MCP remains on the laptop because the laptop owns the USB connection,
Android Studio JBR, Android SDK, and ADB. The VM needs only Node.js 22 or newer,
npm, and an SSH server that permits remote TCP forwarding.

Streamable HTTP is introduced because stdio cannot cross the VM boundary. The
pinned upstream CLI names this mode `httpStream`; inspection and local testing
confirm that version 1.95.0 serves its effective MCP endpoint at `/sse`.

## Loopback security

The laptop startup script explicitly sets FastMCP's process-local host to
`127.0.0.1`, starts the pinned local executable, and inspects the real Windows
TCP listener. It stops the process if any listener is `0.0.0.0`, `::`, or any
other non-loopback address. A firewall rule is not treated as a substitute.

The SSH command independently constrains both sides:

```text
-R 127.0.0.1:<VM_PORT>:127.0.0.1:<LOCAL_PORT>
```

Thus neither the laptop endpoint nor the VM endpoint is intended to be
reachable from a LAN interface. `GatewayPorts` is not requested or modified.

## Startup order

1. Connect and unlock the Android phone.
2. On the laptop, install dependencies with `npm ci` if needed.
3. Start Appium MCP HTTP in laptop terminal 1:

   ```powershell
   .\scripts\windows\start-appium-mcp-http.ps1 -Port 8765
   ```

4. Confirm the script reports `127.0.0.1:8765` as loopback-only. A separate
   check is also available:

   ```powershell
   .\scripts\windows\check-mcp-listener.ps1 -Port 8765
   ```

5. Optionally prove local HTTP initialization and tool discovery in another
   laptop terminal:

   ```powershell
   .\scripts\windows\test-appium-mcp-http.ps1
   ```

6. Start the reverse tunnel in laptop terminal 2, supplying real values only
   at runtime:

   ```powershell
   .\scripts\windows\start-vm-tunnel.ps1 `
     -VmHost <VM_HOST> `
     -VmUser <VM_USER> `
     -VmSshPort 22 `
     -LocalMcpPort 8765 `
     -VmMcpPort 8765
   ```

7. On the VM, copy or clone the repository and run:

   ```sh
   cd tools/remote-mcp-client
   npm ci
   node appium-http-smoke-client.mjs --vm --url http://127.0.0.1:8765/sse
   ```

The VM client keeps one MCP connection open from initialization through Appium
session deletion. It never reconnects between Appium operations.

## Current validation state

The pinned HTTP server has been observed listening only on
`127.0.0.1:8765`, and the VM client code has completed its full Android sequence
against that laptop-loopback endpoint. This proves the new HTTP client and
server path but not the SSH or VM hop. Milestone 3 remains a target until the
same client passes on the actual VM with `--vm`.

## Shutdown order

1. Allow the VM smoke client to delete the Appium session and close MCP.
2. Stop the foreground SSH tunnel with Ctrl+C.
3. Stop the foreground Appium MCP HTTP server with Ctrl+C.
4. Disconnect the phone if desired.

Stopping the tunnel or HTTP server before session deletion can cause Appium MCP
to clean up its owned session on client disconnect.

## Troubleshooting

- **Phone disconnected:** reconnect and unlock it, then rerun `doctor.ps1`.
- **Phone unauthorized:** accept the USB-debugging authorization prompt; the
  scripts will not bypass authorization.
- **Appium MCP fails to start:** run `npm ci`, verify Node.js 22 or newer, and
  run `doctor.ps1` for Java, SDK, ADB, and device diagnostics.
- **Port already in use:** select matching unused laptop and VM ports with the
  script parameters; do not terminate an unidentified process.
- **Non-loopback listener:** the startup script stops its server and fails. Do
  not add a firewall exception; inspect the pinned upstream binding behavior.
- **SSH authentication failure:** verify the runtime host, user, agent, or
  optional `-IdentityFile`. Do not store credentials or key paths here.
- **`remote port forwarding failed`:** the VM port may already be in use. Pick
  another loopback port and use the same value in the VM client URL.
- **SSH server forbids forwarding:** ask the VM administrator to review
  `AllowTcpForwarding`; the script does not edit SSH server configuration.
- **VM URL unreachable:** confirm both foreground laptop processes are still
  running and that the client uses VM loopback with the `/sse` path.
- **MCP initialization failure:** confirm the pinned server finished startup,
  verify the URL, and run the laptop-local HTTP tool-discovery test.
- **HTTP disconnect loses the Appium session:** this is expected safe cleanup.
  Keep one client connection open and explicitly delete the session before
  closing it; do not enable persistence merely to mask disconnects.
