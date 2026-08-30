<!--
title: Calendar and Email
summary: Google Calendar, SMTP email, and SendGrid integrations
read_when:
  - "You want to connect calendar or email"
  - "You want the agent to manage meetings"
section: integrations
-->

# Calendar and Email

Connect your agent to Google Calendar for scheduling and SMTP/SendGrid for email.

## Google Calendar

### Setup

Requires Google Calendar API credentials (OAuth or service account).

```bash
hexis tools set-api-key google_calendar env:GOOGLE_CALENDAR_CREDENTIALS
hexis tools enable calendar_events
hexis tools enable calendar_create
```

### Tools

| Tool | Energy | Description |
|------|--------|-------------|
| `calendar_events` | 2 | List upcoming events |
| `calendar_create` | 3 | Create a new event |
| `calendar_update` | 3 | Update an existing event |
| `calendar_delete` | 3 | Delete an event |
| `meeting_prep` | 4 | Pre-meeting research, attendee context, and agenda preparation |

### Meeting Prep

The `meeting_prep` tool is a compound operation that:
1. Retrieves the upcoming meeting details
2. Searches memories for context about attendees
3. Reviews relevant goals and past interactions
4. Generates an agenda and preparation notes

## Email (SMTP)

### Setup

Configure SMTP credentials for sending and reading email:

```bash
hexis tools set-api-key smtp_host env:SMTP_HOST
hexis tools set-api-key smtp_user env:SMTP_USER
hexis tools set-api-key smtp_password env:SMTP_PASSWORD
```

### Tools

| Tool | Energy | Description |
|------|--------|-------------|
| `email_send` | 4 | Send an email via SMTP |
| `email_list` | 2 | List emails in inbox |
| `email_read` | 2 | Read a specific email |
| `email_search` | 2 | Search emails |
| `email_forward` | 5 | Forward an email |

## Email (SendGrid)

### Setup

```bash
hexis tools set-api-key sendgrid env:SENDGRID_API_KEY
hexis tools enable email_send_sendgrid
```

### Tools

| Tool | Energy | Description |
|------|--------|-------------|
| `email_send_sendgrid` | 4 | Send email via SendGrid API |

## Related

- [Tools Configuration](../../guides/tools-configuration.md) -- enabling and configuring tools
- [Scheduling](../../guides/scheduling.md) -- schedule meeting prep as a daily task
