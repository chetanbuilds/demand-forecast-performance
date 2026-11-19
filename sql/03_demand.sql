
-- =========================================================
-- 03_demand.sql
-- Getting to know the demand before forecasting it:
-- which families matter, trend, seasonality, how predictable, events
-- =========================================================

-- which families make up most of the demand? (ABC)
-- A = top 80% of units, B = next 15%, C = the rest
CREATE OR REPLACE TABLE family_abc AS
WITH totals AS (
    -- total units per family
    SELECT family, SUM(units) AS total_units
    FROM weekly_family
    GROUP BY family
),
ranked AS (
    -- each family's share + running total from biggest to smallest
    SELECT *,
        total_units / SUM(total_units) OVER () AS share,
        SUM(total_units) OVER (ORDER BY total_units DESC
                               ROWS UNBOUNDED PRECEDING)
            / SUM(total_units) OVER ()       AS cum_share
    FROM totals
)
SELECT *,
    RANK() OVER (ORDER BY total_units DESC) AS volume_rank,
    CASE WHEN cum_share <= 0.80 THEN 'A'
         WHEN cum_share <= 0.95 THEN 'B'
         ELSE 'C' END                       AS abc_class
FROM ranked;

-- the ranking
SELECT volume_rank, family, abc_class,
       ROUND(total_units)        AS total_units,
       ROUND(share * 100, 1)     AS share_pct,
       ROUND(cum_share * 100, 1) AS cum_share_pct
FROM family_abc
ORDER BY volume_rank;

-- how many in each class
SELECT abc_class, COUNT(*) AS families
FROM family_abc
GROUP BY abc_class
ORDER BY abc_class;
-- Only 4 families (GROCERY I, BEVERAGES, PRODUCE, CLEANING) are 74.5% of all demand.
-- DAIRY is right on the line: with it the total hits 80.3%, so it just misses A and lands in B.
-- GROCERY I + BEVERAGES alone are about half. The 21 smallest families are only ~5% together.
-- So a miss on GROCERY I matters way more than a miss on MAGAZINES.

-- is demand growing? (avg units per week so years with fewer weeks are still comparable)
SELECT YEAR(week_start)           AS year,
       COUNT(DISTINCT week_start) AS weeks,
       ROUND(SUM(units) / COUNT(DISTINCT week_start)) AS avg_weekly_units
FROM weekly_family
GROUP BY YEAR(week_start)
ORDER BY year;
-- careful with this one: 2015 is only Jun-Dec and 2017 is only Jan-Aug,
-- so the monthly comparison below is more fair.

-- monthly trend + growth vs same month last year
WITH monthly AS (
    SELECT DATE_TRUNC('month', week_start)          AS month,
           SUM(units) / COUNT(DISTINCT week_start)  AS avg_weekly_units
    FROM weekly_family
    GROUP BY 1
)
SELECT CAST(month AS DATE)      AS month,
       ROUND(avg_weekly_units)  AS avg_weekly_units,
       ROUND((avg_weekly_units
              / LAG(avg_weekly_units, 12) OVER (ORDER BY month) - 1) * 100, 1)
                                AS yoy_growth_pct
