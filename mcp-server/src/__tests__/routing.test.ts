import { describe, it, expect, vi, beforeEach } from "vitest";
import { ARTIFACT_SKILL_MAP, registerTools } from "../tools.js";
import type { SkillMeta } from "../skill-loader.js";

const ALL_SKILL_NAMES = [
  "mssql-performance-review",
  "sqlclusterlog-review",
  "sqldeadlock-review",
  "sqldiskio-review",
  "sqlencryption-review",
  "sqlerrorlog-review",
  "sqlhadr-review",
  "sqlindex-advisor",
  "sqlmemory-review",
  "sqlplan-batch",
  "sqlplan-compare",
  "sqlplan-review",
  "sqlprocstats-review",
  "sqlquerystore-review",
  "sqlspn-review",
  "sqlstats-review",
  "sqltrace-review",
  "sqlwait-review",
  "tsql-review",
] as const;

function makeSkills(names: readonly string[]): SkillMeta[] {
  return names.map((name) => ({
    name,
    description: `${name} description`,
    triggers: [`/${name}`],
    checkCount: 10,
    content: `# ${name}`,
  }));
}

describe("ARTIFACT_SKILL_MAP", () => {
  it("covers all 18 specialised skills (none left unreachable)", () => {
    const specialised = ALL_SKILL_NAMES.filter((n) => n !== "mssql-performance-review");
    const reachable = new Set(Object.values(ARTIFACT_SKILL_MAP).flat());
    for (const skill of specialised) {
      expect(reachable, `${skill} must be reachable via at least one artifact type`).toContain(skill);
    }
  });

  it("routes mixed to the orchestrator only", () => {
    expect(ARTIFACT_SKILL_MAP["mixed"]).toEqual(["mssql-performance-review"]);
  });

  it("routes sqlplan to sqlplan-review and sqlindex-advisor together", () => {
    expect(ARTIFACT_SKILL_MAP["sqlplan"]).toContain("sqlplan-review");
    expect(ARTIFACT_SKILL_MAP["sqlplan"]).toContain("sqlindex-advisor");
  });

  it("routes plancompare to sqlplan-compare", () => {
    expect(ARTIFACT_SKILL_MAP["plancompare"]).toEqual(["sqlplan-compare"]);
  });

  it("routes planbatch to sqlplan-batch", () => {
    expect(ARTIFACT_SKILL_MAP["planbatch"]).toEqual(["sqlplan-batch"]);
  });

  it("routes memory to sqlmemory-review", () => {
    expect(ARTIFACT_SKILL_MAP["memory"]).toEqual(["sqlmemory-review"]);
  });

  it("routes diskio to sqldiskio-review", () => {
    expect(ARTIFACT_SKILL_MAP["diskio"]).toEqual(["sqldiskio-review"]);
  });

  it("routes encryption to sqlencryption-review", () => {
    expect(ARTIFACT_SKILL_MAP["encryption"]).toEqual(["sqlencryption-review"]);
  });

  it("routes tsql to tsql-review", () => {
    expect(ARTIFACT_SKILL_MAP["tsql"]).toEqual(["tsql-review"]);
  });

  it("routes deadlock to sqldeadlock-review", () => {
    expect(ARTIFACT_SKILL_MAP["deadlock"]).toEqual(["sqldeadlock-review"]);
  });

  it("has no artifact type that maps to an empty array", () => {
    for (const [type, skills] of Object.entries(ARTIFACT_SKILL_MAP)) {
      expect(skills.length, `artifact type '${type}' maps to an empty array`).toBeGreaterThan(0);
    }
  });

  it("has no artifact type mapping to an unknown skill name", () => {
    const knownSkills = new Set(ALL_SKILL_NAMES);
    for (const [type, skills] of Object.entries(ARTIFACT_SKILL_MAP)) {
      for (const skill of skills) {
        expect(knownSkills, `artifact type '${type}' references unknown skill '${skill}'`).toContain(skill);
      }
    }
  });
});

describe("registerTools — list_skills", () => {
  it("registers list_skills tool and returns all skills as JSON", async () => {
    const skills = makeSkills(ALL_SKILL_NAMES);
    const handlers = new Map<string, (args: Record<string, unknown>) => Promise<unknown>>();

    const mockServer = {
      tool: vi.fn((name: string, _desc: unknown, _schema: unknown, handler: (args: Record<string, unknown>) => Promise<unknown>) => {
        handlers.set(name, handler);
      }),
    };

    registerTools(mockServer as never, skills);

    const handler = handlers.get("list_skills");
    expect(handler).toBeDefined();

    const result = await handler!({}) as { content: Array<{ type: string; text: string }> };
    const parsed = JSON.parse(result.content[0].text);

    expect(parsed).toHaveLength(ALL_SKILL_NAMES.length);
    expect(parsed.map((s: { name: string }) => s.name).sort()).toEqual([...ALL_SKILL_NAMES].sort());
  });

  it("list_skills description includes the real skill count", () => {
    const skills = makeSkills(ALL_SKILL_NAMES);
    const toolDescriptions = new Map<string, string>();

    const mockServer = {
      tool: vi.fn((name: string, desc: string) => { toolDescriptions.set(name, desc); }),
    };

    registerTools(mockServer as never, skills);

    const desc = toolDescriptions.get("list_skills") ?? "";
    expect(desc).toContain(String(ALL_SKILL_NAMES.length));
  });
});

