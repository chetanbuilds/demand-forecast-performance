-- =========================================================
-- 02_clean.sql
-- Checking the raw data + building the weekly tables everything else uses
--
-- Change: moved the start from Jan 5, 2015 to Jun 1, 2015.
-- Found that 7 families (PRODUCE included) had basically no sales recorded
-- Jan-May 2015. CHECK 7 below is how I found it.
-- =========================================================

-- CHECK 1: anything missing?
SELECT COUNT(*) FILTER (WHERE sales IS NULL)       AS null_sales,
       COUNT(*) FILTER (WHERE onpromotion IS NULL) AS null_promo
FROM raw_sales;
-- 0 and 0, nothing missing

-- CHECK 2: any duplicate date + store + family rows?
SELECT date, store_nbr, family, COUNT(*) AS n
FROM raw_sales
GROUP BY ALL
HAVING COUNT(*) > 1;
-- empty, so no duplicates (good, otherwise sales would get counted twice)

-- CHECK 3: any negative sales?
SELECT COUNT(*) AS negative_sales_rows
FROM raw_sales
WHERE sales < 0;
-- 0

-- CHECK 4: days where a store sold nothing at all (probably closed)
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
-- Every Jan 1, 52-53 of the 54 stores sold nothing, so they're closed on New Year's.
-- Also exactly 8 stores show zero on a bunch of days in early 2013... see check 5.

-- CHECK 5: when did each store make its first sale?
SELECT store_nbr, MIN(date) AS first_sale
FROM raw_sales
WHERE sales > 0
GROUP BY store_nbr
ORDER BY first_sale DESC
LIMIT 10;
-- Same 8 stores! They just hadn't opened yet (store 52 didn't open until Apr 2017).
-- Keeping them since I'm adding up by family, a new store just adds demand.

-- CHECK 6: when did each family make its first sale?
SELECT family, MIN(date) AS first_sale
FROM raw_sales
WHERE sales > 0
GROUP BY family
ORDER BY first_sale DESC;
-- 11 families don't start until ~Jan 2014, PRODUCE not until Mar 2013 (weird for groceries),
-- and BOOKS not until Oct 2016. Dropping BOOKS, it only has ~10 months and my
-- forecasts need a full year to look back on.

