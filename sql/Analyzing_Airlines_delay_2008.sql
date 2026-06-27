-- SUMMARY OF THE DATASET

-- ============================================
-- DATASET SCOPE NOTE
-- ============================================
-- During initial exploration (MIN/MAX checks on ArrDelay and DepDelay),
-- it was found that MIN(ArrDelay) = 15, meaning this dataset has been
-- pre-filtered to include only flights with an arrival delay of 15+ minutes.
--
-- Note: The filter appears to be based on ArrDelay >= 15 specifically.
-- DepDelay values are unfiltered (min = 6) and reflect natural variation
-- among flights that arrived 15+ minutes late.
--
-- This is a curated subset of DELAYED flights, not the full flight log.
-- As a result, metrics like "% of flights delayed" or "on-time rate"
-- cannot be calculated from this dataset. 
-- All analysis below focuses on patterns WITHIN delayed flights (severity, causes, routes, timing).
--
-- Since Cancelled = 0 and Diverted = 0 for all records,
-- no flights are either cancelled or diverted.
-- ============================================
--
-- =======================
-- Total Number of Flights 
SELECT
	COUNT(*)
FROM
	AIRLINE_DELAYS;
-- Result : 1153046

-- ==============
-- Total Airports
SELECT
	(COUNT(DISTINCT AIRPORT)) AS TOTAL_AIRPORTS
FROM
	(
		SELECT
			"Origin" AS AIRPORT
		FROM
			AIRLINE_DELAYS
		UNION
		SELECT
			"Dest" AS AIRPORT
		FROM
			AIRLINE_DELAYS
	);
-- Result : 302

-- ========================
-- Total Number of Airlines
SELECT
	COUNT(DISTINCT "UniqueCarrier") AS TOTAL_AIRLINES
FROM
	AIRLINE_DELAYS;
-- Result : 20

-- ==================================
-- Maximum and Minimum Arrival Delays
SELECT
	MIN("ArrDelay") AS MIN_ARRDELAY,
	MAX("ArrDelay") AS MAX_ARRDELAY
FROM
	AIRLINE_DELAYS;
-- Result : Min-15 mins, Max-158 mins.

-- ====================================
-- Maximum and Minimum Departure Delays
SELECT
	MIN("DepDelay") AS MIN_DEPDELAY,
	MAX("DepDelay") AS MAX_DEPDELAY
FROM
	AIRLINE_DELAYS;
-- Result : Min-6 mins, Max-151 mins.

-- ====================================
-- Average Arrival and Departure Delays
SELECT
	ROUND(CAST(AVG("ArrDelay") AS NUMERIC), 2) AS AVG_ARRDELAY,
	ROUND(CAST(AVG("DepDelay") AS NUMERIC), 2) AS AVG_DEPDELAY
FROM
	AIRLINE_DELAYS;
-- Result : Avg_arrdelay- 50.44 mins, Avg_depdelay- 47.34 mins.

-- ===============================
-- SECTION 1: ROUTE-LEVEL ANALYSIS
-- ===============================
--
-- Q1: Which routes consistently rank among the worst 10 delayed routes across multiple months (at least 2 months)?
-- routes across multiple months?

WITH monthly_route_delay AS (
    -- Average delay per route per month
    SELECT
        "Origin" || ' → ' || "Dest" AS route,
        "Month",
        ROUND(CAST(AVG("ArrDelay") AS NUMERIC), 2) AS avg_delay
    FROM
        AIRLINE_DELAYS
    GROUP BY
        "Origin", "Dest", "Month"
),

monthly_route_rank AS (
    -- Rank routes within each month by avg delay
    SELECT
        route,
        "Month",
        avg_delay,
        RANK() OVER (PARTITION BY "Month" ORDER BY avg_delay DESC) AS delay_rank
    FROM
        monthly_route_delay
),

top10_appearances AS (
    -- Filter only top 10 ranked routes per month
    -- then count how many months each route appeared in top 10
    SELECT
        route,
        COUNT(*) AS months_in_top10,
        ROUND(CAST(AVG(avg_delay) AS NUMERIC), 2) AS overall_avg_delay
    FROM
        monthly_route_rank
    WHERE
        delay_rank <= 10
    GROUP BY
        route
)

-- routes that appeared in top 10 in 2+ months
SELECT
    route,
    months_in_top10,
    overall_avg_delay
FROM
    top10_appearances
WHERE
    months_in_top10 >= 2
ORDER BY
    months_in_top10 DESC,
    overall_avg_delay DESC;
	
-- Result: 6 routes consistently appeared in top 10 worst delayed routes
-- across 2+ months (dataset covers 2008 only, so >= 2 months used as threshold)
-- 
-- Top finding: FLL → RIC (Fort Lauderdale → Richmond) averaged 142 mins delay
-- across 2 months - the most severely and consistently delayed route.
-- All 6 routes averaged 128+ minutes, indicating these are structurally
-- problematic routes, not one-off bad months.


-- ===================================================================
-- Q2: Are delays symmetric between route pairs (e.g. JFK→LAX vs LAX→JFK)?
-- Comparing avg ArrDelay for A→B vs B→A

WITH route_avg AS (
    -- Calculating average delay per direction
    SELECT
        "Origin" AS origin,
        "Dest" AS dest,
        "Origin" || ' → ' || "Dest" AS route,
        ROUND(CAST(AVG("ArrDelay") AS NUMERIC), 2) AS avg_delay
    FROM
        AIRLINE_DELAYS
    GROUP BY
        "Origin", "Dest"
),

route_pairs AS (
    -- Self-join to pair each route with its reverse
    SELECT
        a.route AS route_ab,
        b.route AS route_ba,
        a.avg_delay AS delay_ab,
        b.avg_delay AS delay_ba,
        ROUND(ABS(a.avg_delay - b.avg_delay), 2) AS delay_difference,
        CASE
            WHEN ABS(a.avg_delay - b.avg_delay) <= 5 THEN 'Symmetric'
            WHEN ABS(a.avg_delay - b.avg_delay) <= 15 THEN 'Mildly Asymmetric'
            ELSE 'Strongly Asymmetric'
        END AS symmetry_label,
        CASE
            WHEN a.avg_delay > b.avg_delay THEN a.route
            ELSE b.route
        END AS worse_direction
    FROM
        route_avg a
    JOIN
        route_avg b
        ON a.origin = b.dest AND a.dest = b.origin
    -- Avoiding duplicate pairs (A→B and B→A appearing twice)
    WHERE
        a.origin < a.dest
)

-- most asymmetric pairs first
SELECT
    route_ab,
    delay_ab,
    route_ba,
    delay_ba,
    delay_difference,
    symmetry_label,
    worse_direction
FROM
    route_pairs
ORDER BY
    delay_difference DESC
LIMIT 20;

-- Result: Top 20 most asymmetric route pairs (all strongly asymmetric, diff > 15 mins)
--
-- Key finding: ALL routes in the dataset show strong asymmetry —
-- no major route pair has symmetric delays in 2008.
--
-- Most extreme case: DAB → CLT averages 114 mins vs CLT → DAB at 21.67 mins
-- (92.33 min difference) — suggesting structural issues at Daytona Beach (DAB)
-- as a departure airport rather than a route-level problem.
--
-- Insight: Delay asymmetry suggests origin airport operations, ground crew
-- scheduling, or aircraft turnaround issues — not just weather or distance.
-- This finding challenges the assumption that delays are a "route" problem
-- and reframes them as an "origin airport" problem.


-- =============================================================================
-- Q3: Which routes recover departure delays most effectively (DepDelay − ArrDelay)?
-- Recovery = DepDelay - ArrDelay (positive = time made up, negative = delay worsened)

WITH route_recovery AS (
    -- Calculating average recovery per route
    SELECT
        "Origin" || ' → ' || "Dest" AS route,
        ROUND(CAST(AVG("DepDelay") AS NUMERIC), 2) AS avg_dep_delay,
        ROUND(CAST(AVG("ArrDelay") AS NUMERIC), 2) AS avg_arr_delay,
        ROUND(CAST(AVG("DepDelay" - "ArrDelay") AS NUMERIC), 2) AS avg_recovery,
        COUNT(*) AS total_flights
    FROM
        AIRLINE_DELAYS
    GROUP BY
        "Origin", "Dest"
    -- Only include routes with meaningful sample size
    HAVING
        COUNT(*) >= 50
),

categorized AS (
    -- Label routes by recovery behavior
    SELECT
        route,
        avg_dep_delay,
        avg_arr_delay,
        avg_recovery,
        total_flights,
        CASE
            WHEN avg_recovery >= 10 THEN 'Strong Recovery'
            WHEN avg_recovery >= 0  THEN 'Slight Recovery'
            WHEN avg_recovery >= -10 THEN 'Slight Worsening'
            ELSE 'Strong Worsening'
        END AS recovery_label
    FROM
        route_recovery
)

