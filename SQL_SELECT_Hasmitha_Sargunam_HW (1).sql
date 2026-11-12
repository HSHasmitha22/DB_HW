/*
====================================================================================================
SQL SELECT HW - dvdrental database (PostgreSQL)
Author: Hasmitha Sargunam
Every task is solved three ways: JOIN, SUBQUERY and CTE. No window functions are used.
Schema name (public) is written before every table. No IDs are hardcoded (lookups go by name).
Results show names and values only, IDs are used inside the queries to join and group.
Tested on PostgreSQL 16 against the provided dvdrental database. All queries run without errors.
====================================================================================================

----------------------------------------------------------------------------------------------------
DATABASE ANALYSIS (what the tables are used for)
----------------------------------------------------------------------------------------------------
Transactional data (rows are created by business events):
    rental, payment (partitioned by payment_date, Jan-Jun 2017), inventory (copies of films in stores)
Reference data (descriptive, rarely changes):
    film, actor, category, language, customer, staff, store, address, city, country
Connection (bridge) tables for many-to-many links:
    film_actor (film <-> actor), film_category (film <-> category)
Revenue path: payment -> rental -> inventory -> store (a payment knows the staff member and rental,
and the rented copy in inventory knows which store it belongs to).

----------------------------------------------------------------------------------------------------
GENERAL ASSUMPTIONS
----------------------------------------------------------------------------------------------------
A1. "Rate more than 1" means film.rental_rate > 1.
A2. "Released between 2017 and 2019" is inclusive of both years and uses film.release_year.
A3. A store's revenue is the sum of payment.amount for rentals of copies that belong to that store
    (payment -> rental -> inventory.store_id). Dates are always taken from payment.payment_date.
A4. "After March 2017 (since April)" means payment_date >= 2017-04-01 with no upper limit.
    Filters on dates use range conditions (not EXTRACT) so partition pruning and indexes can work.
A5. The store address is address and address2 joined into one column. A NULL or empty address2 is skipped
    so there is no trailing space. The store table has no name, so the address identifies the store.
A6. "Number of movies" counts a film once per actor because film_actor has one row per film and actor.
A7. Ties in "top N" tasks (Part 1 task 3 and Part 2 task 2): every row tied for 5th place is kept, so the result
    can have more than 5 rows. A row is in the top 5 when fewer than 5 rows have a strictly higher count.
    LIMIT is not used for these tasks, because it would cut tied rows at an arbitrary place.
A8. Part 3 lists every actor (V1) and every pair of sequential films (V2), longest inactivity first.
    Nothing is cut off, so the actors with the longest breaks are simply at the top.
A9. Rating to expected audience age uses the Motion Picture Association (MPA) system:
        G = all ages, PG = 8+ (parental guidance), PG-13 = 13+, R = 17+ (younger with an adult), NC-17 = 18+.
A10. Current year for Part 3 V1 comes from CURRENT_DATE, so the V1 numbers grow every year.
A11. Actors without any film: V1 still lists them (years_inactive is NULL, sorted last). V2 has no row for an
    actor with fewer than two films, because there is no pair of sequential films. In this database every actor
    has films.
A12. Part 2 task 1 (top 3 staff): there is no tie for 3rd place in this data (40,077.97 against 33,927.04 for 4th),
    so LIMIT 3 loses no rows. The LIMIT 1 inside the lookups only picks each person's single latest payment.

JOIN TYPE NOTES used throughout:
    INNER JOIN keeps only rows that have a match on both sides, so unmatched rows disappear.
    LEFT JOIN keeps every row from the left table and fills the right side with NULL when there is no match.
====================================================================================================
*/


/*
====================================================================================================
PART 1, TASK 1
Task condition:
The marketing team needs a list of animation movies between 2017 and 2019 to promote family-friendly
content in an upcoming season in stores. Show all animation movies released during this period with
rate more than 1, sorted alphabetically.
====================================================================================================
*/

-- 1.1 JOIN solution
-- INNER JOIN film_category: films without a category are dropped (correct, they cannot be animation).
-- INNER JOIN category: only the category row named Animation survives the WHERE filter.
SELECT
    f.title,
    f.release_year,
    f.rental_rate
FROM public.film AS f
INNER JOIN public.film_category AS fc
    ON fc.film_id = f.film_id
INNER JOIN public.category AS c
    ON c.category_id = fc.category_id
WHERE c.name = 'Animation'
    AND f.release_year BETWEEN 2017 AND 2019
    AND f.rental_rate > 1
ORDER BY f.title;
/*
Pros: shortest and most readable, optimizer plans it as a simple hash/nested-loop join, easy to extend with more columns
      from category or film_category.
Cons: if a film belonged to several categories it could repeat (not possible here because the filter is one category).
*/

-- 1.1 SUBQUERY solution
-- No join is needed in the outer query. IN returns each film once even if the link table repeated it.
SELECT
    f.title,
    f.release_year,
    f.rental_rate
FROM public.film AS f
WHERE f.release_year BETWEEN 2017 AND 2019
    AND f.rental_rate > 1
    AND f.film_id IN (
        SELECT fc.film_id
        FROM public.film_category AS fc
        WHERE fc.category_id IN (
            SELECT c.category_id
            FROM public.category AS c
            WHERE c.name = 'Animation'
        )
    )
ORDER BY f.title;
/*
Pros: never duplicates film rows, shows the logic as "films that belong to Animation".
Cons: nested three levels deep, harder to read, category columns cannot be shown in the result,
      older optimizers could plan IN subqueries badly (PostgreSQL turns them into semi-joins, so it is fine here).
*/

