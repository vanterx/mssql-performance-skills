export interface SkillMeta {
  name: string;
  description: string;
  triggers: string[];
  checkCount: number;
  content: string;
  references: Record<string, string>; // filename → full file content
}
