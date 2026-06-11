import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { SkillMeta } from "./skill-loader.js";
import { buildAnalysisPrompt } from "./prompt-builder.js";

export const ARTIFACT_SKILL_MAP: Record<string, string[]> = {
  tsql:        ["tsql-review"],
  sqlplan:     ["sqlplan-review", "sqlindex-advisor"],
  plancompare: ["sqlplan-compare"],
  planbatch:   ["sqlplan-batch"],
  deadlock:    ["sqldeadlock-review"],
  waits:       ["sqlwait-review"],
  trace:       ["sqltrace-review"],
  stats:       ["sqlstats-review"],
  querystore:  ["sqlquerystore-review"],
  procstats:   ["sqlprocstats-review"],
  hadr:        ["sqlhadr-review"],
  clusterlog:  ["sqlclusterlog-review"],
  errorlog:    ["sqlerrorlog-review"],
  spn:         ["sqlspn-review"],
  memory:      ["sqlmemory-review"],
  diskio:      ["sqldiskio-review"],
  encryption:  ["sqlencryption-review"],
  dbconfig:    ["sqldbconfig-review"],
  setuplog:    ["sqlbootstraplog-review"],
  mixed:       ["mssql-performance-review"],
};

export function registerTools(server: McpServer, skills: SkillMeta[]): void {
  const byName = new Map(skills.map((s) => [s.name, s]));

  server.tool(
    "list_skills",
    `List all ${skills.length} available SQL Server performance tuning skills with their check counts and triggers`,
    {},
    async () => ({
      content: [
        {
          type: "text",
          text: JSON.stringify(
            skills.map(({ name, description, triggers, checkCount, references }) => ({
              name,
              description,
              triggers,
              checkCount,
              referenceFiles: Object.keys(references),
            })),
            null,
            2
          ),
        },
      ],
    })
  );

  server.tool(
    "get_skill",
    "Get the full content of a named skill (SKILL.md) including all checks, thresholds, and output format. Also lists available reference files (check explanations, how-to guides) that can be fetched with get_reference.",
    { name: z.string().describe("Skill name, e.g. tsql-review or sqlplan-review") },
    async ({ name }) => {
      const skill = byName.get(name);
      if (!skill) {
        const available = skills.map((s) => s.name).join(", ");
        return {
          content: [{ type: "text", text: `Skill '${name}' not found. Available: ${available}` }],
          isError: true,
        };
      }
      const refNames = Object.keys(skill.references);
      const refNote = refNames.length > 0
        ? `\n\n---\n**Reference files available** (use get_reference to fetch):\n${refNames.map((f) => `- ${f}`).join("\n")}`
        : "";
      return { content: [{ type: "text", text: skill.content + refNote }] };
    }
  );

  server.tool(
    "get_reference",
    "Get the content of a reference file for a skill — check explanations, how-to guides, concept docs, or error references. Use list_skills or get_skill to discover available reference filenames.",
    {
      skill: z.string().describe("Skill name, e.g. tsql-review"),
      reference: z.string().describe("Reference filename, e.g. check-explanations.md or howto-tde-setup.md"),
    },
    async ({ skill: skillName, reference }) => {
      const skill = byName.get(skillName);
      if (!skill) {
        const available = skills.map((s) => s.name).join(", ");
        return {
          content: [{ type: "text", text: `Skill '${skillName}' not found. Available: ${available}` }],
          isError: true,
        };
      }
      const content = skill.references[reference];
      if (content === undefined) {
        const available = Object.keys(skill.references).join(", ") || "(none)";
        return {
          content: [{ type: "text", text: `Reference '${reference}' not found for skill '${skillName}'. Available: ${available}` }],
          isError: true,
        };
      }
      return { content: [{ type: "text", text: content }] };
    }
  );

  server.tool(
    "route_artifact",
    "Given an artifact type, returns the recommended skill(s) to use for analysis",
    {
      artifact_type: z
        .enum([
          "tsql", "sqlplan", "plancompare", "planbatch",
          "deadlock", "waits", "trace", "stats", "querystore",
          "procstats", "hadr", "clusterlog", "errorlog", "spn",
          "memory", "diskio", "encryption", "dbconfig", "setuplog", "mixed",
        ])
        .describe(
          "Type of artifact to analyze. " +
          "plancompare = two plans for regression diff; planbatch = folder of many plans; " +
          "memory = sys.dm_os_memory_clerks/PLE output; diskio = sys.dm_io_virtual_file_stats output; " +
          "encryption = TDE/AE/CLE/TLS audit output; dbconfig = sp_configure/sys.databases output; " +
          "setuplog = Setup Bootstrap logs (Summary.txt, Detail.txt, MSI logs, ConfigurationFile.ini). " +
          "Use 'mixed' when the artifact combines multiple types or the type is unknown — routes to the mssql-performance-review orchestrator."
        ),
    },
    async ({ artifact_type }) => {
      const skillNames = ARTIFACT_SKILL_MAP[artifact_type] ?? [];
      const matched = skillNames.map((n) => byName.get(n)).filter(Boolean) as SkillMeta[];

      const result = matched.map(({ name, description, triggers }) => ({
        name,
        description,
        primaryTrigger: triggers[0] ?? `/${name}`,
      }));

      return {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
      };
    }
  );

  for (const skill of skills) {
    server.tool(
      skill.name,
      `Apply ${skill.name} (${skill.checkCount} checks) to the provided artifact. ${skill.description}`,
      {
        input: z
          .string()
          .optional()
          .describe("Raw SQL, XML plan, statistics output, trace data, or other artifact to analyze. Omit to retrieve the skill content only."),
      },
      async ({ input }) => ({
        content: [
          {
            type: "text",
            text: input
              ? buildAnalysisPrompt(skill.name, skill.content, input)
              : skill.content,
          },
        ],
      })
    );
  }
}
