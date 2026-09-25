-- Query 1: Top 15 batters by career runs, with their most recent team
-- and career matches played. Joins deliveries -> players -> player_match -> teams.
--
-- Design note: a batter isn't tied to one team (IPL players change franchises
-- across seasons), so "team name" has no single obviously-correct value per
-- player. This uses DISTINCT ON to pick each player's MOST RECENT team
-- (by latest match_date) -- a Postgres-specific idiom for "latest row per
-- group" that's worth knowing outside this project too.

WITH batter_runs AS (
    SELECT batter_id, SUM(runs_batter) AS career_runs
    FROM deliveries
    GROUP BY batter_id
),
matches_played AS (
    SELECT player_id, COUNT(DISTINCT match_id) AS matches_played
    FROM player_match
    GROUP BY player_id
),
latest_team AS (
    SELECT DISTINCT ON (pm.player_id) pm.player_id, t.team_name
    FROM player_match pm
    JOIN matches m ON m.match_id = pm.match_id
    JOIN teams t ON t.team_id = pm.team_id
    ORDER BY pm.player_id, m.match_date DESC
)
SELECT
    p.player_name,
    lt.team_name,
    mp.matches_played,
    br.career_runs
FROM batter_runs br
JOIN players p ON p.player_id = br.batter_id
JOIN matches_played mp ON mp.player_id = br.batter_id
JOIN latest_team lt ON lt.player_id = br.batter_id
ORDER BY br.career_runs DESC
LIMIT 15;
