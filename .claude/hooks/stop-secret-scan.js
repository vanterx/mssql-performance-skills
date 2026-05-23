// Stop hook — scans for accidentally committed secrets at session end
const fs = require("fs");
const path = require("path");

const ENV_NAMES = new Set([".env", ".env.local", ".env.production", ".env.development"]);
const SECRET_PATTERNS = ["API_KEY=", "SECRET=", "PASSWORD=", "TOKEN=", "ANTHROPIC_API_KEY="];
const PLACEHOLDER_SUFFIXES = ["your", "<", "xxx", "example", "changeme"];
const findings = [];

function scanDir(dir) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (_) {
    return;
  }
  for (const entry of entries) {
    if (entry.name === "node_modules" || entry.name === ".git") continue;
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      scanDir(fullPath);
    } else if (ENV_NAMES.has(entry.name)) {
      scanFile(fullPath);
    }
  }
}

function scanFile(file) {
  try {
    const content = fs.readFileSync(file, "utf8");
    for (const pattern of SECRET_PATTERNS) {
      if (!content.includes(pattern)) continue;
      const isPlaceholder = PLACEHOLDER_SUFFIXES.some((s) => content.includes(pattern + s));
      if (!isPlaceholder) {
        findings.push(file + ": possible " + pattern.replace("=", ""));
      }
    }
  } catch (_) {}
}

scanDir(".");

if (findings.length) {
  process.stderr.write("[Stop Hook] Possible secrets detected — review before committing:\n" + findings.join("\n") + "\n");
  process.exit(2);
}
