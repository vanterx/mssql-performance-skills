// PreToolUse guard — guarantees /backlog/ and /backup/ stay gitignored.
//
// Fires before every Bash command. Acts only on `git add` / `git commit`:
//   1. Self-heals .gitignore — if either required pattern was removed, it is
//      re-appended so these local-only scratch folders can never be tracked.
//   2. Blocks a commit if anything under backlog/ or backup/ was force-staged
//      (e.g. `git add -f backlog/x`), telling the user how to unstage it.
//
// Exit 0 = allow, exit 2 = block (per Claude Code hook protocol).

const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

const REQUIRED_PATTERNS = ["/backlog/", "/backup/"];
const GUARDED_PREFIXES = ["backlog/", "backup/"];

process.stdin.setEncoding("utf8");
let data = "";
process.stdin.on("data", (chunk) => (data += chunk));
process.stdin.on("end", () => {
  let input;
  try {
    input = JSON.parse(data);
  } catch (_) {
    // Not our concern — let other hooks/validation handle malformed input.
    process.exit(0);
  }

  const cmd = (input.tool_input && input.tool_input.command) || "";
  const isGitAdd = /\bgit\s+add\b/.test(cmd);
  const isGitCommit = /\bgit\s+commit\b/.test(cmd);
  if (!isGitAdd && !isGitCommit) {
    process.stdout.write(data);
    process.exit(0);
  }

  const repoRoot = findRepoRoot();
  if (!repoRoot) {
    process.stdout.write(data);
    process.exit(0);
  }

  ensureGitignorePatterns(repoRoot);

  const staged = stagedGuardedPaths(repoRoot);
  if (staged.length > 0) {
    process.stderr.write(
      "[gitignore-guard] Blocked: these paths are local-only and must never be committed:\n" +
        staged.map((f) => "  " + f).join("\n") +
        "\n\nUnstage them first:\n" +
        "  git rm --cached -r --ignore-unmatch backlog backup\n"
    );
    process.exit(2);
  }

  process.stdout.write(data);
  process.exit(0);
});

function findRepoRoot() {
  try {
    return execSync("git rev-parse --show-toplevel", {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch (_) {
    return null;
  }
}

function ensureGitignorePatterns(repoRoot) {
  const gitignorePath = path.join(repoRoot, ".gitignore");
  let contents = "";
  try {
    contents = fs.readFileSync(gitignorePath, "utf8");
  } catch (_) {
    contents = "";
  }

  const lines = contents.split(/\r?\n/).map((l) => l.trim());
  const missing = REQUIRED_PATTERNS.filter((p) => !lines.includes(p));
  if (missing.length === 0) return;

  const prefix = contents.length && !contents.endsWith("\n") ? "\n" : "";
  const block =
    prefix +
    "\n# Local-only scratch folders — enforced by .claude/hooks/ensure-gitignore.js\n" +
    missing.join("\n") +
    "\n";
  try {
    fs.appendFileSync(gitignorePath, block);
    process.stderr.write(
      "[gitignore-guard] Restored missing .gitignore pattern(s): " +
        missing.join(", ") +
        "\n"
    );
  } catch (_) {
    // Non-fatal: if we can't write, fall through without blocking.
  }
}

function stagedGuardedPaths(repoRoot) {
  try {
    // --diff-filter=ACMRT selects added/copied/modified/renamed/typechanged and
    // EXCLUDES deletions, so untracking a guarded file (git rm --cached) is allowed.
    const out = execSync("git diff --cached --name-only --diff-filter=ACMRT", {
      cwd: repoRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    return out
      .split(/\r?\n/)
      .map((f) => f.trim())
      .filter((f) => GUARDED_PREFIXES.some((p) => f.startsWith(p)));
  } catch (_) {
    return [];
  }
}
