// PostToolUse guard — only runs scripts/verify-docs.sh when the edited file
// could actually affect a documentation-consistency check (anything under
// skills/, or one of the cross-referenced root docs/manifests). Fires after
// every Write/Edit otherwise, and verify-docs.sh itself is slow (~3 min on
// this Windows/Git Bash setup — 46 checks x 26 skill dirs, each spawning its
// own grep/awk process) so this fast-path skip avoids a multi-minute stall
// on edits that have nothing to do with the skills library (e.g. edits to
// scripts/ or non-skill tooling).

const { spawnSync } = require("child_process");

const RELEVANT = [
  /(^|[\\/])skills[\\/]/,
  /(^|[\\/])README\.md$/,
  /(^|[\\/])CLAUDE\.md$/,
  /(^|[\\/])AGENTS\.md$/,
  /(^|[\\/])PERFORMANCE_TUNING_GUIDE\.md$/,
  /(^|[\\/])LLM_COST_ESTIMATION\.md$/,
  /(^|[\\/])\.claude-plugin[\\/]/,
];

process.stdin.setEncoding("utf8");
let data = "";
process.stdin.on("data", (chunk) => (data += chunk));
process.stdin.on("end", () => {
  let input;
  try {
    input = JSON.parse(data);
  } catch (_) {
    process.exit(0);
  }

  const filePath = (input.tool_input && input.tool_input.file_path) || "";
  if (!RELEVANT.some((re) => re.test(filePath))) {
    process.exit(0);
  }

  const result = spawnSync("bash", ["scripts/verify-docs.sh"], { stdio: "inherit" });
  process.exit(result.status ?? 0);
});
