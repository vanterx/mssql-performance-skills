import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { SKILLS, GUIDE_CONTENT } from "./skills-data.js";
import { registerTools } from "./tools.js";
import { registerResources } from "./resources.js";
import { registerPrompts } from "./prompts.js";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, Mcp-Session-Id",
};

function createServer(): McpServer {
  const server = new McpServer({
    name: "mssql-performance-skills",
    version: "1.0.0",
  });
  registerTools(server, SKILLS);
  registerResources(server, SKILLS, GUIDE_CONTENT);
  registerPrompts(server, SKILLS);
  return server;
}

export default {
  async fetch(request: Request): Promise<Response> {
    // CORS preflight
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    // Health check
    if (request.method === "GET" && new URL(request.url).pathname === "/health") {
      return new Response(
        JSON.stringify({ status: "ok", skills: SKILLS.length }),
        { status: 200, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } }
      );
    }

    try {
      const transport = new WebStandardStreamableHTTPServerTransport({
        sessionIdGenerator: undefined, // stateless — new server per request
      });
      const server = createServer();
      await server.connect(transport);
      const response = await transport.handleRequest(request);
      // Attach CORS headers to every MCP response
      const corsed = new Response(response.body, response);
      Object.entries(CORS_HEADERS).forEach(([k, v]) => corsed.headers.set(k, v));
      return corsed;
    } catch (err) {
      const message = err instanceof Error ? err.message : "Internal server error";
      return new Response(
        JSON.stringify({ error: message }),
        { status: 500, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } }
      );
    }
  },
};
