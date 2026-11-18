-- =========================================================
-- 04_forecasts.sql
-- Four simple one-week-ahead forecasts per family, and the evaluation table
-- =========================================================

-- Four forecasts for every family and week.
-- Each one only uses weeks BEFORE the week it predicts.
CREATE OR REPLACE TABLE forecasts AS
WITH base AS (
    SELECT family, week_start, units,
        -- F1: last week's units
        LAG(units, 1)  OVER w AS f1_naive,
        -- F2: the same week last year (52 weeks back)
        LAG(units, 52) OVER w AS f2_seasonal,
        -- F3: average of the last 4 weeks
        AVG(units) OVER (PARTITION BY family ORDER BY week_start
                         ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS f3_ma4,
        -- the same 4 weeks, but last year (used to measure growth for F4)
        AVG(units) OVER (PARTITION BY family ORDER BY week_start
                         ROWS BETWEEN 56 PRECEDING AND 53 PRECEDING) AS ma4_last_year
    FROM weekly_family
    WINDOW w AS (PARTITION BY family ORDER BY week_start)
)
SELECT *,
    -- F4: last year's same week, scaled by how much bigger the last 4 weeks are than a year ago
    f2_seasonal * f3_ma4 / NULLIF(ma4_last_year, 0) AS f4_trend_seasonal
FROM base;

-- No peeking: every forecast only uses weeks before the one it predicts.
-- F1 and F2 use LAG (1 and 52 rows back). F3's window stops at "1 PRECEDING",
-- so it never includes the current week. F4 is built from F2, F3 and last year's
-- weeks 53-56 back. Proof: the forecast for 2015-06-08 equals 2015-06-01's units.
-- LAG counts rows, not dates. It works here because every family has all
-- 115 weeks with no gaps (checked in 02_clean.sql).

-- Peek at the most recent weeks for one family
SELECT week_start, units,
       ROUND(f1_naive)          AS f1,
       ROUND(f2_seasonal)       AS f2,
       ROUND(f3_ma4)            AS f3,
       ROUND(f4_trend_seasonal) AS f4
FROM forecasts
WHERE family = 'BEVERAGES'
ORDER BY week_start DESC
LIMIT 10;
-- In recent weeks, F2 (last year) runs about 20% low because demand grew from 2016
-- to 2017. F4 scales last year up by recent growth and lands much closer.

-- Early weeks: which forecasts are empty, and why?
SELECT week_start, units, f1_naive, f2_seasonal, f3_ma4, f4_trend_seasonal
FROM forecasts
WHERE family = 'BEVERAGES'
ORDER BY week_start
LIMIT 5;
-- F2 and F4 are empty for about the first year because they need last year's data.
-- F3 averages fewer than 4 weeks at the very start. Only the last 52 weeks get scored.