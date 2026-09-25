-- Query 7: Batters whose death-overs (overs 16-20) strike rate exceeds
-- their own career strike rate by more than 2 standard deviations.
-- A CTE chain: each step answers one sub-question, building toward the
-- final filter, instead of one large nested query.
--
-- Steps: (1) career strike rate per batter, (2) death-overs strike rate
-- per batter, (3) the difference between them, (4) the population's mean
-- and stddev of that difference, (5) filter to batters whose own
-- difference clears mean + 2*stddev.
--
-- over_no is 0-indexed in this schema, so overs 16-20 = over_no 15-19.
-- Strike rate = runs / legal balls faced * 100. "Legal balls faced"
-- excludes wides (a wide doesn't count as a ball faced by the batter)
-- but DOES include no-balls/byes/leg-byes, since the batter still faced
-- that delivery -- a different definition of "legal" than the bowling
-- side's economy-rate calculation elsewhere in this project.
--
-- career_balls >= 60 and death_balls >= 30 are minimum sample-size
-- floors -- without them, a batter with a handful of career balls and
-- one lucky six would show an absurd, meaningless strike-rate jump.
--
-- STDDEV_SAMP is used explicitly rather than the bare STDDEV() alias,
-- since STDDEV() silently means the SAMPLE standard deviation in
-- Postgres, not population -- worth being explicit about which was
-- intended rather than relying on an alias whose meaning isn't obvious
-- from the name.

WITH career_stats AS (
    SELECT
        batter_id,
        SUM(runs_batter) AS career_runs,
        COUNT(*) FILTER (WHERE extras_type IS DISTINCT FROM 'wides') AS career_balls
    FROM deliveries
    GROUP BY batter_id
),
death_overs_stats AS (
    SELECT
        batter_id,
        SUM(runs_batter) AS death_runs,
        COUNT(*) FILTER (WHERE extras_type IS DISTINCT FROM 'wides') AS death_balls
    FROM deliveries
    WHERE over_no BETWEEN 15 AND 19
    GROUP BY batter_id
),
strike_rates AS (
    SELECT
        c.batter_id,
        ROUND((c.career_runs::numeric / c.career_balls) * 100, 2) AS career_sr,
        ROUND((d.death_runs::numeric / d.death_balls) * 100, 2) AS death_sr,
        ROUND((d.death_runs::numeric / d.death_balls) * 100, 2)
            - ROUND((c.career_runs::numeric / c.career_balls) * 100, 2) AS sr_diff
    FROM career_stats c
    JOIN death_overs_stats d ON d.batter_id = c.batter_id
    WHERE c.career_balls >= 60 AND d.death_balls >= 30
),
population AS (
    SELECT AVG(sr_diff) AS mean_diff, STDDEV_SAMP(sr_diff) AS stddev_diff
    FROM strike_rates
)
SELECT
    p_name.player_name,
    sr.career_sr,
    sr.death_sr,
    sr.sr_diff
FROM strike_rates sr
JOIN players p_name ON p_name.player_id = sr.batter_id
CROSS JOIN population pop
WHERE sr.sr_diff > pop.mean_diff + 2 * pop.stddev_diff
ORDER BY sr.sr_diff DESC;
