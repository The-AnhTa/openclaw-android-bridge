import { DatabaseSync } from "node:sqlite";
import { pathToFileURL } from "node:url";

const UNSUPPORTED_SCHEMA = "Unsupported OpenClaw trajectory SQLite schema.";
const EXPECTED_TRAJECTORY_COLUMNS = [
  { name: "session_id", type: "TEXT", notnull: 1, pk: 1 },
  { name: "seq", type: "INTEGER", notnull: 1, pk: 2 },
  { name: "run_id", type: "TEXT", notnull: 0, pk: 0 },
  { name: "event_json", type: "TEXT", notnull: 1, pk: 0 },
  { name: "created_at", type: "INTEGER", notnull: 1, pk: 0 },
];

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function asString(value) {
  return typeof value === "string" ? value : "";
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
  if (
    data.aborted === true ||
    data.externalAbort === true ||
    data.timedOut === true ||
    data.idleTimedOut === true ||
    data.timedOutDuringCompaction === true ||
    data.timedOutDuringToolExecution === true ||
    data.timedOutByRunBudget === true
  ) {
    return false;
  }
  if (
    data.promptError !== undefined &&
    data.promptError !== null &&
    !(typeof data.promptError === "string" && data.promptError.trim() === "")
  ) {
    return false;
  }
  if (
    data.terminalError !== undefined &&
    data.terminalError !== null &&
    !(typeof data.terminalError === "string" && data.terminalError.trim() === "")
  ) {
    return false;
  }
  if (["done", "completed", "success"].includes(status)) {
    return true;
  }

  // OpenClaw 2026.9.7 embedded-agent model.completed rows carry terminal
  // booleans rather than a literal status=done value.
  return data.aborted === false && data.timedOut === false;
}

function hasExpectedTrajectoryColumns(database) {
  const columns = database.prepare("PRAGMA table_info('trajectory_runtime_events')").all();
  if (columns.length !== EXPECTED_TRAJECTORY_COLUMNS.length) {
    return false;
  }

  return EXPECTED_TRAJECTORY_COLUMNS.every((expected, index) => {
    const actual = columns[index];
    return (
      actual.name === expected.name &&
      asString(actual.type).toUpperCase() === expected.type &&
      Number(actual.notnull) === expected.notnull &&
      Number(actual.pk) === expected.pk
    );
  });
}

function hasExpectedSessionKeyColumns(database) {
  const columns = database.prepare("PRAGMA table_info('session_nodes')").all();
  const byName = new Map(columns.map((column) => [column.name, column]));
  const sessionKey = byName.get("session_key");
  const currentSessionId = byName.get("current_session_id");
  return Boolean(
    sessionKey &&
      currentSessionId &&
      asString(sessionKey.type).toUpperCase() === "TEXT" &&
      Number(sessionKey.notnull) === 1 &&
      Number(sessionKey.pk) === 1 &&
      asString(currentSessionId.type).toUpperCase() === "TEXT" &&
      Number(currentSessionId.notnull) === 1,
  );
}

function assertSupportedSchema(database) {
  const schemaRows = database
    .prepare(
      `SELECT name, sql
       FROM sqlite_schema
       WHERE type = 'table'
         AND name IN ('session_nodes', 'trajectory_runtime_events')
       ORDER BY name`,
    )
    .all();
  if (
    schemaRows.length !== 2 ||
    schemaRows.some((row) => typeof row.sql !== "string" || row.sql.trim() === "") ||
    !hasExpectedSessionKeyColumns(database) ||
    !hasExpectedTrajectoryColumns(database)
  ) {
    throw new Error(UNSUPPORTED_SCHEMA);
  }
}

