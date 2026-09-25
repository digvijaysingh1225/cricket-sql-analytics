-- Query 6: Runs by season x venue x innings, with subtotals -- GROUPING SETS.
-- Computes multiple aggregation levels in ONE query: full (season, venue,
-- innings) detail, subtotals per (season, venue), and a grand total --
-- the same mechanism behind a pivot table's subtotal rows.
--
-- On the subtotal/grand-total rows, the rolled-up dimensions come back
-- NULL -- that NULL means "this dimension was aggregated away", not
-- "unknown data". Easy to misread if you're not expecting it.
--
-- Filtered to one season below since the full unfiltered result across
-- every season and 600+ venues is enormous -- change or remove the
-- WHERE clause as needed.

SELECT
    m.season,
    v.venue_name,
    d.innings_no,
    SUM(d.runs_batter + d.runs_extras) AS total_runs
FROM deliveries d
JOIN matches m ON m.match_id = d.match_id
JOIN venues v ON v.venue_id = m.venue_id
WHERE m.season = '2023'  -- change or remove as needed
GROUP BY GROUPING SETS (
    (m.season, v.venue_name, d.innings_no),  -- full detail
    (m.season, v.venue_name),                -- subtotal per season+venue
    ()                                         -- grand total
)
ORDER BY v.venue_name NULLS LAST, d.innings_no NULLS LAST;
