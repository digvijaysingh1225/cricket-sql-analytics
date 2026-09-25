-- Query 2: Leading run-scorer in each IPL season.
-- Uses RANK() OVER (PARTITION BY season ...) so the ranking resets for
-- every season independently, instead of ranking across all seasons at once.

WITH season_runs AS (
    SELECT
        m.season,
        d.batter_id,
        SUM(d.runs_batter) AS runs
    FROM deliveries d
    JOIN matches m ON m.match_id = d.match_id
    WHERE m.competition = 'Indian Premier League'
    GROUP BY m.season, d.batter_id
),
ranked AS (
    SELECT
        season,
        batter_id,
        runs,
        RANK() OVER (PARTITION BY season ORDER BY runs DESC) AS season_rank
    FROM season_runs
)
SELECT
    r.season,
    p.player_name,
    r.runs
FROM ranked r
JOIN players p ON p.player_id = r.batter_id
WHERE r.season_rank = 1
ORDER BY r.season;
