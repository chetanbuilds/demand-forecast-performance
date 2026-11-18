# Data-Quality Log

Checks I ran on `raw_sales` before building the weekly tables.

| # | Check | What I found | What I did |
|---|-------|--------------|------------|
| 1 | Missing values | None | Nothing needed |
| 2 | Duplicate rows | None | Nothing needed |
| 3 | Negative sales | None | Nothing needed |
| 4 | Days with zero sales | Almost every store is closed on Jan 1 | Treated Jan 1 as a closure |
| 5 | Stores opening late | 8 stores opened after the data starts | Kept them |
| 6 | Families starting late | 11 families start in 2014, BOOKS in late 2016 | Dropped BOOKS |
| 7 | Short weeks | 2 Christmas weeks only have 6 days | Kept them |
| 8 | Earthquake and oil gaps | Earthquake listed as events Apr 16 to May 16, 2016; oil missing on weekends | Flagged earthquake weeks from the data, averaged oil per week |
| 9 | Totals after rolling up to weeks | Weekly and daily totals match; all 32 families have 115 weeks | Nothing needed |
| 10 | Recording gap in early 2015 | 7 families had almost no sales Jan to May 2015, all ending the same week | Moved the start date to June 1, 2015 |

## Notes

**Jan 1 closures.** 52 or 53 of the 54 stores show zero sales every New Year's Day. The stores were closed, so these zeros aren't real demand.

**Late store openings.** At first it looked like 8 stores had zero sales on a lot of days in early 2013. When I checked each store's first sale date, it was the same 8 stores. They just hadn't opened yet. The newest one, store 52, didn't open until April 2017. I kept them because I'm totaling sales by product family, so a new store adds demand instead of creating fake zeros. One thing to keep in mind: an opening can cause a jump in demand that a forecast won't see coming.

**Late-starting families.** 11 families have no sales until around January 2014, and BOOKS doesn't start until October 2016. I dropped BOOKS because it only has about 10 months of sales, and my forecasts need at least a year of history to compare against. I first started the analysis on Jan 5, 2015, but later moved it to June 1 (see the recording gap below).

**Christmas weeks.** There's no data at all for Dec 25, so the two Christmas weeks (Dec 21, 2015 and Dec 19, 2016) only have 6 days. I left them in since that's normal for a real business.

**Earthquake and oil.** I didn't have to guess the earthquake dates. The holidays file lists every day from Apr 16 to May 16, 2016 as "Terremoto Manabi," so I flagged those 6 weeks straight from the data. Oil prices are missing on weekends and a few other days, so I just averaged whatever prices each week had.

**Recording gap.** While looking at the demand trend, I saw a 33% jump from May to June 2015, which seemed way too sudden. When I broke it down by family, PRODUCE went from about 2,000 units a week to 836,000, and 6 other families had near-zero sales over the exact same weeks. Since they all came back the same week, it looks like a recording issue, not real demand. My earlier "first sale date" check missed this because these families did have some sales before. I moved the start date to June 1, 2015, which still leaves 115 weeks of data. After the change, weekly and daily totals still match (about 645 million units).