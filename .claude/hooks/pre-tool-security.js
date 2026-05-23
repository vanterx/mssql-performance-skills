// PreToolUse security hook — blocks dangerous Bash commands before execution
process.stdin.setEncoding("utf8");
let data = "";
process.stdin.on("data", (chunk) => (data += chunk));
process.stdin.on("end", () => {
  let input;
  try {
    input = JSON.parse(data);
  } catch (_) {
    process.stderr.write("[Security] Blocked: failed to parse hook input\n");
    process.exit(2);
  }
  const cmd = ((input.tool_input && input.tool_input.command) || "").toLowerCase();
  const blocked = [
    "git push --force",
    "git push --force-with-lease",
    "git reset --hard",
    "git clean -f",
    "drop table",
    "drop database",
  ];
  const hit = blocked.find((b) => cmd.includes(b));
  if (hit) {
    process.stderr.write("[Security] Blocked dangerous command: " + hit + "\n");
    process.exit(2);
  }
  process.stdout.write(data);
});
