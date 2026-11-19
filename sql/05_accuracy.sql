-- =========================================================
-- 05_accuracy.sql
-- How accurate are the 4 forecasts, and why do they miss?
-- =========================================================

-- Scores for every family + method over the last 52 weeks
-- WAPE = total abs error / total actual (lower is better)
-- bias = total error / total actual (+ means forecast too high, - means too low)
-- FVA = how much better than naive (naive WAPE - method WAPE)
CREATE OR REPLACE TABLE scorecard_all AS
WITH m AS (
    SELECT family, method,
           SUM(actual)                  AS total_actual,
           SUM(abs_error) / SUM(actual) AS wape,
           SUM(error)     / SUM(actual) AS bias
    FROM forecast_long
    GROUP BY family, method
    HAVING SUM(actual) > 0
)
SELECT m.*,
       n.wape - m.wape AS fva
FROM m
JOIN m AS n
  ON n.family = m.family
 AND n.method = 'F1 Naive';

-- sanity check: should be 128 rows and naive FVA should be exactly 0
SELECT COUNT(*)                                       AS row_count,
       COUNT(DISTINCT family)                         AS families,
       COUNT(DISTINCT method)                         AS methods,
       MAX(ABS(fva)) FILTER (WHERE method = 'F1 Naive') AS naive_fva
FROM scorecard_all;

-- top 4 families, best method first
SELECT family, method,
       ROUND(wape * 100, 1) AS wape_pct,
       ROUND(bias * 100, 1) AS bias_pct,
       ROUND(fva  * 100, 1) AS fva_points
FROM scorecard_all
WHERE family IN ('GROCERY I', 'BEVERAGES', 'PRODUCE', 'CLEANING')
ORDER BY family, wape;
-- F4 wins for GROCERY I, PRODUCE and CLEANING (2-4 points better than naive).
-- F2 is always too low (-4% to -10%) since it just copies last year and misses the growth.
-- BEVERAGES is weird: F3 wins and F4 is actually worse than naive. Looked into it below.

-- overall score per method (big families count more)
SELECT method,
       ROUND(SUM(abs_error) / SUM(actual) * 100, 1) AS wape_pct,
       ROUND(SUM(error)     / SUM(actual) * 100, 1) AS bias_pct
FROM forecast_long
GROUP BY method
ORDER BY wape_pct;

-- how many families does each method win?
WITH best AS (
    SELECT family, method
    FROM scorecard_all
    QUALIFY ROW_NUMBER() OVER (PARTITION BY family ORDER BY wape) = 1
)
SELECT method, COUNT(*) AS families_won
FROM best
GROUP BY method
ORDER BY families_won DESC;

-- families where nothing beats naive
SELECT s.family,
       a.abc_class,
       ROUND(MAX(s.fva) * 100, 1) AS best_fva_points
FROM scorecard_all s
JOIN family_abc a USING (family)
GROUP BY s.family, a.abc_class
HAVING MAX(s.fva) <= 0
ORDER BY a.abc_class, s.family;

-- does the winner change by family size?
SELECT a.abc_class,
       f.method,
       ROUND(SUM(f.abs_error) / SUM(f.actual) * 100, 1) AS wape_pct
FROM forecast_long f
JOIN family_abc a USING (family)
GROUP BY a.abc_class, f.method
ORDER BY a.abc_class, wape_pct;

-- MAIN RESULT: F4 is the best overall. WAPE goes from 8.7% (naive) to 6.9%,
-- so about 21% less error, and bias is almost 0 (-0.5%). It wins in A, B and C.
-- Funny thing: F3 actually wins more families (12 vs 11), but F4 wins the big ones.
-- If I'd just counted wins I would've picked the wrong method.
-- F3 is the worst for small seasonal families (17.5%) because a 4-week average
-- can't see a December or back-to-school spike coming.
-- 7 small C families can't beat naive no matter what.

-- one row per family with its best method + a review flag
-- I flag it if WAPE > 15% or bias is more than +/-5% (my own cutoffs, a planning
-- team would probably set their own)
CREATE OR REPLACE TABLE scorecard AS
SELECT s.family,
       s.method AS best_method,
       s.wape,
       s.bias,
       s.fva,
       c.abc_class,
       c.xyz_class,
       c.abc_xyz,
       CASE WHEN s.wape > 0.15 OR ABS(s.bias) > 0.05
            THEN 'Review' ELSE 'OK' END AS review_flag