-- 1.1 CTE solution
-- The CTE names the idea "animation films" so the final query reads in two simple steps.
WITH animation_films AS (
    SELECT fc.film_id
    FROM public.film_category AS fc
    INNER JOIN public.category AS c
        ON c.category_id = fc.category_id
    WHERE c.name = 'Animation'
)
SELECT
    f.title,
    f.release_year,
    f.rental_rate
FROM public.film AS f
INNER JOIN animation_films AS af
    ON af.film_id = f.film_id
WHERE f.release_year BETWEEN 2017 AND 2019
    AND f.rental_rate > 1
ORDER BY f.title;
/*
Pros: most readable for long queries, the building block can be reused or tested alone.
Cons: slightly more text for a simple task, and in other databases a CTE may be materialized and slower.
Production choice for 1.1: the JOIN solution. It is the shortest and simplest and the planner handles it best.
*/


/*
====================================================================================================
PART 1, TASK 2
Task condition:
The finance department requires a report on store performance to assess profitability and plan resource
allocation for stores after March 2017. Calculate the revenue earned by each rental store after March 2017
(since April) (include columns: address and address2 - as one column, revenue).
====================================================================================================
*/

-- 2.1 JOIN solution
-- INNER JOIN address: every store has an address.
-- LEFT JOIN inventory, rental, payment: a store with no copies, no rentals or no payments after March still shows (revenue 0).
-- The date condition is inside the ON clause of the payment join. Putting it in WHERE would turn the LEFT JOIN
-- into an INNER JOIN and silently drop stores without recent payments.
SELECT
    CONCAT_WS(' ', a.address, NULLIF(a.address2, '')) AS address,
    COALESCE(SUM(p.amount), 0) AS revenue
FROM public.store AS s
INNER JOIN public.address AS a
    ON a.address_id = s.address_id
LEFT JOIN public.inventory AS i
    ON i.store_id = s.store_id
LEFT JOIN public.rental AS r
    ON r.inventory_id = i.inventory_id
LEFT JOIN public.payment AS p
    ON p.rental_id = r.rental_id
    AND p.payment_date >= DATE '2017-04-01'
GROUP BY
    s.store_id,
    a.address,
    a.address2
ORDER BY revenue DESC;
/*
Pros: one pass, keeps stores with zero revenue, no hidden subqueries.
Cons: joins four tables before grouping so it processes every inventory and rental row, and the filter placement
      inside ON is easy to get wrong.
*/

-- 2.1 SUBQUERY solution
-- A correlated scalar subquery calculates the revenue for each store row.
-- COALESCE turns the NULL from an empty SUM into 0 so stores without payments still appear.
SELECT
    CONCAT_WS(' ', a.address, NULLIF(a.address2, '')) AS address,
    COALESCE((
        SELECT SUM(p.amount)
        FROM public.payment AS p
        INNER JOIN public.rental AS r
            ON r.rental_id = p.rental_id
        INNER JOIN public.inventory AS i
            ON i.inventory_id = r.inventory_id
        WHERE i.store_id = s.store_id
            AND p.payment_date >= DATE '2017-04-01'
    ), 0) AS revenue
FROM public.store AS s
INNER JOIN public.address AS a
    ON a.address_id = s.address_id
ORDER BY revenue DESC;
/*
Pros: the outer query stays tiny (one row per store), no GROUP BY needed, zero-revenue stores are handled naturally.
Cons: the subquery runs once per store, which is fine for 2 stores but slow for thousands,
      and only one value per subquery can be returned.
*/

-- 2.1 CTE solution
-- The CTE aggregates revenue once per store. LEFT JOIN keeps stores that are missing from the CTE (no payments).
WITH store_revenue AS (
    SELECT
        i.store_id,
        SUM(p.amount) AS revenue
    FROM public.payment AS p
    INNER JOIN public.rental AS r
        ON r.rental_id = p.rental_id
    INNER JOIN public.inventory AS i
        ON i.inventory_id = r.inventory_id
    WHERE p.payment_date >= DATE '2017-04-01'
    GROUP BY i.store_id
)
SELECT
    CONCAT_WS(' ', a.address, NULLIF(a.address2, '')) AS address,
    COALESCE(sr.revenue, 0) AS revenue
FROM public.store AS s
INNER JOIN public.address AS a
    ON a.address_id = s.address_id
LEFT JOIN store_revenue AS sr
    ON sr.store_id = s.store_id
ORDER BY revenue DESC;
/*
Pros: aggregation happens once on payments only, then a cheap join to 2 stores, and each step is readable.
Cons: more lines than the others.
Production choice for 2.1: the CTE solution. It aggregates the large payment data first and joins the small
reference tables afterwards, and it is easy to read and extend (for example by month).
*/


/*
====================================================================================================
PART 1, TASK 3
Task condition:
The marketing department in our stores aims to identify the most successful actors since 2015 to boost
customer interest in their films. Show top-5 actors by number of movies (released since 2015) they took
part in (columns: first_name, last_name, number_of_movies, sorted by number_of_movies in descending order).
====================================================================================================
*/

/*
Interpretation: "top-5 actors" means every actor who has fewer than 5 actors ahead of them (an actor is ahead
when they appeared in strictly more films released since 2015). Actors tied for 5th place are all kept, so no rows
are lost and the result can have more than 5 rows (7 rows in this database). LIMIT is not used, because it would
cut the tied actors at an arbitrary row. No window functions are used. The result shows names and the count only,
actor IDs are used inside the query to join and group.
*/

