-- Query 8: Players who bowled in a season but took no wicket.
-- NOT EXISTS is the anti-join pattern: rows in the outer query that have
-- NO matching row in the inner subquery. Preferred over a
-- LEFT JOIN ... WHERE x IS NULL here since it states the "absence" logic
-- directly rather than relying on a NULL check as a side effect.
--
-- Important exclusion: wicket_type NOT IN ('run out', 'retired hurt',
-- 'retired out', 'obstructing the field') -- these dismissal types still
-- populate wicket_type on a delivery, but are NOT credited to the
-- bowler. Without this exclusion, a bowler who only ever featured in a
-- run-out at the non-striker's end would be wrongly counted as having
-- taken a wicket, and incorrectly excluded from this list.

SELECT DISTINCT
    m.season,
    p.player_name
FROM deliveries d
JOIN matches m ON m.match_id = d.match_id
JOIN players p ON p.player_id = d.bowler_id
WHERE NOT EXISTS (
    SELECT 1
    FROM deliveries d2
    JOIN matches m2 ON m2.match_id = d2.match_id
    WHERE d2.bowler_id = d.bowler_id
      AND m2.season = m.season
      AND d2.wicket_type IS NOT NULL
      AND d2.wicket_type NOT IN ('run out', 'retired hurt', 'retired out', 'obstructing the field')
)
ORDER BY m.season, p.player_name;
