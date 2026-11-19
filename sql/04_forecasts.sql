-- =========================================================
-- 04_forecasts.sql
-- 4 simple ways to forecast next week, + the table I use to score them
-- =========================================================

-- 4 forecasts for every family and week
-- F1 = last week, F2 = same week last year, F3 = avg of last 4 weeks,
-- F4 = last year's week adjusted for how the recent weeks are trending
CREATE OR REPLACE TABLE forecasts AS
WITH base AS (
    SELECT family, week_start, units,
        -- F1: last week
        LAG(units, 1)  OVER w AS f1_naive,
        -- F2: same week last year
        LAG(units, 52) OVER w AS f2_seasonal,
        -- F3: last 4 weeks avg (stops at 1 PRECEDING so it doesn't include this week)
        AVG(units) OVER (PARTITION BY family ORDER BY week_start
                         ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS f3_ma4,
        -- same 4 weeks but a year ago, used to get the growth for F4
        AVG(units) OVER (PARTITION BY family ORDER BY week_start
                         ROWS BETWEEN 56 PRECEDING AND 53 PRECEDING) AS ma4_last_year
    FROM weekly_family
    WINDOW w AS (PARTITION BY family ORDER BY week_start)
)
SELECT *,
    -- F4: last year x (recent 4 weeks / same 4 weeks last year)
    -- NULLIF so it doesn't blow up if last year's avg is 0
    f2_seasonal * f3_ma4 / NULLIF(ma4_last_year, 0) AS f4_trend_seasonal
FROM base;
-- Made sure none of these peek at the week they're predicting. F1/F2 just look
-- back 1 or 52 rows, F3 stops the week before, F4 is built from those.
-- Quick proof: the F1 and F3 forecast for 2015-06-08 = the actual from 2015-06-01.
-- Also LAG counts rows not dates, so LAG 52 only means "last year" because every
-- family has all 115 weeks with no gaps (I checked that in 02_clean.sql).

-- look at the last 10 weeks for BEVERAGES
SELECT week_start, units,
       ROUND(f1_naive)          AS f1,
       ROUND(f2_seasonal)       AS f2,
       ROUND(f3_ma4)            AS f3,
       ROUND(f4_trend_seasonal) AS f4
FROM forecasts
WHERE family = 'BEVERAGES'
ORDER BY week_start DESC
LIMIT 10;
-- F2 is like 20% too low here because demand grew from 2016 to 2017 and it just
-- copies last year. F4 fixes that and lands way closer.

-- first few weeks, to see what's empty
SELECT week_start, units, f1_naive, f2_seasonal, f3_ma4, f4_trend_seasonal
FROM forecasts
WHERE family = 'BEVERAGES'
ORDER BY week_start
LIMIT 5;
-- F2 and F4 are empty for the first year since there's no "last year" yet.
-- F3 averages less than 4 weeks at the very start. Not a problem since I only
-- score the last 52 weeks anyway.

-- pulled this into Excel to double check the math by hand
SELECT week_start, units
FROM weekly_family
WHERE family = 'BEVERAGES'
ORDER BY week_start;
-- Redid all 4 forecasts for BEVERAGES (week of 2017-08-07) with Excel formulas in
-- excel/forecast_spot_check.xlsx. All 4 matched, so I trust the rest.

-- scoring table: last 52 weeks only (2016-08-15 to 2017-08-07) so every method
-- gets judged on the same weeks. One row per family + week + method (long format,
-- way easier to use in Excel and Power BI than 4 separate columns)
CREATE OR REPLACE TABLE forecast_long AS
WITH eval AS (
    SELECT family, week_start, units,
           f1_naive, f2_seasonal, f3_ma4, f4_trend_seasonal
    FROM forecasts
    WHERE week_start >= DATE '2016-08-15'
),
long AS (
    UNPIVOT eval
    ON f1_naive, f2_seasonal, f3_ma4, f4_trend_seasonal
    INTO NAME method VALUE forecast
)
SELECT family,
       week_start,
       units AS actual,
       CASE method
           WHEN 'f1_naive'          THEN 'F1 Naive'
           WHEN 'f2_seasonal'       THEN 'F2 Seasonal naive'
           WHEN 'f3_ma4'            THEN 'F3 Moving average'
           WHEN 'f4_trend_seasonal' THEN 'F4 Trend-adjusted seasonal'
       END                   AS method,
       forecast,
       forecast - units      AS error,      -- + = too high, - = too low
       ABS(forecast - units) AS abs_error
FROM long;

-- check: each method should have 32 families x 52 weeks = 1,664 rows
SELECT method,
       COUNT(*)                   AS rows,
       COUNT(DISTINCT family)     AS families,
       COUNT(DISTINCT week_start) AS weeks,
       MIN(week_start)            AS first_week,
       MAX(week_start)            AS last_week
FROM forecast_long
GROUP BY method
ORDER BY method;
-- All 4 have 1,664, so no missing forecasts.

-- one thing to keep in mind: 52 weeks back isn't exactly a year, it's off by a day
-- or two each year. Fine for most weeks but holidays that move around can end up in
-- the wrong week (this came back to bite me with Carnaval in 05_accuracy.sql).