import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { SKILLS, GUIDE_CONTENT } from "./skills-data.js";
import { registerTools } from "./tools.js";
import { registerResources } from "./resources.js";
import { registerPrompts } from "./prompts.js";

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
    const transport = new WebStandardStreamableHTTPServerTransport({
      sessionIdGenerator: undefined, // stateless — new server per request
    });
    const server = createServer();
    await server.connect(transport);
    return transport.handleRequest(request);
  },
};
