import { readFileSync, readdirSync, existsSync } from "fs";
import { join, resolve } from "path";

export interface SkillMeta {
  name: string;
  description: string;
  triggers: string[];
  checkCount: number;
  content: string;
}

function parseFrontmatter(raw: string): { meta: Record<string, unknown>; content: string } {
  const match = raw.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n([\s\S]*)$/);
  if (!match) return { meta: {}, content: raw };

  const yamlBlock = match[1];
  const content = match[2];

  // Minimal YAML parser for the subset used in SKILL.md frontmatter
  const meta: Record<string, unknown> = {};
  const lines = yamlBlock.split(/\r?\n/);
  let currentKey = "";
  let inList = false;

  for (const line of lines) {
    const listItem = line.match(/^\s{2,}-\s+(.+)$/);
    const keyValue = line.match(/^(\w[\w-]*):\s*(.*)$/);

    if (listItem && inList) {
      (meta[currentKey] as string[]).push(listItem[1].trim());
    } else if (keyValue) {
      currentKey = keyValue[1];
      const val = keyValue[2].trim();
      if (val === "") {
        meta[currentKey] = [];
        inList = true;
      } else {
        meta[currentKey] = val;
        inList = false;
      }
    }
  }

  return { meta, content };
}

export function loadSkills(repoRoot: string): SkillMeta[] {
  const skillsDir = join(repoRoot, "skills");
  if (!existsSync(skillsDir)) {
    throw new Error(`Skills directory not found: ${skillsDir}`);
  }

  const entries = readdirSync(skillsDir, { withFileTypes: true });
  const skills: SkillMeta[] = [];

  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const skillMdPath = join(skillsDir, entry.name, "SKILL.md");
    if (!existsSync(skillMdPath)) continue;

    const raw = readFileSync(skillMdPath, "utf-8");
    const { meta, content } = parseFrontmatter(raw);

    const description = (meta["description"] as string) ?? "";
    const countMatch = description.match(/(\d+)\s+checks?/i);
    const checkCount = countMatch ? parseInt(countMatch[1], 10) : 0;

    const triggers = Array.isArray(meta["triggers"])
      ? (meta["triggers"] as string[])
      : [];

    skills.push({
      name: (meta["name"] as string) ?? entry.name,
      description,
      triggers,
      checkCount,
      content: raw,
    });
  }

  return skills.sort((a, b) => a.name.localeCompare(b.name));
}

export function resolveRepoRoot(): string {
  // When installed via npx, skills/ is bundled alongside dist/
  // When running from source, go up from mcp-server/src/ or mcp-server/dist/
  const candidates = [
    resolve(__dirname, "../../.."),  // dist/index.js → mcp-server/dist → mcp-server → repo root
    resolve(__dirname, "../.."),     // src/index.ts  → mcp-server/src  → mcp-server (skills sibling)
    resolve(__dirname, ".."),
    process.cwd(),
  ];

  for (const candidate of candidates) {
    if (existsSync(join(candidate, "skills"))) return candidate;
  }

  throw new Error(
    "Cannot locate skills/ directory. Run from the mssql-performance-skills repo root."
  );
}
