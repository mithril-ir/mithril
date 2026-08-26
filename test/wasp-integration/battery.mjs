// The HTTP battery of the Wasp Confinement Profile v0 vertical test.
//
// Test-only tooling, deliberately outside the confined deployable
// root: it exercises the generated Action exclusively through Wasp's
// real generated HTTP and authentication path (username/password
// signup and login, the bearer session, POST /operations/<route> with
// Wasp's superjson request envelope) and reaches the isolated test
// database directly only to bootstrap the scope entities and the
// authority tuples, to snapshot state, and to install and remove the
// temporary fault-injection and barrier machinery (triggers,
// functions, and sequences) that prove the production retry, error,
// and concurrency paths.  Nothing here is part of the confinement
// claim, and nothing here is added to the generated application.
//
// Environment: MITHRIL_WASP_SERVER_URL (the running built server),
// MITHRIL_WASP_MANIFEST (the generated manifest, read for the route,
// the target model, column, value, and argument names),
// MITHRIL_WASP_DATABASE_URL (the isolated database; psql must be on
// PATH).
//
// What is pinned:
//   * signup and login through Wasp's username/password path;
//   * 401 without a bearer session (the Action's own uniform answer)
//     and 401 with an invalid session (Wasp's answer), 400 for every
//     invalid argument shape — each with the complete authority
//     relation unchanged;
//   * every denied case — a member, an outsider, the actor as the
//     target, a missing target tuple, a foreign scope, and a scope
//     that does not exist — answers exactly 403 with byte-identical
//     uniform bodies, and the complete authority relation (sentinel
//     memberships in unrelated scopes included) is byte-identical
//     before and after;
//   * the allowed path changes exactly the target tuple;
//   * with a temporary trigger raising SQLSTATE 40001 on every update
//     (and advancing sequences, which no rollback undoes), the real
//     HTTP path performs exactly three transaction attempts, each in
//     a fresh transaction (three distinct increasing transaction
//     ids), answers the pinned 409, and changes nothing;
//   * with a temporary trigger raising a generic error, the real HTTP
//     path answers the pinned 500 and changes nothing;
//   * genuine concurrency: a temporary barrier trigger makes each
//     update wait until two transactions have reached it (a run that
//     serialized the two requests would wait out the barrier and be
//     counted as a timeout, failing the round); every round admits
//     only serial outcomes, never write skew, and the complete
//     relation after every round is exactly the expected one;
//   * every temporary trigger, function, and sequence is removed and
//     its removal verified.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const serverUrl = required("MITHRIL_WASP_SERVER_URL");
const manifest = JSON.parse(readFileSync(required("MITHRIL_WASP_MANIFEST"), "utf8"));
const databaseUrl = required("MITHRIL_WASP_DATABASE_URL");

function required(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value;
}

let failures = 0;
function check(name, condition, detail) {
  if (condition) {
    console.log(`ok: ${name}`);
  } else {
    failures += 1;
    console.log(`FAIL: ${name}${detail === undefined ? "" : ` — ${detail}`}`);
  }
}

// --- test-only database access ------------------------------------------