describe("registerTools — get_skill", () => {
  it("returns skill content for a known skill", async () => {
    const skills = makeSkills(["tsql-review"]);
    const handlers = new Map<string, (args: Record<string, unknown>) => Promise<unknown>>();

    const mockServer = {
      tool: vi.fn((name: string, _d: unknown, _s: unknown, handler: (args: Record<string, unknown>) => Promise<unknown>) => {
        handlers.set(name, handler);
      }),
    };

    registerTools(mockServer as never, skills);

    const handler = handlers.get("get_skill");
    const result = await handler!({ name: "tsql-review" }) as { content: Array<{ text: string }> };
    expect(result.content[0].text).toBe("# tsql-review");
  });

  it("returns an error response for an unknown skill", async () => {
    const skills = makeSkills(["tsql-review"]);
    const handlers = new Map<string, (args: Record<string, unknown>) => Promise<unknown>>();

    const mockServer = {
      tool: vi.fn((name: string, _d: unknown, _s: unknown, handler: (args: Record<string, unknown>) => Promise<unknown>) => {
        handlers.set(name, handler);
      }),
    };

    registerTools(mockServer as never, skills);

    const handler = handlers.get("get_skill");
    const result = await handler!({ name: "nonexistent-skill" }) as { isError: boolean; content: Array<{ text: string }> };
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("not found");
  });
});

describe("registerTools — route_artifact", () => {
  it("returns correct skill metadata for tsql artifact type", async () => {
    const skills = makeSkills(ALL_SKILL_NAMES);
    const handlers = new Map<string, (args: Record<string, unknown>) => Promise<unknown>>();

    const mockServer = {
      tool: vi.fn((name: string, _d: unknown, _s: unknown, handler: (args: Record<string, unknown>) => Promise<unknown>) => {
        handlers.set(name, handler);
      }),
    };

    registerTools(mockServer as never, skills);

    const handler = handlers.get("route_artifact");
    const result = await handler!({ artifact_type: "tsql" }) as { content: Array<{ text: string }> };
    const parsed = JSON.parse(result.content[0].text) as Array<{ name: string }>;
    expect(parsed.map((r) => r.name)).toContain("tsql-review");
  });

  it("returns sqlplan-review and sqlindex-advisor for sqlplan type", async () => {
    const skills = makeSkills(ALL_SKILL_NAMES);
    const handlers = new Map<string, (args: Record<string, unknown>) => Promise<unknown>>();

    const mockServer = {
      tool: vi.fn((name: string, _d: unknown, _s: unknown, handler: (args: Record<string, unknown>) => Promise<unknown>) => {
        handlers.set(name, handler);
      }),
    };

    registerTools(mockServer as never, skills);

    const handler = handlers.get("route_artifact");
    const result = await handler!({ artifact_type: "sqlplan" }) as { content: Array<{ text: string }> };
    const parsed = JSON.parse(result.content[0].text) as Array<{ name: string }>;
    const names = parsed.map((r) => r.name);
    expect(names).toContain("sqlplan-review");
    expect(names).toContain("sqlindex-advisor");
  });
});

describe("registerTools — per-skill tools", () => {
  it("registers a tool for every skill", () => {
    const skills = makeSkills(ALL_SKILL_NAMES);
    const registeredNames: string[] = [];

    const mockServer = {
      tool: vi.fn((name: string) => { registeredNames.push(name); }),
    };

    registerTools(mockServer as never, skills);

    for (const skillName of ALL_SKILL_NAMES) {
      expect(registeredNames, `tool for '${skillName}' was not registered`).toContain(skillName);
    }
  });

  it("per-skill tool returns analysis prompt when input is provided", async () => {
    const skills = makeSkills(["tsql-review"]);
    const handlers = new Map<string, (args: Record<string, unknown>) => Promise<unknown>>();

    const mockServer = {
      tool: vi.fn((name: string, _d: unknown, _s: unknown, handler: (args: Record<string, unknown>) => Promise<unknown>) => {
        handlers.set(name, handler);
      }),
    };

    registerTools(mockServer as never, skills);

    const handler = handlers.get("tsql-review");
    const result = await handler!({ input: "SELECT 1" }) as { content: Array<{ text: string }> };
    expect(result.content[0].text).toContain("SELECT 1");
    expect(result.content[0].text).toContain("tsql-review");
  });

  it("per-skill tool returns raw skill content when no input is provided", async () => {
    const skills = makeSkills(["tsql-review"]);
    const handlers = new Map<string, (args: Record<string, unknown>) => Promise<unknown>>();

    const mockServer = {
      tool: vi.fn((name: string, _d: unknown, _s: unknown, handler: (args: Record<string, unknown>) => Promise<unknown>) => {
        handlers.set(name, handler);
      }),
    };

    registerTools(mockServer as never, skills);

    const handler = handlers.get("tsql-review");
    const result = await handler!({}) as { content: Array<{ text: string }> };
    expect(result.content[0].text).toBe("# tsql-review");
  });
});
