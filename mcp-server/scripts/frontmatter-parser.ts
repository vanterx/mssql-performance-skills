export interface ParsedFrontmatter {
  meta: Record<string, unknown>;
  content: string;
}

export function parseFrontmatter(raw: string): ParsedFrontmatter {
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
