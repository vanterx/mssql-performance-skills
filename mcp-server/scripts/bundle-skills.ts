// Reads all skills SKILL.md files and PERFORMANCE_TUNING_GUIDE.md from the repo root,
// then writes src/skills-data.ts as a static TypeScript file bundled into the Cloudflare Worker.
// Run before deploying: npm run bundle
import { readFileSync, readdirSync, existsSync, writeFileSync } from "fs";
import { join, resolve } from "path";

interface SkillMeta {
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

const repoRoot = resolve(__dirname, "../..");
const skillsDir = join(repoRoot, "skills");

if (!existsSync(skillsDir)) {
  process.stderr.write(`Skills directory not found: ${skillsDir}\n`);
  process.exit(1);
}

const skills: SkillMeta[] = readdirSync(skillsDir, { withFileTypes: true })
  .filter((e) => e.isDirectory())
  .map((e) => join(skillsDir, e.name, "SKILL.md"))
  .filter((p) => existsSync(p))
  .map((p) => {
    const raw = readFileSync(p, "utf-8");
    const { meta } = parseFrontmatter(raw);
    const description = (meta["description"] as string) ?? "";
    const countMatch = description.match(/(\d+)\s+checks?/i);
    return {
      name: (meta["name"] as string) ?? "",
      description,
      triggers: Array.isArray(meta["triggers"]) ? (meta["triggers"] as string[]) : [],
      checkCount: countMatch ? parseInt(countMatch[1], 10) : 0,
      content: raw,
    };
  })
  .sort((a, b) => a.name.localeCompare(b.name));

const guidePath = join(repoRoot, "PERFORMANCE_TUNING_GUIDE.md");
const guideContent = existsSync(guidePath) ? readFileSync(guidePath, "utf-8") : "";

const vcPath = join(repoRoot, "VERSION_COMPATIBILITY.md");
const vcContent = existsSync(vcPath) ? readFileSync(vcPath, "utf-8") : "";

const output = `// AUTO-GENERATED — do not edit. Run: npm run bundle
import type { SkillMeta } from "./skill-loader.js";

export const SKILLS: SkillMeta[] = ${JSON.stringify(skills, null, 2)};

export const GUIDE_CONTENT: string = ${JSON.stringify(guideContent)};

export const VERSION_COMPAT_CONTENT: string = ${JSON.stringify(vcContent)};
`;

const outPath = join(__dirname, "../src/skills-data.ts");
writeFileSync(outPath, output, "utf-8");
process.stdout.write(`Bundled ${skills.length} skills → src/skills-data.ts\n`);
