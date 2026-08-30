-- Relationship injuries are a first-class source-link role.
SET search_path = public, ag_catalog, "$user";

ALTER TABLE memory_source_units DROP CONSTRAINT IF EXISTS memory_source_units_role_check;
ALTER TABLE memory_source_units ADD CONSTRAINT memory_source_units_role_check
    CHECK (role IN ('source','direct_promotion','merge_addition','extraction','corroboration','relationship_injury'));