-- 3.1 JOIN solution
-- INNER JOIN to the counts: actors without films since 2015 are dropped (they cannot be in a top 5).
-- LEFT JOIN to the same counts as "better": the leaders have nobody ahead, so without a LEFT JOIN
-- (an INNER JOIN would remove them) the best actors would disappear. COUNT(better.actor_id) counts real matches only.
SELECT
    a.first_name,
    a.last_name,
    mc.number_of_movies
FROM public.actor AS a
INNER JOIN (
    SELECT
        fa.actor_id,
        COUNT(*) AS number_of_movies
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
    WHERE f.release_year >= 2015
    GROUP BY fa.actor_id
) AS mc
    ON mc.actor_id = a.actor_id
LEFT JOIN (
    SELECT
        fa.actor_id,
        COUNT(*) AS number_of_movies
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
    WHERE f.release_year >= 2015
    GROUP BY fa.actor_id
) AS better
    ON better.number_of_movies > mc.number_of_movies
GROUP BY
    a.actor_id,
    a.first_name,
    a.last_name,
    mc.number_of_movies
HAVING COUNT(better.actor_id) < 5
ORDER BY
    mc.number_of_movies DESC,
    a.last_name,
    a.first_name;
/*
Pros: pure joins and grouping, ties are kept automatically, works in any SQL database.
Cons: the counts are written twice, and the non-equal join compares every actor with every other actor
      (200 x 200 here, which is fine, but it grows with the square of the number of actors).
*/

-- 3.1 SUBQUERY solution
-- The WHERE subquery counts how many actors have more films than the current actor. Fewer than 5 means top 5.
-- INNER JOIN to the counts drops actors without films since 2015.
SELECT
    a.first_name,
    a.last_name,
    mc.number_of_movies
FROM public.actor AS a
INNER JOIN (
    SELECT
        fa.actor_id,
        COUNT(*) AS number_of_movies
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
    WHERE f.release_year >= 2015
    GROUP BY fa.actor_id
) AS mc
    ON mc.actor_id = a.actor_id
WHERE (
    SELECT COUNT(*)
    FROM (
        SELECT
            fa.actor_id,
            COUNT(*) AS number_of_movies
        FROM public.film_actor AS fa
        INNER JOIN public.film AS f
            ON f.film_id = fa.film_id
        WHERE f.release_year >= 2015
        GROUP BY fa.actor_id
    ) AS better
    WHERE better.number_of_movies > mc.number_of_movies
) < 5
ORDER BY
    mc.number_of_movies DESC,
    a.last_name,
    a.first_name;
/*
Pros: the rule "fewer than 5 actors ahead" is written almost as a sentence, no extra GROUP BY or HAVING.
Cons: the inner counts are repeated, and the subquery runs once per actor.
*/

-- 3.1 CTE solution
-- Step 1 counts the recent films per actor. Step 2 counts how many actors are ahead of each actor
-- (LEFT JOIN keeps the leaders, who have nobody ahead). Step 3 keeps those with fewer than 5 ahead and adds names.
WITH movie_counts AS (
    SELECT
        fa.actor_id,
        COUNT(*) AS number_of_movies
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
    WHERE f.release_year >= 2015
    GROUP BY fa.actor_id
),
actor_position AS (
    SELECT
        mc.actor_id,
        mc.number_of_movies,
        COUNT(better.actor_id) AS actors_ahead
    FROM movie_counts AS mc
    LEFT JOIN movie_counts AS better
        ON better.number_of_movies > mc.number_of_movies
    GROUP BY
        mc.actor_id,
        mc.number_of_movies
)
SELECT
    a.first_name,
    a.last_name,
    ap.number_of_movies
FROM actor_position AS ap
INNER JOIN public.actor AS a
    ON a.actor_id = ap.actor_id
WHERE ap.actors_ahead < 5
ORDER BY
    ap.number_of_movies DESC,
    a.last_name,
    a.first_name;
/*
Pros: the counts are written once and reused, each step has a name, and ties are kept.
Cons: the longest version for a simple question.
Production choice for 3.1: the CTE solution. It states the counting once and the ranking rule separately,
and it is the easiest to change (for example to top 3 or to a different start year).
*/

/*
====================================================================================================
PART 1, TASK 4
Task condition:
The marketing team needs to track the production trends of Drama, Travel, and Documentary films to inform
genre-specific marketing strategies. Show number of Drama, Travel, Documentary per year (include columns:
release_year, number_of_drama_movies, number_of_travel_movies, number_of_documentary_movies), sorted by
release year in descending order. Dealing with NULL values is encouraged.
====================================================================================================
Assumptions for this task: every release year of any film is shown (a year with no film of a genre shows 0 instead
of NULL or a missing row). Films with a NULL release_year are excluded because they cannot be placed on a year.
*/

-- 4.1 JOIN solution
-- LEFT JOIN film_category and category: films with no category (or another category) still keep their year row.
-- SUM(CASE ...) turns each genre into its own column, and COALESCE guarantees 0 instead of NULL.
SELECT
    f.release_year,
    COALESCE(SUM(CASE WHEN c.name = 'Drama' THEN 1 ELSE 0 END), 0) AS number_of_drama_movies,
    COALESCE(SUM(CASE WHEN c.name = 'Travel' THEN 1 ELSE 0 END), 0) AS number_of_travel_movies,
    COALESCE(SUM(CASE WHEN c.name = 'Documentary' THEN 1 ELSE 0 END), 0) AS number_of_documentary_movies