-- CHECK 7: any stretches where a family suddenly sells almost nothing?
-- (weeks under 10% of that family's normal week, from Jan 2015 on)
-- added this after the trend in 03_demand.sql showed a weird 33% jump in June 2015
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
-- 7 families (PRODUCE, CELEBRATION, PET SUPPLIES, PLAYERS AND ELECTRONICS,
-- SCHOOL AND OFFICE SUPPLIES, LADIESWEAR, and mostly HOME CARE) are near zero every
-- week from Jan 5 to May 25, 2015, and then all come back the same week.
-- 7 unrelated families going quiet on the exact same dates isn't customers,
-- it's the data not being recorded. So the weekly table starts Jun 1, 2015.
-- Check 6 missed this because it only looks at the first sale ever.

-- weekly demand by family, the main table for everything after this
-- starts Jun 1, 2015 (see check 7, I first had Jan 5, 2015)
-- stops before the last week since it only has 2 days. No BOOKS.
CREATE OR REPLACE TABLE weekly_family AS
SELECT
    CAST(DATE_TRUNC('week', date) AS DATE) AS week_start,   -- Monday of each week
    family,
    SUM(sales)           AS units,
    SUM(onpromotion)     AS promo_items,
    COUNT(DISTINCT date) AS days_in_week
FROM raw_sales
WHERE date >= DATE '2015-06-01'
  AND date <  DATE '2017-08-14'
  AND family <> 'BOOKS'
GROUP BY ALL;

-- how big is it?
SELECT COUNT(*)                   AS row_count,
       COUNT(DISTINCT family)     AS families,
       COUNT(DISTINCT week_start) AS weeks,
       MIN(week_start)            AS first_week,
       MAX(week_start)            AS last_week
FROM weekly_family;
-- 3,680 rows = 32 families x 115 weeks, Jun 1 2015 to Aug 7 2017

-- any short weeks?
SELECT week_start, MIN(days_in_week) AS days
FROM weekly_family
GROUP BY week_start
HAVING MIN(days_in_week) < 7
ORDER BY week_start;
-- just the 2 Christmas weeks (6 days, there's no data for Dec 25 at all).
-- Keeping them, a store being closed for a day is normal.

-- quick look at one family
SELECT * FROM weekly_family
WHERE family = 'BEVERAGES'
ORDER BY week_start
LIMIT 10;

-- what's in the holidays table?
DESCRIBE holidays;
-- transferred is a BOOLEAN (true = holiday got moved to another day)

-- types of national holidays
SELECT type, COUNT(*) AS n
FROM holidays
WHERE locale = 'National'
GROUP BY type
ORDER BY n DESC;
-- Holiday, Event, Additional, Transfer, Bridge, Work Day.
-- Work Day = a weekend day people work to make up for a bridge day, so not a day off.

-- what are the events?
SELECT date, description
FROM holidays
WHERE locale = 'National' AND type = 'Event'
ORDER BY date;
-- Mother's Day, Black Friday, Cyber Monday, 2014 World Cup, and the earthquake
-- ("Terremoto Manabi") every day from Apr 16 to May 16, 2016. Didn't have to guess the dates.

-- one row for every single day (sales skip Dec 25 and oil skips weekends)
CREATE OR REPLACE TABLE calendar AS
SELECT CAST(d AS DATE) AS date
FROM generate_series(DATE '2013-01-01', DATE '2017-08-15', INTERVAL 1 DAY) AS t(d);

-- weekly flags: holiday, event, earthquake, payday, oil price
CREATE OR REPLACE TABLE weekly_events AS
WITH national_days AS (
    -- one row per date with a national holiday or event (skipping moved holidays)
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
    -- every day + its flags + oil price
    -- payday in Ecuador = the 15th and the last day of the month
    SELECT c.date,
        CAST(DATE_TRUNC('week', c.date) AS DATE) AS week_start,
        CASE WHEN DAY(c.date) = 15 OR c.date = LAST_DAY(c.date) THEN 1 ELSE 0 END AS is_payday,
        COALESCE(n.is_holiday, 0)    AS is_holiday,
        COALESCE(n.is_event, 0)      AS is_event,
        COALESCE(n.is_earthquake, 0) AS is_earthquake,
        o.dcoilwtico AS oil_price
    FROM calendar c
    LEFT JOIN national_days n ON n.date = c.date   -- LEFT JOIN so days with no holiday still stay
    LEFT JOIN oil o           ON o.date = c.date
),
weekly AS (
    -- days -> weeks. MAX = if any day that week had it, the week gets a 1
    SELECT week_start,
        MAX(is_holiday)    AS national_holiday,
        MAX(is_event)      AS national_event,
        MAX(is_earthquake) AS earthquake_period,
        MAX(is_payday)     AS payday_in_week,
        AVG(oil_price)     AS oil_price_avg    -- just averages whatever days have a price
    FROM daily
    GROUP BY week_start
)
SELECT *,
    oil_price_avg / LAG(oil_price_avg) OVER (ORDER BY week_start) - 1 AS oil_change_pct
FROM weekly;

-- sanity check the flags for my period
SELECT COUNT(*)               AS weeks,
       SUM(national_holiday)  AS holiday_weeks,
       SUM(national_event)    AS event_weeks,
       SUM(earthquake_period) AS earthquake_weeks,
       SUM(payday_in_week)    AS payday_weeks,
       COUNT(oil_price_avg)   AS weeks_with_oil
FROM weekly_events
WHERE week_start BETWEEN DATE '2015-06-01' AND DATE '2017-08-07';
-- 115 weeks, 22 holiday, 6 event, 6 earthquake, 52 payday, all 115 have an oil price.
-- All seem reasonable.

-- did I lose or double count anything going from daily to weekly?
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
-- both ~645.3M, difference 0 (just a tiny rounding thing way out at the 7th decimal)
-- (first version of this errored because I used the column names in the same SELECT
-- that made them, so I split it into a WITH first)

-- same thing for promos
SELECT
    (SELECT SUM(promo_items) FROM weekly_family) AS weekly_promo,
    (SELECT SUM(onpromotion) FROM raw_sales
     WHERE date >= DATE '2015-06-01'
       AND date <  DATE '2017-08-14'
       AND family <> 'BOOKS')                  AS daily_promo;
-- 7,079,351 both, exact match

-- does every family have all 115 weeks? (matters for LAG in 04_forecasts.sql)
SELECT family, COUNT(*) AS weeks
FROM weekly_family
GROUP BY family
HAVING COUNT(*) <> 115;
-- empty, so no gaps