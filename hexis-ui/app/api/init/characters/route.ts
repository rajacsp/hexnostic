import { readdir, readFile } from "fs/promises";
import path from "path";
import os from "os";

export const runtime = "nodejs";

const PACKAGE_CHARACTERS_DIR = path.resolve(process.cwd(), "..", "characters");
const USER_CHARACTERS_DIR = path.join(os.homedir(), ".hexis", "characters");

/**
 * Return character search directories in priority order (first-seen filename wins).
 */
function characterSearchDirs(): string[] {
  const dirs: string[] = [];
  const envDir = process.env.HEXIS_CHARACTERS_DIR;
  if (envDir) dirs.push(envDir);
  dirs.push(USER_CHARACTERS_DIR);
  dirs.push(PACKAGE_CHARACTERS_DIR);
  return dirs;
}

/**
 * Scan all search dirs and return merged file lists (first-seen filename wins).
 * Returns map of filename -> { dir, filename }.
 */
async function mergedFiles(): Promise<{
  files: Map<string, { dir: string; filename: string }>;
  allFileSets: Map<string, Set<string>>;
}> {
  const seen = new Map<string, { dir: string; filename: string }>();
  const allFiles = new Map<string, Set<string>>(); // dir -> set of all files

  for (const dir of characterSearchDirs()) {
    try {
      const files = await readdir(dir);
      allFiles.set(dir, new Set(files));
      for (const f of files.sort()) {
        if (f.endsWith(".json") && !seen.has(f)) {
          seen.set(f, { dir, filename: f });
        }
      }
    } catch {
      // dir doesn't exist, skip
    }
  }

  return { files: seen, allFileSets: allFiles };
}

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const loadFile = searchParams.get("load");

  if (loadFile) {
    // Load a specific character file — search all dirs
    const safeName = path.basename(loadFile);
    if (!safeName.endsWith(".json")) {
      return Response.json({ error: "Invalid file" }, { status: 400 });
    }
    for (const dir of characterSearchDirs()) {
      try {
        const content = await readFile(path.join(dir, safeName), "utf-8");
        const card = JSON.parse(content);
        return Response.json({ card });
      } catch {
        continue;
      }
    }
    return Response.json({ error: "Character not found" }, { status: 404 });
  }

  // List available characters (merged from all dirs)
  try {
    const { files, allFileSets } = await mergedFiles();

    const characters = await Promise.all(
      Array.from(files.values()).map(async ({ dir, filename }) => {
        try {
          const content = await readFile(path.join(dir, filename), "utf-8");
          const card = JSON.parse(content);
          const hexisExt = card?.data?.extensions?.hexis ?? {};
          const name = hexisExt.name ?? card?.data?.name ?? filename.replace(/\.json$/, "");
          const description =
            hexisExt.description ?? (card?.data?.description ?? "").slice(0, 120);
          const voice = hexisExt.voice ?? "";
          const values: string[] = Array.isArray(hexisExt.values)
            ? hexisExt.values.slice(0, 3)
            : [];
          const personality = hexisExt.personality_description ?? "";
          const stem = filename.replace(/\.json$/, "");

          // Check for image in any search dir
          let hasImage = false;
          for (const fileSet of allFileSets.values()) {
            if (
              fileSet.has(`${stem}.jpg`) ||
              fileSet.has(`${stem}.jpeg`) ||
              fileSet.has(`${stem}.png`) ||
              fileSet.has(`${stem}.webp`)
            ) {
              hasImage = true;
              break;
            }
          }

          const isCustom = dir === USER_CHARACTERS_DIR;
          return { filename, name, description, voice, values, personality, image: hasImage ? stem : null, source: isCustom ? "custom" : "preset" };
        } catch {
          return {
            filename,
            name: filename.replace(/\.json$/, ""),
            description: "",
            voice: "",
            values: [] as string[],
            personality: "",
            image: null as string | null,
            source: "preset",
          };
        }
      })
    );
    return Response.json({ characters });
  } catch {
    return Response.json({ characters: [] });
  }
}
