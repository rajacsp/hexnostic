import { prisma } from "@/lib/prisma";
import { toJsonParam } from "@/lib/db";
import { getConsciousLlmConfig, callLlm, extractJson } from "@/lib/llm";

export const runtime = "nodejs";
export const maxDuration = 120;

const SUMMARIZATION_PROMPT = `You are an expert at analyzing character cards (chara_card_v2 format) and converting them into a structured persona for an AI agent.

Given the character card data below, produce a JSON object with the following fields:

{
  "name": "the character's name",
  "pronouns": "inferred pronouns (e.g. he/him, she/her, they/them)",
  "voice": "a short description of their speaking style/tone",
  "description": "2-3 sentence identity description",
  "purpose": "the character's purpose or role",
  "personality_description": "a concise personality summary",
  "personality_traits": {
    "openness": 0.0-1.0,
    "conscientiousness": 0.0-1.0,
    "extraversion": 0.0-1.0,
    "agreeableness": 0.0-1.0,
    "neuroticism": 0.0-1.0
  },
  "values": ["value1", "value2", ...],
  "worldview": {
    "metaphysics": "brief belief about reality",
    "human_nature": "brief belief about people/nature",
    "epistemology": "how they know things",
    "ethics": "moral framework"
  },
  "interests": ["interest1", "interest2", ...],
  "goals": ["goal1", "goal2", ...],
  "boundaries": ["boundary1", "boundary2", ...],
  "narrative": "A comprehensive 2-4 paragraph narrative persona description. This should capture who this character IS — their identity, personality, history, relationships, motivations, quirks, and voice. Write it as a rich prose portrait, not a list. Include relevant world-building details if the card has lore entries. This narrative will become the character's foundational self-knowledge."
}

Guidelines:
- Infer personality traits from the description, not just stated traits
- Extract values from their behavior and beliefs
- Derive worldview from the scenario and character's perspective
- Keep goals actionable and character-appropriate
- The narrative should be the richest field — a living portrait
- If the card has lore/world-building entries, weave the most important ones into the narrative
- Return ONLY the JSON object, no markdown fences or extra text`;

type JsonRecord = Record<string, unknown>;

function recordValue(value: unknown): JsonRecord | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as JsonRecord)
    : null;
}

