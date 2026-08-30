import { describe, expect, it } from "vitest";

import {
  hasCompleteLlmConfig,
  hasCompleteLlmSetup,
  mergePersonaIntoCharacterCard,
  nextStageFromInitStatus,
  safeCharacterFilename,
} from "./page";

describe("init model setup guards", () => {
  it("requires provider and model for a role config", () => {
    expect(hasCompleteLlmConfig(null)).toBe(false);
    expect(hasCompleteLlmConfig({ provider: "openai" })).toBe(false);
    expect(hasCompleteLlmConfig({ model: "gpt-5" })).toBe(false);
    expect(hasCompleteLlmConfig({ provider: " ", model: "gpt-5" })).toBe(false);
    expect(hasCompleteLlmConfig({ provider: "openai", model: " " })).toBe(false);
    expect(hasCompleteLlmConfig({ provider: "openai", model: "gpt-5" })).toBe(true);
  });

  it("does not trust llm_configured when one role is missing", () => {
    expect(
      hasCompleteLlmSetup({
        status: { stage: "llm", steps: { llm_configured: true } },
        llm_heartbeat: { provider: "openai", model: "gpt-5" },
        llm_subconscious: null,
      })
    ).toBe(false);
  });

  it("passes only when conscious and subconscious configs are complete", () => {
    expect(
      hasCompleteLlmSetup({
        status: { stage: "llm", steps: { llm_configured: true } },
        llm_heartbeat: { provider: "openai", model: "gpt-5" },
        llm_subconscious: { provider: "anthropic", model: "claude-sonnet-4-5-latest" },
      })
    ).toBe(true);
  });

  it("does not skip Models from ambient stored config while DB is still at llm", () => {
    expect(
      nextStageFromInitStatus("llm", {
        status: { stage: "llm", steps: { llm_configured: true } },
        llm_heartbeat: { provider: "openai-codex", model: "gpt-5.6-terra" },
        llm_subconscious: { provider: "openai-codex", model: "gpt-5.6-terra" },
      })
    ).toBe("llm");
  });

  it("preserves an explicit in-session advance after models are saved", () => {
    expect(
      nextStageFromInitStatus("choose_path", {
        status: { stage: "llm", steps: { llm_configured: true } },
        llm_heartbeat: { provider: "openai", model: "gpt-5" },
        llm_subconscious: { provider: "openai", model: "gpt-5" },
      })
    ).toBe("choose_path");
  });
});

describe("init character catalog helpers", () => {
  it("generates provider-scoped safe filenames", () => {
    expect(safeCharacterFilename("Althiel Saelith!", "chub")).toBe(
      "chub_althiel_saelith.json"
    );
  });

  it("preserves the original card while adding Hexis persona data", () => {
    const card = {
      spec: "chara_card_v2",
      spec_version: "2.0",
      data: {
        name: "Source Name",
        description: "Original description",
        personality: "Original personality",
        extensions: { provider: { id: "abc" } },
      },
    };
    const merged = mergePersonaIntoCharacterCard(card, {
      name: "Hexis Name",
      pronouns: "she/her",
      voice: "warm",
      description: "Hexis description",
      purpose: "companionship",
      personality_description: "curious",
      personality_traits: {
        openness: 0.8,
        conscientiousness: 0.6,
        extraversion: 0.5,
        agreeableness: 0.7,
        neuroticism: 0.3,
      },
      values: ["honesty"],
      worldview: {
        metaphysics: "",
        human_nature: "",
        epistemology: "",
        ethics: "",
      },
      interests: ["music"],
      goals: ["learn"],
      boundaries: ["no deception"],
      narrative: "A complete character portrait.",
    }) as {
      data: {
        name: string;
        description: string;
        extensions: {
          provider: { id: string };
          hexis: { values: string[] };
        };
      };
    };

    expect(merged.data.name).toBe("Hexis Name");
    expect(merged.data.description).toBe("Original description");
    expect(merged.data.extensions.provider).toEqual({ id: "abc" });
    expect(merged.data.extensions.hexis.values).toEqual(["honesty"]);
  });
});
