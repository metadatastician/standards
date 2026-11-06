// SPDX-License-Identifier: MPL-2.0
import test from "node:test";
import assert from "node:assert/strict";
import { coverage } from "../reviewer-coverage.mjs";

const head = "a".repeat(40);
const bot = "copilot-pull-request-reviewer[bot]";
const review = (extra = {}) => ({ user: { login: bot }, commit_id: head, state: "COMMENTED", body: "Reviewed", ...extra });

test("a quota COMMENTED review is visibly no review", () => {
  const report = coverage(head, [review({ body: "Copilot was unable to review this pull request because the user who requested the review has insufficient remaining quota." })], []);
  assert.match(report, /Copilot \| NO REVIEW — quota exhausted on this head/);
  assert.doesNotMatch(report, /Copilot \| review observed/);
});
test("absence, stale, dismissed and pending reviews cannot imply completion", () => {
  assert.match(coverage(head, [], []), /NO REVIEW observed on this head/);
  for (const r of [review({ commit_id: "b".repeat(40) }), review({ state: "PENDING" }), review({ state: "DISMISSED" })]) {
    assert.match(coverage(head, [r], []), /only stale, pending or dismissed evidence/);
  }
});
test("completed current review remains a coverage observation, never approval", () => {
  assert.match(coverage(head, [review({ state: "CHANGES_REQUESTED" })], []), /review observed on this head \(not an approval inference\)/);
});
test("user text cannot impersonate a bot and historical quota comments have unknown head", () => {
  const body = "insufficient remaining quota";
  assert.doesNotMatch(coverage(head, [], [{ user: { login: "someone" }, body }]), /quota notice/);
  assert.match(coverage(head, [], [{ user: { login: bot }, body }]), /comment head unknown/);
});
test("unknown evidence fails closed", () => {
  assert.throws(() => coverage(head, null, []));
  assert.throws(() => coverage("not-a-sha", [], []));
});
