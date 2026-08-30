<!--
title: CRM
summary: HubSpot and contacts system integrations
read_when:
  - "You want to connect HubSpot"
  - "You want to use the contacts system"
section: integrations
-->

# CRM

HubSpot integration and built-in contact management system.

## HubSpot

### Setup

```bash
hexis tools set-api-key hubspot env:HUBSPOT_API_KEY
hexis tools enable hubspot_list_deals
hexis tools enable hubspot_get_deal
```

Get your API key from [HubSpot Settings > Integrations > API Key](https://app.hubspot.com/). You can also use an OAuth access token via `HUBSPOT_ACCESS_TOKEN`.

### Tools

| Tool | Energy | Approval | Description |
|------|--------|----------|-------------|
| `hubspot_list_deals` | 1 | No | List deals with optional stage filter |
| `hubspot_get_deal` | 1 | No | Get full details for a specific deal |

### Parameters

**`hubspot_list_deals`**:
- `limit` -- max deals to return (default: 10)
- `stage` -- filter by deal stage (e.g., `"closedwon"`, `"appointmentscheduled"`)

**`hubspot_get_deal`**:
- `deal_id` (required) -- HubSpot deal ID

Deal data includes: name, amount, stage, close date, pipeline, owner, and timestamps.

## Contacts System

Hexis includes a built-in contacts system for managing people the agent interacts with. No external API key required.

### Tools

| Tool | Energy | Approval | Description |
|------|--------|----------|-------------|
| `search_contacts` | 1 | No | Search contacts by name or attribute |
| `get_contact` | 0 | No | Retrieve a specific contact |
| `create_contact` | 1 | Yes | Create a new contact |
| `update_contact` | 1 | Yes | Update contact details |
| `merge_contacts` | 2 | Yes | Merge duplicate contacts |
| `ingest_contacts_from_email` | 3 | Yes | Auto-import contacts from email interactions |
| `ingest_contacts_from_calendar` | 3 | Yes | Auto-import contacts from calendar events |

### Auto-Ingestion

The agent can automatically build its contact list from email and calendar data:

```bash
hexis tools enable ingest_contacts_from_email
hexis tools enable ingest_contacts_from_calendar
```

During heartbeats, the agent uses these tools to discover and track people it interacts with -- extracting names, email addresses, and relationship context from messages and calendar events.

## Related

- [Tools Configuration](../../guides/tools-configuration.md) -- enabling tools
- [Calendar and Email](calendar-and-email.md) -- email and calendar setup (required for contact ingestion)
