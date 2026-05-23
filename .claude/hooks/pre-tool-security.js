// PreToolUse security hook — blocks dangerous Bash commands before execution
process.stdin.setEncoding("utf8");
let data = "";
process.stdin.on("data", (chunk) => (data += chunk));
process.stdin.on("end", () => {
  const input = JSON.parse(data);
  const cmd = (input.tool_input && input.tool_input.command) || "";
  const blocked = [
    "git push --force",
    "git reset --hard",
    "git clean -f",
    "DROP TABLE",
    "DROP DATABASE",
  ];
  const hit = blocked.find((b) => cmd.includes(b));
  if (hit) {
    process.stderr.write("[Security] Blocked dangerous command: " + hit + "\n");
    process.exit(2);
  }
  process.stdout.write(data);
});
