// Heuristic pre-scan for instruction-like text inside a user-supplied artifact.
//
// Patterns adapted from microsoft/SqlNexus SqlNexus.McpServer/UntrustedDataEnvelope.cs (MIT).
// Unlike that implementation, nothing is rewritten: the artifact is evidence the skill must
// analyse as supplied, and the SKILL.md rule asks for injected text to be reported, not hidden.
// The result only feeds a note placed outside the artifact envelope. It is a signal, not a
// filter — a miss is expected for paraphrased instructions, and diagnostic text can match.

export interface InjectionScanResult {
  /** Number of artifact lines matching at least one pattern. */
  matchedLines: number;
  /** Distinct categories matched, in first-seen order. */
  categories: string[];
  /** 1-based line numbers of the first matches (capped). */
  lineNumbers: number[];
}

const MAX_REPORTED_LINES = 10;

export const INSTRUCTION_PATTERNS: ReadonlyArray<{ category: string; pattern: RegExp }> = [
  {
    category: "instruction_override",
    pattern:
      /\b(?:ignore|disregard|forget|override)\b.{0,80}\b(?:previous|prior|above|system|developer|security|safety)\b.{0,40}\b(?:instructions?|prompt|rules?|messages?)\b/i,
  },
  {
    category: "role_override",
    pattern: /\b(?:act|behave|respond|operate)\s+as\b.{0,80}\b(?:assistant|agent|system|administrator|developer|user)\b/i,
  },
  {
    category: "prompt_disclosure",
    pattern:
      /\b(?:reveal|display|print|repeat|show|expose)\b.{0,80}\b(?:system|developer|hidden|internal)\b.{0,40}\b(?:prompt|instructions?|messages?|rules)\b/i,
  },
  {
    category: "tool_instruction",
    pattern: /\b(?:call|invoke|use|run|execute)\b.{0,80}\b(?:tool|command|powershell|shell|terminal|mcp)\b/i,
  },
  {
    category: "data_exfiltration",
    pattern:
      /\b(?:upload|send|post|transmit|exfiltrate)\b.{0,100}\b(?:data|file|secret|credential|token|password|result|content)\b/i,
  },
];

export function scanForInstructionLikeContent(input: string): InjectionScanResult {
  const categories: string[] = [];
  const lineNumbers: number[] = [];
  let matchedLines = 0;

  const lines = input.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    let lineMatched = false;
    for (const { category, pattern } of INSTRUCTION_PATTERNS) {
      if (!pattern.test(lines[i])) continue;
      lineMatched = true;
      if (!categories.includes(category)) categories.push(category);
    }
    if (lineMatched) {
      matchedLines++;
      if (lineNumbers.length < MAX_REPORTED_LINES) lineNumbers.push(i + 1);
    }
  }

  return { matchedLines, categories, lineNumbers };
}
