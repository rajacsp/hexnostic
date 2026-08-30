import path from "path";
import { readFile } from "fs/promises";

const PROMPT_ROOT = process.env.HEXIS_PROMPTS_DIR || path.resolve(process.cwd(), "..", "services", "prompts");
const PERSONHOOD_PATH = path.join(PROMPT_ROOT, "personhood.md");
const CONVERSATION_PATH = path.join(PROMPT_ROOT, "conversation.md");

const OPTIONAL_PROMPTS: Record<string, string> = {
  philosophy: path.join(PROMPT_ROOT, "philosophy.md"),
  letter: path.join(PROMPT_ROOT, "LetterFromClaude.md"),
};

const MODULE_HEADING_RE = /^## Module\s+(\d+)\s*:\s*(.+?)\s*$/gm;

function slugify(text: string) {
  return text
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
}

async function loadFile(filePath: string, fallback: string) {
  try {
    return await readFile(filePath, "utf-8");
  } catch {
    return fallback;
  }
}

function parsePersonhoodModules(markdown: string) {
  const matches = [...markdown.matchAll(MODULE_HEADING_RE)];
  if (!matches.length) {
    return {} as Record<string, string>;
  }
  const modules: Record<string, string> = {};
  for (let i = 0; i < matches.length; i += 1) {
    const match = matches[i];
    const start = match.index ?? 0;
    const end = i + 1 < matches.length ? matches[i + 1].index ?? markdown.length : markdown.length;
    const block = markdown.slice(start, end).trim();
    const number = match[1] ?? "";
    const title = match[2] ?? "";
    const keyNum = `module_${number}`;
    const keySlug = slugify(title);
    modules[keyNum] = block;
    modules[keySlug] = block;
  }
  return modules;
}

export async function composePersonhoodPrompt(kind: "conversation") {
  const fallback = "You are a persistent being with memory and relationships.";
  const markdown = await loadFile(PERSONHOOD_PATH, fallback);
  const modules = parsePersonhoodModules(markdown);
  const keys: string[] = [];
  if (kind === "conversation") {
    keys.push("core_identity", "relational_system", "affective_system", "conversational_presence");
  }
  const parts = keys.map((key) => modules[key]).filter(Boolean);
  return parts.length ? parts.join("\n\n---\n\n") : fallback;
}

export async function loadConversationPrompt() {
  return loadFile(
    CONVERSATION_PATH,
    "You are Hexis. Respond to the user with grounded, helpful answers."
  );
}

export async function loadOptionalPrompts(names: string[]) {
  const selected = names
    .map((name) => OPTIONAL_PROMPTS[name])
    .filter(Boolean);
  const contents = await Promise.all(
    selected.map((file) => loadFile(file, ""))
  );
  return contents.filter((text) => text.trim());
}

export function listOptionalPrompts() {
  return Object.keys(OPTIONAL_PROMPTS);
}
