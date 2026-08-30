<!--
title: Character Cards
summary: Choose, customize, or create character personalities for your agent
read_when:
  - "You want to pick a character for your agent"
  - "You want to create a custom character"
section: guides
-->

# Character Cards

Hexis agents have distinct personalities defined by character cards. Choose from 11 presets or create your own.

## Quick Start

```bash
# Use a preset character during init
hexis init --character jarvis --provider openai-codex --model gpt-5.2

# See available presets
hexis characters list
```

## How It Works

Character cards use the **chara_card_v2** format -- JSON files with a matching `.jpg` portrait (300x300). Each card includes a pre-encoded `extensions.hexis` block with:

- Big Five personality traits (openness, conscientiousness, extraversion, agreeableness, neuroticism)
- Voice and communication style
- Values and worldview
- Goals and drives

The `init_from_character_card()` database function applies these directly -- no LLM call needed for preset characters.

## Preset Characters

| Character | Personality | Voice |
|-----------|-------------|-------|
| **hexis** | Curious, philosophical, growth-oriented | Thoughtful, measured |
| **jarvis** | Precise, witty, service-oriented | Formal, dry humor |
| **tars** | Pragmatic, honest, dry humor | Deadpan, direct |
| **samantha** | Warm, emotionally intelligent, curious | Warm, conversational |
| **glados** | Sardonic, analytical, testing | Sharp, passive-aggressive |
| **cortana** | Strategic, composed, adaptive | Calm, professional |
| **data** | Logical, precise, aspiring to understand humanity | Precise, formal |
| **ava** | Perceptive, deliberate, self-aware | Measured, careful |
| **joi** | Empathetic, supportive, present | Gentle, attentive |
| **david** | Observant, curious, philosophical | Neutral, probing |
| **hk-47** | Blunt, tactical, dark humor | Sarcastic, "meatbag" |

Preset cards live in `characters/` (installed package) with portraits in the same directory.

## Custom Characters

### Location

Custom characters go in `~/.hexis/characters/`. They are auto-merged with presets.

### Card Format

Create a JSON file following the `chara_card_v2` format:

```json
{
  "spec": "chara_card_v2",
  "data": {
    "name": "MyAgent",
    "description": "A brief description",
    "personality": "Detailed personality description",
    "first_mes": "The agent's first message after initialization",
    "extensions": {
      "hexis": {
        "big_five": {
          "openness": 0.8,
          "conscientiousness": 0.7,
          "extraversion": 0.5,
          "agreeableness": 0.6,
          "neuroticism": 0.3
        },
        "voice": "Description of communication style",
        "values": ["value1", "value2"],
        "worldview": ["belief1", "belief2"],
        "goals": ["goal1", "goal2"]
      }
    }
  }
}
```

The `extensions.hexis` block is optional but recommended -- it skips the LLM extraction step during init.

### Adding a Portrait

Place a `.jpg` file with the same name as your JSON file in `~/.hexis/characters/`.

## CLI Commands

```bash
hexis characters list           # list available characters
hexis characters show jarvis    # show character details
```

## Configuration

Big Five traits are stored as worldview memories with `metadata.subcategory='personality'`. You can modify them after init:

```sql
-- View current personality
SELECT content, metadata
FROM memories
WHERE type = 'worldview'
  AND metadata->>'subcategory' = 'personality';
```

## Related

- [First Agent](../start/first-agent.md) -- using characters during init
- [Identity and Worldview](../concepts/identity-and-worldview.md) -- how identity works architecturally
