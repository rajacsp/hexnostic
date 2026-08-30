import { inflateRawSync } from "node:zlib";

export type CharacterCatalogProvider = "chub" | "character_tavern" | "risu_realm";

export type CharacterCatalogItem = {
  provider: CharacterCatalogProvider;
  id: string;
  title: string;
  author: string | null;
  description: string;
  tags: string[];
  avatarUrl: string | null;
  pageUrl: string;
  path: string | null;
  stats: {
    downloads?: number;
    likes?: number;
    messages?: number;
    tokens?: number;
  };
  nsfw: boolean;
  sourceLabel: string;
};

export type CharacterCatalogSearchResult = {
  provider: CharacterCatalogProvider;
  query: string;
  page: number;
  total: number | null;
  totalPages: number | null;
  items: CharacterCatalogItem[];
  status: "ok" | "degraded";
  message: string | null;
};

export type CharacterPortraitPayload = {
  dataBase64: string;
  mimeType: string;
};

export type CharacterCatalogDownloadResult = {
  item: CharacterCatalogItem;
  card: Record<string, unknown>;
  portrait: CharacterPortraitPayload | null;
};

type SearchInput = {
  provider: CharacterCatalogProvider;
  query: string;
  tags?: string[];
  page?: number;
  includeNsfw?: boolean;
  sort?: string;
};

type DownloadInput = {
  provider: CharacterCatalogProvider;
  id: string;
  path?: string | null;
  avatarUrl?: string | null;
  pageUrl?: string | null;
};

const CATALOG_LIMIT = 24;
const CHARACTER_TAVERN_CARD_STORAGE = "https://ct-cards.storage.character-tavern.com";

export const characterCatalogProviders: Record<
  CharacterCatalogProvider,
  { label: string; hint: string }
> = {
  chub: {
    label: "Chub",
    hint: "Large Chub/CharacterHub catalog with public card search.",
  },
  character_tavern: {
    label: "Character Tavern",
    hint: "Browse public Tavern cards with rich filters and token metadata.",
  },
  risu_realm: {
    label: "Risu Realm",
    hint: "Download Risu character cards through the documented RisuRealm API.",
  },
};

export function parseCharacterCatalogProvider(value: string | null): CharacterCatalogProvider | null {
  if (value === "chub" || value === "character_tavern" || value === "risu_realm") {
    return value;
  }
  return null;
}

export function safeCharacterFilename(name: string, provider?: CharacterCatalogProvider): string {
  const prefix = provider ? `${provider}_` : "";
  const stem = `${prefix}${name}`
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 80);
  return `${stem || "character"}.json`;
}

export function mergeHexisProfileIntoCard(
  card: Record<string, unknown>,
  hexisProfile: Record<string, unknown>
): Record<string, unknown> {
  const originalData =
    card.data && typeof card.data === "object" && !Array.isArray(card.data)
      ? (card.data as Record<string, unknown>)
      : card;
  const extensions =
    originalData.extensions &&
    typeof originalData.extensions === "object" &&
    !Array.isArray(originalData.extensions)
      ? { ...(originalData.extensions as Record<string, unknown>) }
      : {};
  return {
    spec: typeof card.spec === "string" ? card.spec : "chara_card_v2",
    spec_version: typeof card.spec_version === "string" ? card.spec_version : "2.0",
    data: {
      ...originalData,
      name: stringValue(hexisProfile.name) || stringValue(originalData.name) || "Character",
      description:
        stringValue(originalData.description) || stringValue(hexisProfile.description) || "",
      personality:
        stringValue(originalData.personality) ||
        stringValue(hexisProfile.personality_description) ||
        "",
      extensions: {
        ...extensions,
        hexis: hexisProfile,
      },
    },
  };
}

export async function searchCharacterCatalog(input: SearchInput): Promise<CharacterCatalogSearchResult> {
  if (input.provider === "chub") return searchChub(input);
  if (input.provider === "character_tavern") return searchCharacterTavern(input);
  return searchRisuRealm(input);
}

export async function downloadCharacterCatalogItem(
  input: DownloadInput
): Promise<CharacterCatalogDownloadResult> {
  if (input.provider === "chub") return downloadChub(input);
  if (input.provider === "character_tavern") return downloadCharacterTavern(input);
  return downloadRisuRealm(input);
}

