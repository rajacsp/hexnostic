-- Humanizer pushdown (plans/db_pushdown.md 4.4): the AI-writing-pattern
-- table becomes data and detection/scoring becomes SQL. Patterns are POSIX
-- AREs converted from the Python originals: \b (Python word boundary) is \y
-- here (in ARE, \b means backspace), embedded (?i) becomes the 'i' flag, and
-- every pattern runs with 'n' (newline-sensitive) for parity with Python's
-- re.MULTILINE without DOTALL: ^ matches at line starts and . stays within a
-- line. Word characters are [[:alnum:]_] — equivalent to Python's \w for
-- English text.
SET search_path = public, ag_catalog, "$user";

CREATE TABLE IF NOT EXISTS ai_writing_patterns (
    name TEXT PRIMARY KEY,
    position INT NOT NULL,
    description TEXT NOT NULL,
    pattern TEXT NOT NULL,
    flags TEXT NOT NULL DEFAULT 'n',
    threshold INT NOT NULL DEFAULT 1,
    suggestion TEXT NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE ai_writing_patterns IS
    'AI-writing tells for humanize_detect(). pattern is a POSIX ARE run with the row flags (always include n; add i for case-insensitive). threshold = matches needed to flag.';

INSERT INTO ai_writing_patterns (name, position, description, pattern, flags, threshold, suggestion) VALUES
    ('em_dash_overuse', 1, 'Excessive em dash usage (—) where commas or periods suffice',
     $rx$—$rx$, 'n', 2,
     'Replace some em dashes with commas, periods, or parentheses'),
    ('formulaic_opener', 2, 'Generic opening phrases like ''In today''''s world'' or ''It''''s worth noting''',
     $rx$\y(in today'?s (?:world|landscape|era)|it'?s worth noting|it'?s important to|when it comes to|at the end of the day|in the realm of|in the world of)\y$rx$, 'in', 1,
     'Start with a specific claim or observation instead'),
    ('transition_crutch', 3, 'Overuse of transitional phrases (Moreover, Furthermore, Additionally)',
     $rx$^(moreover|furthermore|additionally|consequently|nevertheless|in conclusion|to summarize|all in all|in summary)[,:]?\s$rx$, 'in', 1,
     'Let ideas flow naturally or use simpler connectors'),
    ('hedge_stacking', 4, 'Multiple hedging phrases in one sentence',
     $rx$\y(it seems|perhaps|arguably|to some extent|in many ways|in a sense|one might argue|it could be said)\y$rx$, 'in', 2,
     'Commit to your assertion or remove unnecessary hedges'),
    ('adverb_inflation', 5, 'Overuse of intensifying adverbs (incredibly, fundamentally, significantly)',
     $rx$\y(incredibly|fundamentally|significantly|remarkably|profoundly|essentially|absolutely|literally|extremely)\y$rx$, 'in', 2,
     'Show impact through specifics rather than adverbs'),
    ('passive_voice', 6, 'Excessive passive constructions',
     $rx$\y(is|are|was|were|been|being)\s+(being\s+)?\w+ed\y$rx$, 'in', 3,
     'Use active voice where possible'),
    ('list_intro', 7, 'Formulaic list introductions (Here are X things, Let''s explore, Let''s dive)',
     $rx$(here are \d+|let'?s (?:explore|dive|look at|examine|break down|unpack)|without further ado)$rx$, 'in', 1,
     'Jump straight into the content'),
    ('metaphor_cliche', 8, 'Overused metaphors (tip of the iceberg, game-changer, paradigm shift)',
     $rx$\y(tip of the iceberg|game[ -]?changer|paradigm shift|double[ -]?edged sword|at the forefront|pave the way|shed light on|a brave new|stand at the crossroads)\y$rx$, 'in', 1,
     'Use fresh, specific language instead'),
    ('grandiose_framing', 9, 'Unnecessarily grand framing (revolutionary, transformative, groundbreaking)',
     $rx$\y(revolutionary|transformative|groundbreaking|game[ -]?changing|cutting[ -]?edge|state[ -]?of[ -]?the[ -]?art|world[ -]?class|next[ -]?generation|bleeding[ -]?edge)\y$rx$, 'in', 1,
     'Use precise descriptors instead of superlatives'),
    ('colon_listing', 10, 'Pattern of colon followed by enumerated list items',
     $rx$:\s*\n\s*\d+\.\s$rx$, 'n', 2,
     'Vary your structure; not every point needs a numbered list'),
    ('rhetorical_question', 11, 'Rhetorical questions used as transitions',
     $rx$^(but what|so what|but how|what does this|how can we|what if we|have you ever|but why)\y.*\?$rx$, 'in', 1,
     'State your point directly instead of asking then answering'),
    ('triple_structure', 12, 'Formulaic three-part structures (X, Y, and Z patterns)',
     $rx$\y\w+,\s+\w+,\s+and\s+\w+\y$rx$, 'in', 3,
     'Vary sentence structure; not everything needs three items'),
    ('conclusion_signal', 13, 'Obvious conclusion signaling phrases',
     $rx$\y(in conclusion|to wrap up|to sum up|all things considered|the bottom line|the takeaway|key takeaway|final thoughts)\y$rx$, 'in', 1,
     'End naturally without announcing the conclusion'),
    ('empathy_opener', 14, 'Performative empathy phrases',
     $rx$(i understand (?:that|your|how)|i appreciate (?:that|your)|that'?s a great (?:question|point)|great question|absolutely[!,]|of course[!,])$rx$, 'in', 1,
     'Address the substance directly'),
    ('filler_phrases', 15, 'Padding phrases that add no meaning',
     $rx$\y(it goes without saying|needless to say|as we all know|as everyone knows|the fact of the matter|at this point in time|for all intents and purposes)\y$rx$, 'in', 1,
     'Remove — these phrases carry no information'),
    ('bookend_structure', 16, 'Mirroring intro and conclusion too closely',
     $rx$(as (?:we'?ve|I'?ve) (?:seen|discussed|explored|examined))$rx$, 'in', 1,
     'End with new insight rather than restating the introduction'),
    ('exclamation_enthusiasm', 17, 'Excessive exclamation marks suggesting forced enthusiasm',
     $rx$!$rx$, 'n', 3,
     'Let content convey enthusiasm rather than punctuation'),
    ('delve', 18, 'The word ''delve'' (strongly associated with AI writing)',
     $rx$\ydelve\y$rx$, 'in', 1,
     'Use ''explore'', ''examine'', ''look at'', or ''investigate'' instead'),
    ('landscape_tapestry', 19, 'Abstract nouns used as filler (landscape, tapestry, realm, arena)',
     $rx$\y(the (?:landscape|tapestry|fabric|realm|arena|ecosystem|sphere) of)\y$rx$, 'in', 1,
     'Be specific about what you''re referring to'),
    ('both_and', 20, 'Overuse of ''both X and Y'' parallel construction',
     $rx$\yboth\s+\w+\s+and\s+\w+\y$rx$, 'in', 2,
     'Vary sentence structure'),
    ('certainly_surely', 21, 'Filler certainty words that weaken rather than strengthen',
     $rx$\y(certainly|surely|undoubtedly|undeniably|unquestionably)\y$rx$, 'in', 2,
     'State facts directly without asserting certainty'),
    ('navigate_complexity', 22, '''Navigate'' used metaphorically (navigate the complexities)',
     $rx$\ynavigate\s+(the\s+)?(complex|intricac|challeng|landscape|world)$rx$, 'in', 1,
     'Use ''handle'', ''manage'', or ''deal with'' instead'),
    ('leverage_utilize', 23, 'Corporate-speak verbs (leverage, utilize, optimize, synergize)',
     $rx$\y(leverage|utilize|synergize|incentivize|operationalize|actualize)\y$rx$, 'in', 1,
     'Use ''use'', ''make the most of'', or a specific verb'),
    ('not_just_but_also', 24, 'The ''not just X but also Y'' construction',
     $rx$\ynot (?:just|only|merely)\y.*\ybut (?:also|additionally)\y$rx$, 'in', 2,
     'Simplify: state both points without the construction')
ON CONFLICT (name) DO NOTHING;

-- Detection + scoring: parity port of detect_ai_patterns/compute_ai_score.
CREATE OR REPLACE FUNCTION humanize_detect(
    p_text TEXT
) RETURNS JSONB AS $$
DECLARE
    detections JSONB := '[]'::jsonb;
    row_rec ai_writing_patterns%ROWTYPE;
    cnt INT;
    examples JSONB;
    n INT;
    match_start INT;
    match_end INT;
    total_hits INT := 0;
    word_count INT;
    density FLOAT;
    diversity FLOAT;
    score FLOAT := 0.0;
BEGIN
    IF NULLIF(trim(E' \t\n\r\f' FROM COALESCE(p_text, '')), '') IS NULL THEN
        RETURN jsonb_build_object(
            'ai_score', 0.0, 'pattern_count', 0, 'total_hits', 0,
            'word_count', 0, 'detections', '[]'::jsonb);
    END IF;

    FOR row_rec IN SELECT * FROM ai_writing_patterns WHERE enabled ORDER BY position LOOP
        cnt := regexp_count(p_text, row_rec.pattern, 1, row_rec.flags);
        IF cnt >= row_rec.threshold THEN
            examples := '[]'::jsonb;
            n := 1;
            WHILE n <= LEAST(cnt, 5) LOOP
                match_start := regexp_instr(p_text, row_rec.pattern, 1, n, 0, row_rec.flags);
                match_end := regexp_instr(p_text, row_rec.pattern, 1, n, 1, row_rec.flags);
                EXIT WHEN match_start = 0;
                examples := examples || to_jsonb(trim(E' \t\n\r\f' FROM substring(
                    p_text
                    FROM GREATEST(1, match_start - 20)
                    FOR (match_end - 1 + 20) - GREATEST(1, match_start - 20) + 1)));
                n := n + 1;
            END LOOP;
            detections := detections || jsonb_build_object(
                'pattern', row_rec.name,
                'description', row_rec.description,
                'count', cnt,
                'threshold', row_rec.threshold,
                'suggestion', row_rec.suggestion,
                'examples', examples);
            total_hits := total_hits + cnt;
        END IF;
    END LOOP;

    word_count := COALESCE(array_length(
        regexp_split_to_array(trim(E' \t\n\r\f' FROM p_text), '\s+'), 1), 0);
    IF word_count >= 20 THEN
        density := (total_hits::float / word_count) * 100;
        diversity := LEAST(jsonb_array_length(detections)::float / 10, 1.0);
        score := round(LEAST(density * 0.3 + diversity * 0.7, 1.0)::numeric, 2);
    END IF;

    RETURN jsonb_build_object(
        'ai_score', score,
        'pattern_count', jsonb_array_length(detections),
        'total_hits', total_hits,
        'word_count', word_count,
        'detections', detections);
END;
$$ LANGUAGE plpgsql STABLE;
