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

The only explicit version floor currently enforced by the doctor is Node.js
22 or newer.

The Appium MCP and embedded-driver versions above were confirmed from the
installed `npm ci` dependency tree. On the initial physical Xiaomi test device,
MCP stdio connection, tool discovery, and device selection succeeded, but the
device rejected deployment of the embedded driver's Android test server with
`INSTALL_FAILED_USER_RESTRICTED`. Consequently, an end-to-end UiAutomator2
session is not yet recorded as passing on that device.

