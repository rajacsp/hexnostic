---
name: hubspot
description: HubSpot CRM deals integration
category: productivity
requires:
  tools: [hubspot_list_deals]
contexts: [heartbeat, chat]
bound_tools: [hubspot_list_deals, hubspot_get_deal]
---

# Hubspot

Use these tools for hubspot crm deals integration. Credentials come from the
environment (HUBSPOT_API_KEY, HUBSPOT_ACCESS_TOKEN); when they are missing, say so
plainly and continue without this capability.
