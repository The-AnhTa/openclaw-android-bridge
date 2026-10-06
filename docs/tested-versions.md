# Tested versions

The following versions describe the Windows development environment used for
the initial Milestone 0 and Milestone 1 validation. They are a tested snapshot,
not a list of minimum supported versions.

| Component | Tested version |
| --- | --- |
| Git for Windows | 2.55.0.windows.3 |
| Node.js | 26.8.1 |
| npm | 11.19.0 |
| Android Studio bundled OpenJDK | 25.0.3 |
| Android Debug Bridge | 37.0.1 |
| appium-mcp | 1.95.0 |
| MCP TypeScript SDK | 1.32.1 |
| Embedded appium-uiautomator2-driver | 8.7.0 |
| Embedded appium-uiautomator2-server | 10.6.6 |
| Tested Android device | Samsung SM-A155F |
| Tested Android OS / API | Android 16 / API 36 |

The only explicit version floor currently enforced by the doctor is Node.js
22 or newer.

The Appium MCP and embedded-driver versions above were confirmed from the
installed `npm ci` dependency tree. Milestone 2 subsequently passed end to end
on a physical Samsung Android phone: stdio initialization, tool discovery,
device selection, embedded UiAutomator2 session creation, Android Settings
activation, page-source and device-information retrieval, and clean deletion.
These are tested versions, not minimum versions. Milestone 3 subsequently
passed from a Node MCP client on the VM through the loopback-only SSH reverse
tunnel and laptop Appium MCP endpoint to the same physical device. The device
model and OS version are observations, not implementation dependencies.
