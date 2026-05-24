import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { SkillMeta } from "./skill-loader.js";
import { buildAnalysisPrompt } from "./prompt-builder.js";

export function registerPrompts(server: McpServer, skills: SkillMeta[]): void {
  for (const skill of skills) {
    server.prompt(
      skill.name,
      `Apply ${skill.name} (${skill.checkCount} checks) to the provided artifact`,
      { input: z.string().describe("Raw SQL, XML, statistics output, or trace data to analyze") },
      ({ input }) => ({
        messages: [
          {
            role: "user",
            content: {
              type: "text",
              text: buildAnalysisPrompt(skill.name, skill.content, input),
            },
          },
        ],
      })
    );
  }
}