FROM public.film AS f
LEFT JOIN public.film_category AS fc
    ON fc.film_id = f.film_id
LEFT JOIN public.category AS c
    ON c.category_id = fc.category_id
WHERE f.release_year IS NOT NULL
GROUP BY f.release_year
ORDER BY f.release_year DESC;
/*
Pros: one scan and one aggregation for all three genres, scales well.
Cons: the CASE expressions repeat for each genre, adding a genre means adding another line.
*/

-- 4.1 SUBQUERY solution
-- The outer query lists the distinct years. Each genre column is a correlated scalar subquery.
SELECT
    y.release_year,
    (
        SELECT COUNT(*)
        FROM public.film AS f
        INNER JOIN public.film_category AS fc
            ON fc.film_id = f.film_id
        INNER JOIN public.category AS c
            ON c.category_id = fc.category_id
        WHERE f.release_year = y.release_year
            AND c.name = 'Drama'
    ) AS number_of_drama_movies,
    (
        SELECT COUNT(*)
        FROM public.film AS f
        INNER JOIN public.film_category AS fc
            ON fc.film_id = f.film_id
        INNER JOIN public.category AS c
            ON c.category_id = fc.category_id
        WHERE f.release_year = y.release_year
            AND c.name = 'Travel'
    ) AS number_of_travel_movies,
    (
        SELECT COUNT(*)
        FROM public.film AS f
        INNER JOIN public.film_category AS fc
            ON fc.film_id = f.film_id
        INNER JOIN public.category AS c
            ON c.category_id = fc.category_id
        WHERE f.release_year = y.release_year
            AND c.name = 'Documentary'
    ) AS number_of_documentary_movies
FROM (
    SELECT DISTINCT f.release_year
    FROM public.film AS f
    WHERE f.release_year IS NOT NULL
) AS y
ORDER BY y.release_year DESC;
/*
Pros: COUNT(*) over zero rows returns 0, so no NULL handling is needed, each column is easy to reason about alone.
Cons: very long, three subqueries run once per year (93 runs for 31 years), the slowest option on large data.
*/

-- 4.1 CTE solution
-- The CTE gives every film one row per category (or NULL category). FILTER counts only matching rows per genre.
WITH film_genre AS (
    SELECT
        f.release_year,
        c.name AS category_name
    FROM public.film AS f
    LEFT JOIN public.film_category AS fc
        ON fc.film_id = f.film_id
    LEFT JOIN public.category AS c
        ON c.category_id = fc.category_id
    WHERE f.release_year IS NOT NULL
)
SELECT
    fg.release_year,
    COUNT(*) FILTER (WHERE fg.category_name = 'Drama') AS number_of_drama_movies,
    COUNT(*) FILTER (WHERE fg.category_name = 'Travel') AS number_of_travel_movies,
    COUNT(*) FILTER (WHERE fg.category_name = 'Documentary') AS number_of_documentary_movies
FROM film_genre AS fg
GROUP BY fg.release_year
ORDER BY fg.release_year DESC;
/*
Pros: the join logic is separated from the counting, FILTER is cleaner than CASE and COUNT never returns NULL.
Cons: FILTER is not available in every database (it is standard SQL and works in PostgreSQL).
Production choice for 4.1: the CTE solution with FILTER. It scales like the JOIN version and reads best.
*/


/*
====================================================================================================
PART 2, TASK 1
Task condition:
The HR department aims to reward top-performing employees in 2017 with bonuses to recognize their contribution
to stores revenue. Show which three employees generated the most revenue in 2017?
Assumptions given:
    staff could work in several stores in a year, please indicate which store the staff worked in (the last one)
    if staff processed the payment then he works in the same store
    take into account only payment_date
====================================================================================================
My interpretation: revenue is the sum of payment.amount handled by the staff member (payment.staff_id) with
payment_date in 2017. "The last store" is the store of the staff member's most recent 2017 payment, found
through payment -> rental -> inventory.store_id. The most recent payment is decided by payment_date and then
payment_id as a tie-break. The result columns are first_name, last_name, last_store_address and revenue.
No IDs are returned (they are used inside the query only). The store table has no name column, so the store is
identified by its address (address and address2 as one text).
Note: staff.store_id is a single static value, so it cannot show a store change during the year.
This is why the store is taken from the payments.
*/

-- 5.1 JOIN solution
-- CROSS JOIN LATERAL finds each staff member's last 2017 store with ORDER BY ... LIMIT 1 (not a window function).
-- A staff member without 2017 payments produces no row, which is correct because there is no revenue or store.
-- INNER JOIN payment then adds up the 2017 payments for the same staff member.
SELECT
    s.first_name,
    s.last_name,
    ls.store_address AS last_store_address,
    SUM(p.amount) AS revenue
FROM public.staff AS s
CROSS JOIN LATERAL (
    SELECT CONCAT_WS(' ', sa.address, NULLIF(sa.address2, '')) AS store_address
    FROM public.payment AS lp
    INNER JOIN public.rental AS r
        ON r.rental_id = lp.rental_id
    INNER JOIN public.inventory AS i
        ON i.inventory_id = r.inventory_id
    INNER JOIN public.store AS st
        ON st.store_id = i.store_id
    INNER JOIN public.address AS sa
        ON sa.address_id = st.address_id
    WHERE lp.staff_id = s.staff_id
        AND lp.payment_date >= DATE '2017-01-01'
        AND lp.payment_date < DATE '2018-01-01'
    ORDER BY
        lp.payment_date DESC,
        lp.payment_id DESC
    LIMIT 1
) AS ls
INNER JOIN public.payment AS p
    ON p.staff_id = s.staff_id
