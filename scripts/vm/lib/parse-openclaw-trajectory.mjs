import { readFileSync } from "node:fs";

const inputPath = process.argv[2];
if (!inputPath) {
  console.error("An events.jsonl path is required.");
  process.exit(2);
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function asString(value) {
  return typeof value === "string" ? value : "";
}

function jsonText(value) {
  try {
    return JSON.stringify(value ?? null);
  } catch {
    return "";
  }
}

function isSuccessfulToolResult(data) {
  if (data.success === true) {
    return true;
  }
  if (data.success === false || data.isError === true) {
    return false;
  }

  const status = asString(data.status).toLowerCase();
  return ["ok", "done", "completed", "success"].includes(status);
}

function isCompletedModel(data) {
  const status = asString(data.status).toLowerCase();
  if (["error", "failed", "aborted", "timeout", "timed_out"].includes(status)) {
    return false;
  }
  if (data.aborted === true || data.externalAbort === true || data.timedOut === true ||
      data.idleTimedOut === true || data.timedOutDuringCompaction === true ||
      data.timedOutDuringToolExecution === true) {
    return false;
  }
  if (typeof data.promptError === "string" && data.promptError.trim() !== "") {
    return false;
  }
  if (["done", "completed", "success"].includes(status)) {
    return true;
  }

  return data.aborted === false && data.timedOut === false;
}

function parseTrajectoryLine(raw, lineNumber) {
  try {
    return {
      value: JSON.parse(raw),
      compatibilityRepairs: 0,
    };
  } catch (originalError) {
    let compatibilityRepairs = 0;
    const repaired = raw.replace(
      /password=\*{3}"\*{3}\\"/gi,
      () => {
        compatibilityRepairs += 1;
        return String.raw`password=\"***\"`;
      },
    );

    if (compatibilityRepairs === 0) {
      throw new Error(`Invalid JSONL at line ${lineNumber}: ${originalError.message}`);
    }

    let value;
    try {
      value = JSON.parse(repaired);
    } catch {
      throw new Error(`Invalid JSONL at line ${lineNumber}: ${originalError.message}`);
    }

    if (
      value?.traceSchema !== "openclaw-trajectory" ||
      value?.schemaVersion !== 1 ||
      value?.type !== "tool.result"
    ) {
      throw new Error(`Invalid JSONL at line ${lineNumber}: ${originalError.message}`);
    }

    return {
      value,
      compatibilityRepairs,
    };
  }
}

let input;
try {
  input = readFileSync(inputPath, "utf8");
} catch (error) {
  console.error(`Could not read events.jsonl: ${error.message}`);
  process.exit(2);
}

const projection = {
  nonBlankLineCount: 0,
  compatibilityRepairs: 0,
  toolCalls: [],
  toolResults: [],
  modelCompletions: [],
  sessionEnds: [],
};

const lines = input.split(/\r?\n/);
for (let index = 0; index < lines.length; index += 1) {
  const line = lines[index];
  const lineNumber = index + 1;
  if (line.trim() === "") {
    continue;
  }

  let parsed;
  try {
    parsed = parseTrajectoryLine(line, lineNumber);
  } catch (error) {
    console.error(error.message);
    process.exit(2);
  }

  const event = parsed.value;
  projection.nonBlankLineCount += 1;
  projection.compatibilityRepairs += parsed.compatibilityRepairs;
  if (!isObject(event)) {
    continue;
  }

  const type = asString(event.type);
  const data = isObject(event.data) ? event.data : {};
  const sessionKey = asString(event.sessionKey || data.sessionKey);

  if (type === "tool.call") {
    projection.toolCalls.push({
      lineNumber,
      sessionKey,
      name: asString(data.name),
      toolCallId: asString(data.toolCallId || data.callId),
      argumentsJson: jsonText(data.arguments),
    });
  } else if (type === "tool.result") {
    const dataJson = jsonText(data);
    projection.toolResults.push({
      lineNumber,
      sessionKey,
      name: asString(data.name),
      toolCallId: asString(data.toolCallId || data.callId),
      success: isSuccessfulToolResult(data),
      hasAndroidHierarchy: /(<\?xml|<hierarchy|<node\b|\\u003c(?:\?xml|hierarchy|node\b))/i.test(dataJson),
      mentionsAndroidSettings: /com\.android\.settings/i.test(dataJson),
    });
  } else if (type === "model.completed") {
    projection.modelCompletions.push({
      lineNumber,
      sessionKey,
      done: isCompletedModel(data),
    });
  } else if (type === "session.ended") {
    projection.sessionEnds.push({
      lineNumber,
      sessionKey,
      status: asString(data.status).toLowerCase(),
    });
  }
}

process.stdout.write(JSON.stringify(projection));