FROM monthly
ORDER BY month;
-- Pretty flat in the 2nd half of 2016 (0-7% over 2015), then it picks up in 2017
-- (about 8-18% over 2016). December is the busiest month both years.
-- April 2017 shows a small drop but that's only because April 2016 was boosted by the earthquake.
-- (When I first ran this starting in Jan 2015, demand "jumped" 33% from May to June.
-- That turned out to be a recording gap, not real demand. CHECK 7 in 02_clean.sql
-- is how I found it, and it's why the weekly table starts Jun 1, 2015 now.)

-- seasonality: how busy is each month vs an average month? (100 = normal)
-- only using 2016 since it's the one full year, so growth doesn't mess up the pattern
CREATE OR REPLACE TABLE seasonality_2016 AS
WITH monthly AS (
    -- avg week in each month, per family
    SELECT family,
           MONTH(week_start) AS month_num,
           AVG(units)        AS avg_weekly_units
    FROM weekly_family
    WHERE YEAR(week_start) = 2016
    GROUP BY family, MONTH(week_start)
),
yearly AS (
    -- avg week across all of 2016, per family
    SELECT family, AVG(units) AS year_avg
    FROM weekly_family
    WHERE YEAR(week_start) = 2016
    GROUP BY family
)
SELECT m.family,
       m.month_num,
       m.avg_weekly_units,
       ROUND(m.avg_weekly_units / y.year_avg * 100) AS seasonal_index
FROM monthly m
JOIN yearly y USING (family);

-- top 5 families, one column per month
SELECT s.family,
       MAX(seasonal_index) FILTER (WHERE month_num = 1)  AS jan,
       MAX(seasonal_index) FILTER (WHERE month_num = 2)  AS feb,
       MAX(seasonal_index) FILTER (WHERE month_num = 3)  AS mar,
       MAX(seasonal_index) FILTER (WHERE month_num = 4)  AS apr,
       MAX(seasonal_index) FILTER (WHERE month_num = 5)  AS may,
       MAX(seasonal_index) FILTER (WHERE month_num = 6)  AS jun,
       MAX(seasonal_index) FILTER (WHERE month_num = 7)  AS jul,
       MAX(seasonal_index) FILTER (WHERE month_num = 8)  AS aug,
       MAX(seasonal_index) FILTER (WHERE month_num = 9)  AS sep,
       MAX(seasonal_index) FILTER (WHERE month_num = 10) AS oct,
       MAX(seasonal_index) FILTER (WHERE month_num = 11) AS nov,
       MAX(seasonal_index) FILTER (WHERE month_num = 12) AS dec
FROM seasonality_2016 s
JOIN family_abc a USING (family)
WHERE a.volume_rank <= 5
GROUP BY s.family
ORDER BY s.family;
-- The big families don't swing that much (GROCERY I 92-124, DAIRY only 95-107).
-- Weird thing: GROCERY I and BEVERAGES both spike in April. That's not normal for groceries.
-- It's the 2016 earthquake (people stocking up), not real seasonality.
-- Problem: any forecast that copies last year will probably overshoot April 2017. (It did, see 05_accuracy.sql.)

-- peak month, slowest month, and how big the swing is for every family
SELECT family,
       ARG_MAX(month_num, seasonal_index) AS peak_month,
       MAX(seasonal_index)                AS peak_index,
       ARG_MIN(month_num, seasonal_index) AS low_month,
       MIN(seasonal_index)                AS low_index,
       MAX(seasonal_index) - MIN(seasonal_index) AS swing
FROM seasonality_2016
GROUP BY family
ORDER BY swing DESC;
-- December is the peak for most families. Biggest swings are all small families:
-- FROZEN FOODS sells ~4x a normal month in December, SCHOOL AND OFFICE SUPPLIES ~3x in August
-- (back to school).

-- how predictable is each family? CV = std dev / avg of weekly units (lower = steadier)
-- X under 0.25, Y 0.25-0.50, Z over 0.50 (common rule of thumb, not a hard rule)
CREATE OR REPLACE TABLE family_class AS
WITH vol AS (
    SELECT family,
           AVG(units)                     AS avg_units,
           STDDEV(units)                  AS sd_units,
           STDDEV(units) / AVG(units)     AS cv
    FROM weekly_family
    GROUP BY family
)
SELECT a.family,
       a.total_units,
       a.volume_rank,
       a.abc_class,
       v.cv,
       CASE WHEN v.cv < 0.25 THEN 'X'
            WHEN v.cv < 0.50 THEN 'Y'
            ELSE 'Z' END                          AS xyz_class,
       a.abc_class || CASE WHEN v.cv < 0.25 THEN 'X'
                           WHEN v.cv < 0.50 THEN 'Y'
                           ELSE 'Z' END           AS abc_xyz   -- || glues the two letters, e.g. 'AX'
FROM family_abc a
JOIN vol v USING (family);

-- every family with its classes
SELECT family, abc_xyz, ROUND(cv, 2) AS cv, volume_rank
FROM family_class
ORDER BY abc_class, cv;

-- ABC-XYZ grid
SELECT abc_class,
       COUNT(*) FILTER (WHERE xyz_class = 'X') AS x_steady,
       COUNT(*) FILTER (WHERE xyz_class = 'Y') AS y_variable,
       COUNT(*) FILTER (WHERE xyz_class = 'Z') AS z_erratic
FROM family_class
GROUP BY abc_class
ORDER BY abc_class;
-- Every A and B family is steady (X, CV under 0.16). PRODUCE is the steadiest (0.07),
-- makes sense, people buy fruit and veggies every week.
-- The only jumpy ones are small families, ~2% of demand total. The Z ones
-- (SCHOOL AND OFFICE SUPPLIES, FROZEN FOODS, LAWN AND GARDEN, HOME APPLIANCES) are
-- jumpy mostly because of seasonal spikes, so looking at last year should help them.
-- These are totals across all 54 stores though. One store on its own would be way less steady.

-- lift: how much each week is above/below the 4 weeks before it, + event flags
-- promo jump = promos more than 1.5x the last 4 weeks (my own cutoff)
-- (05_accuracy.sql reuses this table)
CREATE OR REPLACE TABLE weekly_lift AS
WITH base AS (
    SELECT f.family,
           f.week_start,
           f.units,
           f.promo_items,
           AVG(f.units) OVER (PARTITION BY f.family ORDER BY f.week_start
                              ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS baseline,
           AVG(f.promo_items) OVER (PARTITION BY f.family ORDER BY f.week_start
                              ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING) AS promo_baseline,
           e.national_holiday,
           e.national_event,
           e.payday_in_week,
           e.earthquake_period
    FROM weekly_family f
    JOIN weekly_events e USING (week_start)
)
SELECT *,
       CASE WHEN promo_baseline > 0 AND promo_items > 1.5 * promo_baseline
            THEN 1 ELSE 0 END AS promo_jump
FROM base
WHERE baseline IS NOT NULL;   -- first week of each family has nothing to compare to

-- lift by type of week, all families together (big ones count more)
SELECT 'Holiday week'    AS week_type, COUNT(DISTINCT week_start) AS weeks,
       ROUND((SUM(units) / SUM(baseline) - 1) * 100, 1) AS lift_pct
FROM weekly_lift WHERE national_holiday = 1
UNION ALL
SELECT 'Event week', COUNT(DISTINCT week_start),
       ROUND((SUM(units) / SUM(baseline) - 1) * 100, 1)
FROM weekly_lift WHERE national_event = 1
UNION ALL
SELECT 'Payday week', COUNT(DISTINCT week_start),
       ROUND((SUM(units) / SUM(baseline) - 1) * 100, 1)
FROM weekly_lift WHERE payday_in_week = 1
UNION ALL
SELECT 'Earthquake week', COUNT(DISTINCT week_start),
       ROUND((SUM(units) / SUM(baseline) - 1) * 100, 1)
FROM weekly_lift WHERE earthquake_period = 1
UNION ALL
SELECT 'Normal week', COUNT(DISTINCT week_start),
       ROUND((SUM(units) / SUM(baseline) - 1) * 100, 1)
FROM weekly_lift
WHERE national_holiday = 0 AND national_event = 0
  AND payday_in_week = 0 AND earthquake_period = 0;
-- Compare to normal weeks (-2.5%), not to 0. Normal weeks come out negative because
-- their last 4 weeks usually include some holiday or payday bump.
-- Holidays are about 5 points above normal, events/paydays/earthquake about 3-4.
-- So at the whole-chain, whole-week level, events don't move demand that much.
-- Payday shows up in almost every other week, so it can't really tell busy weeks apart.

-- promo lift by family (only families with 5+ promo jump weeks so one-offs don't count)
SELECT family,
       COUNT(*) FILTER (WHERE promo_jump = 1) AS promo_jump_weeks,
       ROUND((SUM(units)    FILTER (WHERE promo_jump = 1)
            / SUM(baseline) FILTER (WHERE promo_jump = 1) - 1) * 100, 1) AS lift_promo_pct,
       ROUND((SUM(units)    FILTER (WHERE promo_jump = 0)
            / SUM(baseline) FILTER (WHERE promo_jump = 0) - 1) * 100, 1) AS lift_other_pct
FROM weekly_lift
GROUP BY family
HAVING COUNT(*) FILTER (WHERE promo_jump = 1) >= 5
ORDER BY lift_promo_pct - lift_other_pct DESC
LIMIT 10;
-- All top 10 are small, non-food families. SCHOOL AND OFFICE SUPPLIES is +186% but
-- promos probably run during back-to-school, so I can't separate the promo from the season.
-- FROZEN FOODS +25%, HOME AND KITCHEN and BEAUTY +11-14%.
-- Food staples barely react to promos, people buy groceries every week anyway.