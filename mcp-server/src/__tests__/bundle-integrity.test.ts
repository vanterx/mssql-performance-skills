import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync, existsSync } from "fs";
import { join, resolve } from "path";
import { parseFrontmatter } from "../../scripts/frontmatter-parser.js";

const REPO_ROOT = resolve(__dirname, "../../..");
const SKILLS_DIR = join(REPO_ROOT, "skills");

// Dollar-sign patterns that the skill loader would expand as shell variables,
// breaking the skill content when loaded.
const DANGEROUS_DOLLAR_PATTERNS = [/\$0\b/, /\$3\b/, /\$15\b/, /\$\[/];

function getSkillFiles(): Array<{ name: string; path: string; raw: string }> {
  if (!existsSync(SKILLS_DIR)) return [];
  return readdirSync(SKILLS_DIR, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => ({
      name: e.name,
      path: join(SKILLS_DIR, e.name, "SKILL.md"),
      raw: "",
    }))
    .filter(({ path }) => existsSync(path))
    .map(({ name, path }) => ({ name, path, raw: readFileSync(path, "utf-8") }));
}

describe("SKILL.md bundle integrity", () => {
  const skillFiles = getSkillFiles();

  it("finds at least 18 skill directories", () => {
    expect(skillFiles.length).toBeGreaterThanOrEqual(18);
  });

  it.each(skillFiles)(
    "$name — has valid YAML frontmatter with name, description, triggers",
    ({ name, raw }) => {
      const { meta } = parseFrontmatter(raw);
      expect(typeof meta["name"], `${name}: 'name' field missing`).toBe("string");
      expect((meta["name"] as string).length, `${name}: 'name' is empty`).toBeGreaterThan(0);
      expect(typeof meta["description"], `${name}: 'description' field missing`).toBe("string");
      expect(Array.isArray(meta["triggers"]), `${name}: 'triggers' must be a list`).toBe(true);
    }
  );

  it.each(skillFiles)(
    "$name — contains no shell-expandable dollar-sign patterns",
    ({ name, raw }) => {
      for (const pattern of DANGEROUS_DOLLAR_PATTERNS) {
        expect(pattern.test(raw), `${name}: found dangerous pattern ${pattern} in SKILL.md`).toBe(false);
      }
    }
  );

  it.each(skillFiles)(
    "$name — frontmatter name matches directory name",
    ({ name, raw }) => {
      const { meta } = parseFrontmatter(raw);
      expect(meta["name"], `${name}: frontmatter 'name' should match directory name`).toBe(name);
    }
  );

  it.each(skillFiles)(
    "$name — check count in description is a positive integer",
    ({ name, raw }) => {
      const { meta } = parseFrontmatter(raw);
      const description = meta["description"] as string ?? "";
      // Orchestrator and batch-dispatcher skills have checkCount 0 — that is intentional.
      // All other skills must declare a check count in their description.
      const isDispatcher = ["mssql-performance-review", "sqlplan-batch"].includes(name);
      if (!isDispatcher) {
        // Allow "85 checks", "16 patterns", "16 known deadlock patterns", "27 performance patterns"
        const match = description.match(/\b(\d+)(?:\s+\w+){0,3}\s+(?:checks?|patterns?)\b/i);
        expect(match, `${name}: description must contain a count like '85 checks', '16 patterns', or '16 known X patterns'`).not.toBeNull();
        expect(parseInt(match![1], 10), `${name}: check count must be > 0`).toBeGreaterThan(0);
      }
    }
  );

  it.each(skillFiles)(
    "$name — all reference files in references/ directory are present in the bundle",
    ({ name, path: skillMdPath }) => {
      const skillsDataPath = join(REPO_ROOT, "mcp-server/src/skills-data.ts");
      if (!existsSync(skillsDataPath)) return;

      const refsDir = join(skillMdPath.replace(/[\\/]SKILL\.md$/, ""), "references");
      if (!existsSync(refsDir)) return;

      const diskFiles = readdirSync(refsDir)
        .filter((f) => f.endsWith(".md") || f.endsWith(".json") || f.endsWith(".ps1"));

      const skillsData = readFileSync(skillsDataPath, "utf-8");

      for (const filename of diskFiles) {
        expect(skillsData, `${name}: reference file '${filename}' is on disk but not bundled`).toContain(filename);
      }
    }
  );

  it("all skills bundled in skills-data.ts are present as skill directories", () => {
    const skillsDataPath = join(REPO_ROOT, "mcp-server/src/skills-data.ts");
    if (!existsSync(skillsDataPath)) return;

    const skillsData = readFileSync(skillsDataPath, "utf-8");
    const bundledNames = [...skillsData.matchAll(/"name":\s*"([^"]+)"/g)].map((m) => m[1]);

    const directoryNames = new Set(skillFiles.map((f) => f.name));
    for (const bundledName of bundledNames) {
      expect(directoryNames, `bundled skill '${bundledName}' has no matching directory`).toContain(bundledName);
    }
  });
});