FROM scorecard_all s
JOIN family_class c USING (family)
QUALIFY ROW_NUMBER() OVER (PARTITION BY s.family ORDER BY s.wape, s.method) = 1;
-- (added s.method to the sort so ties always pick the same method)
-- caveat: I picked the best method on the same weeks I'm scoring it on, so these
-- numbers are a bit optimistic. Ideally pick on an earlier period, test on a later one.

-- full scorecard, worst first
SELECT family, abc_xyz, best_method,
       ROUND(wape * 100, 1) AS wape_pct,
       ROUND(bias * 100, 1) AS bias_pct,
       ROUND(fva  * 100, 1) AS fva_points,
       review_flag
FROM scorecard
ORDER BY wape DESC;

-- how much of total demand is flagged?
SELECT s.review_flag,
       COUNT(*) AS families,
       ROUND(SUM(c.total_units) / SUM(SUM(c.total_units)) OVER () * 100, 1) AS pct_of_demand
FROM scorecard s
JOIN family_class c USING (family)
GROUP BY s.review_flag;
-- Only 3 families get flagged and they're 0.1% of demand: SCHOOL AND OFFICE SUPPLIES
-- (43% WAPE, 13% too low), LAWN AND GARDEN and HOME APPLIANCES (18-19%).
-- Naive is their best method, so these need a person looking at them, not a better formula.
-- All the A and B families are between 3.4% and 9.9% with bias within 1%. That's good news.
-- FROZEN FOODS does best with F2 (+18 points), makes sense with its big December spike.

-- best-method errors for each family with the event/promo flags attached
-- (promo_jump is from weekly_lift in 03_demand.sql: promos > 1.5x the last 4 weeks)
CREATE OR REPLACE TABLE best_errors AS
SELECT f.*,
       e.national_holiday,
       e.national_event,
       e.payday_in_week,
       e.oil_change_pct,
       l.promo_items,
       l.promo_jump
FROM forecast_long f
JOIN scorecard s
  ON s.family = f.family AND s.best_method = f.method
JOIN weekly_events e
  ON e.week_start = f.week_start
JOIN weekly_lift l
  ON l.family = f.family AND l.week_start = f.week_start;

-- which kind of week is hardest to forecast?
SELECT 'Holiday week' AS week_type, COUNT(*) AS family_weeks,
       ROUND(SUM(abs_error) / SUM(actual) * 100, 1) AS wape_pct,
       ROUND(SUM(error)     / SUM(actual) * 100, 1) AS bias_pct
FROM best_errors WHERE national_holiday = 1
UNION ALL
SELECT 'Event week', COUNT(*),
       ROUND(SUM(abs_error) / SUM(actual) * 100, 1),
       ROUND(SUM(error)     / SUM(actual) * 100, 1)
FROM best_errors WHERE national_event = 1
UNION ALL
SELECT 'Payday week', COUNT(*),
       ROUND(SUM(abs_error) / SUM(actual) * 100, 1),
       ROUND(SUM(error)     / SUM(actual) * 100, 1)
FROM best_errors WHERE payday_in_week = 1
UNION ALL
SELECT 'Promo jump week', COUNT(*),
       ROUND(SUM(abs_error) / SUM(actual) * 100, 1),
       ROUND(SUM(error)     / SUM(actual) * 100, 1)
FROM best_errors WHERE promo_jump = 1
UNION ALL
SELECT 'Normal week', COUNT(*),
       ROUND(SUM(abs_error) / SUM(actual) * 100, 1),
       ROUND(SUM(error)     / SUM(actual) * 100, 1)
FROM best_errors
WHERE national_holiday = 0 AND national_event = 0
  AND payday_in_week = 0 AND promo_jump = 0;