async function searchChub(input: SearchInput): Promise<CharacterCatalogSearchResult> {
  const query = buildSearchText(input.query, input.tags);
  const response = await fetchWithError("https://api.chub.ai/search", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ search: query || "assistant", page: input.page ?? 1, limit: CATALOG_LIMIT }),
  });
  const payload = await response.json();
  const nodes = Array.isArray(payload?.data?.nodes) ? payload.data.nodes : [];
  const items = nodes
    .map((node: Record<string, unknown>) => chubNodeToCatalogItem(node))
    .filter((item: CharacterCatalogItem | null): item is CharacterCatalogItem => {
      if (!item) return false;
      return input.includeNsfw ? true : !item.nsfw;
    });
  return {
    provider: "chub",
    query,
    page: numberValue(payload?.data?.page) || input.page || 1,
    total: numberValue(payload?.data?.count),
    totalPages: null,
    items,
    status: "ok",
    message: null,
  };
}

export function chubNodeToCatalogItem(node: Record<string, unknown>): CharacterCatalogItem | null {
  const id = numberValue(node.id);
  const fullPath = stringValue(node.fullPath);
  const title = stringValue(node.name);
  if (!id || !title) return null;
  const author = fullPath ? fullPath.split("/")[0] ?? null : null;
  const topics = stringArray(node.topics);
  return {
    provider: "chub",
    id: String(id),
    title,
    author,
    description: stringValue(node.description) || stringValue(node.tagline) || "",
    tags: topics,
    avatarUrl: stringValue(node.avatar_url) || stringValue(node.max_res_url) || null,
    pageUrl: fullPath ? `https://chub.ai/characters/${fullPath}` : `https://chub.ai/characters/${id}`,
    path: fullPath || String(id),
    stats: {
      likes: numberValue(node.starCount) ?? numberValue(node.n_favorites) ?? undefined,
      messages: numberValue(node.nMessages) ?? undefined,
      tokens: numberValue(node.nTokens) ?? undefined,
    },
    nsfw: booleanValue(node.nsfw_image) || false,
    sourceLabel: "Chub",
  };
}

async function downloadChub(input: DownloadInput): Promise<CharacterCatalogDownloadResult> {
  const route = input.path && input.path.includes("/")
    ? `https://api.chub.ai/api/characters/${input.path}?full=true`
    : `https://api.chub.ai/api/characters/${encodeURIComponent(input.id)}?full=true`;
  const response = await fetchWithError(route);
  const payload = await response.json();
  const node = payload?.node && typeof payload.node === "object" ? payload.node as Record<string, unknown> : null;
  if (!node) throw new Error("Chub did not return a project.");
  const item = chubNodeToCatalogItem(node) ?? {
    provider: "chub" as const,
    id: input.id,
    title: input.path ?? input.id,
    author: null,
    description: "",
    tags: [],
    avatarUrl: input.avatarUrl ?? null,
    pageUrl: input.pageUrl ?? route,
    path: input.path ?? input.id,
    stats: {},
    nsfw: false,
    sourceLabel: "Chub",
  };
  const card = chubProjectToCharacterCard(node);
  const portrait = await fetchPortraitPayload(item.avatarUrl || stringValue(node.max_res_url));
  return { item, card, portrait };
}

export function chubProjectToCharacterCard(node: Record<string, unknown>): Record<string, unknown> {
  const definition =
    node.definition && typeof node.definition === "object" && !Array.isArray(node.definition)
      ? (node.definition as Record<string, unknown>)
      : {};
  const fullPath = stringValue(node.fullPath) || stringValue(definition.full_path);
  const creator = fullPath ? fullPath.split("/")[0] ?? "" : "";
  const extensions =
    definition.extensions &&
    typeof definition.extensions === "object" &&
    !Array.isArray(definition.extensions)
      ? definition.extensions as Record<string, unknown>
      : {};
  return {
    spec: "chara_card_v2",
    spec_version: "2.0",
    data: {
      name: stringValue(definition.name) || stringValue(node.name) || "Character",
      description: stringValue(definition.description) || stringValue(node.description) || "",
      personality:
        stringValue(definition.personality) || stringValue(definition.tavern_personality) || "",
      scenario: stringValue(definition.scenario),
      first_mes: stringValue(definition.first_message),
      mes_example: stringValue(definition.example_dialogs),
      creator_notes: stringValue(node.description),
      system_prompt: stringValue(definition.system_prompt),
      post_history_instructions: stringValue(definition.post_history_instructions),
      alternate_greetings: stringArray(definition.alternate_greetings),
      tags: stringArray(node.topics),
      creator,
      character_version: "",
      extensions: {
        ...extensions,
        chub_source: {
          id: numberValue(node.id),
          full_path: fullPath,
          source_url: fullPath ? `https://chub.ai/characters/${fullPath}` : null,
        },
      },
    },
  };
}

