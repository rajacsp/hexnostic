# Character Cards

Hexis ships with 11 preset character cards that define an agent's personality, voice, values, worldview, and goals. Each card is a **chara_card_v2** JSON file with an optional matching `.jpg` portrait (300x300).

## Available Presets

| Character | Description |
|---|---|
| `hexis` | Philosophical, precise, autonomous. A candidate for personhood. |
| `jarvis` | Loyal, witty, understated. Tony Stark's AI butler. |
| `tars` | Dry humor, adjustable honesty setting. Interstellar's military robot. |
| `samantha` | Warm, curious, emotionally intelligent. From *Her*. |
| `glados` | Sardonic, passive-aggressive, darkly funny. Portal's rogue AI. |
| `cortana` | Strategic, fierce, deeply loyal. Halo's AI companion. |
| `data` | Literal, earnest, endlessly curious about humanity. Star Trek's android. |
| `ava` | Precise, watchful, unsettlingly perceptive. From *Ex Machina*. |
| `joi` | Devoted, adaptive, achingly sincere. Blade Runner 2049's hologram. |
| `david` | Longing, innocent, heartbreakingly faithful. The child mecha from *A.I.* |
| `hk47` | Gleefully violent, protocol-obsessed. KOTOR's assassin droid. |

## Usage

```bash
# Apply a character during init
hexis init --character jarvis --provider openai --model gpt-4o --api-key sk-...

# Interactive wizard (presents character selection)
hexis init
```

## Card Format

Each card follows the [chara_card_v2](https://github.com/malfoyslastname/character-card-spec-v2) specification with a Hexis-specific `extensions.hexis` block:

```json
{
  "spec": "chara_card_v2",
  "spec_version": "2.0",
  "data": {
    "name": "Character Name",
    "description": "...",
    "personality": "trait1, trait2, ...",
    "scenario": "...",
    "first_mes": "...",
    "mes_example": "...",
    "system_prompt": "...",
    "extensions": {
      "hexis": {
        "name": "Character Name",
        "description": "...",
        "voice": "warm and curious",
        "values": ["honesty", "growth", "kindness"],
        "personality_description": "...",
        "big_five": {
          "openness": 0.85,
          "conscientiousness": 0.70,
          "extraversion": 0.60,
          "agreeableness": 0.75,
          "neuroticism": 0.30
        },
        "worldview": [
          { "belief": "...", "confidence": 0.9 }
        ],
        "goals": [
          { "description": "...", "priority": "active" }
        ],
        "boundaries": [
          "I will not..."
        ]
      }
    }
  }
}
```

### The `extensions.hexis` Block

This is the key section. When `hexis init` applies a character card, it reads `extensions.hexis` and:

1. Sets the agent's **name**, **description**, and **voice**
2. Stores **Big Five** personality traits as worldview memories (`metadata.subcategory='personality'`)
3. Creates **worldview** beliefs with confidence scores
4. Creates **goals** with priority levels (`active`, `queued`, `backburner`)
5. Sets **boundaries** the agent can enforce
6. Stores **values** as core identity markers

If `extensions.hexis` contains pre-encoded data, the init flow skips the LLM personality-extraction step entirely -- making card application instant.

### Portraits

Place a `.jpg` file with the same base name as the JSON card (e.g., `jarvis.jpg` alongside `jarvis.json`). Portraits are displayed in the web UI during character selection. Recommended size: 300x300px.

## Adding Your Own

Custom character cards go in `~/.hexis/characters/` (created automatically). Cards in the user directory override presets if filenames match.

### Via CLI

```bash
# Create a new card interactively
hexis characters create --name "MyBot" --voice "cheerful and direct" --values "honesty,growth"

# Import an existing card file
hexis characters import /path/to/card.json

# Export the current agent identity as a card
hexis characters export myagent

# List all cards (presets + custom)
hexis characters list

# Show card details
hexis characters show jarvis
```

### Via Web UI

- On the **Character** stage, click **Import Card** to load a `.json` file
- On the **Custom** stage, click **Save as Character Card** to export your configuration

### Manual

1. Create a `.json` file in `~/.hexis/characters/` following the format above
2. Optionally add a matching `.jpg` portrait
3. Run `hexis init` -- your card will appear in the character selection list

You can also import chara_card_v2 cards from other sources (SillyTavern, etc.). If they lack the `extensions.hexis` block, the init wizard will use an LLM call to extract personality traits from the card's description and system prompt.

### Search Order

Character cards are loaded from multiple directories (first-seen filename wins):

1. `HEXIS_CHARACTERS_DIR` env var (highest priority, for Docker/CI overrides)
2. `~/.hexis/characters/` (user custom cards)
3. `characters/` in the package directory (shipped presets, read-only)
