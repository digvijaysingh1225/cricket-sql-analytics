-- Query 5: Median and p90 bowler economy rate per season.
-- PERCENTILE_CONT finds a percentile by interpolating between data points
-- (continuous), as opposed to PERCENTILE_DISC which picks an actual data
-- point -- PERCENTILE_CONT is the standard choice for "typical" and
-- "high-end" summaries of a numeric distribution like this one.
--
-- Economy rate is computed PER BOWLER PER MATCH first, then percentiles
-- are taken across that whole distribution within a season -- this
-- measures the spread of individual match performances, not one
-- pre-averaged number per bowler.
--
-- legal_balls >= 6 filters out bowlers who bowled less than a full over
-- in a match (rare, but happens with injuries/rain) -- without this, a
-- tiny sample (e.g. 1 run off 1 ball) produces a meaningless, wildly
-- distorted economy rate that shouldn't sit in the same distribution as
-- bowlers who completed real spells.

WITH bowler_match_stats AS (
    SELECT
        m.season,
        d.bowler_id,
        d.match_id,
        SUM(d.runs_batter + d.runs_extras) AS runs_conceded,
        COUNT(*) FILTER (
            WHERE d.extras_type IS DISTINCT FROM 'wides'
              AND d.extras_type IS DISTINCT FROM 'noballs'
        ) AS legal_balls
    FROM deliveries d
    JOIN matches m ON m.match_id = d.match_id
    GROUP BY m.season, d.bowler_id, d.match_id
),
economy_rates AS (
    SELECT
        season,
        bowler_id,
        runs_conceded::numeric / (legal_balls::numeric / 6) AS economy_rate
    FROM bowler_match_stats
    WHERE legal_balls >= 6
)
SELECT
    season,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY economy_rate)::numeric, 2) AS median_economy,
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY economy_rate)::numeric, 2) AS p90_economy
FROM economy_rates
GROUP BY season
ORDER BY season;
