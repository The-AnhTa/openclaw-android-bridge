# openclaw-android-bridge

A reproducible bridge for controlling a physical Android phone from a local
language model through a remote OpenClaw deployment.

The eventual request path is:

```text
Local GLM -> OpenClaw on a remote VM -> MCP over an SSH tunnel
          -> appium-mcp on a Windows laptop -> embedded UiAutomator2
          -> ADB -> physical Android phone
```

Implemented repository stages are Milestone 0 (repository foundation),
Milestone 1 (Windows and Android prerequisite validation), and Milestone 2
(local Appium MCP smoke testing). OpenClaw, the remote VM, SSH tunnelling, and
network transport belong to later milestones and are not configured here.

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

See [prerequisites](docs/prerequisites.md), [architecture](docs/architecture.md),
[Appium MCP](docs/appium-mcp.md), and [tested versions](docs/tested-versions.md)
for details.
