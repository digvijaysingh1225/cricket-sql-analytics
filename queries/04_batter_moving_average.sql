-- Query 4: A batter's 10-innings moving average.
-- ROWS BETWEEN 9 PRECEDING AND CURRENT ROW defines a true ROLLING frame
-- (this row plus the 9 before it) rather than an expanding average from
-- the start of their career. Early innings (fewer than 10 prior rows
-- exist) simply average over however many rows are actually in the frame.
--
-- Change the player_name filter below to any batter of interest.

WITH innings_runs AS (
    SELECT
        d.batter_id,
        d.match_id,
        d.innings_no,
        SUM(d.runs_batter) AS runs_in_innings,
        MIN(m.match_date) AS match_date
    FROM deliveries d
    JOIN matches m ON m.match_id = d.match_id
    GROUP BY d.batter_id, d.match_id, d.innings_no
)
SELECT
    p.player_name,
    ir.match_date,
    ir.runs_in_innings,
    ROUND(AVG(ir.runs_in_innings) OVER (
        PARTITION BY ir.batter_id
        ORDER BY ir.match_date
        ROWS BETWEEN 9 PRECEDING AND CURRENT ROW
    ), 2) AS moving_avg_10_innings
FROM innings_runs ir
JOIN players p ON p.player_id = ir.batter_id
WHERE p.player_name = 'V Kohli'  -- change to any batter
ORDER BY ir.match_date;
