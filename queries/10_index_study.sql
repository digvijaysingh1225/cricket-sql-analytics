-- Query 10: Index study -- all deliveries by one batter in death overs
-- (over 16-20), measured with EXPLAIN ANALYZE before and after adding a
-- composite index on (batter_id, over_no).
--
-- ============================================================
-- RESULT (measured on the full ~5.05M-row deliveries table, batter =
-- V Kohli, player_id = 135):
--
--   BEFORE (single-column index on batter_id only):
--     Execution Time: 433.597 ms
--     Plan: Bitmap Heap Scan, Recheck Cond: (batter_id = 135),
--           Filter: over_no BETWEEN 15 AND 19 (applied AFTER the index
--           narrowed to 42,876 rows -- 38,239 of those then discarded
--           by the filter step). Heap Blocks: exact=1678.
--
--   AFTER (composite index on (batter_id, over_no)):
--     Execution Time: 3.877 ms
--     Plan: Bitmap Heap Scan, Recheck Cond: (batter_id = 135 AND
--           over_no BETWEEN 15 AND 19) -- BOTH conditions are now part
--           of the index condition itself, so Postgres goes straight to
--           the 4,637 actually-matching rows with no separate filter
--           step. Heap Blocks: exact=482.
--
--   ~112x speedup (433.6ms -> 3.9ms).
--
--   The mechanism: this is NOT "no index vs index" -- the schema already
--   ships a single-column index on batter_id as a baseline. The real
--   improvement is eliminating a POST-INDEX FILTERING STEP: the
--   single-column index still had to check every one of the 42,876
--   batter-matching rows against the over_no condition one by one. The
--   composite index encodes both conditions directly, so no filtering
--   step is needed at all.
-- ============================================================

-- Step 1: find the player_id for the batter you want to test with.
SELECT player_id FROM players WHERE player_name = 'V Kohli';

-- Step 2: BASELINE -- run this BEFORE creating the composite index.
-- Replace <ID> with the player_id from Step 1.
EXPLAIN ANALYZE
SELECT * FROM deliveries
WHERE batter_id = <ID> AND over_no BETWEEN 15 AND 19;

-- Step 3: create the composite index (this is the index the schema
-- deliberately withheld until this study, per schema.sql's comments).
CREATE INDEX idx_deliveries_batter_over ON deliveries(batter_id, over_no);

-- Step 4: re-run the EXACT SAME query and compare the plan + timing.
EXPLAIN ANALYZE
SELECT * FROM deliveries
WHERE batter_id = <ID> AND over_no BETWEEN 15 AND 19;