-- (weeks can be in more than one group, e.g. holiday + payday, so counts don't add up)

-- earthquake echo test: F2 and F4 look back 52 weeks, so in Apr-May 2017 they should
-- be copying last year's earthquake stock-up and come out too high
SELECT family, method,
       ROUND(SUM(error)  FILTER (WHERE echo)
           / SUM(actual) FILTER (WHERE echo) * 100, 1)      AS bias_echo_weeks_pct,
       ROUND(SUM(error)  FILTER (WHERE NOT echo)
           / SUM(actual) FILTER (WHERE NOT echo) * 100, 1)  AS bias_other_weeks_pct
FROM (
    SELECT *,
           week_start BETWEEN DATE '2017-04-10' AND DATE '2017-05-15' AS echo
    FROM forecast_long
)
WHERE family IN ('GROCERY I', 'BEVERAGES')
GROUP BY family, method
ORDER BY family, method;

-- is it really the promos, or just that small families have more promos?
SELECT a.abc_class,
       b.promo_jump,
       COUNT(*) AS family_weeks,
       ROUND(SUM(b.abs_error) / SUM(b.actual) * 100, 1) AS wape_pct,
       ROUND(SUM(b.error)     / SUM(b.actual) * 100, 1) AS bias_pct
FROM best_errors b
JOIN family_abc a USING (family)
GROUP BY a.abc_class, b.promo_jump
ORDER BY a.abc_class, b.promo_jump;

-- What I found:
-- Normal weeks are 4.7% WAPE. Holiday weeks are about 2x worse (9.1%) and the
-- forecast is too low (-3.9%). Promo jump weeks are about 3x worse (14.5%) and too high (+5.7%).
-- It's not just a small-family thing. A families go 5.4% -> 16.0% in promo weeks
-- (only 17 weeks though, so I wouldn't call it proven) and C families 7.7% -> 15.5%.
-- B families barely change. Paydays and events don't really matter.
-- The earthquake idea checks out for GROCERY I: in Apr-May 2017 F2 and F4 are about
-- 4-5% too high because they copied last year's stock-up. F1 and F3 don't do that.
-- For BEVERAGES it only explains part of it.
-- What I'd do: get the promo calendar ahead of time, bump up holiday weeks, and take
-- one-time events out of last year's data before using it.

-- 10 biggest misses (in units) + whatever holidays were that week
CREATE OR REPLACE TABLE root_cause AS
WITH worst AS (
    SELECT family, week_start, method, actual, forecast, error, abs_error,
           abs_error / actual AS pct_error,
           national_holiday, national_event, payday_in_week, promo_jump
    FROM best_errors
    ORDER BY abs_error DESC
    LIMIT 10
)
SELECT w.*,
       (SELECT STRING_AGG(DISTINCT h.description, ', ')
        FROM holidays h
        WHERE h.locale = 'National'
          AND h.transferred = FALSE
          AND CAST(DATE_TRUNC('week', h.date) AS DATE) = w.week_start) AS holidays_that_week
FROM worst w
ORDER BY abs_error DESC;

-- easier to read version
SELECT family, week_start,
       ROUND(actual)          AS actual,
       ROUND(forecast)        AS forecast,
       ROUND(pct_error * 100, 1) AS pct_error,
       CASE WHEN error > 0 THEN 'Over' ELSE 'Under' END AS direction,
       national_holiday, national_event, payday_in_week, promo_jump,
       holidays_that_week
FROM root_cause
ORDER BY abs_error DESC;

-- my best guess at the cause of each miss + what a planner should do
CREATE OR REPLACE TABLE root_cause_explained AS
SELECT *,
    CASE
        WHEN family = 'GROCERY I' AND week_start = DATE '2017-04-17'
            THEN 'Earthquake echo: copied last year''s stock-up week'
        WHEN family = 'GROCERY I' AND week_start IN (DATE '2017-05-01', DATE '2017-05-08', DATE '2017-05-15')
            THEN 'Likely earthquake after-effect, plus Labor Day / Mother''s Day'
        WHEN week_start = DATE '2017-01-02'
            THEN 'Holiday: New Year'
        WHEN week_start = DATE '2016-12-19'
            THEN 'Holiday: Christmas'
        WHEN week_start = DATE '2016-10-31'
            THEN 'Holiday: Day of the Dead long weekend, plus promo jump'
        WHEN week_start = DATE '2017-02-27'
            THEN 'Moving holiday: Carnaval'
        WHEN week_start = DATE '2016-11-07'
            THEN 'Week after a long holiday weekend'
    END AS likely_cause,
    CASE
        WHEN family = 'GROCERY I' AND week_start = DATE '2017-04-17'
            THEN 'Remove one-time events from last year''s data before forecasting'
        WHEN family = 'GROCERY I' AND week_start IN (DATE '2017-05-01', DATE '2017-05-08', DATE '2017-05-15')
            THEN 'Check the growth adjustment after one-time events; add holiday uplift'
        WHEN week_start = DATE '2017-02-27'
            THEN 'Line up last year by holiday date, not by 52 weeks back'
        WHEN week_start = DATE '2016-10-31'
            THEN 'Add holiday uplift and use the promotion calendar'
        WHEN week_start = DATE '2016-11-07'
            THEN 'Review the week after long holidays'
        ELSE 'Add a holiday uplift based on last year''s same holiday'
    END AS recommended_action
FROM root_cause;
-- ('' inside the text is how SQL writes an apostrophe)

-- check
SELECT family, week_start,
       ROUND(pct_error * 100, 1) AS pct_error,
       CASE WHEN error > 0 THEN 'Over' ELSE 'Under' END AS direction,
       likely_cause,
       recommended_action
FROM root_cause_explained
ORDER BY abs_error DESC;
-- All 10 are GROCERY I or BEVERAGES (makes sense, they're the biggest) and every one
-- is a holiday, the earthquake, or both. 9 of 10 are too low, so stockout risk.
-- The worst one by far is GROCERY I on Apr 17 2017: forecast 3.16M, actual 1.69M (87% too high).
-- That's exactly 52 weeks after the earthquake stock-up week, so F4 copied it.
-- That one miss is bigger than the next 3 put together.
-- Carnaval moves every year (Feb 8 in 2016, Feb 27 in 2017), so "52 weeks back"
-- grabs the wrong week. Didn't think about that until I saw it here.
-- The May 2017 GROCERY I misses are probably the earthquake messing with F4's growth
-- adjustment, but I haven't confirmed that yet (would check the growth ratio for those weeks).

-- same week-type comparison, saved as a table for Power BI (unrounded on purpose)
CREATE OR REPLACE TABLE condition_summary AS
SELECT 'Holiday week' AS week_type, COUNT(*) AS family_weeks,
       SUM(abs_error) / SUM(actual) AS wape,
       SUM(error)     / SUM(actual) AS bias
FROM best_errors WHERE national_holiday = 1
UNION ALL
SELECT 'Event week', COUNT(*), SUM(abs_error) / SUM(actual), SUM(error) / SUM(actual)
FROM best_errors WHERE national_event = 1
UNION ALL
SELECT 'Payday week', COUNT(*), SUM(abs_error) / SUM(actual), SUM(error) / SUM(actual)
FROM best_errors WHERE payday_in_week = 1
UNION ALL
SELECT 'Promo jump week', COUNT(*), SUM(abs_error) / SUM(actual), SUM(error) / SUM(actual)
FROM best_errors WHERE promo_jump = 1
UNION ALL
SELECT 'Normal week', COUNT(*), SUM(abs_error) / SUM(actual), SUM(error) / SUM(actual)
FROM best_errors
WHERE national_holiday = 0 AND national_event = 0
  AND payday_in_week = 0 AND promo_jump = 0;

-- export for Excel and Power BI
-- (these are my local paths, change them if you're running this yourself)
COPY forecast_long        TO '/Users/chetankumar/Documents/Projects/demand-forecast-performance/excel/forecast_long.csv'        (HEADER);
COPY scorecard_all        TO '/Users/chetankumar/Documents/Projects/demand-forecast-performance/excel/scorecard_all.csv'        (HEADER);
COPY scorecard            TO '/Users/chetankumar/Documents/Projects/demand-forecast-performance/excel/scorecard.csv'            (HEADER);
COPY family_class         TO '/Users/chetankumar/Documents/Projects/demand-forecast-performance/excel/family_class.csv'         (HEADER);
COPY weekly_events        TO '/Users/chetankumar/Documents/Projects/demand-forecast-performance/excel/weekly_events.csv'        (HEADER);
COPY condition_summary    TO '/Users/chetankumar/Documents/Projects/demand-forecast-performance/excel/condition_summary.csv'    (HEADER);
COPY root_cause_explained TO '/Users/chetankumar/Documents/Projects/demand-forecast-performance/excel/root_cause_explained.csv' (HEADER);

-- In short:
-- Use F4 (last year's same week scaled by recent growth) as the default forecast.
-- It cuts error from 8.7% to 6.9% vs naive with almost no bias.
-- Most of what's left comes from holidays (too low), promos (too high), and one-off
-- events like the 2016 earthquake showing up again a year later.
-- Fixes: holiday bumps lined up by the actual holiday date, use the promo calendar,
-- and clean one-time events out of last year's data. Only 3 tiny families (0.1% of
-- demand) need someone checking them every week.