import { mkdir, writeFile } from "fs/promises";
import path from "path";
import os from "os";

export const runtime = "nodejs";

const USER_CHARACTERS_DIR = path.join(os.homedir(), ".hexis", "characters");
const IMAGE_EXTENSION_BY_MIME: Record<string, string> = {
  "image/jpeg": ".jpg",
  "image/jpg": ".jpg",
  "image/png": ".png",
  "image/webp": ".webp",
};

export async function POST(request: Request) {
  try {
    const body = await request.json();
    const { card, filename, portrait } = body;

    if (!card || typeof card !== "object") {
      return Response.json({ error: "Missing or invalid card data" }, { status: 400 });
    }

    // Validate basic chara_card_v2 structure
    if (!card.data || typeof card.data !== "object") {
      return Response.json({ error: "Invalid card: missing 'data' object" }, { status: 400 });
    }

    // Determine filename
    const hexisExt = card.data?.extensions?.hexis ?? {};
    const cardName = hexisExt.name ?? card.data.name ?? "custom";
    const safeName = (filename ?? `${cardName.toLowerCase().replace(/[^a-z0-9_-]/g, "_")}.json`)
      .replace(/[^a-zA-Z0-9_.-]/g, "_");

    if (!safeName.endsWith(".json")) {
      return Response.json({ error: "Filename must end with .json" }, { status: 400 });
    }

    // Ensure user dir exists
    await mkdir(USER_CHARACTERS_DIR, { recursive: true });

    // Write card JSON
    const destPath = path.join(USER_CHARACTERS_DIR, safeName);
    await writeFile(destPath, JSON.stringify(card, null, 2), "utf-8");

    // Write portrait if provided (base64 string legacy shape, or typed payload).
    const portraitData =
      typeof portrait === "string"
        ? portrait
        : typeof portrait?.dataBase64 === "string"
          ? portrait.dataBase64
          : "";
    const portraitMime =
      typeof portrait === "object" && typeof portrait?.mimeType === "string"
        ? portrait.mimeType.toLowerCase()
        : "image/jpeg";
    if (portraitData) {
      const extension = IMAGE_EXTENSION_BY_MIME[portraitMime] ?? ".jpg";
      const imgName = safeName.replace(/\.json$/, extension);
      const imgPath = path.join(USER_CHARACTERS_DIR, imgName);
      const buffer = Buffer.from(portraitData, "base64");
      await writeFile(imgPath, buffer);
    }

    return Response.json({ filename: safeName, path: destPath });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Failed to save character";
    return Response.json({ error: message }, { status: 500 });
  }
}
