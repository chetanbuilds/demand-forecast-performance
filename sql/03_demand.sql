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

-- FINDING 1: 5 of 32 families make up about 80% of demand.
-- GROCERY I (30%) and BEVERAGES (21%) alone are more than half.
-- 21 small families together are only about 5%.