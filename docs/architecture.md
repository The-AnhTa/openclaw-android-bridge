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
USB access. The future SSH tunnel will carry MCP traffic without exposing the
local service on a network interface.

## Current scope

- Milestone 0 establishes the repository and documentation.
- Milestone 1 validates Windows tools, Android Studio's bundled JBR, the Android
  SDK, ADB, and exactly one authorized physical device.
- Milestone 2 validates a local MCP-to-Android path over stdio using the pinned
  repository-local Appium MCP and its embedded UiAutomator2 driver.

The validation scripts make process-local environment changes only. They do not
install software, edit the registry, change persistent environment variables,
or start a network listener.

## Deferred milestones

OpenClaw configuration, the remote VM, SSH tunnelling, and a controlled bridge
transport will be addressed later. Milestone 2 does not open a network port.
