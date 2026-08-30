import { readFile, access } from "fs/promises";
import path from "path";
import os from "os";

export const runtime = "nodejs";

const PACKAGE_CHARACTERS_DIR = path.resolve(process.cwd(), "..", "characters");
const USER_CHARACTERS_DIR = path.join(os.homedir(), ".hexis", "characters");
const IMAGE_EXTENSIONS: Record<string, string> = {
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".png": "image/png",
  ".webp": "image/webp",
};

function characterSearchDirs(): string[] {
  const dirs: string[] = [];
  const envDir = process.env.HEXIS_CHARACTERS_DIR;
  if (envDir) dirs.push(envDir);
  dirs.push(USER_CHARACTERS_DIR);
  dirs.push(PACKAGE_CHARACTERS_DIR);
  return dirs;
}

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const name = searchParams.get("name");
  if (!name) {
    return new Response("Missing name parameter", { status: 400 });
  }

  // Sanitize: only allow alphanumeric, hyphen, underscore
  const safeName = path.basename(name).replace(/[^a-zA-Z0-9_-]/g, "");
  if (!safeName) {
    return new Response("Invalid name", { status: 400 });
  }

  // Search all character dirs for the image
  for (const dir of characterSearchDirs()) {
    for (const [extension, contentType] of Object.entries(IMAGE_EXTENSIONS)) {
      const filePath = path.join(dir, `${safeName}${extension}`);
      try {
        await access(filePath);
        const buffer = await readFile(filePath);
        return new Response(buffer, {
          headers: {
            "Content-Type": contentType,
            "Cache-Control": "public, max-age=86400, immutable",
          },
        });
      } catch {
        continue;
      }
    }
  }

  return new Response("Image not found", { status: 404 });
}