WHERE p.payment_date >= DATE '2017-01-01'
    AND p.payment_date < DATE '2018-01-01'
GROUP BY
    s.staff_id,
    s.first_name,
    s.last_name,
    ls.store_address
ORDER BY
    revenue DESC,
    s.staff_id
LIMIT 3;
/*
Pros: everything in one statement, the lateral lookup runs once per staff member (5 times).
Cons: LATERAL is less known and harder to read, it is not supported by every database,
      and the last-store logic is hidden inside the join.
*/

-- 5.1 SUBQUERY solution
-- A derived table sums the 2017 revenue per staff member. A scalar subquery picks the last store.
SELECT
    s.first_name,
    s.last_name,
    (
        SELECT CONCAT_WS(' ', sa.address, NULLIF(sa.address2, ''))
        FROM public.payment AS lp
        INNER JOIN public.rental AS r
            ON r.rental_id = lp.rental_id
        INNER JOIN public.inventory AS i
            ON i.inventory_id = r.inventory_id
        INNER JOIN public.store AS st
            ON st.store_id = i.store_id
        INNER JOIN public.address AS sa
            ON sa.address_id = st.address_id
        WHERE lp.staff_id = s.staff_id
            AND lp.payment_date >= DATE '2017-01-01'
            AND lp.payment_date < DATE '2018-01-01'
        ORDER BY
            lp.payment_date DESC,
            lp.payment_id DESC
        LIMIT 1
    ) AS last_store_address,
    sr.revenue
FROM public.staff AS s
INNER JOIN (
    SELECT
        p.staff_id,
        SUM(p.amount) AS revenue
    FROM public.payment AS p
    WHERE p.payment_date >= DATE '2017-01-01'
        AND p.payment_date < DATE '2018-01-01'
    GROUP BY p.staff_id
) AS sr
    ON sr.staff_id = s.staff_id
ORDER BY
    sr.revenue DESC,
    s.staff_id
LIMIT 3;
/*
Pros: standard and portable SQL, each piece (revenue and last store) is independent and easy to test.
Cons: the scalar subquery runs once per staff row, and the payment table is scanned twice.
*/

-- 5.1 CTE solution
-- The last payment per staff member is found without window functions: it is the payment for which no later
-- payment (by date, then id) exists for the same staff member (NOT EXISTS anti-join).
WITH payments_2017 AS (
    SELECT
        p.payment_id,
        p.staff_id,
        p.rental_id,
        p.amount,
        p.payment_date
    FROM public.payment AS p
    WHERE p.payment_date >= DATE '2017-01-01'
        AND p.payment_date < DATE '2018-01-01'
),
staff_revenue AS (
    SELECT
        pay.staff_id,
        SUM(pay.amount) AS revenue
    FROM payments_2017 AS pay
    GROUP BY pay.staff_id
),
staff_last_store AS (
    SELECT
        pay.staff_id,
        CONCAT_WS(' ', sa.address, NULLIF(sa.address2, '')) AS store_address
    FROM payments_2017 AS pay
    INNER JOIN public.rental AS r
        ON r.rental_id = pay.rental_id
    INNER JOIN public.inventory AS i
        ON i.inventory_id = r.inventory_id
    INNER JOIN public.store AS st
        ON st.store_id = i.store_id
    INNER JOIN public.address AS sa
        ON sa.address_id = st.address_id
    WHERE NOT EXISTS (
        SELECT 1
        FROM payments_2017 AS later
        WHERE later.staff_id = pay.staff_id
            AND (later.payment_date, later.payment_id) > (pay.payment_date, pay.payment_id)
    )
)
SELECT
    s.first_name,
    s.last_name,
    sls.store_address AS last_store_address,
    sr.revenue
FROM public.staff AS s
INNER JOIN staff_revenue AS sr
    ON sr.staff_id = s.staff_id
INNER JOIN staff_last_store AS sls
    ON sls.staff_id = s.staff_id
ORDER BY
    sr.revenue DESC,
    s.staff_id
LIMIT 3;
/*
Pros: each requirement has its own named step, filtering on 2017 is written once, standard SQL with no vendor tricks.
Cons: the longest version, the NOT EXISTS check compares every payment with later payments of the same staff member,
      which is slow on very large payment tables without an index on (staff_id, payment_date).
Production choice for 5.1: the CTE solution. It is portable, easy to read and review, and each business rule can be
tested separately. With a bigger table I would add an index on payment (staff_id, payment_date).
*/


/*
====================================================================================================
PART 2, TASK 2
Task condition:
The management team wants to identify the most popular movies and their target audience age groups to optimize
marketing efforts. Show which 5 movies were rented more than others (number of rentals), and what's the expected
age of the audience for these movies? To determine expected age please use 'Motion Picture Association film
rating system'.
====================================================================================================
Assumption: a rental is one row in rental. The film of a rental is found through inventory.film_id.
Ties for 5th place are all kept (see A7), so the result has more than 5 rows when several films share the
5th place (7 rows in this database). The mapping from rating to age is assumption A9.
*/

