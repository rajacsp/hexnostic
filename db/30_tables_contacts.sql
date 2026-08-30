-- =============================================================
-- Personal CRM  —  Contacts Table
-- =============================================================
SET search_path = public, ag_catalog, "$user";

-- Stores people the agent has interacted with.
-- Supports semantic search via pgvector embedding and traditional
-- search via text indexes.

-- -------------------------------------------------------------
-- Table
-- -------------------------------------------------------------

CREATE TABLE contacts (
    id              BIGSERIAL PRIMARY KEY,
    name            TEXT NOT NULL,
    email           TEXT,
    company         TEXT,
    role            TEXT,               -- e.g. 'CEO', 'engineer', 'investor'
    phone           TEXT,
    notes           TEXT,
    tags            TEXT[] NOT NULL DEFAULT '{}',
    source          TEXT NOT NULL DEFAULT 'manual',  -- 'email', 'calendar', 'manual', 'import'
    embedding       vector,             -- semantic search vector (lazy-populated)
    first_seen      TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_touch      TIMESTAMPTZ NOT NULL DEFAULT now(),
    metadata        JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -------------------------------------------------------------
-- Indexes
-- -------------------------------------------------------------

CREATE INDEX idx_contacts_name
    ON contacts USING gin (to_tsvector('english', name));

CREATE INDEX idx_contacts_email
    ON contacts (lower(email))
    WHERE email IS NOT NULL;

CREATE INDEX idx_contacts_company
    ON contacts USING gin (to_tsvector('english', coalesce(company, '')));

CREATE INDEX idx_contacts_tags
    ON contacts USING gin (tags);

CREATE INDEX idx_contacts_last_touch
    ON contacts (last_touch DESC);

-- Note: vector index (HNSW or ivfflat) will be created after the first
-- batch of embeddings is populated, since ivfflat requires training data
-- and the dimension is set at runtime via config.

-- -------------------------------------------------------------
-- Trigger: auto-update updated_at
-- -------------------------------------------------------------

CREATE FUNCTION contacts_update_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_contacts_updated_at
    BEFORE UPDATE ON contacts
    FOR EACH ROW
    EXECUTE FUNCTION contacts_update_timestamp();

-- -------------------------------------------------------------
-- Functions
-- -------------------------------------------------------------

-- Create a new contact
CREATE FUNCTION create_contact(
    p_name TEXT,
    p_email TEXT DEFAULT NULL,
    p_company TEXT DEFAULT NULL,
    p_role TEXT DEFAULT NULL,
    p_phone TEXT DEFAULT NULL,
    p_notes TEXT DEFAULT NULL,
    p_tags TEXT[] DEFAULT '{}',
    p_source TEXT DEFAULT 'manual',
    p_metadata JSONB DEFAULT '{}'
) RETURNS BIGINT AS $$
    INSERT INTO contacts (name, email, company, role, phone, notes, tags, source, metadata)
    VALUES (p_name, p_email, p_company, p_role, p_phone, p_notes, p_tags, p_source, p_metadata)
    RETURNING id;
$$ LANGUAGE sql;


-- Update a contact's fields (NULL params = no change)
CREATE FUNCTION update_contact(
    p_id BIGINT,
    p_name TEXT DEFAULT NULL,
    p_email TEXT DEFAULT NULL,
    p_company TEXT DEFAULT NULL,
    p_role TEXT DEFAULT NULL,
    p_phone TEXT DEFAULT NULL,
    p_notes TEXT DEFAULT NULL,
    p_tags TEXT[] DEFAULT NULL,
    p_metadata JSONB DEFAULT NULL
) RETURNS BOOLEAN AS $$
    UPDATE contacts SET
        name     = COALESCE(p_name, name),
        email    = COALESCE(p_email, email),
        company  = COALESCE(p_company, company),
        role     = COALESCE(p_role, role),
        phone    = COALESCE(p_phone, phone),
        notes    = COALESCE(p_notes, notes),
        tags     = COALESCE(p_tags, tags),
        metadata = CASE WHEN p_metadata IS NOT NULL
                        THEN metadata || p_metadata
                        ELSE metadata END
    WHERE id = p_id
    RETURNING TRUE;
$$ LANGUAGE sql;


-- Touch a contact (update last_touch timestamp)
CREATE FUNCTION touch_contact(p_id BIGINT)
RETURNS VOID AS $$
    UPDATE contacts SET last_touch = now() WHERE id = p_id;
$$ LANGUAGE sql;


-- Search contacts by text query (name, email, company, notes)
CREATE FUNCTION search_contacts(
    p_query TEXT,
    p_limit INT DEFAULT 20
) RETURNS SETOF contacts AS $$
    SELECT c.*
    FROM contacts c
    WHERE to_tsvector('english', coalesce(c.name, '') || ' ' ||
                                  coalesce(c.email, '') || ' ' ||
                                  coalesce(c.company, '') || ' ' ||
                                  coalesce(c.notes, ''))
          @@ plainto_tsquery('english', p_query)
       OR c.name ILIKE '%' || p_query || '%'
       OR c.email ILIKE '%' || p_query || '%'
       OR c.company ILIKE '%' || p_query || '%'
    ORDER BY c.last_touch DESC
    LIMIT p_limit;
$$ LANGUAGE sql STABLE;


-- Semantic search over contacts using vector similarity
CREATE FUNCTION search_contacts_semantic(
    p_embedding vector,
    p_limit INT DEFAULT 10,
    p_threshold FLOAT DEFAULT 0.3
) RETURNS TABLE (
    id BIGINT,
    name TEXT,
    email TEXT,
    company TEXT,
    role TEXT,
    similarity FLOAT
) AS $$
    SELECT
        c.id,
        c.name,
        c.email,
        c.company,
        c.role,
        1.0 - (c.embedding <=> p_embedding) AS similarity
    FROM contacts c
    WHERE c.embedding IS NOT NULL
      AND 1.0 - (c.embedding <=> p_embedding) >= p_threshold
    ORDER BY c.embedding <=> p_embedding
    LIMIT p_limit;
$$ LANGUAGE sql STABLE;


-- Find contacts by exact email
CREATE FUNCTION get_contact_by_email(p_email TEXT)
RETURNS SETOF contacts AS $$
    SELECT * FROM contacts WHERE lower(email) = lower(p_email) LIMIT 1;
$$ LANGUAGE sql STABLE;


-- Get contacts by tag
CREATE FUNCTION get_contacts_by_tag(p_tag TEXT, p_limit INT DEFAULT 50)
RETURNS SETOF contacts AS $$
    SELECT * FROM contacts WHERE p_tag = ANY(tags)
    ORDER BY last_touch DESC LIMIT p_limit;
$$ LANGUAGE sql STABLE;


-- Merge two contacts (keep p_keep_id, delete p_remove_id)
CREATE FUNCTION merge_contacts(p_keep_id BIGINT, p_remove_id BIGINT)
RETURNS BOOLEAN AS $$
DECLARE
    v_remove contacts;
BEGIN
    SELECT * INTO v_remove FROM contacts WHERE id = p_remove_id;
    IF NOT FOUND THEN RETURN FALSE; END IF;

    -- Merge: fill NULLs on keep from remove, combine tags
    UPDATE contacts SET
        email    = COALESCE(email, v_remove.email),
        company  = COALESCE(company, v_remove.company),
        role     = COALESCE(role, v_remove.role),
        phone    = COALESCE(phone, v_remove.phone),
        notes    = CASE WHEN notes IS NOT NULL AND v_remove.notes IS NOT NULL
                        THEN notes || E'\n---\n' || v_remove.notes
                        ELSE COALESCE(notes, v_remove.notes) END,
        tags     = ARRAY(SELECT DISTINCT unnest(tags || v_remove.tags)),
        first_seen = LEAST(first_seen, v_remove.first_seen),
        last_touch = GREATEST(last_touch, v_remove.last_touch),
        metadata = metadata || v_remove.metadata
    WHERE id = p_keep_id;

    DELETE FROM contacts WHERE id = p_remove_id;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;


-- Get contacts recently touched
CREATE FUNCTION recent_contacts(p_limit INT DEFAULT 20)
RETURNS SETOF contacts AS $$
    SELECT * FROM contacts ORDER BY last_touch DESC LIMIT p_limit;
$$ LANGUAGE sql STABLE;
