// Stop hook — scans for accidentally committed secrets at session end
const fs = require("fs");
const envFiles = fs.readdirSync(".").filter(
  (f) => f === ".env" || f === ".env.local" || f === ".env.production"
);
const secretPatterns = ["API_KEY=", "SECRET=", "PASSWORD=", "TOKEN=", "ANTHROPIC_API_KEY="];
const findings = [];

envFiles.forEach((file) => {
  try {
    const content = fs.readFileSync(file, "utf8");
    secretPatterns.forEach((pattern) => {
      if (content.includes(pattern) && !content.includes(pattern + "your") && !content.includes(pattern + "<")) {
        findings.push(file + ": possible " + pattern.replace("=", ""));
      }
    });
  } catch (_) {}
});

if (findings.length) {
  process.stderr.write("[Stop Hook] Possible secrets in files:\n" + findings.join("\n") + "\n");
}
