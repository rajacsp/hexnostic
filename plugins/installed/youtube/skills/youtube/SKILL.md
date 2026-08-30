---
name: youtube
description: YouTube channel/video statistics and search
category: analytics
requires:
  tools: [youtube_channel_stats]
contexts: [heartbeat, chat]
bound_tools: [youtube_channel_stats, youtube_video_stats, youtube_search]
---

# Youtube

Use these tools for youtube channel/video statistics and search. Credentials come from the
environment (YOUTUBE_API_KEY); when they are missing, say so
plainly and continue without this capability.
