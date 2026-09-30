#!/usr/bin/env node
// Prepare a worker's worktree before dispatch (replaces the manual mkdir/cp/printf):
//   node .claude/hooks/proteus-worktree.js <worktree> <owned path or glob>...
// The harness adapter copies the worker hooks in and registers them (Claude Code: .claude/hooks/ and
// .claude/settings.local.json from worktree-settings.local.json); this writes the owned-path list
// (one entry per line) and keeps those local files out of `git add` via <git-common-dir>/info/exclude.
"use strict";
const fs = require("fs");
const path = require("path");
const lib = require(path.join(__dirname, "proteus-lib.js"));
const ad = require(path.join(__dirname, "proteus-harness.js"));

const [wtArg, ...owned] = process.argv.slice(2);
if (!wtArg || !owned.length) {
  console.error("usage: node proteus-worktree.js <worktree> <owned path or glob>...");
  process.exitCode = 1;
  return;
}
const wt = path.resolve(wtArg);
if (!fs.existsSync(path.join(wt, ".git"))) {
  console.error(`proteus-worktree: ${wt} is not a git worktree (git worktree add it first)`);
  process.exitCode = 1;
  return;
}

const EXCLUDE = ad.prepareWorker(wt, __dirname);
const entries = owned.map((p) => p.replace(/\\/g, "/").replace(/^\.\//, "")).filter(Boolean);
fs.mkdirSync(path.dirname(lib.ownedFile(wt)), { recursive: true });
fs.writeFileSync(lib.ownedFile(wt), entries.join("\n") + "\n");

try {
  const common = lib.gitCommonDir(wt);
  if (common) {
    const file = path.join(common, "info", "exclude");
    let cur = "";
    try { cur = fs.readFileSync(file, "utf8"); } catch {}
    const have = new Set(cur.split(/\r?\n/));
    const add = EXCLUDE.filter((l) => !have.has(l));
    if (add.length) {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.appendFileSync(file, (cur && !cur.endsWith("\n") ? "\n" : "") + "# proteus: machine-local worker files\n" + add.join("\n") + "\n");
    }
  }
} catch {}

console.log(`worktree ${wt}: hooks + ${entries.length} owned paths`);
