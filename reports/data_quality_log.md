
# Data-Quality Log

Checks run on `raw_sales` before building the weekly tables.

| # | Check | What I found | What I did |
|---|-------|--------------|------------|
| 1 | Missing values | None | Nothing needed |
| 2 | Duplicate rows | None | Nothing needed |
| 3 | Negative sales | None | Nothing needed |
| 4 | Days with zero sales | Almost every store is closed on Jan 1 | Treated Jan 1 as a closure |
| 5 | Stores opening late | 8 stores opened after 2013 | Kept them |
| 6 | Families starting late | 11 families start in 2014, BOOKS in late 2016 | Start analysis in 2015, drop BOOKS |

## Notes

**Jan 1 closures.** 52 or 53 of the 54 stores show zero sales every New Year's Day. The stores were closed, so these zeros aren't real demand.

**Late store openings.** At first, it looked like 8 stores had zero sales on many days in early 2013. It turns out those 8 stores simply hadn't opened yet. The newest one, store 52, opened in April 2017. I kept them because I'm totaling sales by product family, so a new store adds demand rather than creating fake zeros. One thing to keep in mind: an opening can cause a jump in demand that a forecast won't see coming.

**Late-starting families.** 11 families have no sales until around January 2014, and PRODUCE has none until March 2013. BOOKS doesn't start until October 2016. Starting the analysis on Jan 1, 2015 gives every family except BOOKS a full history, and still leaves about 2.5 years of data. I dropped BOOKS because it has less than a year of sales, and my forecasts need at least a year of history to compare against.