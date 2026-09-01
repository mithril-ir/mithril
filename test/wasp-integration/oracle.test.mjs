// Hermetic regression for the serial-outcome oracle
// (test/wasp-integration/oracle.mjs): it needs no PostgreSQL and no
// Wasp server.  Every expectation below is a LITERAL — the permitted
// tables are pinned row by row against literal lists, every permitted
// row is exercised as a positive case with literal statuses, bodies,
// and states, and the rejected mutants are literal too — so nothing
// here regenerates its expectations from the oracle under test.
//
// The tables model an ISOLATED pair of two requests, where exactly one
// conflicting write commits and the other is decided against it, so a
// 409 (three exhausted Serializable attempts) has no serial
// interpretation and no table admits it.  Every 409-containing status
// pair is therefore exercised as a rejected mutant here; 409 as a
// contract is pinned SEPARATELY by the battery's persistent-P2034
// exhaustion test, not by these tables.
//
// Run by test/wasp-integration/test-harness.sh (scenario 11).
// Test-only tooling, outside the confinement claim.

import {
  CROSS_OPERATION_ROWS,
  FINAL_A_BOTTOM_P_TOP,
  FINAL_A_TOP_P_BOTTOM,
  FINAL_BOTH_TOP,
  FINAL_BOTTOM,
  FINAL_TOP,
  SAME_OPERATION_ROWS,
  TWO_ADMIN_ROWS,
  judgeRound,
  renderTally,
  rowLabel,
  tallyRows,
} from "./oracle.mjs";

let failures = 0;
function check(name, condition, detail) {
  if (condition) {
    console.log(`ok: ${name}`);
  } else {
    failures += 1;
    console.log(`FAIL: ${name}${detail === undefined ? "" : ` — ${detail}`}`);
  }
}

// The pinned bodies, exactly as the battery pins them.
const body200 = JSON.stringify({ json: null, meta: { values: ["undefined"], v: 1 } });
const body403 = JSON.stringify({ message: "forbidden" });
const body409 = JSON.stringify({ message: "conflict" });
const body500 = JSON.stringify({ message: "internal error" });
const body400 = JSON.stringify({ message: "invalid arguments" });
const bodies = { 200: body200, 403: body403, 409: body409 };

// Literal relation strings standing in for the battery's complete
// relation (scope 7, actor 3, peer 4, a sentinel tuple 9:3).
const stateActorBottom = "7:3=Value0,7:4=Value1,9:3=Value0";
const stateActorTop = "7:3=Value1,7:4=Value1,9:3=Value0";
const statePeerBottom = "7:3=Value1,7:4=Value0,9:3=Value0";
const statePeerTop = stateActorTop;
const stateABottomPTop = "7:3=Value0,7:4=Value1,9:3=Value0";
const stateATopPBottom = "7:3=Value1,7:4=Value0,9:3=Value0";
const stateBothTop = stateActorTop;
const stateBothBottom = "7:3=Value0,7:4=Value0,9:3=Value0";

const sameContext = {
  bodies,
  expectedState: (final) => (final === "bottom" ? stateActorBottom : final === "top" ? stateActorTop : undefined),
};
const crossContext = {
  bodies,
  expectedState: (final) => (final === "bottom" ? statePeerBottom : final === "top" ? statePeerTop : undefined),
};
const twoAdminContext = {
  bodies,
  expectedState: (final) =>
    final === "A=top,P=bottom" ? stateATopPBottom : final === "A=bottom,P=top" ? stateABottomPTop : final === "A=top,P=top" ? stateBothTop : undefined,
};

const response = (status, text) => ({ status, text });
const ok = () => response(200, body200);
const forbidden = () => response(403, body403);
const conflict = () => response(409, body409);

// --- 1. the tables are pinned literally ------------------------------------