async function searchCharacterTavern(input: SearchInput): Promise<CharacterCatalogSearchResult> {
  const query = buildSearchText(input.query, input.tags);
  const url = new URL("https://character-tavern.com/api/search/cards");
  url.searchParams.set("query", query);
  url.searchParams.set("limit", String(CATALOG_LIMIT));
  url.searchParams.set("page", String(input.page ?? 1));
  if (input.sort) url.searchParams.set("sort", input.sort);
  const response = await fetchWithError(url.toString());
  const payload = await response.json();
  const hits = Array.isArray(payload?.hits) ? payload.hits : [];
  const items = hits
    .map((hit: Record<string, unknown>) => characterTavernHitToCatalogItem(hit))
    .filter((item: CharacterCatalogItem | null): item is CharacterCatalogItem => {
      if (!item) return false;
      return input.includeNsfw ? true : !item.nsfw;
    });
  return {
    provider: "character_tavern",
    query,
    page: numberValue(payload?.page) || input.page || 1,
    total: numberValue(payload?.totalHits),
    totalPages: numberValue(payload?.totalPages),
    items,
    status: "ok",
    message: null,
  };
}

export function characterTavernHitToCatalogItem(hit: Record<string, unknown>): CharacterCatalogItem | null {
  const id = stringValue(hit.id);
  const path = stringValue(hit.path);
  const name = stringValue(hit.name);
  if (!id || !path || !name) return null;
  return {
    provider: "character_tavern",
    id,
    title: name,
    author: stringValue(hit.author) || null,
    description: stringValue(hit.tagline) || stringValue(hit.pageDescription) || "",
    tags: stringArray(hit.tags),
    avatarUrl: characterTavernCardImageUrl(path, { width: 320, quality: 85 }),
    pageUrl: `https://character-tavern.com/character/${path}`,
    path,
    stats: {
      downloads: numberValue(hit.downloads) ?? undefined,
      likes: numberValue(hit.likes) ?? undefined,
      messages: numberValue(hit.messages) ?? undefined,
      tokens: numberValue(hit.totalTokens) ?? undefined,
    },
    nsfw: booleanValue(hit.isNSFW) || false,
    sourceLabel: "Character Tavern",
  };
}

async function downloadCharacterTavern(input: DownloadInput): Promise<CharacterCatalogDownloadResult> {
  const path = input.path ?? input.id;
  const response = await fetchWithError(`https://character-tavern.com/api/character/${path}`);
  const payload = await response.json();
  const rawCard = payload?.card && typeof payload.card === "object"
    ? payload.card as Record<string, unknown>
    : null;
  if (!rawCard) throw new Error("Character Tavern did not return a card.");
  const item = characterTavernCardToCatalogItem(rawCard);
  const card = characterTavernCardToCharacterCard(rawCard);
  const portrait = await fetchPortraitPayload(item.avatarUrl);
  return { item, card, portrait };
}

function characterTavernCardToCatalogItem(card: Record<string, unknown>): CharacterCatalogItem {
  const path = stringValue(card.path);
  return {
    provider: "character_tavern",
    id: stringValue(card.id) || path,
    title: stringValue(card.name) || "Character",
    author: stringValue(card.ownerCTId) || stringValue(card.author) || null,
    description: stringValue(card.tagline) || stringValue(card.description) || "",
    tags: [],
    avatarUrl: path ? characterTavernCardImageUrl(path, { width: 320, quality: 85 }) : null,
    pageUrl: path ? `https://character-tavern.com/character/${path}` : "https://character-tavern.com",
    path,
    stats: {
      downloads: numberValue(card.analytics_downloads) ?? undefined,
      messages: numberValue(card.analytics_messages) ?? undefined,
      tokens: numberValue(card.tokenTotal) ?? undefined,
    },
    nsfw: booleanValue(card.isNSFW) || false,
    sourceLabel: "Character Tavern",
  };
}

