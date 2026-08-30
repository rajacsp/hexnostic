---
name: video_gen
description: Video generation via Runway
category: creative
requires:
  tools: [generate_video]
contexts: [heartbeat, chat]
bound_tools: [generate_video]
---

# Video Gen

Use these tools for video generation via runway. Credentials come from the
environment (RUNWAY_API_KEY); when they are missing, say so
plainly and continue without this capability.