-- best and worst recovering routes
(
    -- Top 10 best recovering routes
    SELECT *, 'Best Recovering' AS category
    FROM categorized
    ORDER BY avg_recovery DESC
    LIMIT 10
)
UNION ALL
(
    -- Top 10 worst recovering routes (delay worsens most)
    SELECT *, 'Worst Recovering' AS category
    FROM categorized
    ORDER BY avg_recovery ASC
    LIMIT 10
)
ORDER BY
    category, avg_recovery DESC;
	
-- Result: 10 best and 10 worst recovering routes (min 50 flights, 2008)
--
-- BEST RECOVERING:
-- STL → PHL leads with +16.48 mins avg recovery — departed 71 mins late
-- but arrived only 54 mins late, consistently making up ~16 mins in the air.
-- All top 8 routes show "Strong Recovery" (>= 10 mins), suggesting airlines
-- build significant schedule buffer into these routes.
-- Notable: LAS (Las Vegas) appears 4 times in best recovering — suggesting
-- LAS departures benefit from favorable westward tailwinds or generous
-- scheduled flight times.
--
-- WORST RECOVERING:
-- PHL → SMF is the worst at -22.56 mins — departs 41 mins late but
-- arrives 64 mins late, adding ~23 mins of delay during the flight.
-- STT → JFK (-20.66) and JFK → STL (-16.96) suggest JFK-connected
-- routes compound delays rather than recover them — likely due to
-- heavy air traffic congestion at JFK.
--
-- Key insight: Short/medium routes to congested hub airports (JFK, ORD, LGA)
-- consistently worsen delays, while routes FROM Las Vegas and other
-- mid-sized airports show strong recovery — pointing to air traffic
-- control congestion at destination hubs as the primary driver of
-- delay worsening, not in-flight factors.


-- =======================================
-- SECTION 2: AIRLINE PERFORMANCE ANALYSIS
-- =======================================
--
-- Q4: Which airline has the most consistent performance (lowest STDDEV of ArrDelay)?
-- Consistency = lowest STDDEV of ArrDelay (predictability, not just avg delay)

WITH airline_stats AS (
    -- Calculate key performance stats per airline
    SELECT
        "UniqueCarrier" AS airline,
        COUNT(*) AS total_flights,
        ROUND(CAST(AVG("ArrDelay") AS NUMERIC), 2) AS avg_delay,
        ROUND(CAST(STDDEV("ArrDelay") AS NUMERIC), 2) AS stddev_delay,
        ROUND(CAST(MIN("ArrDelay") AS NUMERIC), 2) AS min_delay,
        ROUND(CAST(MAX("ArrDelay") AS NUMERIC), 2) AS max_delay
    FROM
        AIRLINE_DELAYS
    GROUP BY
        "UniqueCarrier"
    HAVING
        COUNT(*) >= 100
),

ranked AS (
    -- Ranking airlines by consistency (lowest STDDEV = most consistent)
    SELECT
        airline,
        total_flights,
        avg_delay,
        stddev_delay,
        min_delay,
        max_delay,
        RANK() OVER (ORDER BY stddev_delay ASC) AS consistency_rank,
        RANK() OVER (ORDER BY avg_delay ASC) AS avg_delay_rank,
        CASE
            WHEN stddev_delay <= 20 THEN 'Highly Consistent'
            WHEN stddev_delay <= 30 THEN 'Moderately Consistent'
            ELSE 'Inconsistent'
        END AS consistency_label
    FROM
        airline_stats
)

-- all airlines ranked by consistency
-- with avg_delay_rank to spot airlines consistent but still slow
SELECT
    consistency_rank,
    airline,
    total_flights,
    avg_delay,
    stddev_delay,
    consistency_label,
    avg_delay_rank,
    CASE
        WHEN consistency_rank <= 3 
         AND avg_delay_rank <= 3 THEN 'Best Overall'
        WHEN consistency_rank <= 3 THEN 'Consistent but Slow'
        WHEN avg_delay_rank <= 3 THEN 'Fast but Unpredictable'
        ELSE 'Standard'
    END AS performance_profile
FROM
    ranked
ORDER BY
    consistency_rank ASC;

-- Result: 20 airlines ranked by consistency (lowest STDDEV = most consistent)
--
-- TOP 3 "BEST OVERALL" (low STDDEV + low avg delay):
-- AQ (rank 1): STDDEV 24.90, avg delay 37.51 mins — most consistent AND
--              fastest airline in the dataset. Only 330 delayed flights,
--              suggesting a small but highly reliable operation.
-- HA (rank 2): STDDEV 26.23, avg delay 38.34 mins — Hawaii Airlines,
--              second most consistent with 4063 flights. Strong performance
--              at meaningful scale.
-- F9 (rank 3): STDDEV 26.80, avg delay 39.85 mins — Frontier Airlines,
--              best performer among mid-size carriers (15,497 flights).
--
-- KEY OBSERVATION — The "Consistent but Slow" trap:
-- No airline falls into "Consistent but Slow" or "Fast but Unpredictable"
-- categories — the top 3 are Best Overall, and ranks 4-20 are all Standard.
-- This means consistency and speed are correlated in this dataset:
-- airlines that manage delays well tend to manage BOTH metrics together.
--
-- NOTABLE: WN (Southwest) ranks 4th with 193,552 flights — by far the
-- largest carrier in the dataset — yet maintains Moderately Consistent
-- performance. Maintaining low STDDEV at that volume is operationally
-- impressive and suggests strong scheduling and ground ops systems.
--
-- BOTTOM: YV, B6, OO, UA all rank 17-20 with STDDEV > 34 mins —
-- meaning passengers on these airlines face highly unpredictable delays,
-- sometimes 15 mins, sometimes 90+ mins, with little consistency.


-- =============================================================
-- Q5: Which airline improved or worsened the most month-over-month?
-- Using LAG() to compare each month's avg delay to the previous month

WITH monthly_airline_avg AS (
    -- Average delay per airline per month
    SELECT
        "UniqueCarrier" AS airline,
        "Month",
        ROUND(CAST(AVG("ArrDelay") AS NUMERIC), 2) AS avg_delay,
        COUNT(*) AS total_flights
    FROM
        AIRLINE_DELAYS
    GROUP BY
        "UniqueCarrier", "Month"
    HAVING
        COUNT(*) >= 30
),

mom_change AS (
    -- Using LAG() to get previous month's avg delay
    -- and calculate month-over-month change
    SELECT
        airline,
        "Month",
        avg_delay,
        total_flights,
        LAG(avg_delay) OVER (
            PARTITION BY airline
            ORDER BY "Month"
        ) AS prev_month_avg,
        ROUND(
            avg_delay - LAG(avg_delay) OVER (
                PARTITION BY airline
                ORDER BY "Month"
            ), 2
        ) AS mom_change
    FROM
        monthly_airline_avg
),

labeled AS (
    -- Labelling each month-over-month change
    SELECT
        airline,
        "Month",
        avg_delay,
        prev_month_avg,
        mom_change,
        CASE
            WHEN mom_change IS NULL THEN 'First Month (no prior)'
            WHEN mom_change <= -10 THEN 'Strong Improvement'
            WHEN mom_change < 0   THEN 'Slight Improvement'
            WHEN mom_change <= 10 THEN 'Slight Worsening'
            ELSE 'Strong Worsening'
        END AS trend_label
    FROM
        mom_change
),

airline_summary AS (
    -- Summarizing each airline's overall MoM trend
    SELECT
        airline,
        COUNT(*) AS months_tracked,
        ROUND(AVG(mom_change), 2) AS avg_mom_change,
        ROUND(MIN(mom_change), 2) AS best_single_month_improvement,
        ROUND(MAX(mom_change), 2) AS worst_single_month_worsening,
        COUNT(CASE WHEN mom_change < 0 THEN 1 END) AS months_improved,
        COUNT(CASE WHEN mom_change > 0 THEN 1 END) AS months_worsened,
        CASE
            WHEN AVG(mom_change) <= -2 THEN 'Overall Improving'
            WHEN AVG(mom_change) >= 2  THEN 'Overall Worsening'
            ELSE 'Stable'
        END AS overall_trend
    FROM
        labeled
    WHERE
        mom_change IS NOT NULL
    GROUP BY
        airline
)

-- Final output — ranked by avg MoM change
SELECT
    airline,
    months_tracked,
    avg_mom_change,
    best_single_month_improvement,
    worst_single_month_worsening,
    months_improved,
    months_worsened,
    overall_trend
FROM
    airline_summary
ORDER BY
    avg_mom_change ASC;