function projectEvents(rows, expectedSessionId, expectedSessionKey) {
  const projection = {
    source: "openclaw-2026.9.7-sqlite",
    databaseReadOnly: true,
    eventCount: rows.length,
    toolCalls: [],
    toolResults: [],
    modelCompletions: [],
    sessionEnds: [],
  };

  for (const [index, row] of rows.entries()) {
    let event;
    try {
      event = JSON.parse(row.event_json);
    } catch {
      throw new Error(`Invalid runtime trajectory event JSON at storage sequence ${row.seq}.`);
    }

    if (
      !isObject(event) ||
      event.traceSchema !== "openclaw-trajectory" ||
      event.schemaVersion !== 1 ||
      event.source !== "runtime" ||
      typeof event.type !== "string" ||
      event.sessionId !== expectedSessionId ||
      (event.sessionKey !== undefined && event.sessionKey !== expectedSessionKey)
    ) {
      throw new Error(`Invalid runtime trajectory event envelope at storage sequence ${row.seq}.`);
    }

    const sequence = index + 1;
    const data = isObject(event.data) ? event.data : {};
    if (event.type === "tool.call") {
      const args = isObject(data.args)
        ? data.args
        : isObject(data.arguments)
          ? data.arguments
          : {};
      const argsText = JSON.stringify(args);
      projection.toolCalls.push({
        lineNumber: sequence,
        sessionKey: expectedSessionKey,
        name: asString(data.name),
        toolCallId: asString(data.toolCallId || data.callId),
        isCreate: asString(args.action).toLowerCase() === "create",
        isDelete: asString(args.action).toLowerCase() === "delete",
        activatesSettings:
          asString(args.action).toLowerCase() === "activate" &&
          /com\.android\.settings/i.test(argsText),
      });
    } else if (event.type === "tool.result") {
      const resultText = JSON.stringify(data.result ?? data);
      projection.toolResults.push({
        lineNumber: sequence,
        sessionKey: expectedSessionKey,
        name: asString(data.name),
        toolCallId: asString(data.toolCallId || data.callId),
        success: isSuccessfulToolResult(data),
        hasAndroidHierarchy: /(<\?xml|<hierarchy|<node\b|\\u003c(?:\?xml|hierarchy|node\b))/i.test(
          resultText,
        ),
        mentionsAndroidSettings: /com\.android\.settings/i.test(resultText),
      });
    } else if (event.type === "model.completed") {
      projection.modelCompletions.push({
        lineNumber: sequence,
        sessionKey: expectedSessionKey,
        done: isCompletedModel(data),
      });
    } else if (event.type === "session.ended") {
      projection.sessionEnds.push({
        lineNumber: sequence,
        sessionKey: expectedSessionKey,
        status: asString(data.status).toLowerCase(),
      });
    }
  }

  return projection;
}

export function readOpenClawTrajectorySqliteProjection(databasePath, sessionKey) {
  if (typeof databasePath !== "string" || databasePath.trim() === "") {
    throw new Error("An OpenClaw SQLite database path is required.");
  }
  if (typeof sessionKey !== "string" || sessionKey.trim() === "") {
    throw new Error("An exact OpenClaw session key is required.");
  }

  let database;
  try {
    database = new DatabaseSync(databasePath, { readOnly: true });
    database.exec("PRAGMA query_only = ON");
    const queryOnly = database.prepare("PRAGMA query_only").get();
    if (Number(queryOnly.query_only) !== 1) {
      throw new Error("The OpenClaw SQLite database is not query-only.");
    }

    assertSupportedSchema(database);
    const session = database
      .prepare(
        `SELECT current_session_id AS session_id
         FROM session_nodes
         WHERE session_key = ?`,
      )
      .get(sessionKey);
    if (!session || typeof session.session_id !== "string" || session.session_id === "") {
      throw new Error("The exact OpenClaw session key was not found in the selected agent store.");
    }

    const rows = database
      .prepare(
        `SELECT seq, event_json
         FROM trajectory_runtime_events
         WHERE session_id = ?
         ORDER BY seq ASC`,
      )
      .all(session.session_id);
    if (rows.length === 0) {
      throw new Error("No runtime trajectory events exist for the exact OpenClaw session key.");
    }

    return projectEvents(rows, session.session_id, sessionKey);
  } finally {
    database?.close();
  }
}

async function runCli() {
  const databasePath = process.argv[2];
  const sessionKey = process.argv[3];
  try {
    const projection = readOpenClawTrajectorySqliteProjection(databasePath, sessionKey);
    process.stdout.write(JSON.stringify(projection));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 2;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await runCli();
}