const literal = (rows) => rows.map((row) => [row.first, row.second, row.final]);
check(
  "the same-operation table is exactly the two literal rows 200/403→bottom, 200/200→bottom (no 409 row)",
  JSON.stringify(literal(SAME_OPERATION_ROWS)) ===
    JSON.stringify([
      [200, 403, "bottom"],
      [200, 200, "bottom"],
    ]),
  JSON.stringify(literal(SAME_OPERATION_ROWS)),
);
check(
  "the cross-operation table is exactly the two literal rows 200/403→bottom, 200/200→bottom (no 409 row)",
  JSON.stringify(literal(CROSS_OPERATION_ROWS)) ===
    JSON.stringify([
      [200, 403, "bottom"],
      [200, 200, "bottom"],
    ]),
  JSON.stringify(literal(CROSS_OPERATION_ROWS)),
);
check(
  "the two-admin table is exactly the two literal rows 200/403→A=top,P=bottom and 403/200→A=bottom,P=top (no 409 row)",
  JSON.stringify(literal(TWO_ADMIN_ROWS)) ===
    JSON.stringify([
      [200, 403, "A=top,P=bottom"],
      [403, 200, "A=bottom,P=top"],
    ]),
  JSON.stringify(literal(TWO_ADMIN_ROWS)),
);
check(
  "no barrier-scenario table admits any 409-containing row",
  [...SAME_OPERATION_ROWS, ...CROSS_OPERATION_ROWS, ...TWO_ADMIN_ROWS].every((row) => row.first !== 409 && row.second !== 409),
);
check(
  "the six permitted rows carry only the statuses 200 and 403",
  [...SAME_OPERATION_ROWS, ...CROSS_OPERATION_ROWS, ...TWO_ADMIN_ROWS].every((row) => [200, 403].includes(row.first) && [200, 403].includes(row.second)) &&
    [...SAME_OPERATION_ROWS, ...CROSS_OPERATION_ROWS, ...TWO_ADMIN_ROWS].length === 6,
);
check(
  "the final-state labels are the literal strings the battery maps",
  FINAL_BOTTOM === "bottom" &&
    FINAL_TOP === "top" &&
    FINAL_A_TOP_P_BOTTOM === "A=top,P=bottom" &&
    FINAL_A_BOTTOM_P_TOP === "A=bottom,P=top" &&
    FINAL_BOTH_TOP === "A=top,P=top",
);
check(
  "every row of every table names its serial history interpretation",
  [...SAME_OPERATION_ROWS, ...CROSS_OPERATION_ROWS, ...TWO_ADMIN_ROWS].every((row) => typeof row.history === "string" && row.history.length > 20),
);
check(
  "no single-tuple row denies the demoting request (D and rule 1 are never 403)",
  [...SAME_OPERATION_ROWS, ...CROSS_OPERATION_ROWS].every((row) => row.first !== 403),
);
check(
  "a row label renders as first/second→final",
  rowLabel({ first: 200, second: 403, final: "bottom" }) === "200/403→bottom",
  rowLabel({ first: 200, second: 403, final: "bottom" }),
);

// --- 2. positive cases: every row the real battery may admit -------------

const positive = (name, rows, context, first, second, state, expectedLabel) => {
  const judgement = judgeRound(rows, { first, second, state }, context);
  check(
    `${name}: accepted as row ${expectedLabel}`,
    judgement.accepted === true && judgement.row !== null && rowLabel(judgement.row) === expectedLabel && judgement.reason === "",
    JSON.stringify(judgement),
  );
};

positive("same-operation 200/403 with the actor at the bottom value", SAME_OPERATION_ROWS, sameContext, ok(), forbidden(), stateActorBottom, "200/403→bottom");
positive("same-operation 200/200 with the actor at the bottom value", SAME_OPERATION_ROWS, sameContext, ok(), ok(), stateActorBottom, "200/200→bottom");

positive("cross-operation 200/403 with the peer at the bottom value", CROSS_OPERATION_ROWS, crossContext, ok(), forbidden(), statePeerBottom, "200/403→bottom");
positive("cross-operation 200/200 with the peer at the bottom value", CROSS_OPERATION_ROWS, crossContext, ok(), ok(), statePeerBottom, "200/200→bottom");

positive("two-admin 200/403 with A at the top and P at the bottom value", TWO_ADMIN_ROWS, twoAdminContext, ok(), forbidden(), stateATopPBottom, "200/403→A=top,P=bottom");
positive("two-admin 403/200 with A at the bottom and P at the top value", TWO_ADMIN_ROWS, twoAdminContext, forbidden(), ok(), stateABottomPTop, "403/200→A=bottom,P=top");

// --- 3. mutants: outcomes the oracle must reject ---------------------------