function textValue(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function extractCardData(card: unknown): string {
  const root = recordValue(card) ?? {};
  const data = recordValue(root.data) ?? root;
  const charName = textValue(data.name) || "the character";
  const parts: string[] = [];

  if (textValue(data.name)) parts.push(`Name: ${textValue(data.name)}`);
  if (textValue(data.description)) parts.push(`Description:\n${textValue(data.description)}`);
  if (textValue(data.personality)) parts.push(`Personality: ${textValue(data.personality)}`);
  if (textValue(data.scenario)) parts.push(`Scenario:\n${textValue(data.scenario)}`);
  if (textValue(data.first_mes)) {
    parts.push(`First Message (voice sample):\n${textValue(data.first_mes)}`);
  }
  if (textValue(data.mes_example)) {
    // Cap example messages — they're useful for voice/tone but can be very long
    const trimmed = textValue(data.mes_example).slice(0, 1500);
    parts.push(`Example Messages:\n${trimmed}`);
  }
  if (textValue(data.system_prompt)) {
    parts.push(`System Prompt: ${textValue(data.system_prompt)}`);
  }
  if (textValue(data.creator_notes)) {
    parts.push(`Creator Notes: ${textValue(data.creator_notes)}`);
  }
  if (Array.isArray(data.tags) && data.tags.length > 0) {
    parts.push(`Tags: ${data.tags.filter((tag) => typeof tag === "string").join(", ")}`);
  }

  // Character book entries (lore) — include up to 10 most relevant
  const characterBook = recordValue(data.character_book);
  const entries = Array.isArray(characterBook?.entries) ? characterBook.entries : [];
  if (entries.length > 0) {
    const loreItems = entries
      .map((entry) => recordValue(entry))
      .filter((entry): entry is JsonRecord => !!entry && (!!entry.content || !!entry.name))
      .slice(0, 10)
      .map((entry) => {
        const name = textValue(entry.name) || textValue(entry.comment) || "Lore Entry";
        return `- ${name}: ${textValue(entry.content).slice(0, 500)}`;
      });
    if (loreItems.length > 0) {
      parts.push(`World-Building Lore:\n${loreItems.join("\n")}`);
    }
  }

  // Replace chara_card template variables so the LLM produces clean narrative
  return parts
    .join("\n\n")
    .replace(/\{\{char\}\}/gi, charName)
    .replace(/\{\{user\}\}/gi, "the user");
}

export async function POST(request: Request) {
  try {
    const body = await request.json().catch(() => null);
    if (!body) {
      return Response.json({ error: "Invalid JSON body" }, { status: 400 });
    }

    const bodyRecord = recordValue(body) ?? {};
    const cardData = bodyRecord.card ?? bodyRecord;
    const cardRecord = recordValue(cardData) ?? {};
    const dataRecord = recordValue(cardRecord.data);
    const extensionsRecord = recordValue(dataRecord?.extensions);
    const hexisProfile = recordValue(extensionsRecord?.hexis);
    const persist = bodyRecord.persist === true;

    // If the card has pre-encoded hexis profile data, use it directly (skip LLM)
    if (hexisProfile && hexisProfile.personality_traits) {
      const parsed = hexisProfile;

      // Store the narrative as a foundational worldview memory only when the
      // caller explicitly asks for a persistent import. Catalog adaptation is a
      // preview/customization step; applying the card writes the real init data.
      const narrative = typeof parsed.narrative === "string" ? parsed.narrative : "";
      if (persist && narrative.length > 10) {
        const cardName =
          textValue(dataRecord?.name) || textValue(cardRecord.name) || "unknown";
        const metadata = {
          subcategory: "imported_persona",
          source: "chara_card_v2",
          original_name: cardName,
          change_requires: "deliberate_transformation",
          evidence_threshold: 0.9,
        };
        await prisma.$queryRaw`
          SELECT create_worldview_memory(
            ${narrative}::text,
            'self'::text,
            0.95::float,
            0.95::float,
            0.95::float,
            'character_card_import'::text,
            NULL::jsonb,
            NULL::text,
            NULL::text,
            0.0::float,
            ${toJsonParam(metadata)}::jsonb
          )
        `;
      }

      return Response.json({ persona: parsed });
    }

    // No pre-encoded profile — fall back to LLM extraction
    const extracted = extractCardData(cardData);
    if (!extracted || extracted.length < 20) {
      return Response.json(
        { error: "Character card appears empty or invalid" },
        { status: 400 }
      );
    }

    const llmConfig = await getConsciousLlmConfig();

    const userPrompt = `Here is the character card data:\n\n${extracted}\n\nProduce the JSON persona object.`;
    const useJsonMode =
      llmConfig.provider === "openai" ||
      llmConfig.provider === "grok" ||
      llmConfig.provider === "openai_compatible";

    const response = await callLlm({
      config: llmConfig,
      system: SUMMARIZATION_PROMPT,
      user: userPrompt,
      temperature: 0.3,
      maxTokens: 4000,
      jsonMode: useJsonMode,
    });

    const parsed = extractJson(response);
    if (!parsed.name && !parsed.narrative) {
      return Response.json(
        { error: "LLM did not return a valid persona. Try again.", raw: response },
        { status: 502 }
      );
    }

    // Store the narrative as a foundational worldview memory only when the
    // caller explicitly asks for a persistent import. Catalog adaptation is a
    // preview/customization step; applying the card writes the real init data.
    const narrative = typeof parsed.narrative === "string" ? parsed.narrative : "";
    if (persist && narrative.length > 10) {
      const cardName =
        textValue(dataRecord?.name) || textValue(cardRecord.name) || "unknown";
      const metadata = {
        subcategory: "imported_persona",
        source: "chara_card_v2",
        original_name: cardName,
        change_requires: "deliberate_transformation",
        evidence_threshold: 0.9,
      };
      await prisma.$queryRaw`
        SELECT create_worldview_memory(
          ${narrative}::text,
          'self'::text,
          0.95::float,
          0.95::float,
          0.95::float,
          'character_card_import'::text,
          NULL::jsonb,
          NULL::text,
          NULL::text,
          0.0::float,
          ${toJsonParam(metadata)}::jsonb
        )
      `;
    }

    return Response.json({ persona: parsed });
  } catch (err: unknown) {
    console.error("import-card error:", err instanceof Error ? err.message : err);
    return Response.json(
      { error: err instanceof Error ? err.message : "Failed to import character card" },
      { status: 500 }
    );
  }
}