function sql(query) {
  return execFileSync("psql", [databaseUrl, "-q", "-t", "-A", "-v", "ON_ERROR_STOP=1", "-c", query], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

function quoteIdentifier(name) {
  return '"' + name.replace(/"/g, '""') + '"';
}

const subjectTable = quoteIdentifier(manifest.subjectEntity.model);
const scopeTable = quoteIdentifier(manifest.scopeEntity.model);
const authorityTable = quoteIdentifier(manifest.authorityRelation.model);
const subjectColumn = quoteIdentifier(manifest.subjectEndpoint.idField);
const scopeColumn = quoteIdentifier(manifest.scopeEndpoint.idField);
const payloadColumn = quoteIdentifier(manifest.authorityRelation.payloadColumn);
const [subjectArgument, scopeArgument, payloadArgument] = manifest.parameters.map((p) => p.argument);
const bottom = manifest.bottom.value;
const top = manifest.floor.value;
const route = manifest.caseAction.route;

function userId(username) {
  return Number(
    sql(
      `select u.id from ${subjectTable} u join "Auth" a on a."userId" = u.id ` +
        `join "AuthIdentity" ai on ai."authId" = a.id where ai."providerUserId" = '${username}';`,
    ),
  );
}

// The complete authority relation, every scope included.
function relationState() {
  return sql(
    `select coalesce(string_agg(${scopeColumn} || ':' || ${subjectColumn} || '=' || ${payloadColumn}, ',' order by ${scopeColumn}, ${subjectColumn}), '') ` +
      `from ${authorityTable};`,
  );
}

function setMembership(userIdValue, scopeId, value) {
  sql(
    `insert into ${authorityTable} (${subjectColumn}, ${scopeColumn}, ${payloadColumn}) values (${userIdValue}, ${scopeId}, '${value}') ` +
      `on conflict (${subjectColumn}, ${scopeColumn}) do update set ${payloadColumn} = excluded.${payloadColumn};`,
  );
}

function newScope() {
  return Number(sql(`insert into ${scopeTable} default values returning id;`));
}

// --- Wasp's real HTTP and authentication path -------------------------

async function post(path, body, session) {
  const headers = { "Content-Type": "application/json" };
  if (session !== undefined) {
    headers["Authorization"] = `Bearer ${session}`;
  }
  const response = await fetch(serverUrl + path, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
  const text = await response.text();
  return { status: response.status, text };
}

async function signup(username) {
  const response = await post("/auth/username/signup", { username, password: "password1" });
  if (response.status !== 200) {
    throw new Error(`signup of ${username} failed: ${response.status} ${response.text}`);
  }
}

async function login(username) {
  const response = await post("/auth/username/login", { username, password: "password1" });
  let json = null;
  try {
    json = JSON.parse(response.text);
  } catch {
    json = null;
  }
  if (response.status !== 200 || !json || typeof json.sessionId !== "string") {
    throw new Error(`login of ${username} failed: ${response.status} ${response.text}`);
  }
  return json.sessionId;
}

// The generated Action, invoked exactly as Wasp's client would:
// POST /operations/<route> with the superjson envelope { json: args }.
async function changeRole(session, target, scope, newValue) {
  const args = {};
  args[subjectArgument] = target;
  args[scopeArgument] = scope;
  args[payloadArgument] = newValue;
  return post(route, { json: args }, session);
}

async function waitForServer() {
  for (let attempt = 0; attempt < 120; attempt += 1) {
    try {
      const response = await fetch(serverUrl + "/");
      if (response.status === 200) {
        return;
      }
    } catch {
      // not up yet
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error("the Wasp server did not come up");
}

// The Action's own uniform response bodies (Wasp renders an HttpError
// as { message, data } and omits an undefined data).
const body401 = JSON.stringify({ message: "authentication required" });
const body400 = JSON.stringify({ message: "invalid arguments" });
const body403 = JSON.stringify({ message: "forbidden" });
const body409 = JSON.stringify({ message: "conflict" });
const body500 = JSON.stringify({ message: "internal error" });
// Wasp's superjson envelope of the Action's void result.
const body200 = JSON.stringify({ json: null, meta: { values: ["undefined"], v: 1 } });

// --- test-only fault-injection and barrier machinery ---------------------

const testObjects = {
  functions: ["mithril_test_conflict", "mithril_test_fault", "mithril_test_barrier"],
  triggers: ["mithril_test_conflict", "mithril_test_fault", "mithril_test_barrier"],
  sequences: [
    "mithril_test_attempts",
    "mithril_test_txid_1",
    "mithril_test_txid_2",
    "mithril_test_txid_3",
    "mithril_test_txid_4",
    "mithril_test_arrivals",
    "mithril_test_timeouts",
  ],
};

function installConflictTrigger() {
  sql(
    `create sequence mithril_test_attempts;
     create sequence mithril_test_txid_1; create sequence mithril_test_txid_2;
     create sequence mithril_test_txid_3; create sequence mithril_test_txid_4;
     create function mithril_test_conflict() returns trigger language plpgsql as $$
     declare n bigint;
     begin
       n := nextval('mithril_test_attempts');
       if n <= 4 then
         execute format('select setval(%L, %s)', 'mithril_test_txid_' || n, txid_current());
       end if;
       raise exception 'mithril test serialization failure' using errcode = '40001';
     end $$;
     create trigger mithril_test_conflict before update on ${authorityTable}
       for each row execute function mithril_test_conflict();`,
  );
}

function installFaultTrigger() {
  sql(
    `create function mithril_test_fault() returns trigger language plpgsql as $$
     begin
       raise exception 'mithril test fault';
     end $$;
     create trigger mithril_test_fault before update on ${authorityTable}
       for each row execute function mithril_test_fault();`,
  );
}

function installBarrierTrigger() {
  sql(
    `create sequence mithril_test_arrivals;
     create sequence mithril_test_timeouts;
     create function mithril_test_barrier() returns trigger language plpgsql as $$
     declare deadline timestamptz := clock_timestamp() + interval '5 seconds';
     begin
       perform nextval('mithril_test_arrivals');
       loop
         if (select last_value from mithril_test_arrivals) >= 2 then
           return new;
         end if;
         if clock_timestamp() > deadline then
           perform nextval('mithril_test_timeouts');
           return new;
         end if;
         perform pg_sleep(0.01);
       end loop;
     end $$;
     create trigger mithril_test_barrier before update on ${authorityTable}
       for each row execute function mithril_test_barrier();`,
  );
}

function removeTestObjects() {
  for (const trigger of testObjects.triggers) {
    sql(`drop trigger if exists ${trigger} on ${authorityTable};`);
  }
  for (const fn of testObjects.functions) {
    sql(`drop function if exists ${fn}();`);
  }
  for (const sequence of testObjects.sequences) {
    sql(`drop sequence if exists ${sequence};`);
  }
}

function remainingTestObjects() {
  const triggers = sql(`select count(*) from pg_trigger where tgname like 'mithril_test_%';`);
  const functions = sql(`select count(*) from pg_proc where proname like 'mithril_test_%';`);
  const sequences = sql(`select count(*) from pg_class where relkind = 'S' and relname like 'mithril_test_%';`);
  return `${triggers} triggers, ${functions} functions, ${sequences} sequences`;
}

function sequenceValue(name) {
  const [lastValue, isCalled] = sql(`select last_value, is_called from ${name};`).split("|");
  return { lastValue: Number(lastValue), isCalled: isCalled === "t" };
}

// --- the battery ---------------------------------------------------------

async function main() {
  await waitForServer();
  console.log(`server: ${serverUrl}, route: ${route}, authority model: ${manifest.authorityRelation.model}`);

  const stamp = `${Date.now()}`;
  const names = {
    admin: `admin${stamp}`,
    member: `member${stamp}`,
    outsider: `outsider${stamp}`,
    peer: `peer${stamp}`,
    bystander: `bystander${stamp}`,
  };
  for (const name of Object.values(names)) {
    await signup(name);
  }
  const adminSession = await login(names.admin);
  const memberSession = await login(names.member);
  const outsiderSession = await login(names.outsider);
  const peerSession = await login(names.peer);
  const admin = userId(names.admin);
  const member = userId(names.member);
  const outsider = userId(names.outsider);
  const peer = userId(names.peer);
  const bystander = userId(names.bystander);
  check(
    "signup and login through Wasp's username/password path",
    [admin, member, outsider, peer, bystander].every((id) => Number.isInteger(id) && id >= 1),
  );

  // The relevant scope and an unrelated sentinel scope, with sentinel
  // memberships in both.
  const scope = newScope();
  const otherScope = newScope();
  setMembership(admin, scope, top);
  setMembership(member, scope, bottom);
  setMembership(bystander, scope, bottom);
  setMembership(admin, otherScope, bottom);
  setMembership(member, otherScope, top);
  setMembership(bystander, otherScope, top);
  const expectedInitial =
    `${scope}:${admin}=${top},${scope}:${member}=${bottom},${scope}:${bystander}=${bottom},` +
    `${otherScope}:${admin}=${bottom},${otherScope}:${member}=${top},${otherScope}:${bystander}=${top}`;
  const initial = relationState();
  check("bootstrap state (complete relation, sentinels included)", initial === expectedInitial, initial);

  async function unchanged(name, run, expectedStatus, expectedBody) {
    const before = relationState();
    const response = await run();
    const after = relationState();
    check(`${name}: status ${expectedStatus}`, response.status === expectedStatus, `got ${response.status} ${response.text}`);
    if (expectedBody !== undefined) {
      check(`${name}: exact response bytes`, response.text === expectedBody, `got ${response.text}`);
    }
    check(`${name}: complete relation unchanged`, before === after && after === expectedInitial, after);
    return response;
  }

  // Unauthenticated: no bearer session at all — the Action's own 401.
  await unchanged("no bearer session", () => changeRole(undefined, member, scope, top), 401, body401);
  // An invalid bearer session — Wasp's own 401; the body is Wasp's,
  // so only its status and the unchanged state are pinned, plus the
  // absence of any authority value in it.
  {
    const response = await unchanged("invalid bearer session", () => changeRole("not-a-session", member, scope, top), 401);
    check("invalid bearer session: no authority value leaks", !response.text.includes(top) && !response.text.includes(bottom), response.text);
  }
  // Invalid input shapes: a non-integer target, an unknown payload
  // value, a missing body, a zero target, and a non-object envelope.
  await unchanged(
    "non-integer target argument",
    () => post(route, { json: { [subjectArgument]: "x", [scopeArgument]: scope, [payloadArgument]: top } }, adminSession),
    400,
    body400,
  );
  await unchanged("unknown payload value", () => changeRole(adminSession, member, scope, "NotAValue"), 400, body400);
  await unchanged("empty request envelope", () => post(route, {}, adminSession), 400, body400);
  await unchanged("zero entity reference", () => changeRole(adminSession, 0, scope, top), 400, body400);
  await unchanged("array envelope", () => post(route, { json: [member, scope, top] }, adminSession), 400, body400);

  // Every denied case: exactly 403, byte-identical bodies, the
  // complete relation byte-identical before and after.
  const deniedBodies = [];
  async function denied(name, run) {
    const response = await unchanged(name, run, 403, body403);
    deniedBodies.push(response.text);
  }
  await denied("a member changing another member", () => changeRole(memberSession, admin, scope, bottom));
  await denied("an outsider with no authority tuple", () => changeRole(outsiderSession, member, scope, top));
  await denied("the actor as the target (an admin changing their own role)", () => changeRole(adminSession, admin, scope, bottom));
  await denied("a missing target tuple", () => changeRole(adminSession, outsider, scope, top));
  await denied("a scope where the actor holds only the bottom value", () => changeRole(adminSession, member, otherScope, bottom));
  await denied("a scope that does not exist", () => changeRole(adminSession, member, scope + 1000000, top));
  await denied("a member using the sentinel scope's admin session against the main scope", () => changeRole(memberSession, bystander, scope, top));
  check("every denied response is byte-identical (uniform 403)", deniedBodies.every((b) => b === deniedBodies[0]), deniedBodies.join(" | "));

  // The one allowed path: an admin changing another existing member
  // changes exactly the target tuple.
  {
    const before = relationState();
    const response = await changeRole(adminSession, member, scope, top);
    const after = relationState();
    check("an admin promoting another member succeeds with 200", response.status === 200, `${response.status} ${response.text}`);
    check("the success response is the pinned superjson envelope of the void result", response.text === body200, response.text);
    check(
      "exactly the target tuple changed",
      after === before.replace(`${scope}:${member}=${bottom}`, `${scope}:${member}=${top}`) && after !== before,
      after,
    );
    const demote = await changeRole(adminSession, member, scope, bottom);
    check("an admin demoting another member succeeds with 200", demote.status === 200 && demote.text === body200, `${demote.status} ${demote.text}`);
    check("the relation is back to its initial state", relationState() === expectedInitial, relationState());
  }

  // P2034 exhaustion through the real HTTP path.
  removeTestObjects();
  installConflictTrigger();
  try {
    const before = relationState();
    const response = await changeRole(adminSession, member, scope, top);
    const after = relationState();
    const attempts = sequenceValue("mithril_test_attempts");
    const txids = [1, 2, 3, 4].map((n) => sequenceValue(`mithril_test_txid_${n}`));
    check("exhausted P2034 answers the pinned 409", response.status === 409 && response.text === body409, `${response.status} ${response.text}`);
    check("exactly three transaction attempts reached the update", attempts.isCalled && attempts.lastValue === 3, JSON.stringify(attempts));
    check(
      "every attempt ran in a fresh transaction (three distinct increasing transaction ids, no fourth attempt)",
      txids[0].isCalled &&
        txids[1].isCalled &&
        txids[2].isCalled &&
        !txids[3].isCalled &&
        txids[0].lastValue < txids[1].lastValue &&
        txids[1].lastValue < txids[2].lastValue,
      JSON.stringify(txids),
    );
    check("exhausted P2034 leaves the complete relation unchanged", before === after && after === expectedInitial, after);
  } finally {
    removeTestObjects();
  }

  // A generic database error through the real HTTP path.
  installFaultTrigger();
  try {
    const before = relationState();
    const response = await changeRole(adminSession, member, scope, top);
    const after = relationState();
    check("a generic database failure answers the pinned 500", response.status === 500 && response.text === body500, `${response.status} ${response.text}`);
    check("a generic database failure leaves the complete relation unchanged", before === after && after === expectedInitial, after);
  } finally {
    removeTestObjects();
  }

  // Genuine concurrency with a PostgreSQL-level barrier: two admins
  // each demote the other; both updates wait at the barrier until the
  // other has arrived, so the two transactions provably overlap.  A
  // serial execution admits exactly two outcomes — whichever commits
  // first succeeds and leaves the other actor demoted, so the other
  // request is denied (or fails with the pinned 409 after the bounded
  // Serializable retry) — or both fail; both succeeding (write skew)
  // is inconsistent with every serial execution.
  setMembership(peer, scope, top);
  const concurrentBase = relationState();
  installBarrierTrigger();
  const rounds = 12;
  const outcomes = [];
  let consistentRounds = 0;
  let overlappingRounds = 0;
  try {
    for (let round = 0; round < rounds; round += 1) {
      setMembership(admin, scope, top);
      setMembership(peer, scope, top);
      sql(`select setval('mithril_test_arrivals', 1, false); select setval('mithril_test_timeouts', 1, false);`);
      const [first, second] = await Promise.all([
        changeRole(adminSession, peer, scope, bottom),
        changeRole(peerSession, admin, scope, bottom),
      ]);
      const state = relationState();
      const arrivals = sequenceValue("mithril_test_arrivals");
      const timeouts = sequenceValue("mithril_test_timeouts");
      const adminValue = state.includes(`${scope}:${admin}=${top}`) ? top : bottom;
      const peerValue = state.includes(`${scope}:${peer}=${top}`) ? top : bottom;
      const expectedState = (adminV, peerV) =>
        concurrentBase.replace(`${scope}:${admin}=${top}`, `${scope}:${admin}=${adminV}`).replace(`${scope}:${peer}=${top}`, `${scope}:${peer}=${peerV}`);
      const serialA = first.status === 200 && second.status !== 200 && state === expectedState(top, bottom);
      const serialB = second.status === 200 && first.status !== 200 && state === expectedState(bottom, top);
      const neither = first.status !== 200 && second.status !== 200 && state === expectedState(top, top);
      const statusesPinned = [first.status, second.status].every((s) => [200, 403, 409].includes(s));
      const bodiesPinned = [first, second].every(
        (r) => (r.status === 403 && r.text === body403) || (r.status === 409 && r.text === body409) || (r.status === 200 && r.text === body200),
      );
      const consistent = (serialA || serialB || neither) && statusesPinned && bodiesPinned;
      const overlapping = arrivals.isCalled && arrivals.lastValue >= 2 && !timeouts.isCalled;
      outcomes.push(`${first.status}/${second.status}:${adminValue}/${peerValue}:arrivals=${arrivals.lastValue}:timeouts=${timeouts.isCalled ? timeouts.lastValue : 0}`);
      if (consistent) {
        consistentRounds += 1;
      }
      if (overlapping) {
        overlappingRounds += 1;
      }
    }
  } finally {
    removeTestObjects();
  }
  console.log(`concurrency outcomes: ${outcomes.join(" ")}`);
  check(`every concurrent round admits only serial outcomes with the complete relation as expected (${consistentRounds}/${rounds})`, consistentRounds === rounds);
  check(`both transactions reached the barrier in every round (no serialized execution, no timeout) (${overlappingRounds}/${rounds})`, overlappingRounds === rounds);
  check("no concurrent round demoted both actors (no write skew)", outcomes.every((o) => !o.includes(`:${bottom}/${bottom}:`)));
  check("unrelated memberships are unchanged after the concurrency rounds", relationState().includes(`${otherScope}:${admin}=${bottom},${otherScope}:${member}=${top},${otherScope}:${bystander}=${top}`) && relationState().includes(`${scope}:${bystander}=${bottom}`), relationState());

  const remaining = remainingTestObjects();
  check("every temporary trigger, function, and sequence was removed", remaining === "0 triggers, 0 functions, 0 sequences", remaining);
}

try {
  await main();
} catch (error) {
  failures += 1;
  console.log(`FAIL: the battery raised: ${error && error.stack ? error.stack : error}`);
  try {
    removeTestObjects();
  } catch (cleanupError) {
    console.log(`FAIL: removing the temporary test objects raised: ${cleanupError}`);
  }
}

if (failures > 0) {
  console.log(`${failures} battery check(s) failed`);
  process.exit(1);
}
console.log("All battery checks passed.");
