-- Keep reinforcement within the documented memory-strength range and repair
-- rows inflated by the former multiplicative-on-every-access trigger.
CREATE OR REPLACE FUNCTION update_memory_importance()
RETURNS TRIGGER AS $$
BEGIN
    NEW.importance = LEAST(
        1.0,
        GREATEST(0.0, NEW.importance * (1.0 + (LN(NEW.access_count + 1) * 0.1)))
    );
    NEW.last_accessed = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

UPDATE memories
SET importance = LEAST(1.0, GREATEST(0.0, importance))
WHERE importance < 0.0 OR importance > 1.0;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'memories'::regclass
          AND conname = 'memories_importance_range'
    ) THEN
        ALTER TABLE memories
            ADD CONSTRAINT memories_importance_range
            CHECK (importance BETWEEN 0 AND 1);
    END IF;
END;
$$;
