import { describe, it, expect, vi, beforeEach } from "vitest";

// Mock the auto-generated skills-data before importing the handler
vi.mock("../skills-data.js", () => ({
  SKILLS: [
    {
      name: "tsql-review",
      description: "85 checks for T-SQL",
      triggers: ["/tsql-review"],
      checkCount: 85,
      content: "# tsql-review skill",
    },
  ],
  GUIDE_CONTENT: "# Guide",
  VERSION_COMPAT_CONTENT: "# Version compat",
}));

// Import after mock is established
const { default: worker } = await import("../index.js");

const BASE_URL = "https://mssql-mcp.example.com";

function makeRequest(method: string, path: string, init?: RequestInit): Request {
  return new Request(`${BASE_URL}${path}`, { method, ...init });
}

describe("HTTP handler — CORS preflight", () => {
  it("returns 204 for OPTIONS requests", async () => {
    const req = makeRequest("OPTIONS", "/");
    const res = await worker.fetch(req);
    expect(res.status).toBe(204);
  });

  it("sets Access-Control-Allow-Origin: * on OPTIONS", async () => {
    const req = makeRequest("OPTIONS", "/");
    const res = await worker.fetch(req);
    expect(res.headers.get("Access-Control-Allow-Origin")).toBe("*");
  });

  it("allows the required HTTP methods in CORS header", async () => {
    const req = makeRequest("OPTIONS", "/");
    const res = await worker.fetch(req);
    const methods = res.headers.get("Access-Control-Allow-Methods") ?? "";
    expect(methods).toContain("POST");
    expect(methods).toContain("GET");
  });
});

describe("HTTP handler — health check", () => {
  it("returns 200 for GET /health", async () => {
    const req = makeRequest("GET", "/health");
    const res = await worker.fetch(req);
    expect(res.status).toBe(200);
  });

  it("returns JSON with status: ok", async () => {
    const req = makeRequest("GET", "/health");
    const res = await worker.fetch(req);
    const body = await res.json() as { status: string; skills: number };
    expect(body.status).toBe("ok");
  });

  it("reports the correct number of bundled skills", async () => {
    const req = makeRequest("GET", "/health");
    const res = await worker.fetch(req);
    const body = await res.json() as { skills: number };
    expect(body.skills).toBe(1); // matches the mocked SKILLS array above
  });

  it("sets CORS headers on /health response", async () => {
    const req = makeRequest("GET", "/health");
    const res = await worker.fetch(req);
    expect(res.headers.get("Access-Control-Allow-Origin")).toBe("*");
  });

  it("returns Content-Type: application/json for /health", async () => {
    const req = makeRequest("GET", "/health");
    const res = await worker.fetch(req);
    expect(res.headers.get("Content-Type")).toContain("application/json");
  });
});
