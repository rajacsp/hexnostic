import { describe, expect, it } from "vitest";

import {
  characterTavernCardToCharacterCard,
  characterTavernHitToCatalogItem,
  chubNodeToCatalogItem,
  chubProjectToCharacterCard,
  parseRisuSearchHtml,
} from "./character-catalog";

describe("character catalog normalization", () => {
  it("normalizes Chub search nodes", () => {
    const item = chubNodeToCatalogItem({
      id: 4921471,
      name: "Althiel Saelith",
      fullPath: "Anonymous/althiel-saelith-25cba0d4",
      description: "Elven professor",
      topics: ["Tool", "Elf"],
      avatar_url: "https://avatars.charhub.io/avatar.webp",
      starCount: 12,
      nMessages: 99,
      nTokens: 203,
    });

    expect(item).toMatchObject({
      provider: "chub",
      id: "4921471",
      title: "Althiel Saelith",
      author: "Anonymous",
      tags: ["Tool", "Elf"],
      pageUrl: "https://chub.ai/characters/Anonymous/althiel-saelith-25cba0d4",
    });
    expect(item?.stats).toMatchObject({ likes: 12, messages: 99, tokens: 203 });
  });

  it("converts a Chub project definition into chara_card_v2", () => {
    const card = chubProjectToCharacterCard({
      id: 42,
      name: "Example",
      fullPath: "maker/example",
      topics: ["assistant"],
      definition: {
        name: "Example",
        description: "Description",
        personality: "Patient and precise",
        first_message: "Hello",
        extensions: { talkativeness: "0.5" },
      },
    }) as {
      spec: string;
      data: {
        name: string;
        extensions: {
          talkativeness: string;
          chub_source: { full_path: string };
        };
      };
    };

    expect(card.spec).toBe("chara_card_v2");
    expect(card.data.name).toBe("Example");
    expect(card.data.extensions.talkativeness).toBe("0.5");
    expect(card.data.extensions.chub_source.full_path).toBe("maker/example");
  });

  it("normalizes Character Tavern search hits and card details", () => {
    const item = characterTavernHitToCatalogItem({
      id: "CT_1",
      name: "Fuka Shikuzaki",
      path: "rickrocka/fuka_shikuzaki",
      author: "rickrocka",
      tagline: "Fuka Shikuzaki",
      tags: ["female", "roleplay"],
      downloads: 81,
      messages: 8191,
      totalTokens: 1049,
    });
    expect(item).toMatchObject({
      provider: "character_tavern",
      id: "CT_1",
      title: "Fuka Shikuzaki",
      pageUrl: "https://character-tavern.com/character/rickrocka/fuka_shikuzaki",
    });
    expect(item?.avatarUrl).toContain("ct-cards.storage.character-tavern.com");

    const card = characterTavernCardToCharacterCard({
      id: "CT_1",
      path: "rickrocka/fuka_shikuzaki",
      name: "Fuka",
      inChatName: "Fuka Shikuzaki",
      definition_character_description: "Description",
      definition_first_message: "Hi",
    }) as {
      data: {
        name: string;
        description: string;
        first_mes: string;
      };
    };
    expect(card.data.name).toBe("Fuka Shikuzaki");
    expect(card.data.description).toBe("Description");
    expect(card.data.first_mes).toBe("Hi");
  });

  it("parses Risu Realm server-rendered search cards", () => {
    const html = `
      <a class="border p-4 flex hover:ring-2 rounded-md transition" href="/character/abc-123">
        <div><img src="https://sv.risuai.xyz/resource/image-id" alt="Fukawa Toko"></div>
        <div><h2>Fukawa Toko</h2>
        <span>By v596vtg1pw</span>
        <p>Ultimate Writing Prodigy</p>
        <div><a href="/?q=tag%3Afemale">female</a><a href="/?q=tag%3Aanime">anime</a></div></div>
      </a></div>
    `;

    expect(parseRisuSearchHtml(html)).toEqual([
      expect.objectContaining({
        provider: "risu_realm",
        id: "abc-123",
        title: "Fukawa Toko",
        author: "v596vtg1pw",
        tags: ["female", "anime"],
        avatarUrl: "https://sv.risuai.xyz/resource/image-id",
      }),
    ]);
  });
});
