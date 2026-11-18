-- =========================================================
-- 02_clean.sql
-- Data-quality checks and weekly tables for analysis
--
-- Change log
-- Nov 18, 2026: moved the analysis start from Jan 5, 2015 to Jun 1, 2015.
--   While checking the demand trend, I found that 7 families (including PRODUCE)
--   had almost no sales recorded from Jan to May 2015. See CHECK 7 below.
-- =========================================================

-- CHECK 1: Are any sales or promotion values missing?
SELECT COUNT(*) FILTER (WHERE sales IS NULL)       AS null_sales,
       COUNT(*) FILTER (WHERE onpromotion IS NULL) AS null_promo
FROM raw_sales;

-- CHECK 2: Does any date + store + family appear more than once?
SELECT date, store_nbr, family, COUNT(*) AS n
FROM raw_sales
GROUP BY ALL
HAVING COUNT(*) > 1;

-- CHECK 3: Are there any negative sales (returns or errors)?
SELECT COUNT(*) AS negative_sales_rows
FROM raw_sales
WHERE sales < 0;

-- CHECK 4: Which dates have stores with zero total sales (likely closed)?
SELECT date, COUNT(*) AS stores_with_zero
FROM (
    SELECT date, store_nbr, SUM(sales) AS total
    FROM raw_sales
    GROUP BY ALL
)
WHERE total = 0
GROUP BY date
ORDER BY stores_with_zero DESC
LIMIT 20;

-- CHECK 5: When did each store first record sales?
SELECT store_nbr, MIN(date) AS first_sale
FROM raw_sales
WHERE sales > 0
GROUP BY store_nbr
ORDER BY first_sale DESC
LIMIT 10;

-- CHECK 6: When did each product family first record sales?
SELECT family, MIN(date) AS first_sale
FROM raw_sales
WHERE sales > 0
GROUP BY family
ORDER BY first_sale DESC;

