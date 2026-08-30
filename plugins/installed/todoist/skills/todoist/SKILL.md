---
name: todoist
description: Todoist task management (create, list, complete)
category: productivity
requires:
  tools: [todoist_create_task]
contexts: [heartbeat, chat]
bound_tools: [todoist_create_task, todoist_list_tasks, todoist_complete_task]
---

# Todoist

Use these tools for todoist task management (create, list, complete). Credentials come from the
environment (TODOIST_API_KEY); when they are missing, say so
plainly and continue without this capability.
