import { describe, it, expect } from "vitest";
import { parseFrontmatter } from "../frontmatter-parser.js";

describe("parseFrontmatter", () => {
  it("returns empty meta and full content when no frontmatter block is present", () => {
    const raw = "# Just a heading\nSome content here.";
    const { meta, content } = parseFrontmatter(raw);
    expect(meta).toEqual({});
    expect(content).toBe(raw);
  });

  it("parses a simple key-value YAML block", () => {
    const raw = "---\nname: tsql-review\ndescription: Applies 85 checks\n---\n# Body";
    const { meta, content } = parseFrontmatter(raw);
    expect(meta["name"]).toBe("tsql-review");
    expect(meta["description"]).toBe("Applies 85 checks");
    expect(content).toBe("# Body");
  });

  it("parses a YAML list field", () => {
    const raw = "---\nname: tsql-review\ntriggers:\n  - /tsql-review\n  - /tsql\n---\n# Body";
    const { meta } = parseFrontmatter(raw);
    expect(meta["triggers"]).toEqual(["/tsql-review", "/tsql"]);
  });

  it("handles Windows-style CRLF line endings", () => {
    const raw = "---\r\nname: sqlplan-review\r\ndescription: 108 checks\r\n---\r\n# Body";
    const { meta, content } = parseFrontmatter(raw);
    expect(meta["name"]).toBe("sqlplan-review");
    expect(content).toBe("# Body");
  });

  it("preserves multi-line body content after the frontmatter block", () => {
    const body = "## Section\n\nSome text.\n\nMore text.";
    const raw = `---\nname: skill\n---\n${body}`;
    const { content } = parseFrontmatter(raw);
    expect(content).toBe(body);
  });

  it("returns empty string content for a frontmatter-only file", () => {
    const raw = "---\nname: skill\n---\n";
    const { content } = parseFrontmatter(raw);
    expect(content).toBe("");
  });

  it("ignores lines that are not key-value pairs or list items", () => {
    const raw = "---\nname: my-skill\n  ignored indented line\ndescription: ok\n---\n";
    const { meta } = parseFrontmatter(raw);
    expect(meta["name"]).toBe("my-skill");
    expect(meta["description"]).toBe("ok");
  });

  it("handles a description field with numbers (check count pattern)", () => {
    const raw = "---\nname: sqlwait-review\ndescription: Applies 44 checks (V1–V44)\n---\n";
    const { meta } = parseFrontmatter(raw);
    const desc = meta["description"] as string;
    const match = desc.match(/(\d+)\s+checks?/i);
    expect(match).not.toBeNull();
    expect(parseInt(match![1], 10)).toBe(44);
  });
});