-- 6.1 JOIN solution
-- INNER JOIN to the rental counts: films without any copy or rental are dropped, which is right for a ranking of rentals.
-- LEFT JOIN to the same counts as "better": the most rented films have nobody ahead, so an INNER JOIN would remove
-- them. COUNT(better.film_id) counts real matches only. Films tied for 5th place are all kept.
SELECT
    f.title,
    f.rating,
    fr.number_of_rentals,
    CASE f.rating
        WHEN 'G' THEN 'All ages (0+)'
        WHEN 'PG' THEN '8+ (parental guidance suggested)'
        WHEN 'PG-13' THEN '13+ (parents strongly cautioned under 13)'
        WHEN 'R' THEN '17+ (under 17 only with an adult)'
        WHEN 'NC-17' THEN '18+ (no one 17 and under)'
        ELSE 'Not rated'
    END AS expected_audience_age
FROM public.film AS f
INNER JOIN (
    SELECT
        i.film_id,
        COUNT(r.rental_id) AS number_of_rentals
    FROM public.inventory AS i
    INNER JOIN public.rental AS r
        ON r.inventory_id = i.inventory_id
    GROUP BY i.film_id
) AS fr
    ON fr.film_id = f.film_id
LEFT JOIN (
    SELECT
        i.film_id,
        COUNT(r.rental_id) AS number_of_rentals
    FROM public.inventory AS i
    INNER JOIN public.rental AS r
        ON r.inventory_id = i.inventory_id
    GROUP BY i.film_id
) AS better
    ON better.number_of_rentals > fr.number_of_rentals
GROUP BY
    f.film_id,
    f.title,
    f.rating,
    fr.number_of_rentals
HAVING COUNT(better.film_id) < 5
ORDER BY
    fr.number_of_rentals DESC,
    f.title;
/*
Pros: pure joins and grouping, ties are kept automatically.
Cons: the counts are written twice, and the non-equal join compares every film with every other film
      (about 1000 x 1000 here, fine for this size but it grows with the square of the number of films).
*/

-- 6.1 SUBQUERY solution
-- The WHERE subquery counts how many films were rented more than the current film. Fewer than 5 means top 5.
-- INNER JOIN to the counts drops films without rentals.
SELECT
    f.title,
    f.rating,
    fr.number_of_rentals,
    CASE f.rating
        WHEN 'G' THEN 'All ages (0+)'
        WHEN 'PG' THEN '8+ (parental guidance suggested)'
        WHEN 'PG-13' THEN '13+ (parents strongly cautioned under 13)'
        WHEN 'R' THEN '17+ (under 17 only with an adult)'
        WHEN 'NC-17' THEN '18+ (no one 17 and under)'
        ELSE 'Not rated'
    END AS expected_audience_age
FROM public.film AS f
INNER JOIN (
    SELECT
        i.film_id,
        COUNT(r.rental_id) AS number_of_rentals
    FROM public.inventory AS i
    INNER JOIN public.rental AS r
        ON r.inventory_id = i.inventory_id
    GROUP BY i.film_id
) AS fr
    ON fr.film_id = f.film_id
WHERE (
    SELECT COUNT(*)
    FROM (
        SELECT
            i.film_id,
            COUNT(r.rental_id) AS number_of_rentals
        FROM public.inventory AS i
        INNER JOIN public.rental AS r
            ON r.inventory_id = i.inventory_id
        GROUP BY i.film_id
    ) AS better
    WHERE better.number_of_rentals > fr.number_of_rentals
) < 5
ORDER BY
    fr.number_of_rentals DESC,
    f.title;
/*
Pros: the rule "fewer than 5 films ahead" reads almost like a sentence.
Cons: the counts are repeated, and the subquery runs once per film.
*/

-- 6.1 CTE solution
-- Step 1 counts rentals per film (on the big tables only). Step 2 counts how many films are ahead of each film
-- (LEFT JOIN keeps the most rented films, which have nobody ahead). Step 3 keeps films with fewer than 5 ahead
-- and adds the film details and the age text.
WITH film_rentals AS (
    SELECT
        i.film_id,
        COUNT(r.rental_id) AS number_of_rentals
    FROM public.inventory AS i
    INNER JOIN public.rental AS r
        ON r.inventory_id = i.inventory_id
    GROUP BY i.film_id
),
film_position AS (
    SELECT
        fr.film_id,
        fr.number_of_rentals,
        COUNT(better.film_id) AS films_ahead
    FROM film_rentals AS fr
    LEFT JOIN film_rentals AS better
        ON better.number_of_rentals > fr.number_of_rentals
    GROUP BY
        fr.film_id,
        fr.number_of_rentals
)
SELECT
    f.title,
    f.rating,
    fp.number_of_rentals,
    CASE f.rating
        WHEN 'G' THEN 'All ages (0+)'
        WHEN 'PG' THEN '8+ (parental guidance suggested)'
        WHEN 'PG-13' THEN '13+ (parents strongly cautioned under 13)'
        WHEN 'R' THEN '17+ (under 17 only with an adult)'
        WHEN 'NC-17' THEN '18+ (no one 17 and under)'
        ELSE 'Not rated'
    END AS expected_audience_age
FROM film_position AS fp
INNER JOIN public.film AS f
    ON f.film_id = fp.film_id
WHERE fp.films_ahead < 5
ORDER BY
    fp.number_of_rentals DESC,
    f.title;