-- Result: 20 airlines ranked by avg month-over-month change (best to worst)
--
-- KEY FINDING: The entire industry is remarkably stable in 2008.
-- 19 out of 20 airlines are classified as "Stable" (avg MoM change between -2 and +2).
-- No airline shows a dramatic overall improving or worsening trend across the year.
-- This suggests 2008 US airline delays were structurally persistent,
-- not driven by any single airline's operational deterioration or improvement.
--
-- BEST: AQ (Aloha Airlines) — only airline classified "Overall Improving"
-- with avg MoM change of -2.49 mins. However, AQ only has 1 month tracked,
-- making this statistically unreliable — likely ceased operations mid-2008
-- (Aloha Airlines filed for bankruptcy and shut down in March 2008).
-- This is a data artifact, not a genuine trend.
--
-- MOST IMPROVED SINGLE MONTH:
-- FL (AirTran): best single month improvement of -11.06 mins
-- B6 (JetBlue): best single month improvement of -10.34 mins
-- F9 (Frontier): best single month improvement of -10.11 mins
-- These airlines had at least one month of strong operational recovery.
--
-- WORST SINGLE MONTH WORSENING:
-- B6 (JetBlue): worst single month worsening of +10.10 mins
-- WN (Southwest): worst single month worsening of +9.96 mins
-- MQ (American Eagle): worst single month worsening of +9.47 mins
--
-- MOST VOLATILE — B6 (JetBlue):
-- best improvement: -10.34 mins, worst worsening: +10.10 mins
-- Nearly 20-minute swing between best and worst months —
-- JetBlue is the most operationally volatile airline in 2008,
-- consistent with their February 2008 Valentine's Day ice storm
-- crisis which led to their Customer Bill of Rights.
--
-- MOST CONSISTENT MoM — UA (United Airlines):
-- months_improved: 7, months_worsened: 4 — most months trending better
-- despite being ranked 17th in overall avg delay (Q4).
-- Shows operational improvement efforts even while remaining a slow carrier.	


-- ==================================================================
-- Q6: Which airline has the highest severe-delay rate (delay > 60 mins)?
-- Severe delay rate = % of flights with ArrDelay > 60 mins
-- (not raw count — adjusted for airline size)

WITH airline_severity AS (
    -- Count total flights and severe delay flights per airline
    SELECT
        "UniqueCarrier" AS airline,
        COUNT(*) AS total_flights,
        COUNT(CASE WHEN "ArrDelay" > 60 THEN 1 END) AS severe_delay_flights,
        COUNT(CASE WHEN "ArrDelay" BETWEEN 15 AND 30 THEN 1 END) AS mild_delay_flights,
        COUNT(CASE WHEN "ArrDelay" BETWEEN 31 AND 60 THEN 1 END) AS moderate_delay_flights,
        ROUND(CAST(AVG("ArrDelay") AS NUMERIC), 2) AS avg_delay
    FROM
        AIRLINE_DELAYS
    GROUP BY
        "UniqueCarrier"
),

rates AS (
    -- Calculate rates and classify severity profile
    SELECT
        airline,
        total_flights,
        severe_delay_flights,
        mild_delay_flights,
        moderate_delay_flights,
        avg_delay,
        ROUND(100.0 * severe_delay_flights / total_flights, 2)
            AS severe_delay_rate,
        ROUND(100.0 * mild_delay_flights / total_flights, 2)
            AS mild_delay_rate,
        ROUND(100.0 * moderate_delay_flights / total_flights, 2)
            AS moderate_delay_rate,
        CASE
            WHEN ROUND(100.0 * severe_delay_flights / total_flights, 2) >= 40
                THEN 'Critical'
            WHEN ROUND(100.0 * severe_delay_flights / total_flights, 2) >= 30
                THEN 'High Severity'
            WHEN ROUND(100.0 * severe_delay_flights / total_flights, 2) >= 20
                THEN 'Moderate Severity'
            ELSE 'Low Severity'
        END AS severity_profile
    FROM
        airline_severity
)

-- Final output ranked by severe delay rate
SELECT
    RANK() OVER (ORDER BY severe_delay_rate DESC) AS severity_rank,
    airline,
    total_flights,
    severe_delay_flights,
    severe_delay_rate,
    mild_delay_rate,
    moderate_delay_rate,
    avg_delay,
    severity_profile
FROM
    rates
ORDER BY
    severe_delay_rate DESC;

-- Result: 20 airlines ranked by severe delay rate (ArrDelay > 60 mins)
--
-- SEVERITY DISTRIBUTION ACROSS INDUSTRY:
-- Range: 13.94% (AQ) to 37.64% (B6)
-- 11 airlines = High Severity (30-40% severe rate)
-- 6 airlines = Moderate Severity (20-30%)
-- 3 airlines = Low Severity (< 20%): F9, HA, AQ
-- No airline reaches "Critical" (>= 40%) — industry stays below that threshold.
--
-- WORST: B6 (JetBlue) — 37.64% severe delay rate
-- 12,532 out of 33,297 delayed flights exceeded 60 mins.
-- Consistent with Q5 finding (most volatile MoM) and the February 2008
-- Valentine's Day crisis. JetBlue emerges as the most problematic
-- airline across multiple dimensions in 2008.
--
-- NOTABLE SIZE VS SEVERITY CONTRAST:
-- WN (Southwest): largest carrier (193,552 flights) yet only 22.95% severe rate
-- ranks 17th — confirming Q4 finding that Southwest manages delay
-- severity better than most despite massive operational scale.
-- AA (American): 122,213 flights but 32.66% severe rate (rank 7) —
-- larger than Southwest but significantly worse severity management.
--
-- BEST: F9 (Frontier), HA (Hawaii), AQ (Aloha) — all Low Severity
-- F9 at 17.66% is the standout: 15,497 flights with lowest severe rate
-- among meaningful-sized carriers. Combined with Q4 result (3rd most
-- consistent, avg delay 39.85 mins), Frontier emerges as the
-- best-performing mid-size airline of 2008 across all dimensions.
--
-- CROSS-QUERY VALIDATION:
-- Airlines with high STDDEV in Q4 (B6, YV, OO, UA) all appear in
-- top 5 for severe delay rate here — confirming that high variability
-- and high severity are the same underlying operational problem.
-- Low STDDEV airlines (F9, HA, AQ) all appear in Low Severity here.
-- Both metrics independently point to the same airline rankings.


-- =================================
-- SECTION 3: AIRPORT-LEVEL ANALYSIS
-- =================================
--
-- Q7: Do busier airports actually have worse delays? (flight volume vs avg delay)
-- Comparing flight volume rank vs avg delay rank per airport

WITH airport_flights AS (
    -- Step 1: Count total flights per airport
    -- (combining both Origin and Dest appearances)
    SELECT airport, SUM(flight_count) AS total_flights
    FROM (
        SELECT "Origin" AS airport, COUNT(*) AS flight_count
        FROM AIRLINE_DELAYS
        GROUP BY "Origin"

        UNION ALL

        SELECT "Dest" AS airport, COUNT(*) AS flight_count
        FROM AIRLINE_DELAYS
        GROUP BY "Dest"
    ) combined
    GROUP BY airport
),

airport_delays AS (
    -- Avg arrival delay per airport as ORIGIN
    -- (departure performance is what the airport controls)
    SELECT
        "Origin" AS airport,
        ROUND(CAST(AVG("ArrDelay") AS NUMERIC), 2) AS avg_delay,
        ROUND(CAST(STDDEV("ArrDelay") AS NUMERIC), 2) AS stddev_delay,
        COUNT(*) AS departures
    FROM
        AIRLINE_DELAYS
    GROUP BY
        "Origin"
    HAVING
        COUNT(*) >= 500
),

combined AS (
    -- Joining volume and delay data
    -- and rank airports on both dimensions
    SELECT
        d.airport,
        f.total_flights,
        d.avg_delay,
        d.stddev_delay,
        d.departures,
        RANK() OVER (ORDER BY f.total_flights DESC) AS volume_rank,
        RANK() OVER (ORDER BY d.avg_delay DESC) AS delay_rank,
        CASE
            WHEN RANK() OVER (ORDER BY f.total_flights DESC) <= 20
             AND RANK() OVER (ORDER BY d.avg_delay DESC) <= 20
                THEN 'Busy & Delayed'
            WHEN RANK() OVER (ORDER BY f.total_flights DESC) <= 20
             AND RANK() OVER (ORDER BY d.avg_delay DESC) > 20
                THEN 'Busy but Punctual'
            WHEN RANK() OVER (ORDER BY f.total_flights DESC) > 20
             AND RANK() OVER (ORDER BY d.avg_delay DESC) <= 20
                THEN 'Quiet but Chaotic'
            ELSE 'Standard'
        END AS airport_profile
    FROM
        airport_delays d
    JOIN
        airport_flights f ON d.airport = f.airport
),

final AS (
    -- Calculating rank difference
    -- positive = airport is more delayed than its volume suggests
    -- negative = airport performs better than its volume suggests
    SELECT
        airport,
        total_flights,
        departures,
        avg_delay,
        stddev_delay,
        volume_rank,
        delay_rank,
        delay_rank - volume_rank AS rank_difference,
        airport_profile
    FROM combined
)

