import { describe, expect, it } from "vitest";

import { IntegrationStatusData, summarizeConnectors } from "./status";

describe("connection status helpers", () => {
  it("groups DB-owned integration status by connector", () => {
    const data: IntegrationStatusData = {
      connectors: [
        {
          id: "gmail",
          display_name: "Gmail",
          category: "email",
          auth_type: "oauth2",
          status: "available",
          capability_manifest: { read: {}, search: {} },
          setup_manifest: { default_capabilities: ["read"] },
          docs_url: "https://example.com/gmail",
        },
        {
          id: "telegram",
          display_name: "Telegram",
          category: "chat",
          auth_type: "api_key",
          status: "available",
          capability_manifest: { live_chat: {}, send: {} },
          setup_manifest: { default_capabilities: ["live_chat"] },
          docs_url: null,
        },
        {
          id: "twitter_x",
          display_name: "Twitter/X",
          category: "social",
          auth_type: "local_export",
          status: "available",
          capability_manifest: { ingest: { status: "available" } },
          setup_manifest: { default_capabilities: ["ingest"] },
          docs_url: null,
        },
      ],
      connections: [
        {
          id: "connection-1",
          connector_id: "gmail",
          account_key: "eric@example.com",
          display_name: "Eric",
          status: "connected",
          credential_ref: "integration.gmail.default",
          granted_scopes: ["gmail.readonly"],
          capabilities: ["read", "search"],
          source_channel: "web",
          source_session_id: null,
          last_error: null,
          connected_at: "2026-07-20T12:00:00.000Z",
          last_verified_at: null,
          revoked_at: null,
          updated_at: "2026-07-20T12:00:00.000Z",
        },
      ],
      recent_attempts: [
        {
          attempt_id: "attempt-1",
          connector_id: "telegram",
          account_key: null,
          status: "pending_user",
          requested_capabilities: ["live_chat"],
          requested_scopes: [],
          authorization_url: null,
          user_next_step: "Set TELEGRAM_BOT_TOKEN.",
          source_channel: "web",
          source_session_id: "setup",
          credential_ref: null,
          error: null,
          expires_at: null,
          completed_at: null,
          created_at: "2026-07-20T12:01:00.000Z",
          updated_at: "2026-07-20T12:01:00.000Z",
        },
      ],
      channel_runtime: [
        {
          channel_type: "telegram",
          status: "running",
          configured: true,
          running: true,
          worker_id: "worker-1",
          pid: 123,
          last_checked_at: null,
          last_started_at: null,
          last_stopped_at: null,
          last_error: null,
          metadata: {},
          updated_at: "2026-07-20T12:02:00.000Z",
        },
      ],
      backfill: {
        jobs: [
          {
            job_id: "job-1",
            connector_id: "gmail",
            account_key: "eric@example.com",
            cursor_key: "messages",
            status: "completed",
            attempts: 1,
            max_attempts: 3,
            progress: {},
            result: {},
            error: null,
            cancel_requested: false,
            pause_requested: false,
            updated_at: "2026-07-20T12:03:00.000Z",
            completed_at: "2026-07-20T12:03:00.000Z",
          },
        ],
        cursors: [],
        item_counts: [
          {
            connector_id: "gmail",
            account_key: "eric@example.com",
            item_kind: "message",
            status: "ingested",
            count: 12,
            latest_item_at: "2026-07-20T12:04:00.000Z",
          },
        ],
      },
    };

    const summaries = summarizeConnectors(data);
    const byId = Object.fromEntries(summaries.map((summary) => [summary.connector.id, summary]));

    expect(byId.gmail.state).toBe("connected");
    expect(byId.gmail.activeConnections).toHaveLength(1);
    expect(byId.gmail.backfillJobs).toHaveLength(1);
    expect(byId.gmail.sourceItemCount).toBe(12);
    expect(byId.telegram.state).toBe("pending");
    expect(byId.telegram.runtime?.status).toBe("running");
    expect(byId.twitter_x.state).toBe("available");
  });
});