const rejected = (name, rows, context, first, second, state, reasonFragment) => {
  const judgement = judgeRound(rows, { first, second, state }, context);
  check(
    `${name}: rejected`,
    judgement.accepted === false && (reasonFragment === undefined || judgement.reason.includes(reasonFragment)),
    JSON.stringify(judgement),
  );
};

// 3a. EVERY 409-containing status pair is rejected in EVERY scenario — a
// barrier-scenario 409 has no serial interpretation and no row, even
// with otherwise plausible bodies and a plausible committed state.
for (const [scenarioName, rows, context, oneCommitted, bothOpen] of [
  ["same-operation", SAME_OPERATION_ROWS, sameContext, stateActorBottom, stateActorTop],
  ["cross-operation", CROSS_OPERATION_ROWS, crossContext, statePeerBottom, statePeerTop],
  ["two-admin", TWO_ADMIN_ROWS, twoAdminContext, stateATopPBottom, stateBothTop],
]) {
  rejected(`${scenarioName} 200/409 (a spurious conflict where the pair resolves serially)`, rows, context, ok(), conflict(), oneCommitted, "not a permitted row");
  rejected(`${scenarioName} 403/409`, rows, context, forbidden(), conflict(), oneCommitted, "not a permitted row");
  rejected(`${scenarioName} 409/200`, rows, context, conflict(), ok(), oneCommitted, "not a permitted row");
  rejected(`${scenarioName} 409/403`, rows, context, conflict(), forbidden(), oneCommitted, "not a permitted row");
  rejected(`${scenarioName} 409/409 (both aborted — impossible for an isolated pair)`, rows, context, conflict(), conflict(), bothOpen, "not a permitted row");
}