export function characterTavernCardToCharacterCard(
  card: Record<string, unknown>
): Record<string, unknown> {
  return {
    spec: "chara_card_v2",
    spec_version: "2.0",
    data: {
      name: stringValue(card.inChatName) || stringValue(card.name) || "Character",
      description:
        stringValue(card.definition_character_description) ||
        stringValue(card.description) ||
        "",
      personality: stringValue(card.definition_personality),
      scenario: stringValue(card.definition_scenario),
      first_mes: stringValue(card.definition_first_message),
      mes_example: stringValue(card.definition_example_messages),
      creator_notes: stringValue(card.description),
      system_prompt: stringValue(card.definition_system_prompt),
      post_history_instructions: stringValue(card.definition_post_history_prompt),
      alternate_greetings: [],
      tags: [],
      creator: stringValue(card.author),
      character_version: stringValue(card.versionId),
      extensions: {
        character_tavern_source: {
          id: stringValue(card.id),
          path: stringValue(card.path),
          source_url: stringValue(card.path)
            ? `https://character-tavern.com/character/${stringValue(card.path)}`
            : null,
        },
      },
    },
  };
}

function characterTavernCardImageUrl(
  path: string,
  options: { width?: number; quality?: number } = {}
): string {
  const url = new URL(`${path}.png`, `${CHARACTER_TAVERN_CARD_STORAGE}/`);
  if (options.width) url.searchParams.set("width", String(options.width));
  if (options.quality) url.searchParams.set("quality", String(options.quality));
  url.searchParams.set("format", "auto");
  return url.toString();
}

async function searchRisuRealm(input: SearchInput): Promise<CharacterCatalogSearchResult> {
  const query = buildSearchText(input.query, input.tags);
  const url = new URL("https://realm.risuai.net/");
  if (query) url.searchParams.set("q", query);
  const response = await fetchWithError(url.toString());
  const html = await response.text();
  const parsed = parseRisuSearchHtml(html);
  const items = parsed
    .filter((item) => input.includeNsfw ? true : !item.nsfw)
    .slice(0, CATALOG_LIMIT);
  return {
    provider: "risu_realm",
    query,
    page: input.page || 1,
    total: items.length,
    totalPages: null,
    items,
    status: "ok",
    message: null,
  };
}

export function parseRisuSearchHtml(html: string): CharacterCatalogItem[] {
  const items: CharacterCatalogItem[] = [];
  const cardPattern =
    /<a class="border p-4 flex hover:ring-2 rounded-md transition" href="\/character\/([^"]+)">([\s\S]*?)(?=<a class="border p-4 flex hover:ring-2 rounded-md transition"|<div class="mt-4 w-full flex justify-center|$)/g;
  let match: RegExpExecArray | null;
  while ((match = cardPattern.exec(html))) {
    const id = decodeHtml(match[1] ?? "");
    const block = match[2] ?? "";
    const title = decodeHtml(extractFirst(block, /<h2[^>]*>([\s\S]*?)<\/h2>/));
    if (!id || !title) continue;
    const authorLine = decodeHtml(extractFirst(block, /<span[^>]*>\s*By\s+([\s\S]*?)<\/span>/));
    const description = decodeHtml(extractFirst(block, /<p[^>]*>([\s\S]*?)<\/p>/));
    const image = decodeHtml(extractFirst(block, /<img src="([^"]+)"/));
    const tags = [...block.matchAll(/q=tag%3A[^"]+"[^>]*>([\s\S]*?)<\/a>/g)]
      .map((tag) => decodeHtml(stripTags(tag[1] ?? "")).trim())
      .filter(Boolean);
    items.push({
      provider: "risu_realm",
      id,
      title,
      author: authorLine || null,
      description,
      tags,
      avatarUrl: image || null,
      pageUrl: `https://realm.risuai.net/character/${id}`,
      path: id,
      stats: {},
      nsfw: tags.some((tag) => tag.toLowerCase().includes("nsfw")),
      sourceLabel: "Risu Realm",
    });
  }
  return items;
}

