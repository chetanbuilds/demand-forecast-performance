-- =========================================================
-- 03_demand.sql
-- Demand analysis: ranking, trend, seasonality, volatility, events
-- =========================================================

-- Which families drive most of the demand? (ABC classes)
CREATE OR REPLACE TABLE family_abc AS
WITH totals AS (
    -- total units per family over the whole period
    SELECT family, SUM(units) AS total_units
    FROM weekly_family
    GROUP BY family
),
ranked AS (
    -- each family's share, and the running share from biggest to smallest
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

-- See the ranking
SELECT volume_rank, family, abc_class,
       ROUND(total_units)        AS total_units,
       ROUND(share * 100, 1)     AS share_pct,
       ROUND(cum_share * 100, 1) AS cum_share_pct
FROM family_abc
ORDER BY volume_rank;

-- How many families in each class?
SELECT abc_class, COUNT(*) AS families
FROM family_abc
GROUP BY abc_class
ORDER BY abc_class;


-- Is demand growing year over year? (average units per week, so years are comparable)
-- Careful: 2015 is Jun-Dec only and 2017 is Jan-Aug only, so the monthly
-- year-over-year growth below is the better comparison.
SELECT YEAR(week_start)           AS year,
       COUNT(DISTINCT week_start) AS weeks,
       ROUND(SUM(units) / COUNT(DISTINCT week_start)) AS avg_weekly_units
FROM weekly_family
GROUP BY YEAR(week_start)
ORDER BY year;

-- Monthly trend with growth vs. the same month last year
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


-- Seasonality: how busy is each month compared with an average month? (2016 only,
-- the one full calendar year, so growth between years doesn't mix in)
CREATE OR REPLACE TABLE seasonality_2016 AS
WITH monthly AS (
    -- average week in each month, per family
    SELECT family,
           MONTH(week_start) AS month_num,
           AVG(units)        AS avg_weekly_units
    FROM weekly_family
    WHERE YEAR(week_start) = 2016
    GROUP BY family, MONTH(week_start)
),
yearly AS (
    -- average week across all of 2016, per family
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

-- Seasonal index by month for the 5 biggest families (100 = average month)
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


-- Peak month, slowest month, and how big the swing is, for every family
SELECT family,
       ARG_MAX(month_num, seasonal_index) AS peak_month,
       MAX(seasonal_index)                AS peak_index,
       ARG_MIN(month_num, seasonal_index) AS low_month,
       MIN(seasonal_index)                AS low_index,
       MAX(seasonal_index) - MIN(seasonal_index) AS swing
FROM seasonality_2016
GROUP BY family
ORDER BY swing DESC;


-- How predictable is each family? CV = standard deviation / average of weekly units.
-- XYZ cutoffs (0.25 and 0.50) are a common rule of thumb, not a fixed rule.
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
                           ELSE 'Z' END           AS abc_xyz
FROM family_abc a
JOIN vol v USING (family);

-- Every family with its size class, predictability class, and CV
SELECT family, abc_xyz, ROUND(cv, 2) AS cv, volume_rank
FROM family_class
ORDER BY abc_class, cv;


-- How many families fall in each ABC-XYZ cell?
SELECT abc_class,
       COUNT(*) FILTER (WHERE xyz_class = 'X') AS x_steady,
       COUNT(*) FILTER (WHERE xyz_class = 'Y') AS y_variable,
       COUNT(*) FILTER (WHERE xyz_class = 'Z') AS z_erratic
FROM family_class
GROUP BY abc_class
ORDER BY abc_class;

-- Note: the May-June 2015 jump I first saw here turned out to be a recording gap.
-- The check that found it is CHECK 7 in 02_clean.sql; the weekly table now starts Jun 1, 2015.


-- FINDING 1: 4 families (GROCERY I, BEVERAGES, PRODUCE, CLEANING) make up 74.5% of demand.
-- DAIRY is right on the edge: adding it brings the total to 80.3%, so it lands in class B.
-- GROCERY I and BEVERAGES alone are 51%. The 21 smallest families together are about 5%.

-- FINDING 2: Demand was nearly flat in the second half of 2016 (0-7% over 2015),
-- then picked up in 2017 (about 8-18% over 2016). December is the peak month both years.
-- April 2017 looks slightly down only because April 2016 was boosted during the earthquake.

-- FINDING 3: The big families are fairly steady through the year (GROCERY I swings
-- from 92 to 124, DAIRY only 95 to 107, where 100 = an average month). December is
-- the main peak for most families. The biggest swings are in small families:
-- FROZEN FOODS sells about 4x an average month in December, and SCHOOL AND OFFICE
-- SUPPLIES about 3x in August (back to school).
-- Watch out: GROCERY I and BEVERAGES spike in April 2016 because of the earthquake,
-- not normal seasonality. A forecast that copies last year will likely overshoot April 2017.

-- FINDING 4: All 11 A and B families are steady (class X, CV under 0.16), and
-- PRODUCE is the steadiest (0.07). The only Y and Z families are small ones, about
-- 2% of demand together. The Z families (SCHOOL AND OFFICE SUPPLIES, FROZEN FOODS,
-- LAWN AND GARDEN, HOME APPLIANCES) swing mostly because of seasonal spikes, so
-- forecasts that look at last year should help them most.
-- Note: these are chain-wide totals; single stores would look much less steady.