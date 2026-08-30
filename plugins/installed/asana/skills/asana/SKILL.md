---
name: asana
description: Asana project and task integration
category: productivity
requires:
  tools: [asana_create_task]
contexts: [heartbeat, chat]
bound_tools: [asana_create_task, asana_list_projects]
---

# Asana

Use these tools for asana project and task integration. Credentials come from the
environment (ASANA_ACCESS_TOKEN, ASANA_API_KEY); when they are missing, say so
plainly and continue without this capability.
