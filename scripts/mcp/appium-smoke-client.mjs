import { access } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const REQUIRED_TOOLS = [
  "select_device",
  "appium_session_management",
  "appium_get_page_source",
  "appium_app_lifecycle",
];
const TOOL_TIMEOUT_MS = 90_000;
const SESSION_TIMEOUT_MS = 240_000;
const MAX_DIAGNOSTIC_CHARACTERS = 16_000;

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(scriptDirectory, "..", "..");
const serverEntryPoint = join(
  repositoryRoot,
  "node_modules",
  "appium-mcp",
  "dist",
  "index.js",
);
const deviceUdid = process.env.OPENCLAW_ANDROID_UDID;

let diagnosticOutput = "";
let client;
let transport;
let sessionCreated = false;
let primaryError;
let cleanupError;

function pass(message) {
  console.log(`[PASS] ${message}`);
}

function warn(message) {
  console.warn(`[WARN] ${message}`);
}

function resultText(result) {
  return (result?.content ?? [])
    .filter((item) => item.type === "text")
    .map((item) => item.text)
    .join("\n");
}

function conciseDetail(value, maximumLength = 1_200) {
  const redacted = deviceUdid
    ? value.split(deviceUdid).join("<device-serial>")
    : value;
  const normalized = redacted.replace(/\s+/g, " ").trim();
  return normalized.length > maximumLength
    ? `${normalized.slice(0, maximumLength)}...`
    : normalized;
}

function requireSuccessfulToolResult(result, operation) {
  if (result?.isError) {
    const detail = conciseDetail(resultText(result));
    throw new Error(`${operation} failed: ${detail || "unknown MCP tool error"}`);
  }
  return result;
}

function appendDiagnostics(chunk) {
  diagnosticOutput += chunk.toString();
  if (diagnosticOutput.length > MAX_DIAGNOSTIC_CHARACTERS) {
    diagnosticOutput = diagnosticOutput.slice(-MAX_DIAGNOSTIC_CHARACTERS);
  }
}

function printDiagnostics() {
  const redacted = deviceUdid
    ? diagnosticOutput.split(deviceUdid).join("<device-serial>")
    : diagnosticOutput;
  const lines = redacted
    .split(/\r?\n/)
    .map((line) => line.trimEnd())
    .filter(Boolean)
    .slice(-60);
  if (lines.length > 0) {
    console.error("[WARN] Recent appium-mcp diagnostics:");
    for (const line of lines) {
      console.error(`  ${line}`);
    }
  }
}

async function callTool(name, args, timeout = TOOL_TIMEOUT_MS) {
  const result = await client.callTool(
    { name, arguments: args },
    undefined,
    { timeout, maxTotalTimeout: timeout },
  );
  return requireSuccessfulToolResult(result, name);
}

try {
  if (!deviceUdid) {
    throw new Error("No validated Android device UDID was supplied by the PowerShell prerequisite check.");
  }
  await access(serverEntryPoint);

  transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverEntryPoint],
    cwd: repositoryRoot,
    stderr: "pipe",
    env: {
      JAVA_HOME: process.env.JAVA_HOME,
      ANDROID_HOME: process.env.ANDROID_HOME,
      PATH: process.env.PATH,
      ALLOW_REMOTE_APP_URLS: "false",
      AI_VISION_ENABLED: "false",
      APPIUM_MCP_DOCS_ENABLED: "false",
      APPIUM_MCP_OTEL_ENABLED: "false",
      APPIUM_MCP_APPS_ENABLED: "false",
      APPIUM_MCP_ON_CLIENT_DISCONNECT: "delete_all",
      NO_UI: "true",
    },
  });
  transport.stderr?.on("data", appendDiagnostics);

  client = new Client(
    { name: "openclaw-android-bridge-smoke-test", version: "0.2.0" },
    { capabilities: {} },
  );
  await client.connect(transport, {
    timeout: SESSION_TIMEOUT_MS,
    maxTotalTimeout: SESSION_TIMEOUT_MS,
  });
  pass("MCP stdio connection established");

  const toolsResponse = await client.listTools(undefined, { timeout: TOOL_TIMEOUT_MS });
  const toolNames = new Set(toolsResponse.tools.map((tool) => tool.name));
  const missingTools = REQUIRED_TOOLS.filter((name) => !toolNames.has(name));
  if (missingTools.length > 0) {
    throw new Error(`Required MCP tools are missing: ${missingTools.join(", ")}`);
  }
  pass("Required Appium MCP tools discovered");

  await callTool("select_device", {
    platform: "android",
    deviceUdid,
  });
  pass("Device selected");

  const capabilities = {
    platformName: "Android",
    "appium:automationName": "UiAutomator2",
    "appium:udid": deviceUdid,
    "appium:noReset": true,
    "appium:autoGrantPermissions": false,
    "appium:ignoreHiddenApiPolicyError": true,
    "appium:skipDeviceInitialization": true,
    "appium:skipLogcatCapture": true,
    "appium:skipUnlock": true,
  };
  await callTool(
    "appium_session_management",
    {
      action: "create",
      platform: "android",
      capabilities: JSON.stringify(capabilities),
    },
    SESSION_TIMEOUT_MS,
  );
  sessionCreated = true;
  pass("Embedded UiAutomator2 session created");

  await callTool("appium_app_lifecycle", {
    action: "activate",
    id: "com.android.settings",
  });
  pass("Android Settings activated");

  const pageSourceResult = await callTool("appium_get_page_source", {});
  const pageSourceText = resultText(pageSourceResult);
  if (!/<(?:\?xml|hierarchy|android\.)/i.test(pageSourceText)) {
    throw new Error("Appium MCP returned no recognizable Android UI XML.");
  }
  pass("Android page source retrieved");

  if (toolNames.has("appium_mobile_device_info")) {
    try {
      await callTool("appium_mobile_device_info", { action: "info" });
      pass("Basic device information retrieved");
    } catch (error) {
      warn(`Basic device information was unavailable: ${error.message}`);
    }
  }
} catch (error) {
  primaryError = error;
} finally {
  if (sessionCreated && client) {
    try {
      await callTool(
        "appium_session_management",
        { action: "delete" },
        SESSION_TIMEOUT_MS,
      );
      sessionCreated = false;
      pass("Session deleted");
    } catch (error) {
      cleanupError = error;
    }
  }

  if (client) {
    try {
      await client.close();
    } catch (error) {
      cleanupError ??= error;
    }
  } else if (transport) {
    try {
      await transport.close();
    } catch (error) {
      cleanupError ??= error;
    }
  }
}

if (primaryError || cleanupError) {
  const error = primaryError ?? cleanupError;
  console.error(`[FAIL] Milestone 2 smoke test failed: ${conciseDetail(error.message)}`);
  if (cleanupError && primaryError) {
    console.error(`[FAIL] Session cleanup also failed: ${conciseDetail(cleanupError.message)}`);
  }
  printDiagnostics();
  process.exitCode = 1;
} else {
  pass("Milestone 2 local Appium MCP smoke test passed");
}
