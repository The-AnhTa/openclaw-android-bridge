# Prerequisites

## Minimal Windows prerequisites

1. Git
2. Node.js 22 or newer (including npm)
3. Android Studio
4. The Windows OpenSSH client
5. A physical Android phone with Developer Options and USB debugging enabled

Connect the phone by USB, unlock it, and accept the computer's USB-debugging
authorization prompt before validation.

Android Studio already supplies the Java runtime and Android SDK needed by this
project. The scripts automatically discover Android Studio's bundled JBR and
the SDK's `adb.exe`; do not install a separate JDK or standalone ADB for this
architecture. Standalone Appium, appium-mcp, and UiAutomator2 are also not
prerequisites for the current milestones.

## Validate the machine

Run from the repository root in a normal, non-Administrator PowerShell prompt:

```powershell
.\scripts\windows\doctor.ps1
```

The check requires exactly one connected device in the `device` state. It
reports no device, unauthorized, offline, and multiple-device conditions
separately. For a focused repeat of the Java, SDK, ADB, and phone checks, use:

```powershell
.\scripts\windows\check-device.ps1
```

Both scripts set `JAVA_HOME`, `ANDROID_HOME`, and any required `PATH` entries
only in the current PowerShell process. They do not persist settings or require
Administrator privileges.