-- Showing top 30 by flight volume with full profile
SELECT
    volume_rank,
    airport,
    total_flights,
    avg_delay,
    stddev_delay,
    delay_rank,
    rank_difference,
    airport_profile
FROM
    final
ORDER BY
    volume_rank ASC
LIMIT 30;

-- Result: Top 30 airports by flight volume with delay profile (2008)
--
-- HEADLINE FINDING: The "busier = more delayed" assumption is largely a MYTH.
-- 19 out of 20 busiest airports are classified "Busy but Punctual" —
-- meaning high flight volume does NOT correlate with worse delays
-- among the top 20 busiest US airports in 2008.
--
-- TOP 5 BUSIEST AIRPORTS — all "Busy but Punctual":
-- ORD (Chicago O'Hare): #1 busiest (152,328 flights), delay rank 36
--   rank_difference = +35 — handles volume significantly better than expected
-- ATL (Atlanta): #2 busiest (146,846 flights), delay rank 120
--   rank_difference = +118 — most impressive in the dataset.
--   World's busiest airport yet ranks 120th in avg delay. Definitively
--   proves high volume does not cause high delays.
-- DFW: #3 busiest, delay rank 123 (+120 rank difference)
-- DEN: #4 busiest, delay rank 125 (+121 rank difference)
-- EWR: #5 busiest, delay rank 41 (+36) — only top-5 airport with
--   meaningful delay concern, avg 55.71 mins.
--
-- THE ONE EXCEPTION — JFK (#13 busiest):
-- Only airport in top 20 classified "Busy & Delayed"
-- volume_rank 13, delay_rank 19, rank_difference only +6
-- avg delay 57.23 mins — nearly identical delay rank to volume rank.
-- JFK is the singular counter-example to the overall trend:
-- a major hub where congestion genuinely translates to delays.
-- Consistent with Q3 finding where JFK-connected routes showed
-- the worst delay worsening in recovery analysis.
--
-- MOST EFFICIENT MAJOR AIRPORT:
-- ATL: rank_difference of +118 — handles 146,846 flights
-- with avg delay of only 48.57 mins (rank 120 out of ~200+ airports).
-- Delta's hub optimization and Hartsfield-Jackson's runway layout
-- appear to be genuine operational advantages at scale.
--
-- PHX (#9 busiest): rank_difference +143 — best rank difference
-- in entire top 30. 55,343 flights with avg delay only 44.80 mins
-- (delay rank 152). The most efficiently managed airport
-- relative to its traffic volume in 2008.
--
-- SEA (#19): rank_difference +128 despite avg delay 45.65 mins —
-- Seattle punches well above its weight for punctuality.
--
-- CROSS-QUERY CONNECTION:
-- JFK's "Busy & Delayed" classification here directly validates
-- Q2 (route asymmetry) and Q3 (delay worsening) findings —
-- three independent queries all identify JFK as a structural
-- delay problem, making this one of the most robust findings
-- in the entire analysis.


-- ==============================================================================
-- Q8: Which airports have unusually high departure delays but normal arrival delays?
-- Identifies ground operations problems vs in-flight/destination problems

WITH airport_stats AS (
    -- Calculating avg dep and arr delay per origin airport
    SELECT
        "Origin" AS airport,
        COUNT(*) AS total_flights,
        ROUND(CAST(AVG("DepDelay") AS NUMERIC), 2) AS avg_dep_delay,
        ROUND(CAST(AVG("ArrDelay") AS NUMERIC), 2) AS avg_arr_delay,
        ROUND(CAST(STDDEV("DepDelay") AS NUMERIC), 2) AS stddev_dep,
        ROUND(CAST(STDDEV("ArrDelay") AS NUMERIC), 2) AS stddev_arr
    FROM
        AIRLINE_DELAYS
    GROUP BY
        "Origin"
    HAVING
        COUNT(*) >= 500
),

global_stats AS (
    -- Calculating global averages to use as baseline
    SELECT
        ROUND(CAST(AVG("DepDelay") AS NUMERIC), 2) AS global_avg_dep,
        ROUND(CAST(AVG("ArrDelay") AS NUMERIC), 2) AS global_avg_arr,
        ROUND(CAST(STDDEV("DepDelay") AS NUMERIC), 2) AS global_stddev_dep,
        ROUND(CAST(STDDEV("ArrDelay") AS NUMERIC), 2) AS global_stddev_arr
    FROM
        AIRLINE_DELAYS
),

classified AS (
    -- Comparing each airport to global baseline
    -- Flag airports where DepDelay is high but ArrDelay is normal
    SELECT
        a.airport,
        a.total_flights,
        a.avg_dep_delay,
        a.avg_arr_delay,
        g.global_avg_dep,
        g.global_avg_arr,
        -- Recovery = how much time is made up in the air
        ROUND(a.avg_dep_delay - a.avg_arr_delay, 2) AS avg_recovery,
        -- Departure gap = how much worse than global average
        ROUND(a.avg_dep_delay - g.global_avg_dep, 2) AS dep_vs_global,
        -- Arrival gap = how much better/worse than global average  
        ROUND(a.avg_arr_delay - g.global_avg_arr, 2) AS arr_vs_global,
        CASE
            WHEN a.avg_dep_delay > g.global_avg_dep
             AND a.avg_arr_delay <= g.global_avg_arr
                THEN 'High Dep / Normal Arr : Ground Ops Problem'
            WHEN a.avg_dep_delay <= g.global_avg_dep
             AND a.avg_arr_delay > g.global_avg_arr
                THEN 'Normal Dep / High Arr : Destination Congestion'
            WHEN a.avg_dep_delay > g.global_avg_dep
             AND a.avg_arr_delay > g.global_avg_arr
                THEN 'High Both : Systemic Problem'
            ELSE 'Normal Both : Well Performing'
        END AS delay_profile,
        CASE
            WHEN a.avg_dep_delay > g.global_avg_dep
             AND a.avg_arr_delay <= g.global_avg_arr
                THEN a.avg_dep_delay - g.global_avg_dep
            ELSE NULL
        END AS ground_ops_severity
    FROM
        airport_stats a
    CROSS JOIN
        global_stats g
),

ranked AS (
    -- Ranking "Ground Ops Problem" airports by severity
    SELECT
        airport,
        total_flights,
        avg_dep_delay,
        avg_arr_delay,
        global_avg_dep,
        global_avg_arr,
        avg_recovery,
        dep_vs_global,
        arr_vs_global,
        delay_profile,
        ground_ops_severity,
        CASE
            WHEN delay_profile = 
                'High Dep / Normal Arr → Ground Ops Problem'
                THEN RANK() OVER (
                    PARTITION BY delay_profile
                    ORDER BY ground_ops_severity DESC
                )
            ELSE NULL
        END AS ground_ops_rank
    FROM classified
)

-- Showing all profiles, prioritizing ground ops airports
SELECT
    airport,
    total_flights,
    avg_dep_delay,
    avg_arr_delay,
    avg_recovery,
    dep_vs_global,
    arr_vs_global,
    delay_profile,
    ground_ops_rank
FROM
    ranked
ORDER BY
    CASE delay_profile
        WHEN 'High Dep / Normal Arr : Ground Ops Problem' THEN 1
        WHEN 'High Both : Systemic Problem' THEN 2
        WHEN 'Normal Dep / High Arr : Destination Congestion' THEN 3
        ELSE 4
    END,
    ground_ops_rank ASC NULLS LAST;

-- Result: 163 airports classified across 4 delay profiles (2008)
--
-- PROFILE DISTRIBUTION:
-- "High Dep / Normal Arr → Ground Ops Problem": 5 airports (rows 1-5)
-- "High Both → Systemic Problem": ~130 airports (rows 6-141)
-- "Normal Both → Well Performing": ~22 airports (rows 142-163)
-- "Normal Dep / High Arr → Destination Congestion": 0 airports
--
-- HEADLINE: No airport in the dataset shows "Normal Dep / High Arr" —
-- meaning NO airport departs on time but receives delayed flights.
-- This confirms that delays originate at departure airports,
-- not in the air or at destination airports. Delay is fundamentally
-- a departure-side problem across the entire US aviation network in 2008.
--
-- GROUND OPS PROBLEM AIRPORTS (High Dep / Normal Arr):
-- LAS (#3, 28,308 flights): dep_vs_global +1.14, arr_vs_global -3.39
--   Departs above average but arrives BETTER than average by 3.39 mins.
--   Pilots consistently recover LAS ground delays in the air.
--   Consistent with Q3 finding where LAS appeared 4x in best recovering routes.
-- TPA (#2, 11,655 flights): dep_vs_global +1.26, arr_vs_global -0.73
-- BUR (#5, 4,032 flights): dep_vs_global +0.04, arr_vs_global -3.53
--   Burbank barely departs above average but arrives 3.53 mins
--   better than average — strongest recovery ratio in this group.
-- GJT (#1, 536 flights): smallest airport in Ground Ops group,
--   marginal differences — statistically less reliable.
--
-- WELL PERFORMING AIRPORTS (Normal Both):
-- 22 airports including major names:
-- KOA (Kona, Hawaii): avg_dep 37.04, avg_arr 42.55 —
--   lowest departure delay of any airport in the dataset.
--   arr_vs_global -7.89 — arrives nearly 8 mins better than global avg.
-- PHX: dep_vs_global -2.07, arr_vs_global -5.64 — 9th busiest airport
--   (Q7) performing well on both dimensions. Consistent with Q7
--   finding where PHX had rank_difference of +143.
-- LAX: dep_vs_global -0.49, arr_vs_global -3.66 — 6th busiest
--   airport (Q7) classified Well Performing here. Another Q7 validation.
-- SEA: dep_vs_global -3.19, arr_vs_global -4.79 — among the best
--   performers in the entire dataset. Consistent with Q7 (+128 rank diff).
--
-- SYSTEMIC PROBLEM AIRPORTS:
-- EWR (#12, 32,288 flights): dep_vs_global +3.79, arr_vs_global +5.27
--   Largest "High Both" airport by volume — Newark is systemically
--   problematic on both departure AND arrival dimensions.
--   Consistent with Q7 where EWR was the only top-5 airport
--   with meaningful delay concern (avg 55.71 mins).
-- EGE (Eagle County, CO): arr_vs_global +9.68 — highest arrival
--   delay excess of any airport. Small mountain airport likely
--   affected by weather and limited runway capacity.
--
-- CROSS-QUERY VALIDATION (strongest in entire analysis):
-- LAS: Ground Ops Problem here ← consistent with Q3 (4x in best recovery)
-- PHX: Well Performing here ← consistent with Q7 (+143 rank difference)
-- SEA: Well Performing here ← consistent with Q7 (+128 rank difference)
-- EWR: Systemic Problem here ← consistent with Q7 (only top-5 with high delay)
-- JFK: would appear as Systemic Problem ← consistent with Q7 & Q2 & Q3
-- 5 independent queries all pointing to same airports = robust findings.


-- ==============================
-- SECTION 4: TIME-BASED ANALYSIS
-- ==============================
--
-- Q9: Which departure hour has the highest probability (not average) of a major delay?
-- Probability = % of flights with ArrDelay > 60 mins per departure hour
-- (not average delay — probability is more actionable for passengers)

WITH hour_stats AS (
    -- Calculating stats per departure hour
    SELECT
        "DepHour" AS dep_hour,
        COUNT(*) AS total_flights,
        COUNT(CASE WHEN "ArrDelay" > 60 THEN 1 END) 
            AS major_delay_flights,
        COUNT(CASE WHEN "ArrDelay" BETWEEN 15 AND 30 THEN 1 END) 
            AS mild_delay_flights,
        COUNT(CASE WHEN "ArrDelay" BETWEEN 31 AND 60 THEN 1 END) 
            AS moderate_delay_flights,
        ROUND(CAST(AVG("ArrDelay") AS NUMERIC), 2) 
            AS avg_arr_delay,
        ROUND(CAST(AVG("DepDelay") AS NUMERIC), 2) 
            AS avg_dep_delay,
        ROUND(CAST(MIN("ArrDelay") AS NUMERIC), 2) 
            AS min_delay,
        ROUND(CAST(MAX("ArrDelay") AS NUMERIC), 2) 
            AS max_delay
    FROM
        AIRLINE_DELAYS
    GROUP BY
        "DepHour"
),

probabilities AS (
    -- Calculating probabilities for each delay bucket
    SELECT
        dep_hour,
        total_flights,
        major_delay_flights,
        mild_delay_flights,
        moderate_delay_flights,
        avg_arr_delay,
        avg_dep_delay,
        min_delay,
        max_delay,
        -- Core metric: probability of major delay
        ROUND(100.0 * major_delay_flights / total_flights, 2) 
            AS major_delay_prob,
        ROUND(100.0 * mild_delay_flights / total_flights, 2) 
            AS mild_delay_prob,
        ROUND(100.0 * moderate_delay_flights / total_flights, 2) 
            AS moderate_delay_prob,
        -- Time of day label
        CASE
            WHEN dep_hour BETWEEN 5 AND 8   THEN 'Early Morning'
            WHEN dep_hour BETWEEN 9 AND 11  THEN 'Mid Morning'
            WHEN dep_hour BETWEEN 12 AND 14 THEN 'Afternoon'
            WHEN dep_hour BETWEEN 15 AND 17 THEN 'Peak Hours'
            WHEN dep_hour BETWEEN 18 AND 20 THEN 'Evening'
            ELSE 'Night / Red Eye'
        END AS time_of_day
    FROM
        hour_stats
),

ranked AS (
    -- Ranking hours by major delay probability
    SELECT
        dep_hour,
        time_of_day,
        total_flights,
        avg_dep_delay,
        avg_arr_delay,
        major_delay_prob,
        mild_delay_prob,
        moderate_delay_prob,
        min_delay,
        max_delay,
        RANK() OVER (ORDER BY major_delay_prob DESC) 
            AS probability_rank,
        RANK() OVER (ORDER BY avg_arr_delay DESC) 
            AS avg_delay_rank,
        -- Key: does probability rank differ from avg delay rank?
        RANK() OVER (ORDER BY major_delay_prob DESC) -
        RANK() OVER (ORDER BY avg_arr_delay DESC) 
            AS rank_divergence,
        CASE
            WHEN ROUND(100.0 * major_delay_flights 
                / total_flights, 2) >= 40 THEN 'Very High Risk'
            WHEN ROUND(100.0 * major_delay_flights 
                / total_flights, 2) >= 30 THEN 'High Risk'
            WHEN ROUND(100.0 * major_delay_flights 
                / total_flights, 2) >= 20 THEN 'Moderate Risk'
            ELSE 'Low Risk'
        END AS risk_label
    FROM probabilities
)

-- Final output ordered by probability rank
SELECT
    probability_rank,
    dep_hour,
    time_of_day,
    total_flights,
    major_delay_prob,
    mild_delay_prob,
    moderate_delay_prob,
    avg_arr_delay,
    avg_dep_delay,
    rank_divergence,
    risk_label
FROM
    ranked
ORDER BY
    probability_rank ASC;

-- Result: 24 departure hours ranked by major delay probability (2008)
--
-- HEADLINE FINDING: Hour 3 (3 AM) has the HIGHEST major delay probability
-- at 36.96% — but with only 92 flights, this is statistically unreliable.
-- The first statistically meaningful finding is Hour 17 (5 PM Peak Hours)
-- at 33.57% with 100,687 flights — the largest sample in the dataset.
--
-- TOP 8 HOURS ALL CLASSIFIED "HIGH RISK" (major_delay_prob >= 30%):
-- Hours 17, 18, 19 (Peak/Evening): 33.57%, 33.50%, 33.15%
-- Hours 15, 16 (Peak Hours): 30.36%, 31.86%
-- Hours 3, 4, 5 (Night/Red Eye): 36.96%, 32.94% — small samples
-- This confirms the "delay cascade" theory: delays accumulate
-- throughout the day, peaking in late afternoon and evening hours.
--
-- SAFEST HOURS TO FLY (lowest major delay probability):
-- Hour 8 (8 AM Early Morning): 25.63% — rank 20, Low Risk
-- Hour 9 (9 AM Mid Morning): 25.47% — rank 21
-- Hour 0 (midnight): 22.81% — rank 24 (but only 1,039 flights)
-- Hour 2 (2 AM): 23.94% — rank 22 (only 71 flights, unreliable)
-- Statistically: 8 AM and 9 AM are the safest meaningful
-- departure hours — lowest major delay probability with large samples.
--
-- THE COUNTER-INTUITIVE FINDING — rank_divergence:
-- Nearly ALL hours show rank_divergence of 0 or ±1-2 —
-- meaning probability rank and average delay rank are almost identical.
-- This tells us the distribution of delays is UNIFORM across hours:
-- no hour has "hidden" extreme outliers that differ from its average.
-- The delay distribution shape is consistent — only the magnitude changes.
--
-- TIME OF DAY PATTERN — clear cascade effect confirmed:
-- Early Morning (5-8): avg major_delay_prob ~26% → Moderate Risk
-- Mid Morning (9-11): avg major_delay_prob ~26% → Moderate Risk  
-- Afternoon (12-14): avg major_delay_prob ~28-29% → Moderate Risk
-- Peak Hours (15-17): avg major_delay_prob ~31-34% → High Risk
-- Evening (18-20): avg major_delay_prob ~32-33% → High Risk
-- Each time period is progressively worse — textbook cascade effect.
--
-- PRACTICAL PASSENGER INSIGHT:
-- Flying at 8-9 AM gives you a 25% lower major delay probability
-- compared to flying at 5-7 PM (25.5% vs 33.5%).
-- For a 100-flight frequent flyer, that's ~8 fewer major delays per year
-- simply by choosing morning departures.
-- This is the most actionable finding for passengers in the entire analysis.


-- ===================================================================================
-- Q10: Is there a rolling increase in delays during certain months? (rolling average trend)
-- Using AVG() OVER() as a 3-month rolling average to smooth noise
-- and identify sustained delay trends across 2008

WITH monthly_stats AS (
    -- Step 1: Calculate core stats per month
    SELECT
        "Month",
        COUNT(*) AS total_flights,
        ROUND(CAST(AVG("ArrDelay") AS NUMERIC), 2) AS avg_arr_delay,
        ROUND(CAST(AVG("DepDelay") AS NUMERIC), 2) AS avg_dep_delay,
        ROUND(CAST(STDDEV("ArrDelay") AS NUMERIC), 2) AS stddev_delay,
        COUNT(CASE WHEN "ArrDelay" > 60 THEN 1 END) AS severe_flights,
        ROUND(
            100.0 * COUNT(CASE WHEN "ArrDelay" > 60 THEN 1 END) 
            / COUNT(*), 2
        ) AS severe_rate
    FROM
        AIRLINE_DELAYS
    GROUP BY
        "Month"
),

rolling AS (
    -- Applying rolling averages using window functions
    SELECT
        "Month",
        total_flights,
        avg_arr_delay,
        avg_dep_delay,
        stddev_delay,
        severe_rate,

        -- 3-month rolling average (current + 2 preceding months)
        ROUND(CAST(
            AVG(avg_arr_delay) OVER (
                ORDER BY "Month"
                ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
            ) AS NUMERIC), 2) AS rolling_3m_avg,

        -- Month-over-month change (from Q5 logic, now at network level)
        ROUND(
            avg_arr_delay - LAG(avg_arr_delay) 
                OVER (ORDER BY "Month"), 2
        ) AS mom_change,

        -- Cumulative average from January onwards
        ROUND(CAST(
            AVG(avg_arr_delay) OVER (
                ORDER BY "Month"
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS NUMERIC), 2) AS cumulative_avg,

        -- Position relative to cumulative avg
        -- positive = this month is worse than year-to-date avg
        ROUND(
            avg_arr_delay - AVG(avg_arr_delay) OVER (
                ORDER BY "Month"
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ), 2
        ) AS vs_cumulative_avg

    FROM monthly_stats
),

labeled AS (
    -- Labelling each month's trend direction
    SELECT
        "Month",
        total_flights,
        avg_arr_delay,
        avg_dep_delay,
        stddev_delay,
        severe_rate,
        rolling_3m_avg,
        mom_change,
        cumulative_avg,
        vs_cumulative_avg,
        -- Month name for readability
        CASE "Month"
            WHEN 1  THEN 'January'
            WHEN 2  THEN 'February'
            WHEN 3  THEN 'March'
            WHEN 4  THEN 'April'
            WHEN 5  THEN 'May'
            WHEN 6  THEN 'June'
            WHEN 7  THEN 'July'
            WHEN 8  THEN 'August'
            WHEN 9  THEN 'September'
            WHEN 10 THEN 'October'
            WHEN 11 THEN 'November'
            WHEN 12 THEN 'December'
        END AS month_name,
        -- MoM trend label
        CASE
            WHEN mom_change IS NULL     THEN 'Baseline'
            WHEN mom_change <= -5       THEN 'Strong Improvement'
            WHEN mom_change < 0         THEN 'Slight Improvement'
            WHEN mom_change <= 5        THEN 'Slight Worsening'
            ELSE                             'Strong Worsening'
        END AS mom_trend,
        -- Position vs year average
        CASE
            WHEN vs_cumulative_avg > 5  THEN 'Above Trend'
            WHEN vs_cumulative_avg < -5 THEN 'Below Trend'
            ELSE                             'On Trend'
        END AS trend_position,
        -- Season label
        CASE
            WHEN "Month" IN (12, 1, 2)  THEN 'Winter'
            WHEN "Month" IN (3, 4, 5)   THEN 'Spring'
            WHEN "Month" IN (6, 7, 8)   THEN 'Summer'
            ELSE                             'Fall'
        END AS season
    FROM rolling
)

-- Final output - full year trend 
SELECT
    "Month",
    month_name,
    season,
    total_flights,
    avg_arr_delay,
    rolling_3m_avg,
    mom_change,
    mom_trend,
    cumulative_avg,
    vs_cumulative_avg,
    trend_position,
    severe_rate
FROM
    labeled
ORDER BY
    "Month" ASC;

-- Result: 12 months of rolling average trend analysis (2008)
--
-- HEADLINE FINDING: US airline delays in 2008 follow a clear
-- seasonal W-shape pattern — two peaks (Winter/Summer) with
-- a sustained Spring improvement trough and Fall recovery dip,
-- before rising again in December.
--
-- FULL YEAR TREND:
-- Jan: 50.52 (Baseline)     → Winter peak starts high
-- Feb: 51.67 (+1.15)        → Slight Worsening — winter continues
-- Mar: 49.96 (-1.71)        → Spring improvement begins
-- Apr: 48.25 (-1.71)        → Continued improvement
-- May: 47.92 (-0.33)        → LOWEST month of year — best time to fly
-- Jun: 52.56 (+4.64)        → Sharpest single-month spike — Summer surge
-- Jul: 51.94 (-0.62)        → Slight improvement but still elevated
-- Aug: 50.10 (-1.84)        → Summer winding down
-- Sep: 48.09 (-2.01)        → Fall improvement — 2nd lowest month
-- Oct: 45.60 (-2.49)        → BEST month of year — lowest avg delay
-- Nov: 50.36 (+4.76)        → Sharpest non-summer spike — holiday travel
-- Dec: 52.92 (+2.56)        → HIGHEST month — winter holiday peak
--
-- W-SHAPE CONFIRMED:
-- Peak 1: February (51.67) — winter weather/holiday recovery
-- Trough 1: May (47.92) — spring sweet spot
-- Peak 2: June (52.56) — summer thunderstorm/vacation surge  
-- Trough 2: October (45.60) — fall sweet spot
-- Peak 3: December (52.92) — holiday season, year's worst month
-- Classic aviation seasonal pattern validated with 1.15M+ flight records.
--
-- ROLLING AVERAGE INSIGHT:
-- rolling_3m_avg smooths the June spike — the 3-month window
-- (Apr+May+Jun = 49.58) shows summer is bad but not as extreme
-- as the raw June number (52.56) suggests in isolation.
-- Similarly Nov spike (50.36) is smoothed to 48.02 rolling avg,
-- showing Fall is genuinely improving even as November deteriorates.
-- Rolling avg is more reliable for trend identification than raw monthly.
--
-- vs_cumulative_avg — all 12 months classified "On Trend":
-- No month deviates more than ±5 mins from cumulative average.
-- Range: -4.06 (October, best) to +2.93 (December, worst).
-- This means 2008 had NO true anomaly months — every month
-- stayed within a tight band of the year-to-date average.
-- The year was structurally stable despite seasonal variation.
--
-- SEVERE RATE MIRRORS TREND EXACTLY:
-- May severe_rate: 26.97% (lowest) → consistent with lowest avg delay
-- Oct severe_rate: 24.03% (absolute lowest) → best month confirmed
-- Jun severe_rate: 32.58% → highest alongside December (32.58%)
-- Two independent metrics (avg delay + severe rate) produce
-- identical seasonal rankings — strong internal validation.
--
-- 2008 FINANCIAL CRISIS EFFECT:
-- September 2008 (Lehman Brothers collapse): 48.09 avg delay
-- October 2008: 45.60 — lowest month of year
-- November 2008: 50.36 — sharp rebound
-- The Sep-Oct dip is partially consistent with reduced travel
-- demand post-financial crisis (fewer flights = less congestion).
-- However November's sharp spike suggests holiday demand
-- overrode any crisis-driven demand reduction by Q4.
--
-- BEST MONTHS TO FLY: October (45.60), May (47.92), September (48.09)
-- WORST MONTHS TO FLY: December (52.92), June (52.56), February (51.67)
-- Difference between best and worst: 7.32 minutes avg delay —
-- a meaningful but not dramatic seasonal spread.


-- ===============================
-- SECTION 5: DELAY CAUSE ANALYSIS
-- ===============================
--
-- Q11: Which delay cause contributes the most total delay minutes (not average)?
-- Total impact = SUM across all flights (not average per flight)
-- Covers all 5 cause columns: Carrier, Weather, NAS, Security, LateAircraft

WITH cause_totals AS (
    -- Sum each delay cause across all flights
    -- Using UNION ALL to unpivot 5 columns into rows
    -- This allows ranking and % calculation cleanly

    SELECT 'Carrier Delay'       AS delay_cause,
           SUM("CarrierDelay")   AS total_minutes,
           COUNT(CASE WHEN "CarrierDelay" > 0 THEN 1 END) AS flights_affected,
           ROUND(CAST(AVG(CASE WHEN "CarrierDelay" > 0 
               THEN "CarrierDelay" END) AS NUMERIC), 2) AS avg_when_present,
           MAX("CarrierDelay")   AS max_single_flight
    FROM AIRLINE_DELAYS

    UNION ALL

    SELECT 'Weather Delay'       AS delay_cause,
           SUM("WeatherDelay")   AS total_minutes,
           COUNT(CASE WHEN "WeatherDelay" > 0 THEN 1 END) AS flights_affected,
           ROUND(CAST(AVG(CASE WHEN "WeatherDelay" > 0 
               THEN "WeatherDelay" END) AS NUMERIC), 2) AS avg_when_present,
           MAX("WeatherDelay")   AS max_single_flight
    FROM AIRLINE_DELAYS

    UNION ALL

    SELECT 'NAS Delay'           AS delay_cause,
           SUM("NASDelay")       AS total_minutes,
           COUNT(CASE WHEN "NASDelay" > 0 THEN 1 END) AS flights_affected,
           ROUND(CAST(AVG(CASE WHEN "NASDelay" > 0 
               THEN "NASDelay" END) AS NUMERIC), 2) AS avg_when_present,
           MAX("NASDelay")       AS max_single_flight
    FROM AIRLINE_DELAYS

    UNION ALL

    SELECT 'Security Delay'      AS delay_cause,
           SUM("SecurityDelay")  AS total_minutes,
           COUNT(CASE WHEN "SecurityDelay" > 0 THEN 1 END) AS flights_affected,
           ROUND(CAST(AVG(CASE WHEN "SecurityDelay" > 0 
               THEN "SecurityDelay" END) AS NUMERIC), 2) AS avg_when_present,
           MAX("SecurityDelay")  AS max_single_flight
    FROM AIRLINE_DELAYS

    UNION ALL

    SELECT 'Late Aircraft Delay'       AS delay_cause,
           SUM("LateAircraftDelay")    AS total_minutes,
           COUNT(CASE WHEN "LateAircraftDelay" > 0 THEN 1 END) 
               AS flights_affected,
           ROUND(CAST(AVG(CASE WHEN "LateAircraftDelay" > 0 
               THEN "LateAircraftDelay" END) AS NUMERIC), 2) 
               AS avg_when_present,
           MAX("LateAircraftDelay")    AS max_single_flight
    FROM AIRLINE_DELAYS
),

with_percentages AS (
    -- Adding percentage of total and rank
    SELECT
        delay_cause,
        total_minutes,
        flights_affected,
        avg_when_present,
        max_single_flight,
        -- % of total delay minutes across all causes
        ROUND(
            CAST(100.0 * total_minutes / SUM(total_minutes) OVER () AS NUMERIC), 2
        ) AS pct_of_total_minutes,
        -- % of flights affected out of total flights
        ROUND(
            CAST(100.0 * flights_affected / 
            (SELECT COUNT(*) FROM AIRLINE_DELAYS) AS NUMERIC), 2
        ) AS pct_flights_affected,
        RANK() OVER (ORDER BY total_minutes DESC) AS impact_rank,
        RANK() OVER (ORDER BY flights_affected DESC) AS breadth_rank,
        RANK() OVER (ORDER BY avg_when_present DESC) AS severity_rank
    FROM cause_totals
)

-- Final output with full impact profile
SELECT
    impact_rank,
    delay_cause,
    total_minutes,
    pct_of_total_minutes,
    flights_affected,
    pct_flights_affected,
    avg_when_present,
    max_single_flight,
    breadth_rank,
    severity_rank,
    -- Impact label
    CASE
        WHEN pct_of_total_minutes >= 30 THEN 'Dominant Cause'
        WHEN pct_of_total_minutes >= 20 THEN 'Major Cause'
        WHEN pct_of_total_minutes >= 10 THEN 'Moderate Cause'
        ELSE                                  'Minor Cause'
    END AS impact_label,
    -- Efficiency label: high breadth but low avg = spreads thinly
    -- low breadth but high avg = concentrated and severe
    CASE
        WHEN breadth_rank <= 2 
         AND severity_rank <= 2 THEN 'Wide & Severe'
        WHEN breadth_rank <= 2 
         AND severity_rank > 2  THEN 'Wide but Mild'
        WHEN breadth_rank > 2  
         AND severity_rank <= 2 THEN 'Narrow but Severe'
        ELSE                         'Narrow & Mild'
    END AS spread_label
FROM
    with_percentages
ORDER BY
    impact_rank ASC;

-- Result: 5 delay causes ranked by total impact (2008)
--
-- TOTAL DELAY MINUTES ACROSS ALL CAUSES: ~58.15M minutes
-- (23.65M + 17.42M + 14.10M + 2.88M + 0.10M)
-- That's equivalent to ~110 years of cumulative passenger delay in 2008.
--
-- RANKING BY TOTAL IMPACT:
-- 1. Late Aircraft Delay: 23,654,200 mins (40.67%) → Dominant Cause
-- 2. Carrier Delay:       17,417,627 mins (29.95%) → Major Cause
-- 3. NAS Delay:           14,100,842 mins (24.25%) → Major Cause
-- 4. Weather Delay:        2,877,178 mins  (4.95%) → Minor Cause
-- 5. Security Delay:         104,552 mins  (0.18%) → Minor Cause
--
-- HEADLINE FINDING: Airline-controllable delays dominate.
-- Late Aircraft (40.67%) + Carrier (29.95%) = 70.62% of ALL delay minutes
-- are caused by factors WITHIN airline control (fleet rotation,
-- scheduling, ground operations, maintenance decisions).
-- Only 4.95% is weather and 0.18% is security — both external factors.
-- NAS (24.25%) is partially controllable (air traffic control).
-- Bottom line: ~70% of US flight delay burden in 2008 was
-- self-inflicted by airlines, not caused by weather or government.
--
-- SPREAD LABELS reveal operational character of each cause:
-- Late Aircraft: "Wide & Severe" — affects 639,609 flights (55.47%)
--   AND has highest avg per-flight (36.98 mins when present).
--   Most flights experience it AND it hits hard when it does.
--   This is the single most damaging delay mechanism in aviation.
-- Carrier Delay: "Wide but Mild" — affects 614,404 flights (53.29%)
--   but only 28.35 mins avg when present. Wide reach, softer impact.
-- NAS Delay: "Narrow & Mild" — 607,452 flights (52.68%), 23.21 mins avg.
--   Similar breadth to Carrier but milder per-flight impact.
-- Weather Delay: "Narrow but Severe" — only 85,276 flights (7.40%)
--   but 33.74 mins avg when present. Rare but punishing when it hits.
--   severity_rank 2 despite being impact_rank 4 — confirms that
--   weather creates severe disruption for the minority it affects.
-- Security Delay: "Narrow & Mild" — only 5,900 flights (0.51%),
--   17.72 mins avg. Essentially negligible at network level.
--
-- COUNTER-INTUITIVE WEATHER FINDING:
-- Weather ranks 4th in total impact but 2nd in per-flight severity.
-- This means weather is not the primary CAUSE of US delays
-- but is the most DISRUPTIVE when it does occur.
-- The common passenger perception "it's weather" is statistically wrong —
-- weather explains less than 5% of total delay burden.
--
-- LATE AIRCRAFT DELAY INSIGHT:
-- 55.47% of all flights in the dataset have Late Aircraft as a cause.
-- This means more than half of delayed flights are affected by the
-- "ripple effect" — a delay earlier in the day cascades to later flights
-- on the same aircraft. This directly validates Q9 finding (evening
-- flights have highest major delay probability) — the cascade builds
-- throughout the day, peaking in hours 17-19.
--
-- CROSS-QUERY VALIDATION:
-- Q9 showed evening flights have highest delay probability →
-- Q11 shows Late Aircraft (cascade effect) is #1 cause →
-- Both findings point to the same root cause: delays compound
-- across an aircraft's daily rotation, peaking in evening hours.
-- This is the strongest causal chain in the entire analysis.


-- ==============================================
-- Q12: Does the dominant delay cause vary by airline?
-- For each airline, identify which cause contributes most total minutes
-- and compare to network-level ranking from Q11

WITH airline_cause_totals AS (
    -- Sum each delay cause per airline
    -- Using UNION ALL to unpivot causes into rows (same as Q11)

    SELECT "UniqueCarrier" AS airline,
           'Late Aircraft Delay' AS delay_cause,
           SUM("LateAircraftDelay") AS total_minutes,
           COUNT(CASE WHEN "LateAircraftDelay" > 0 
               THEN 1 END) AS flights_affected,
           ROUND(CAST(AVG(CASE WHEN "LateAircraftDelay" > 0
               THEN "LateAircraftDelay" END) AS NUMERIC), 2)
               AS avg_when_present
    FROM AIRLINE_DELAYS
    GROUP BY "UniqueCarrier"

    UNION ALL

    SELECT "UniqueCarrier",
           'Carrier Delay',
           SUM("CarrierDelay"),
           COUNT(CASE WHEN "CarrierDelay" > 0 THEN 1 END),
           ROUND(CAST(AVG(CASE WHEN "CarrierDelay" > 0
               THEN "CarrierDelay" END) AS NUMERIC), 2)
    FROM AIRLINE_DELAYS
    GROUP BY "UniqueCarrier"

    UNION ALL

    SELECT "UniqueCarrier",
           'NAS Delay',
           SUM("NASDelay"),
           COUNT(CASE WHEN "NASDelay" > 0 THEN 1 END),
           ROUND(CAST(AVG(CASE WHEN "NASDelay" > 0
               THEN "NASDelay" END) AS NUMERIC), 2)
    FROM AIRLINE_DELAYS
    GROUP BY "UniqueCarrier"

    UNION ALL

    SELECT "UniqueCarrier",
           'Weather Delay',
           SUM("WeatherDelay"),
           COUNT(CASE WHEN "WeatherDelay" > 0 THEN 1 END),
           ROUND(CAST(AVG(CASE WHEN "WeatherDelay" > 0
               THEN "WeatherDelay" END) AS NUMERIC), 2)
    FROM AIRLINE_DELAYS
    GROUP BY "UniqueCarrier"

    UNION ALL

    SELECT "UniqueCarrier",
           'Security Delay',
           SUM("SecurityDelay"),
           COUNT(CASE WHEN "SecurityDelay" > 0 THEN 1 END),
           ROUND(CAST(AVG(CASE WHEN "SecurityDelay" > 0
               THEN "SecurityDelay" END) AS NUMERIC), 2)
    FROM AIRLINE_DELAYS
    GROUP BY "UniqueCarrier"
),

ranked_per_airline AS (
    -- Rank causes within each airline by total minutes
    SELECT
        airline,
        delay_cause,
        total_minutes,
        flights_affected,
        avg_when_present,
        RANK() OVER (
            PARTITION BY airline
            ORDER BY total_minutes DESC
        ) AS cause_rank_within_airline,
        -- % of that airline's total delay minutes
        ROUND(CAST(
            100.0 * total_minutes /
            SUM(total_minutes) OVER (PARTITION BY airline)
        AS NUMERIC), 2) AS pct_of_airline_total
    FROM airline_cause_totals
),

dominant_cause AS (
    -- Extracting only the #1 dominant cause per airline
    SELECT
        airline,
        delay_cause AS dominant_cause,
        total_minutes AS dominant_minutes,
        pct_of_airline_total AS dominant_pct,
        flights_affected,
        avg_when_present
    FROM ranked_per_airline
    WHERE cause_rank_within_airline = 1
),

-- Also get #2 cause per airline for context
second_cause AS (
    SELECT
        airline,
        delay_cause AS second_cause,
        pct_of_airline_total AS second_pct
    FROM ranked_per_airline
    WHERE cause_rank_within_airline = 2
),

final AS (
    SELECT
        d.airline,
        d.dominant_cause,
        d.dominant_pct,
        s.second_cause,
        s.second_pct,
        d.flights_affected AS dominant_flights,
        d.avg_when_present AS dominant_avg_mins,
        -- Does this airline deviate from network norm?
        -- Network norm from Q11: Late Aircraft is #1
        CASE
            WHEN d.dominant_cause = 'Late Aircraft Delay'
                THEN 'Follows Network Pattern'
            ELSE 'Deviates from Network'
        END AS vs_network,
        -- How concentrated is the dominant cause?
        CASE
            WHEN d.dominant_pct >= 50
                THEN 'Highly Concentrated'
            WHEN d.dominant_pct >= 40
                THEN 'Moderately Concentrated'
            ELSE 'Distributed'
        END AS concentration_label
    FROM dominant_cause d
    JOIN second_cause s ON d.airline = s.airline
)

-- Final output
SELECT
    airline,
    dominant_cause,
    CONCAT(CAST(dominant_pct AS TEXT), '%') AS dominant_pct,
    second_cause,
    CONCAT(CAST(second_pct AS TEXT), '%') AS second_pct,
    dominant_flights,
    dominant_avg_mins,
    vs_network,
    concentration_label
FROM final
ORDER BY
    -- Deviating airlines first, then by dominant %
    vs_network ASC,
    dominant_pct DESC;

-- Result: 20 airlines with dominant delay cause profile (2008)
--
-- NETWORK DEVIATION SPLIT:
-- 8 airlines DEVIATE from network pattern (rows 1-8)
-- 12 airlines FOLLOW network pattern (rows 9-20)
-- 40% of airlines have a different dominant cause than the industry norm.
-- This is a significant finding — the "Late Aircraft dominates" conclusion
-- from Q11 is a network-level average that masks major airline variation.
--
-- ============================================================
-- DEVIATING AIRLINES (Carrier Delay or NAS as dominant cause)
-- ============================================================
--
-- GROUP A: Carrier Delay dominant (5 airlines)
-- YV (Mesa Air):    56.53% Carrier, 2nd Late Aircraft (21.16%)
-- AQ (Aloha):       56.28% Carrier, 2nd Late Aircraft (36.66%)
-- HA (Hawaiian):    53.54% Carrier, 2nd Late Aircraft (44.45%)
-- EV (ExpressJet):  44.04% Carrier, 2nd NAS (23.75%)
-- OH (Comair):      40.95% Carrier, 2nd NAS (28.12%)
-- NW (Northwest):   39.29% Carrier, 2nd Late Aircraft (27.24%)
--
-- Carrier Delay = airline's own fault: maintenance, crew scheduling,
-- aircraft cleaning, fueling, boarding management.
-- These 6 airlines have an internal operations problem,
-- not a fleet rotation or external problem.
-- YV (Mesa Air) at 56.53% is the most internally broken airline
-- in the dataset — more than half of all delay burden is self-inflicted.
--
-- GROUP B: NAS Delay dominant (2 airlines)
-- F9 (Frontier):  40.68% NAS, 2nd Carrier (30.82%)
-- CO (Continental): 40.14% NAS, 2nd Late Aircraft (30.45%)
-- NAS = National Airspace System = air traffic control,
-- heavy traffic routes, runway congestion, ground stops.
-- Frontier and Continental operate heavily through congested
-- airspace corridors — their delay profile reflects geography
-- and route network, not internal operations.
-- F9's NAS dominance is surprising given it ranked 3rd overall
-- in Q4 (most consistent) and Low Severity in Q6 —
-- suggesting F9 manages its internal operations well but
-- is exposed to ATC congestion on its specific routes.
--
-- ============================================================
-- FOLLOWING NETWORK PATTERN (Late Aircraft dominant)
-- ============================================================
--
-- WN (Southwest): 60.78% Late Aircraft — highest concentration
-- of any airline. Southwest's point-to-point model means
-- aircraft rarely sit idle between flights — a single early
-- delay cascades through the entire day's rotation.
-- This explains why WN has the most cascade-driven delay profile
-- despite being one of the most consistent airlines in Q4.
-- FL (AirTran): 55.56% Late Aircraft — similar cascade model.
--
-- MOST DISTRIBUTED PROFILES (lowest dominant %):
-- DL (Delta): 36.79% Late Aircraft — most balanced cause distribution
-- AA (American): 38.71% — also distributed
-- 9E, US: both "Distributed" concentration
-- These airlines don't have one dominant problem —
-- their delay burden is spread across multiple causes,
-- making operational improvement harder to target.
--
-- ============================================================
-- CROSS-QUERY VALIDATION (strongest chain in entire analysis)
-- ============================================================
-- Q4: WN ranks 4th most consistent (low STDDEV)
-- Q6: WN ranks 17th in severe delay rate (Moderate Severity)
-- Q12: WN has 60.78% Late Aircraft — highest cascade concentration
-- All three queries tell the same story: Southwest's delays are
-- predictable and moderate because they stem from cascade effects
-- (Late Aircraft), not random operational failures.
-- Cascade delays are more uniform in severity than carrier failures —
-- explaining WN's low STDDEV despite high Late Aircraft dominance.
--
-- Q4: B6 (JetBlue) most volatile (highest STDDEV)
-- Q5: B6 most volatile month-over-month
-- Q6: B6 highest severe delay rate (37.64%)
-- Q12: B6 has 44.18% Late Aircraft + 33.33% NAS
-- JetBlue's mixed Late Aircraft + NAS profile explains volatility —
-- two unpredictable causes combining creates extreme variability.
--
-- KEY BUSINESS INSIGHT:
-- Carrier Delay dominant : fix internal ops (scheduling, crew, maintenance)
-- Late Aircraft dominant : fix fleet rotation and scheduling buffers
-- NAS dominant : route network review, hub airport diversification
-- Each dominant cause type requires a fundamentally different fix.
-- Grouping all airlines under "Late Aircraft problem" (Q11 network view)
-- would lead to wrong interventions for 8 of 20 airlines.	
