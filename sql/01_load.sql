-- PROFILE NOTES
-- raw_sales: 3,000,888 rows, 54 stores, 33 product families
-- Dates: 2013-01-01 to 2017-08-15 (about 4.6 years of daily sales)
-- Missing values: none (0% null in every column)
-- Sales: min 0 (no negatives), median ~11, avg ~358, max 124,717
--   -> very skewed; at least 25% of rows have zero sales (closures or no demand? check in Milestone 2)
-- Promotions: most rows have 0 items on promotion
-- Oil table has missing prices on some days (check in Milestone 2)



-- =========================================================
-- 01_load.sql
-- Load the raw Kaggle files into DuckDB tables
-- =========================================================

CREATE OR REPLACE TABLE raw_sales AS
SELECT * FROM read_csv_auto('/Users/chetankumar/Documents/Projects/demand-forecast-performance/data/train.csv');

CREATE OR REPLACE TABLE stores AS
SELECT * FROM read_csv_auto('/Users/chetankumar/Documents/Projects/demand-forecast-performance/data/stores.csv');

CREATE OR REPLACE TABLE holidays AS
SELECT * FROM read_csv_auto('/Users/chetankumar/Documents/Projects/demand-forecast-performance/data/holidays_events.csv');

CREATE OR REPLACE TABLE oil AS
SELECT * FROM read_csv_auto('/Users/chetankumar/Documents/Projects/demand-forecast-performance/data/oil.csv');

CREATE OR REPLACE TABLE transactions AS
SELECT * FROM read_csv_auto('/Users/chetankumar/Documents/Projects/demand-forecast-performance/data/transactions.csv');

-- Row count for every table
SELECT 'raw_sales'    AS table_name, COUNT(*) AS row_count FROM raw_sales
UNION ALL SELECT 'stores',       COUNT(*) FROM stores
UNION ALL SELECT 'holidays',     COUNT(*) FROM holidays
UNION ALL SELECT 'oil',          COUNT(*) FROM oil
UNION ALL SELECT 'transactions', COUNT(*) FROM transactions;

SELECT * FROM raw_sales LIMIT 10;

-- What columns does the sales table have, and what type is each?
DESCRIBE raw_sales;

-- How big is the data, and what period does it cover?
SELECT COUNT(*)                  AS row_count,
       MIN(date)                 AS first_date,
       MAX(date)                 AS last_date,
       COUNT(DISTINCT store_nbr) AS stores,
       COUNT(DISTINCT family)    AS families
FROM raw_sales;

-- Min, max, average, and missing values for every column
SUMMARIZE raw_sales;

-- What are the 33 product families?
SELECT DISTINCT family FROM raw_sales ORDER BY family;

-- What do the supporting tables look like?
SELECT * FROM holidays LIMIT 20;

SELECT * FROM oil LIMIT 20;

SELECT * FROM stores LIMIT 10;