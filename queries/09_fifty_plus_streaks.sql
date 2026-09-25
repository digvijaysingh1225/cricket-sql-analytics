-- Query 9: Longest streak of consecutive matches with a 50+ score, per batter.
-- Classic gaps-and-islands technique:
--   1. rn_all      = row number over ALL of a batter's matches, in order
--   2. rn_qual     = row number over ONLY their qualifying (50+) matches
--   3. (rn_all - rn_qual) is CONSTANT for consecutive qualifying rows,
--      and jumps whenever a non-qualifying match breaks the sequence --
--      that constant becomes the "island" grouping key.
-- Grouping by (batter_id, that difference) and counting rows per group
-- gives the length of each streak; taking the max per batter (with a
-- tie-break on earliest start date) gives the longest one.
--
-- Verified against a hand-designed test sequence (60,70,80,90,10,20,55)
-- during development -- correctly found the streak of 4 (the first four
-- scores), not the trailing single 55, and did not merge across the
-- 10/20 break.
--
-- Known simplification: batter_match_scores sums a batter's runs across
-- ALL innings within a match. For single-innings formats (IPL/ODI/T20I)
-- this is a non-issue. In a Test where a batter bats twice, this treats
-- their two separate innings scores as one combined "match score" --
-- e.g. 30 + 25 = 55 would count as a "50+" match even though neither
-- individual innings reached 50. This is unlikely to change who leads
-- this list (T20/ODI specialists with single innings per match tend to
-- dominate long streaks), but it's a real edge case worth naming.

WITH batter_match_scores AS (
    SELECT d.batter_id, d.match_id, m.match_date, SUM(d.runs_batter) AS runs
    FROM deliveries d
    JOIN matches m ON m.match_id = d.match_id
    GROUP BY d.batter_id, d.match_id, m.match_date
),
numbered AS (
    SELECT
        batter_id, match_id, match_date, runs,
        ROW_NUMBER() OVER (PARTITION BY batter_id ORDER BY match_date) AS rn_all
    FROM batter_match_scores
),
qualifying AS (
    SELECT
        batter_id, match_date, rn_all,
        ROW_NUMBER() OVER (PARTITION BY batter_id ORDER BY match_date) AS rn_qual
    FROM numbered
    WHERE runs >= 50
),
islands AS (
    SELECT
        batter_id,
        (rn_all - rn_qual) AS grp,
        COUNT(*) AS streak_len,
        MIN(match_date) AS streak_start,
        MAX(match_date) AS streak_end
    FROM qualifying
    GROUP BY batter_id, grp
),
ranked_islands AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY batter_id ORDER BY streak_len DESC, streak_start) AS rnk
    FROM islands
)
SELECT p.player_name, ri.streak_len AS longest_streak, ri.streak_start, ri.streak_end
FROM ranked_islands ri
JOIN players p ON p.player_id = ri.batter_id
WHERE ri.rnk = 1
ORDER BY ri.streak_len DESC
LIMIT 20;
