import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const REQUIRED_TOOLS = [
  "select_device",
  "appium_session_management",
  "appium_get_page_source",
  "appium_app_lifecycle",
];
const REQUEST_TIMEOUT_MS = 90_000;
const SESSION_TIMEOUT_MS = 240_000;

function parseArguments(argv) {
  const result = {
    listToolsOnly: false,
    vmMode: false,
    url: process.env.APPIUM_MCP_URL,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--list-tools-only") {
      result.listToolsOnly = true;
    } else if (argument === "--vm") {
      result.vmMode = true;
    } else if (argument === "--url") {
      index += 1;
      result.url = argv[index];
    } else if (argument.startsWith("--url=")) {
      result.url = argument.slice("--url=".length);
    } else {
      throw new Error(`Unknown argument: ${argument}`);
    }
  }
  return result;
}

function validateLoopbackUrl(value) {
  if (!value) {
    throw new Error("Supply --url http://127.0.0.1:<port>/sse or set APPIUM_MCP_URL.");
  }

  const url = new URL(value);
  const hostname = url.hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (url.protocol !== "http:" || !["127.0.0.1", "::1"].includes(hostname)) {
    throw new Error("The MCP URL must use HTTP and a literal loopback address (127.0.0.1 or ::1).");
  }
  if (url.username || url.password || url.search || url.hash) {
    throw new Error("The MCP URL must not contain credentials, a query, or a fragment.");
  }
  return url;
}

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

let deviceUdid;

function conciseDetail(value, maximumLength = 1_200) {
  const redacted = deviceUdid
    ? String(value).split(deviceUdid).join("<device-serial>")
    : String(value);
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

function getSelectedDeviceUdid(result) {
  const text = resultText(result).trim();
  try {
    const selection = JSON.parse(text);
    const udid = selection?.capabilities?.["appium:udid"];
    if (typeof udid === "string" && udid.length > 0) {
      return udid;
    }
  } catch {
    // A non-JSON response normally means multiple devices require selection.
  }
  throw new Error("select_device did not auto-select exactly one Android device.");
}

let options;
let client;
let transport;
let connected = false;
let sessionCreated = false;
let sessionDeleted = false;
let primaryError;
let cleanupError;

async function callTool(name, args, timeout = REQUEST_TIMEOUT_MS) {
  const result = await client.callTool(
    { name, arguments: args },
    undefined,
    { timeout, maxTotalTimeout: timeout },
  );
  return requireSuccessfulToolResult(result, name);
}

try {
  options = parseArguments(process.argv.slice(2));
  const mcpUrl = validateLoopbackUrl(options.url);
  transport = new StreamableHTTPClientTransport(mcpUrl, {
    reconnectionOptions: {
      maxReconnectionDelay: 1_000,
      initialReconnectionDelay: 1_000,
      reconnectionDelayGrowFactor: 1,
      maxRetries: 0,
    },
  });
  client = new Client(
    { name: "openclaw-android-bridge-remote-smoke-test", version: "0.3.0" },
    { capabilities: {} },
  );

  await client.connect(transport, {
    timeout: REQUEST_TIMEOUT_MS,
    maxTotalTimeout: REQUEST_TIMEOUT_MS,
  });
  connected = true;
  pass("Connected to the loopback /sse route using StreamableHTTPClientTransport");
  if (options.vmMode) {
    warn("VM mode cannot identify the SSH hop; verify the reverse forward independently");
  }
  pass("MCP initialization completed");

  const toolsResponse = await client.listTools(undefined, {
    timeout: REQUEST_TIMEOUT_MS,
    maxTotalTimeout: REQUEST_TIMEOUT_MS,
  });
  const toolNames = new Set(toolsResponse.tools.map((tool) => tool.name));
  const missingTools = REQUIRED_TOOLS.filter((name) => !toolNames.has(name));
  if (missingTools.length > 0) {
    throw new Error(`Required MCP tools are missing: ${missingTools.join(", ")}`);
  }
  pass("Required Appium MCP tools discovered");

  if (!options.listToolsOnly) {
    const selectResult = await callTool("select_device", { platform: "android" });
    deviceUdid = getSelectedDeviceUdid(selectResult);
    pass("Android device selected");

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
    if (!/<(?:\?xml|hierarchy|android\.)/i.test(resultText(pageSourceResult))) {
      throw new Error("Appium MCP returned no recognizable Android UI XML.");
    }
    pass("Android page source retrieved");

    if (toolNames.has("appium_mobile_device_info")) {
      try {
        await callTool("appium_mobile_device_info", { action: "info" });
        pass("Basic device information retrieved");
      } catch (error) {
        warn(`Basic device information was unavailable: ${conciseDetail(error.message)}`);
      }
    }

    await callTool(
      "appium_session_management",
      { action: "delete" },
      SESSION_TIMEOUT_MS,
    );
    sessionCreated = false;
    sessionDeleted = true;
    pass("Appium session deleted");
  }
} catch (error) {
  primaryError = error;
} finally {
  if (sessionCreated) {
    try {
      await callTool(
        "appium_session_management",
        { action: "delete" },
        SESSION_TIMEOUT_MS,
      );
      sessionCreated = false;
      sessionDeleted = true;
      pass("Appium session deleted during cleanup");
    } catch (error) {
      cleanupError = error;
    }
  }

  if (connected) {
    try {
      await client.close();
      connected = false;
      pass("MCP connection closed");
    } catch (error) {
      cleanupError ??= error;
    }
  }
}

if (primaryError || cleanupError) {
  const error = primaryError ?? cleanupError;
  console.error(`[FAIL] MCP HTTP smoke test failed: ${conciseDetail(error.message)}`);
  if (cleanupError && primaryError) {
    console.error(`[FAIL] Cleanup also failed: ${conciseDetail(cleanupError.message)}`);
  }
  process.exitCode = 1;
} else if (options?.listToolsOnly) {
  pass("Streamable HTTP MCP tool-discovery smoke test passed");
} else if (!sessionDeleted) {
  console.error("[FAIL] MCP HTTP smoke test failed: Appium session deletion was not confirmed.");
  process.exitCode = 1;
} else if (!options?.vmMode) {
  pass("Full Streamable HTTP-to-Android smoke test passed; SSH was not asserted");
} else {
  pass("VM-mode Streamable HTTP-to-Android smoke test passed; SSH requires independent evidence");
}