async function downloadRisuRealm(input: DownloadInput): Promise<CharacterCatalogDownloadResult> {
  const id = input.id;
  const jsonUrl = `https://realm.risuai.net/api/v1/download/json-v3/${encodeURIComponent(id)}?non_commercial=true`;
  let card: Record<string, unknown>;
  let packagedPortrait: CharacterPortraitPayload | null = null;
  try {
    const jsonResponse = await fetchWithError(jsonUrl).catch(() =>
      fetchWithError(
        `https://realm.risuai.net/api/v1/download/json-v2/${encodeURIComponent(id)}?non_commercial=true`
      )
    );
    card = await jsonResponse.json();
  } catch {
    const charxResponse = await fetchWithError(
      `https://realm.risuai.net/api/v1/download/charx-v3/${encodeURIComponent(id)}`
    );
    const buffer = Buffer.from(await charxResponse.arrayBuffer());
    const extracted = extractRisuCharx(buffer);
    card = extracted.card;
    packagedPortrait = extracted.portrait;
  }
  const item = risuCardToCatalogItem(id, card, input.avatarUrl ?? null);
  const portrait =
    await fetchPortraitPayload(input.avatarUrl).catch(() => null) ??
    packagedPortrait ??
    await fetchPortraitPayload(
      `https://realm.risuai.net/api/v1/download/png-v3/${encodeURIComponent(id)}?non_commercial=true`
    ).catch(() => null) ??
    await fetchPortraitPayload(
      `https://realm.risuai.net/api/v1/download/png-v2/${encodeURIComponent(id)}?non_commercial=true`
    ).catch(() => null);
  return { item, card, portrait };
}

type ZipEntry = {
  name: string;
  method: number;
  compressedSize: number;
  uncompressedSize: number;
  localOffset: number;
};

function extractRisuCharx(buffer: Buffer): {
  card: Record<string, unknown>;
  portrait: CharacterPortraitPayload | null;
} {
  if (buffer.length > 64 * 1024 * 1024) {
    throw new Error("Risu charx package is too large to inspect safely.");
  }
  const entries = readZipEntries(buffer);
  const cardEntry = entries.find((entry) => entry.name === "card.json");
  if (!cardEntry) throw new Error("Risu charx package is missing card.json.");
  const card = JSON.parse(extractZipEntry(buffer, cardEntry).toString("utf-8"));
  if (!card || typeof card !== "object" || Array.isArray(card)) {
    throw new Error("Risu charx card.json is invalid.");
  }
  const portraitEntry = entries.find((entry) =>
    /^assets\/icon\/image\/(main|iconx)\.(png|jpe?g|webp)$/i.test(entry.name)
  );
  const portrait = portraitEntry
    ? {
        dataBase64: extractZipEntry(buffer, portraitEntry).toString("base64"),
        mimeType: mimeTypeForFilename(portraitEntry.name),
      }
    : null;
  return { card: card as Record<string, unknown>, portrait };
}

