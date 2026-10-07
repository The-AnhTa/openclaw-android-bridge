import { existsSync, readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";

const [databasePath, specificationPath] = process.argv.slice(2);
if (!databasePath || !specificationPath) {
  console.error("Usage: node test-openclaw-sqlite-fixture.mjs <database> <specification.json>");
  process.exit(2);
}

const specification = JSON.parse(readFileSync(specificationPath, "utf8"));
if (existsSync(databasePath)) {
  throw new Error("Refusing to overwrite an existing SQLite fixture.");
}
const database = new DatabaseSync(databasePath);
try {
  database.exec(`
    CREATE TABLE session_nodes (
      session_key TEXT NOT NULL PRIMARY KEY,
      current_session_id TEXT NOT NULL
    ) STRICT;
  `);
  if (specification.unsupportedSchema === true) {
    database.exec(`
      CREATE TABLE trajectory_runtime_events (
        session_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        run_id TEXT,
        payload_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (session_id, seq)
      ) STRICT;
    `);
  } else {
    database.exec(`
      CREATE TABLE trajectory_runtime_events (
        session_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        run_id TEXT,
        event_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (session_id, seq)
      ) STRICT;
    `);
  }

  const insertSession = database.prepare(
    "INSERT INTO session_nodes (session_key, current_session_id) VALUES (?, ?)",
  );
  for (const session of specification.sessions ?? []) {
    insertSession.run(session.key, session.id);
  }

  const payloadColumn = specification.unsupportedSchema === true ? "payload_json" : "event_json";
  const insertEvent = database.prepare(
    `INSERT INTO trajectory_runtime_events
       (session_id, seq, run_id, ${payloadColumn}, created_at)
     VALUES (?, ?, ?, ?, ?)`,
  );
  for (const event of specification.events ?? []) {
    insertEvent.run(
      event.sessionId,
      event.seq,
      event.runId ?? "fixture-run",
      JSON.stringify(event.event),
      event.createdAt ?? event.seq,
    );
  }
} finally {
  database.close();
}