/*
Pros: the counting is written once and reused, the age text is separate from the counting logic, and ties are kept.
Cons: one more step than the JOIN version.
Production choice for 6.1: the CTE solution. The heavy counting is isolated, and the age mapping is easy to move
into a reference table later.
*/


/*
====================================================================================================
PART 3
Task condition:
Which actors/actresses didn't act for a longer period of time than the others? The stores' marketing team wants
to analyze actors' inactivity periods to select those with notable career breaks for targeted promotional
campaigns, highlighting their comebacks or consistent appearances to engage customers with nostalgic or
reliable film stars.
The task can be interpreted in various ways, and here are a few options (provide solutions for each one):
    V1: gap between the latest release_year and current year per each actor
    V2: gaps between sequential films per each actor
====================================================================================================
Window functions are not allowed, so the "next film" is found with an anti-join (NOT EXISTS, or LEFT JOIN with
IS NULL): a film is the next one when no other film of the same actor lies between them.
Nothing is cut off with LIMIT or "only the winners", so no actor and no row is lost. The longest inactivity is simply
at the top of each result. Results show names, film titles and years only, IDs are used inside the queries to join.
*/

/*
----------------------------------------------------------------------------------------------------
PART 3, V1: gap between the latest release_year and the current year, per each actor
Result: every actor (first_name, last_name, last_release_year, years_inactive), longest inactivity first.
The current year comes from CURRENT_DATE, so years_inactive grows every year.
----------------------------------------------------------------------------------------------------
*/

-- V1 JOIN solution
-- LEFT JOIN film_actor and film: an actor without any film is still listed (years_inactive is NULL), so no actor is lost.
-- NULLS LAST puts such actors at the bottom of the descending sort instead of the top.
SELECT
    a.first_name,
    a.last_name,
    MAX(f.release_year) AS last_release_year,
    EXTRACT(YEAR FROM CURRENT_DATE)::integer - MAX(f.release_year) AS years_inactive
FROM public.actor AS a
LEFT JOIN public.film_actor AS fa
    ON fa.actor_id = a.actor_id
LEFT JOIN public.film AS f
    ON f.film_id = fa.film_id
GROUP BY
    a.actor_id,
    a.first_name,
    a.last_name
ORDER BY
    years_inactive DESC NULLS LAST,
    a.last_name,
    a.first_name;
/*
Pros: shortest, one aggregation, every actor is listed.
Cons: none significant. Grouping is by actor_id so two actors with the same name are never merged.
*/

-- V1 SUBQUERY solution
-- A scalar subquery finds each actor's latest release year. The wrapper query turns it into a gap,
-- so the computed column can be reused and sorted. Actors without films are kept (NULL).
SELECT
    t.first_name,
    t.last_name,
    t.last_release_year,
    EXTRACT(YEAR FROM CURRENT_DATE)::integer - t.last_release_year AS years_inactive
FROM (
    SELECT
        a.actor_id,
        a.first_name,
        a.last_name,
        (
            SELECT MAX(f.release_year)
            FROM public.film_actor AS fa
            INNER JOIN public.film AS f
                ON f.film_id = fa.film_id
            WHERE fa.actor_id = a.actor_id
        ) AS last_release_year
    FROM public.actor AS a
) AS t
ORDER BY
    years_inactive DESC NULLS LAST,
    t.last_name,
    t.first_name;
/*
Pros: the "latest year" logic is isolated and easy to test.
Cons: the subquery runs once per actor and a wrapper query is needed to reuse the computed column.
*/

-- V1 CTE solution
-- The CTE finds the latest year per actor. LEFT JOIN from actor keeps actors that have no film.
WITH actor_last_year AS (
    SELECT
        fa.actor_id,
        MAX(f.release_year) AS last_release_year
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
    GROUP BY fa.actor_id
)
SELECT
    a.first_name,
    a.last_name,
    aly.last_release_year,
    EXTRACT(YEAR FROM CURRENT_DATE)::integer - aly.last_release_year AS years_inactive
FROM public.actor AS a
LEFT JOIN actor_last_year AS aly
    ON aly.actor_id = a.actor_id
ORDER BY
    years_inactive DESC NULLS LAST,
    a.last_name,
    a.first_name;
/*
Pros: the aggregation is named and reusable, the final query is easy to read.
Cons: one more step than the JOIN version for the same result.
Production choice for V1: the JOIN solution. It is the shortest and aggregates once.
*/

/*
----------------------------------------------------------------------------------------------------
PART 3, V2: gaps between sequential films, per each actor
Result: one row per pair of consecutive films of an actor: first_name, last_name, previous_film,
previous_release_year, next_film, next_release_year, gap_years. The longest gaps are first.
A gap is next_release_year - previous_release_year. Films of one actor are ordered by release_year and, inside
the same year, by film_id (only to make the order fixed), so two films of the same year have a gap of 0.
An actor with one film has no pair of sequential films and therefore no row.
----------------------------------------------------------------------------------------------------
*/

-- V2 JOIN solution
-- previous and next are two films of the same actor, with next later than previous.
-- The LEFT JOIN to a "between" film plus WHERE ... IS NULL is an anti-join: it keeps only pairs where no film of that
-- actor lies between them, so only consecutive films remain. INNER JOINs drop actors with fewer than two films.
SELECT
    a.first_name,
    a.last_name,
    prev_f.title AS previous_film,
    prev_f.release_year AS previous_release_year,
    next_f.title AS next_film,
    next_f.release_year AS next_release_year,
    next_f.release_year - prev_f.release_year AS gap_years