function readZipEntries(buffer: Buffer): ZipEntry[] {
  const eocdOffset = findEndOfCentralDirectory(buffer);
  const entryCount = buffer.readUInt16LE(eocdOffset + 10);
  const centralDirOffset = buffer.readUInt32LE(eocdOffset + 16);
  const entries: ZipEntry[] = [];
  let offset = centralDirOffset;
  for (let index = 0; index < entryCount; index += 1) {
    if (buffer.readUInt32LE(offset) !== 0x02014b50) {
      throw new Error("Invalid ZIP central directory.");
    }
    const method = buffer.readUInt16LE(offset + 10);
    const compressedSize = buffer.readUInt32LE(offset + 20);
    const uncompressedSize = buffer.readUInt32LE(offset + 24);
    const nameLength = buffer.readUInt16LE(offset + 28);
    const extraLength = buffer.readUInt16LE(offset + 30);
    const commentLength = buffer.readUInt16LE(offset + 32);
    const localOffset = buffer.readUInt32LE(offset + 42);
    const name = buffer.subarray(offset + 46, offset + 46 + nameLength).toString("utf-8");
    entries.push({ name, method, compressedSize, uncompressedSize, localOffset });
    offset += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}

function findEndOfCentralDirectory(buffer: Buffer): number {
  const minimum = Math.max(0, buffer.length - 0xffff - 22);
  for (let offset = buffer.length - 22; offset >= minimum; offset -= 1) {
    if (buffer.readUInt32LE(offset) === 0x06054b50) return offset;
  }
  throw new Error("Invalid ZIP package.");
}

function extractZipEntry(buffer: Buffer, entry: ZipEntry): Buffer {
  const offset = entry.localOffset;
  if (buffer.readUInt32LE(offset) !== 0x04034b50) {
    throw new Error("Invalid ZIP local file header.");
  }
  if (entry.uncompressedSize > 8 * 1024 * 1024 && entry.name !== "card.json") {
    throw new Error("ZIP entry is too large to extract safely.");
  }
  const nameLength = buffer.readUInt16LE(offset + 26);
  const extraLength = buffer.readUInt16LE(offset + 28);
  const dataStart = offset + 30 + nameLength + extraLength;
  const compressed = buffer.subarray(dataStart, dataStart + entry.compressedSize);
  if (entry.method === 0) return compressed;
  if (entry.method === 8) return inflateRawSync(compressed);
  throw new Error(`Unsupported ZIP compression method ${entry.method}.`);
}

function mimeTypeForFilename(filename: string): string {
  const lower = filename.toLowerCase();
  if (lower.endsWith(".png")) return "image/png";
  if (lower.endsWith(".webp")) return "image/webp";
  return "image/jpeg";
}

function risuCardToCatalogItem(
  id: string,
  card: Record<string, unknown>,
  avatarUrl: string | null
): CharacterCatalogItem {
  const data =
    card.data && typeof card.data === "object" && !Array.isArray(card.data)
      ? card.data as Record<string, unknown>
      : card;
  return {
    provider: "risu_realm",
    id,
    title: stringValue(data.name) || "Character",
    author: stringValue(data.creator) || null,
    description: stringValue(data.description),
    tags: stringArray(data.tags),
    avatarUrl,
    pageUrl: `https://realm.risuai.net/character/${id}`,
    path: id,
    stats: {},
    nsfw: stringArray(data.tags).some((tag) => tag.toLowerCase().includes("nsfw")),
    sourceLabel: "Risu Realm",
  };
}

async function fetchPortraitPayload(url: string | null | undefined): Promise<CharacterPortraitPayload | null> {
  if (!url) return null;
  try {
    const response = await fetchWithError(url);
    const mimeType = response.headers.get("content-type")?.split(";")[0]?.trim() || "image/jpeg";
    if (!mimeType.startsWith("image/")) return null;
    const buffer = Buffer.from(await response.arrayBuffer());
    if (buffer.length === 0 || buffer.length > 8 * 1024 * 1024) return null;
    return { dataBase64: buffer.toString("base64"), mimeType };
  } catch {
    return null;
  }
}

async function fetchWithError(url: string, init?: RequestInit): Promise<Response> {
  const response = await fetch(url, {
    ...init,
    headers: {
      "User-Agent": "Hexis Character Catalog/1.0",
      ...(init?.headers ?? {}),
    },
  });
  if (!response.ok) {
    throw new Error(`Provider request failed (${response.status}) for ${new URL(url).hostname}`);
  }
  return response;
}

function buildSearchText(query: string, tags?: string[]): string {
  const pieces = [query, ...(tags ?? [])]
    .map((item) => item.trim())
    .filter(Boolean);
  return Array.from(new Set(pieces)).join(" ");
}

function extractFirst(text: string, regex: RegExp): string {
  return stripTags(regex.exec(text)?.[1] ?? "").trim();
}

function stripTags(value: string): string {
  return value.replace(/<[^>]*>/g, "");
}

function decodeHtml(value: string): string {
  return value
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, "\"")
    .replace(/&#39;/g, "'")
    .replace(/&#x27;/g, "'");
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function numberValue(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
}

function booleanValue(value: unknown): boolean | null {
  if (typeof value === "boolean") return value;
  if (typeof value === "string") {
    if (value.toLowerCase() === "true") return true;
    if (value.toLowerCase() === "false") return false;
  }
  return null;
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string" && item.trim().length > 0)
    : [];
}
