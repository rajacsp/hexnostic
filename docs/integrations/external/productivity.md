<!--
title: Productivity
summary: Todoist and Asana integrations
read_when:
  - "You want to connect Todoist or Asana"
section: integrations
-->

# Productivity

Connect your agent to task management services.

## Todoist

### Setup

```bash
hexis tools set-api-key todoist env:TODOIST_API_KEY
hexis tools enable todoist_create_task
hexis tools enable todoist_list_tasks
hexis tools enable todoist_complete_task
```

Get your API key from [Todoist Settings > Integrations](https://todoist.com/app/settings/integrations).

### Tools

| Tool | Energy | Approval | Description |
|------|--------|----------|-------------|
| `todoist_create_task` | 2 | Yes | Create a new task with optional due date, priority, labels |
| `todoist_list_tasks` | 1 | No | List tasks with optional filters (project, label, or Todoist filter query) |
| `todoist_complete_task` | 2 | Yes | Mark a task as complete by ID |

### Parameters

**`todoist_create_task`**:
- `content` (required) -- task title
- `description` -- detailed description
- `due_string` -- natural language date (e.g., "tomorrow", "next Monday", "every Friday")
- `priority` -- 1 (normal) to 4 (urgent)
- `project_id` -- target project ID
- `labels` -- array of tag names

**`todoist_list_tasks`**:
- `project_id` -- filter by project
- `label` -- filter by label name
- `filter` -- Todoist filter query (e.g., `"today"`, `"overdue"`, `"priority 1"`)

## Asana

### Setup

```bash
hexis tools set-api-key asana env:ASANA_ACCESS_TOKEN
hexis tools enable asana_create_task
hexis tools enable asana_list_projects
```

Get your personal access token from [Asana Developer Console](https://app.asana.com/0/developer-console).

### Tools

| Tool | Energy | Approval | Description |
|------|--------|----------|-------------|
| `asana_create_task` | 2 | Yes | Create a new task with assignee, due date, and project |
| `asana_list_projects` | 1 | No | List projects in a workspace |

### Parameters

**`asana_create_task`**:
- `name` (required) -- task name
- `notes` -- description/notes
- `project_gid` -- project GID (from `asana_list_projects`)
- `assignee` -- email address or `"me"`
- `due_on` -- date in `YYYY-MM-DD` format
- `workspace_gid` -- workspace GID (required if no project specified)

## Related

- [Tools Configuration](../../guides/tools-configuration.md) -- enabling and configuring tools
- [Goals and Backlog](../../guides/goals-and-backlog.md) -- built-in goal management (no API key needed)