-- CHECK 7: Are there stretches where a family has almost no sales?
-- (weeks under 10% of that family's typical week, from Jan 2015 on)
WITH weekly AS (
    SELECT CAST(DATE_TRUNC('week', date) AS DATE) AS week_start,
           family,
           SUM(sales) AS units
    FROM raw_sales
    WHERE date >= DATE '2015-01-05'
      AND date <  DATE '2017-08-14'
      AND family <> 'BOOKS'
    GROUP BY ALL
),
med AS (
    SELECT family, MEDIAN(units) AS med_units
    FROM weekly
    GROUP BY family
)
SELECT w.family,
       COUNT(*)          AS low_weeks,
       MIN(w.week_start) AS first_low_week,
       MAX(w.week_start) AS last_low_week
FROM weekly w
JOIN med m USING (family)
WHERE w.units < 0.1 * m.med_units
GROUP BY w.family
ORDER BY low_weeks DESC;
-- Result: 7 families (PRODUCE, CELEBRATION, PET SUPPLIES, PLAYERS AND ELECTRONICS,
-- SCHOOL AND OFFICE SUPPLIES, LADIESWEAR, and mostly HOME CARE) are near zero
-- every week from Jan 5 to May 25, 2015, and they all come back the same week.
-- That looks like a recording gap, not real demand, so the weekly table starts Jun 1, 2015.

-- Weekly demand by product family
-- Starts 2015-06-01: Jan-May 2015 has a recording gap in 7 families (see CHECK 7).
--   I originally started on 2015-01-05.
-- Ends before the partial last week. BOOKS excluded (less than a year of sales history).
CREATE OR REPLACE TABLE weekly_family AS
SELECT
    CAST(DATE_TRUNC('week', date) AS DATE) AS week_start,
    family,
    SUM(sales)           AS units,
    SUM(onpromotion)     AS promo_items,
    COUNT(DISTINCT date) AS days_in_week
FROM raw_sales
WHERE date >= DATE '2015-06-01'
  AND date <  DATE '2017-08-14'
  AND family <> 'BOOKS'
GROUP BY ALL;

-- How big is the weekly table?
SELECT COUNT(*)                   AS row_count,
       COUNT(DISTINCT family)     AS families,
       COUNT(DISTINCT week_start) AS weeks,
       MIN(week_start)            AS first_week,
       MAX(week_start)            AS last_week
FROM weekly_family;

-- Which weeks have fewer than 7 days of data?
SELECT week_start, MIN(days_in_week) AS days
FROM weekly_family
GROUP BY week_start
HAVING MIN(days_in_week) < 7
ORDER BY week_start;

SELECT * FROM weekly_family
WHERE family = 'BEVERAGES'
ORDER BY week_start
LIMIT 10;


-- What kind of data is in each holidays column?
DESCRIBE holidays;

-- What types of national holidays and events are there?
SELECT type, COUNT(*) AS n
FROM holidays
WHERE locale = 'National'
GROUP BY type
ORDER BY n DESC;

-- What are the national events?
SELECT date, description
FROM holidays
WHERE locale = 'National' AND type = 'Event'
ORDER BY date;

-- One row for every day in the data
CREATE OR REPLACE TABLE calendar AS
SELECT CAST(d AS DATE) AS date
FROM generate_series(DATE '2013-01-01', DATE '2017-08-15', INTERVAL 1 DAY) AS t(d);

-- Weekly flags for holidays, events, the 2016 earthquake, paydays, and oil price
CREATE OR REPLACE TABLE weekly_events AS
WITH national_days AS (
    -- one row per date with a national holiday or event
    SELECT date,
        MAX(CASE WHEN type IN ('Holiday', 'Transfer', 'Additional', 'Bridge') THEN 1 ELSE 0 END) AS is_holiday,
        MAX(CASE WHEN type = 'Event' AND description NOT LIKE 'Terremoto%' THEN 1 ELSE 0 END) AS is_event,
        MAX(CASE WHEN description LIKE 'Terremoto%' THEN 1 ELSE 0 END) AS is_earthquake
    FROM holidays
    WHERE locale = 'National'
      AND transferred = FALSE
    GROUP BY date
),
daily AS (
    -- every day, with its flags and oil price
    SELECT c.date,
        CAST(DATE_TRUNC('week', c.date) AS DATE) AS week_start,
        CASE WHEN DAY(c.date) = 15 OR c.date = LAST_DAY(c.date) THEN 1 ELSE 0 END AS is_payday,
        COALESCE(n.is_holiday, 0)    AS is_holiday,
        COALESCE(n.is_event, 0)      AS is_event,
        COALESCE(n.is_earthquake, 0) AS is_earthquake,
        o.dcoilwtico AS oil_price
    FROM calendar c
    LEFT JOIN national_days n ON n.date = c.date
    LEFT JOIN oil o           ON o.date = c.date
),
weekly AS (
    -- roll the days up into weeks
    SELECT week_start,
        MAX(is_holiday)    AS national_holiday,
        MAX(is_event)      AS national_event,
        MAX(is_earthquake) AS earthquake_period,
        MAX(is_payday)     AS payday_in_week,
        AVG(oil_price)     AS oil_price_avg
    FROM daily
    GROUP BY week_start
)
SELECT *,
    oil_price_avg / LAG(oil_price_avg) OVER (ORDER BY week_start) - 1 AS oil_change_pct
FROM weekly;


-- Check the flags for the analysis period
SELECT COUNT(*)               AS weeks,
       SUM(national_holiday)  AS holiday_weeks,
       SUM(national_event)    AS event_weeks,
       SUM(earthquake_period) AS earthquake_weeks,
       SUM(payday_in_week)    AS payday_weeks,
       COUNT(oil_price_avg)   AS weeks_with_oil
FROM weekly_events
WHERE week_start BETWEEN DATE '2015-06-01' AND DATE '2017-08-07';

-- RECONCILE: Do weekly totals match the daily data for the same period?
WITH totals AS (
    SELECT
        (SELECT SUM(units) FROM weekly_family) AS weekly_total,
        (SELECT SUM(sales) FROM raw_sales
         WHERE date >= DATE '2015-06-01'
           AND date <  DATE '2017-08-14'
           AND family <> 'BOOKS')            AS daily_total
)
SELECT weekly_total,
       daily_total,
       ROUND(weekly_total - daily_total, 2) AS difference
FROM totals;

-- RECONCILE: Do weekly promotion totals match too?
SELECT
    (SELECT SUM(promo_items) FROM weekly_family) AS weekly_promo,
    (SELECT SUM(onpromotion) FROM raw_sales
     WHERE date >= DATE '2015-06-01'
       AND date <  DATE '2017-08-14'
       AND family <> 'BOOKS')                  AS daily_promo;


-- Does every family have all 115 weeks?
SELECT family, COUNT(*) AS weeks
FROM weekly_family
GROUP BY family
HAVING COUNT(*) <> 115;


