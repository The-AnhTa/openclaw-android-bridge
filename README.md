# openclaw-android-bridge

A reproducible bridge for controlling a physical Android phone from a local
language model through a remote OpenClaw deployment.

The eventual request path is:

```text
Local GLM -> OpenClaw on a remote VM -> MCP over an SSH tunnel
          -> appium-mcp on a Windows laptop -> embedded UiAutomator2
          -> ADB -> physical Android phone
```

This repository currently covers only Milestone 0 (repository foundation) and
Milestone 1 (Windows and Android prerequisite validation). OpenClaw, SSH
tunnelling, Appium MCP, Appium, and UiAutomator2 integration belong to later
milestones and are not configured here.

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

See [prerequisites](docs/prerequisites.md), [architecture](docs/architecture.md),
and [tested versions](docs/tested-versions.md) for details.