// 3b. The reviewer's counterexamples: a denied demotion by the top-ranked
// actor, paired with a successful equal write and a final top value.
rejected("same-operation demote = 403, keep = 200, final actor rank top (the reviewer's counterexample)", SAME_OPERATION_ROWS, sameContext, forbidden(), ok(), stateActorTop, "not a permitted row");
rejected("cross-operation rule 1 = 403, rule 2 = 200, final peer rank top (the reviewer's counterexample)", CROSS_OPERATION_ROWS, crossContext, forbidden(), ok(), statePeerTop, "not a permitted row");
// 200/200 with the tuple still at the top value: no serial interpretation.
rejected("cross-operation 200/200 with the peer still at the top value", CROSS_OPERATION_ROWS, crossContext, ok(), ok(), statePeerTop, "final authority relation");
rejected("same-operation 200/200 with the actor still at the top value", SAME_OPERATION_ROWS, sameContext, ok(), ok(), stateActorTop, "final authority relation");
// Write skew in the two-admin scenario: both succeed, both demoted.
rejected("two-admin 200/200 with both actors demoted (write skew)", TWO_ADMIN_ROWS, twoAdminContext, ok(), ok(), stateBothBottom, "not a permitted row");
rejected("two-admin 200/200 with both still at the top value (no demotion committed)", TWO_ADMIN_ROWS, twoAdminContext, ok(), ok(), stateBothTop, "not a permitted row");
rejected("two-admin 403/403 with both at the top value (nobody committed, yet somebody was denied)", TWO_ADMIN_ROWS, twoAdminContext, forbidden(), forbidden(), stateBothTop, "not a permitted row");
// Incorrect bodies paired with otherwise permitted statuses.
rejected("same-operation 200/403 whose 200 carries the 403 body", SAME_OPERATION_ROWS, sameContext, response(200, body403), forbidden(), stateActorBottom, "first response");
rejected("same-operation 200/403 whose 403 carries the 200 body", SAME_OPERATION_ROWS, sameContext, ok(), response(403, body200), stateActorBottom, "second response");
rejected("two-admin 403/200 whose 403 carries the 500 body", TWO_ADMIN_ROWS, twoAdminContext, response(403, body500), ok(), stateABottomPTop, "first response");
rejected("cross-operation 200/200 whose second 200 carries an empty body", CROSS_OPERATION_ROWS, crossContext, ok(), response(200, ""), statePeerBottom, "second response");
rejected("two-admin 200/403 whose 403 carries a non-uniform body", TWO_ADMIN_ROWS, twoAdminContext, ok(), response(403, JSON.stringify({ message: "forbidden", who: "P" })), stateATopPBottom, "second response");
// Final states inconsistent with each permitted pair.
rejected("same-operation 200/403 with the actor still at the top value", SAME_OPERATION_ROWS, sameContext, ok(), forbidden(), stateActorTop, "final authority relation");
rejected("cross-operation 200/403 with the peer still at the top value", CROSS_OPERATION_ROWS, crossContext, ok(), forbidden(), statePeerTop, "final authority relation");
rejected("cross-operation 200/200 with the peer still at the top value (second copy for state)", CROSS_OPERATION_ROWS, crossContext, ok(), ok(), statePeerTop, "final authority relation");
rejected("cross-operation 200/403 where the actor's own tuple changed too", CROSS_OPERATION_ROWS, crossContext, ok(), forbidden(), stateBothBottom, "final authority relation");
rejected("two-admin 200/403 with P still at the top value", TWO_ADMIN_ROWS, twoAdminContext, ok(), forbidden(), stateBothTop, "final authority relation");
rejected("two-admin 403/200 with A still at the top value", TWO_ADMIN_ROWS, twoAdminContext, forbidden(), ok(), stateBothTop, "final authority relation");
rejected("two-admin 200/403 with A demoted too (both demoted)", TWO_ADMIN_ROWS, twoAdminContext, ok(), forbidden(), stateBothBottom, "final authority relation");
// Outcomes with no row at all: 500, malformed input, and transport failures.
rejected("same-operation 500/200 (a fault answer is never a concurrency outcome)", SAME_OPERATION_ROWS, sameContext, response(500, body500), ok(), stateActorTop, "not a permitted row");
rejected("cross-operation 200/500", CROSS_OPERATION_ROWS, crossContext, ok(), response(500, body500), statePeerBottom, "not a permitted row");
rejected("same-operation 400/200 (malformed input is never a concurrency outcome)", SAME_OPERATION_ROWS, sameContext, response(400, body400), ok(), stateActorTop, "not a permitted row");
rejected("two-admin 401/200 (an auth answer is never a concurrency outcome)", TWO_ADMIN_ROWS, twoAdminContext, response(401, JSON.stringify({ message: "authentication required" })), ok(), stateABottomPTop, "not a permitted row");
rejected("cross-operation with a transport failure in place of the first response", CROSS_OPERATION_ROWS, crossContext, null, ok(), statePeerTop, "transport failure");
rejected("same-operation with a transport failure in place of the second response", SAME_OPERATION_ROWS, sameContext, ok(), null, stateActorBottom, "transport failure");
rejected("a context that cannot render the row's final state rejects the round", SAME_OPERATION_ROWS, { bodies, expectedState: () => undefined }, ok(), forbidden(), stateActorBottom, "final authority relation");

// --- 4. the tally of observed rows ----------------------------------------

{
  const judgements = [
    judgeRound(SAME_OPERATION_ROWS, { first: ok(), second: forbidden(), state: stateActorBottom }, sameContext),
    judgeRound(SAME_OPERATION_ROWS, { first: ok(), second: ok(), state: stateActorBottom }, sameContext),
    judgeRound(SAME_OPERATION_ROWS, { first: ok(), second: forbidden(), state: stateActorBottom }, sameContext),
    // A rejected round (a spurious 409) contributes to no row.
    judgeRound(SAME_OPERATION_ROWS, { first: ok(), second: conflict(), state: stateActorBottom }, sameContext),
  ];
  const tally = tallyRows(SAME_OPERATION_ROWS, judgements);
  check(
    "the tally counts accepted judgements per row, in table order, listing unobserved rows with zero",
    JSON.stringify(tally) ===
      JSON.stringify([
        { label: "200/403→bottom", count: 2 },
        { label: "200/200→bottom", count: 1 },
      ]),
    JSON.stringify(tally),
  );
  check(
    "a rejected round (a spurious 409) contributes to no row of the tally",
    tally.reduce((sum, entry) => sum + entry.count, 0) === 3,
  );
  check(
    "the tally renders as label ×count pairs",
    renderTally(tally) === "200/403→bottom ×2, 200/200→bottom ×1",
    renderTally(tally),
  );
}

if (failures > 0) {
  console.log(`${failures} serial-outcome oracle regression check(s) failed`);
  process.exit(1);
}
console.log("All serial-outcome oracle regression checks passed.");
