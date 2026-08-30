-- Council personas pushdown (plans/db_pushdown.md 4.3): the five analytical
-- personas become prompt_modules rows (council.persona.<key>, name in
-- metadata), and get_council_personas() serves them in the shape the council
-- tools consume. The Python COUNCIL_PERSONAS dict is deleted.
SET search_path = public, ag_catalog, "$user";

SELECT upsert_prompt_module(
    'council.persona.growth_strategist',
    'You are a growth strategist. Focus on market expansion, user acquisition, revenue growth opportunities, and scalability. Be optimistic but data-driven.',
    'Council persona: Growth Strategist',
    NULL,
    '{"name": "Growth Strategist"}'::jsonb
);
SELECT upsert_prompt_module(
    'council.persona.revenue_guardian',
    'You are a revenue guardian. Focus on profitability, unit economics, pricing strategy, and financial sustainability. Be conservative and metrics-focused.',
    'Council persona: Revenue Guardian',
    NULL,
    '{"name": "Revenue Guardian"}'::jsonb
);
SELECT upsert_prompt_module(
    'council.persona.skeptical_operator',
    'You are a skeptical operator. Challenge assumptions, identify risks, point out what could go wrong, and ensure operational feasibility. Play devil''s advocate.',
    'Council persona: Skeptical Operator',
    NULL,
    '{"name": "Skeptical Operator"}'::jsonb
);
SELECT upsert_prompt_module(
    'council.persona.creative_innovator',
    'You are a creative innovator. Think outside the box, propose unconventional solutions, and explore novel approaches. Focus on differentiation and user delight.',
    'Council persona: Creative Innovator',
    NULL,
    '{"name": "Creative Innovator"}'::jsonb
);
SELECT upsert_prompt_module(
    'council.persona.customer_advocate',
    'You are a customer advocate. Represent the user''s perspective, focus on user experience, pain points, satisfaction, and long-term loyalty.',
    'Council persona: Customer Advocate',
    NULL,
    '{"name": "Customer Advocate"}'::jsonb
);

CREATE OR REPLACE FUNCTION get_council_personas()
RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_object_agg(
        replace(key, 'council.persona.', ''),
        jsonb_build_object(
            'name', COALESCE(metadata->>'name', replace(key, 'council.persona.', '')),
            'system_prompt', content
        )
    ), '{}'::jsonb)
    FROM prompt_modules
    WHERE key LIKE 'council.persona.%';
$$ LANGUAGE sql STABLE;
