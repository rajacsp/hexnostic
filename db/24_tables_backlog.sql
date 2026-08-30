-- ============================================================================
-- Backlog System Tables
--
-- Task/todo list that both the agent and user can CRUD.
-- Enables productive heartbeat work and chat-to-heartbeat delegation.
-- ============================================================================
SET search_path = public, ag_catalog, "$user";

CREATE TABLE IF NOT EXISTS public.backlog (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    description TEXT DEFAULT '',
    status TEXT NOT NULL DEFAULT 'todo'
        CHECK (status IN ('todo', 'in_progress', 'done', 'blocked', 'cancelled')),
    priority TEXT NOT NULL DEFAULT 'normal'
        CHECK (priority IN ('urgent', 'high', 'normal', 'low')),
    owner TEXT NOT NULL DEFAULT 'agent'
        CHECK (owner IN ('agent', 'user', 'shared')),
    created_by TEXT NOT NULL DEFAULT 'agent'
        CHECK (created_by IN ('agent', 'user')),
    tags TEXT[] DEFAULT '{}',
    checkpoint JSONB DEFAULT NULL,
    parent_id UUID REFERENCES backlog(id) ON DELETE SET NULL,
    due_date TIMESTAMPTZ DEFAULT NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for fast lookups
CREATE INDEX IF NOT EXISTS idx_backlog_status ON public.backlog(status);
CREATE INDEX IF NOT EXISTS idx_backlog_priority ON public.backlog(priority);
CREATE INDEX IF NOT EXISTS idx_backlog_owner ON public.backlog(owner);
CREATE INDEX IF NOT EXISTS idx_backlog_parent ON public.backlog(parent_id) WHERE parent_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_backlog_created_at ON public.backlog(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_backlog_actionable ON public.backlog(priority, created_at)
    WHERE status IN ('todo', 'in_progress');
