-- Query 3: Season-over-season change in each team's run rate.
-- LAG() looks at the PREVIOUS row in an ordered sequence -- here, each
-- team's own previous season -- which is what makes a "change from last
-- time" calculation possible without a self-join.
--
-- Run rate = runs per over = total runs / (legal balls / 6). "Legal balls"
-- excludes wides and no-balls, which is why the schema's ball_no column
-- (built during the load script) only increments on legal deliveries.
--
-- Known caveat: teams with very few matches in a season (e.g. Associate
-- nations) can show wildly swinging run rates purely from small sample
-- size -- not a data error, just low N. Worth checking match counts
-- before treating an extreme swing as meaningful.

WITH team_season_stats AS (
    SELECT
        m.season,
        pm.team_id,
        SUM(d.runs_batter + d.runs_extras) AS total_runs,
        COUNT(*) FILTER (
            WHERE d.extras_type IS DISTINCT FROM 'wides'
              AND d.extras_type IS DISTINCT FROM 'noballs'
        ) AS legal_balls
    FROM deliveries d
    JOIN matches m ON m.match_id = d.match_id
    JOIN player_match pm ON pm.match_id = d.match_id AND pm.player_id = d.batter_id
    GROUP BY m.season, pm.team_id
),
run_rates AS (
    SELECT
        season,
        team_id,
        total_runs,
        legal_balls,
        ROUND(total_runs::numeric / (legal_balls::numeric / 6), 2) AS run_rate
    FROM team_season_stats
    WHERE legal_balls > 0
)
SELECT
    t.team_name,
    r.season,
    r.run_rate,
    LAG(r.run_rate) OVER (PARTITION BY r.team_id ORDER BY r.season) AS prev_season_run_rate,
    r.run_rate - LAG(r.run_rate) OVER (PARTITION BY r.team_id ORDER BY r.season) AS change
FROM run_rates r
JOIN teams t ON t.team_id = r.team_id
ORDER BY t.team_name, r.season;