FROM public.actor AS a
INNER JOIN public.film_actor AS prev_fa
    ON prev_fa.actor_id = a.actor_id
INNER JOIN public.film AS prev_f
    ON prev_f.film_id = prev_fa.film_id
INNER JOIN public.film_actor AS next_fa
    ON next_fa.actor_id = a.actor_id
INNER JOIN public.film AS next_f
    ON next_f.film_id = next_fa.film_id
    AND (next_f.release_year, next_f.film_id) > (prev_f.release_year, prev_f.film_id)
LEFT JOIN (
    public.film_actor AS mid_fa
    INNER JOIN public.film AS mid_f
        ON mid_f.film_id = mid_fa.film_id
)
    ON mid_fa.actor_id = a.actor_id
    AND (mid_f.release_year, mid_f.film_id) > (prev_f.release_year, prev_f.film_id)
    AND (mid_f.release_year, mid_f.film_id) < (next_f.release_year, next_f.film_id)
WHERE mid_fa.actor_id IS NULL
ORDER BY
    gap_years DESC,
    a.last_name,
    a.first_name,
    previous_release_year,
    previous_film;
/*
Pros: no subqueries, uses joins only, every pair of consecutive films is visible.
Cons: hard to read, and it first builds every pair of films of an actor before the anti-join removes the
      non-consecutive ones.
*/

-- V2 SUBQUERY solution
-- For every film of an actor, a scalar subquery returns the film that comes right after it: a later film
-- with no film of that actor between them (NOT EXISTS). A film with no next film (the actor's last one) gets no row.
SELECT
    a.first_name,
    a.last_name,
    prev_f.title AS previous_film,
    prev_f.release_year AS previous_release_year,
    next_f.title AS next_film,
    next_f.release_year AS next_release_year,
    next_f.release_year - prev_f.release_year AS gap_years
FROM public.actor AS a
INNER JOIN public.film_actor AS prev_fa
    ON prev_fa.actor_id = a.actor_id
INNER JOIN public.film AS prev_f
    ON prev_f.film_id = prev_fa.film_id
INNER JOIN public.film AS next_f
    ON next_f.film_id = (
        SELECT cand.film_id
        FROM public.film_actor AS cand_fa
        INNER JOIN public.film AS cand
            ON cand.film_id = cand_fa.film_id
        WHERE cand_fa.actor_id = a.actor_id
            AND (cand.release_year, cand.film_id) > (prev_f.release_year, prev_f.film_id)
            AND NOT EXISTS (
                SELECT 1
                FROM public.film_actor AS mid_fa
                INNER JOIN public.film AS mid
                    ON mid.film_id = mid_fa.film_id
                WHERE mid_fa.actor_id = a.actor_id
                    AND (mid.release_year, mid.film_id) > (prev_f.release_year, prev_f.film_id)
                    AND (mid.release_year, mid.film_id) < (cand.release_year, cand.film_id)
            )
    )
ORDER BY
    gap_years DESC,
    a.last_name,
    a.first_name,
    previous_release_year,
    previous_film;
/*
Pros: the idea "the next film is the earliest later film" is explicit and there is no giant pair list.
Cons: deeply nested, hard to read, and the subquery runs once per film of every actor.
*/

-- V2 CTE solution
-- Step 1 lists the films of each actor. Step 2 pairs every film with every later film of the same actor.
-- Step 3 keeps only the consecutive pairs (no film of that actor lies between them). Step 4 adds names and the gap.
WITH actor_films AS (
    SELECT
        fa.actor_id,
        f.film_id,
        f.title,
        f.release_year
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
),
film_pairs AS (
    SELECT
        cur.actor_id,
        cur.film_id AS previous_film_id,
        cur.title AS previous_film,
        cur.release_year AS previous_release_year,
        nxt.film_id AS next_film_id,
        nxt.title AS next_film,
        nxt.release_year AS next_release_year
    FROM actor_films AS cur
    INNER JOIN actor_films AS nxt
        ON nxt.actor_id = cur.actor_id
        AND (nxt.release_year, nxt.film_id) > (cur.release_year, cur.film_id)
),
sequential_pairs AS (
    SELECT
        fp.actor_id,
        fp.previous_film,
        fp.previous_release_year,
        fp.next_film,
        fp.next_release_year
    FROM film_pairs AS fp
    WHERE NOT EXISTS (
        SELECT 1
        FROM actor_films AS mid
        WHERE mid.actor_id = fp.actor_id
            AND (mid.release_year, mid.film_id) > (fp.previous_release_year, fp.previous_film_id)
            AND (mid.release_year, mid.film_id) < (fp.next_release_year, fp.next_film_id)
    )
)
SELECT
    a.first_name,
    a.last_name,
    sp.previous_film,
    sp.previous_release_year,
    sp.next_film,
    sp.next_release_year,
    sp.next_release_year - sp.previous_release_year AS gap_years
FROM sequential_pairs AS sp
INNER JOIN public.actor AS a
    ON a.actor_id = sp.actor_id
ORDER BY
    gap_years DESC,
    a.last_name,
    a.first_name,
    sp.previous_release_year,
    sp.previous_film;
/*
Pros: every step is small and testable, and the consecutive-film rule is written in one place.
Cons: the longest version, and step 2 builds all pairs of films per actor before step 3 removes most of them.
Production choice for V2: the CTE solution. It is the most readable and each rule can be checked on its own.
With window functions allowed, steps 2 and 3 would be replaced by LEAD() over each actor's films.
*/
