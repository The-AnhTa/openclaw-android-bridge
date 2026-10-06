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
- Milestone 3 targets a VM-side Node MCP client connected to Appium MCP through
  loopback-only Streamable HTTP and an SSH reverse forward.

Milestone 3 introduces the first network listener, but constrains it to laptop
loopback and validates the actual Windows socket after startup. The reverse
forward explicitly binds VM loopback and targets laptop loopback:

```text
VM 127.0.0.1:8765 -> SSH reverse forwarding -> laptop 127.0.0.1:8765
```

No LAN listener or firewall rule is part of the architecture. Scripts make
process-local environment changes only and do not edit the registry or
persistent environment variables.

## Deferred milestones

Milestone 3 is a target until its VM-side acceptance test succeeds. Milestone 4
will connect OpenClaw to the proven MCP endpoint; OpenClaw and the GLM are not
configured during Milestone 3.
