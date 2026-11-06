// SPDX-License-Identifier: MPL-2.0
// Read-only snapshot; no bot request, approval, or merge decision is issued.
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const reviewers = {
  Copilot: ["copilot-pull-request-reviewer", "copilot-pull-request-reviewer[bot]"],
  Codex: ["chatgpt-codex-connector[bot]"],
  CodeRabbit: ["coderabbitai", "coderabbitai[bot]"],
};
const quota = /insufficient remaining quota|quota.{0,40}(exhausted|exceeded)|rate limit exceeded|review limit reached|add carrot credits/i;

export function coverage(head, reviews, comments) {
  if (!/^[a-f0-9]{40}$/.test(head) || !Array.isArray(reviews) || !Array.isArray(comments)) {
    throw new Error("invalid or incomplete review evidence");
  }
  const rows = Object.entries(reviewers).map(([name, accounts]) => {
    const own = reviews.filter((r) => accounts.includes(r.user?.login));
    const current = own.filter((r) => r.commit_id === head && r.state !== "PENDING" && r.state !== "DISMISSED");
    // A COMMENTED review can be the quota failure itself, not a completed review.
    const completed = current.filter((r) => ["APPROVED", "CHANGES_REQUESTED", "COMMENTED"].includes(r.state) && !quota.test(r.body ?? ""));
    let state;
    if (completed.length) state = "review observed on this head (not an approval inference)";
    else if (current.some((r) => quota.test(r.body ?? ""))) state = "NO REVIEW — quota exhausted on this head";
    else if (comments.some((r) => accounts.includes(r.user?.login) && quota.test(r.body ?? ""))) state = "NO REVIEW on this head — quota notice observed; comment head unknown";
    else if (own.length) state = "NO REVIEW on this head — only stale, pending or dismissed evidence";
    else state = "NO REVIEW observed on this head";
    return `| ${name} | ${state} |`;
  });
  return ["**External reviewer coverage (advisory snapshot)**", "",
    `Head: \`${head}\`. This is coverage, not a fourth lane or a merge verdict.`,
    "Later reviews require a fresh summary run. Silence and quota failures never mean approval.", "",
    "| Reviewer | Evidence |", "|---|---|", ...rows, ""].join("\n");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const [head, reviewsFile, commentsFile, checkedHead] = process.argv.slice(2);
    if (head !== checkedHead) throw new Error("PR head changed during evidence collection");
    const read = (file) => {
      const pages = JSON.parse(readFileSync(file, "utf8"));
      if (!Array.isArray(pages) || !pages.every(Array.isArray)) throw new Error("incomplete paginated response");
      return pages.flat();
    };
    console.log(coverage(head, read(reviewsFile), read(commentsFile)));
  } catch {
    console.log("**External reviewer coverage (advisory snapshot)**\n\nINDETERMINATE — evidence unavailable or head changed; no review or approval inferred.\n");
    process.exitCode = 1;
  }
}
