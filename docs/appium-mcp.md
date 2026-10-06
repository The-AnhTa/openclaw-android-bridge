# Local Appium MCP

## Why the driver is embedded

This project pins `appium-mcp` 1.95.0. That package depends on the
UiAutomator2 driver and creates it in-process when
`appium_session_management` is called without `remoteServerUrl`. There is no
standalone Appium server to install or operate, and collaborators must not run
`appium driver install uiautomator2`.

The embedded driver still manages its own Android instrumentation components
on the connected phone when a session starts. This is internal driver setup,
not installation of an application under test. The smoke client never supplies
an `appium:app` capability and never calls Appium MCP's install, uninstall,
permission, data-clearing, settings, or shell-command operations.

## Why versions are pinned

Mobile automation combines an MCP protocol implementation, Appium driver code,
Android instrumentation, Java, and SDK tools. Exact npm versions and the lock
file make that combination reproducible. The repository declares exactly
`appium-mcp` 1.95.0 and uses `npm ci`; it does not use `@latest` or a global
installation.

Documentation/ML tools, AI vision, telemetry, MCP UI components, and remote app
URLs are disabled for the smoke test. Its capabilities also disable automatic
permission grants and preserve application data.

## Why stdio

Milestone 2 has one local client and one local server, so stdio is the smallest
and safest transport. The client starts the executable from this repository's
`node_modules`, and Appium MCP communicates only through the child process's
standard streams. No HTTP transport or listening TCP port is created.

A later milestone will make Appium MCP reachable from the remote VM through a
controlled transport. OpenClaw, the VM, and SSH tunnelling are deliberately out
of scope here.

## Install and validate

From a normal PowerShell prompt in the repository root:

```powershell
npm ci
.\scripts\windows\doctor.ps1
.\scripts\windows\test-appium-mcp.ps1
```

The acceptance script reuses Milestone 1 discovery for Android Studio's JBR,
the SDK, ADB, and the authorized device. It then selects that device through
MCP, creates an embedded UiAutomator2 session, activates
`com.android.settings`, verifies non-empty Android UI XML, and deletes the
session.

For manual MCP server startup over stdio, use:

```powershell
.\scripts\windows\start-appium-mcp.ps1
```

Startup diagnostics go to stderr so stdout remains reserved for the MCP
protocol. The script does not open a network listener.

## Device policy failures

Some vendor Android builds restrict USB deployment of test instrumentation. If
session creation reports `INSTALL_FAILED_USER_RESTRICTED`, the scripts do not
bypass that policy, grant privileged permissions, or change phone settings.
Resolve the phone's own authorization or organizational policy outside the
script, then rerun the acceptance command.
