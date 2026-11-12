/* =====================================================================
   SQL_DML_HW  |  Task 1  |  Favorite films, actors, inventory, customer, rentals, payments

   Author: Hasmitha Sargunam
   Personal data used: first name 'Hasmitha', last name 'Sargunam',
   e-mail 'hasmitha.sargunam@example.com'.
   (the same values are used in subtasks 5, 6 and 7 to find "my" customer row;
    they are the natural key that makes the script rerunnable)

   GENERAL NOTES (apply to every subtask below)
   * Every subtask is its own transaction (BEGIN ... COMMIT). Why separate:
       - each subtask is one logical unit of work; if it fails, only that unit
         is undone and earlier committed subtasks stay intact,
       - a failure is easy to locate and the script can simply be re-run,
       - locks are held only briefly.
   * If a transaction fails (constraint violation, typo, lost connection) PostgreSQL
     aborts it; every statement inside it is rolled back and nothing from that
     subtask is stored. Data committed by previous subtasks is NOT affected.
     In psql run with  \set ON_ERROR_STOP on  and send ROLLBACK after an error.
     Before COMMIT you may also run ROLLBACK manually: only the rows touched by the
     current subtask are affected.
   * Referential integrity: no IDs are hardcoded. Every foreign key value
     (language_id, film_id, actor_id, store_id, staff_id, inventory_id, customer_id,
     rental_id) is looked up by joining to the parent table at run time, so a child row
     can only be created if its parent row exists. The database foreign keys
     (ON DELETE RESTRICT) back this up: a wrong delete/insert fails instead of
     leaving orphans.
   * INSERT ... SELECT instead of INSERT ... VALUES: the SELECT lets us (a) resolve
     foreign keys by lookup instead of typing IDs that differ between databases,
     (b) reuse the same statement to filter out rows that already exist (WHERE NOT
     EXISTS), and (c) insert several related rows in one statement. A VALUES list
     with literal IDs would break on any database where the IDs differ.
   * Every INSERT/UPDATE/DELETE has RETURNING so the changed rows are visible.
   * last_update is set to current_date on all new/updated rows. The payment table
     has no last_update column, so the rule cannot apply there. Note: the schema's
     BEFORE UPDATE trigger last_updated() sets last_update = CURRENT_TIMESTAMP on
     updates; that is still today's date.
   ===================================================================== */


/* ---------------------------------------------------------------------
   SUBTASK 1: add 3 favorite films
   Rental rate / duration pairs: 4.99 -> 1 week, 9.99 -> 2 weeks, 19.99 -> 3 weeks.
   rental_duration is stored in DAYS, so 1/2/3 weeks = 7/14/21.
   Films (different years and genres):
     THE SHAWSHANK REDEMPTION  1994  drama
     INCEPTION                 2010  science fiction thriller
     THE GRAND BUDAPEST HOTEL  2014  comedy
   Uniqueness: film has no unique constraint on title, so WHERE NOT EXISTS compares
     titles case-insensitively; re-running inserts nothing new.
   Relationships: language_id is looked up from public.language by name (not hardcoded).
   --------------------------------------------------------------------- */
BEGIN;

INSERT INTO public.film
       (title, description, release_year, language_id, rental_duration, rental_rate,
        length, replacement_cost, rating, last_update)
SELECT v.title, v.description, v.release_year, l.language_id, v.rental_duration, v.rental_rate,
       v.length, v.replacement_cost, v.rating::public.mpaa_rating, current_date
FROM (VALUES
        ('THE SHAWSHANK REDEMPTION',
         'Two imprisoned men bond over years, finding solace and eventual redemption through acts of common decency.',
         1994, 7,  4.99, 142, 19.99, 'R'),
        ('INCEPTION',
         'A thief who steals corporate secrets through dream-sharing technology is given the task of planting an idea.',
         2010, 14, 9.99, 148, 19.99, 'PG-13'),
        ('THE GRAND BUDAPEST HOTEL',
         'The adventures of a legendary concierge and his lobby boy at a famous European hotel between the wars.',
         2014, 21, 19.99, 99, 19.99, 'R')
     ) AS v(title, description, release_year, rental_duration, rental_rate, length, replacement_cost, rating)
JOIN public.language l ON UPPER(TRIM(l.name)) = 'ENGLISH'
WHERE NOT EXISTS (SELECT 1 FROM public.film f WHERE UPPER(f.title) = UPPER(v.title))
RETURNING film_id, title, release_year, rental_duration, rental_rate, last_update;

COMMIT;


/* ---------------------------------------------------------------------
   SUBTASK 2: add the leading actors (2 per film, 6 in total) to public.actor
   Film -> actors:
     THE SHAWSHANK REDEMPTION : Tim Robbins, Morgan Freeman
     INCEPTION                : Leonardo DiCaprio, Joseph Gordon-Levitt
     THE GRAND BUDAPEST HOTEL : Ralph Fiennes, Tony Revolori
   Uniqueness: an actor is identified by (first_name, last_name) compared
     case-insensitively (the table has no unique constraint and the data is stored in
     upper case). WHERE NOT EXISTS skips actors that are already in the system, so
     there are no duplicates, and an existing actor is reused in subtask 3.
   --------------------------------------------------------------------- */
BEGIN;

INSERT INTO public.actor (first_name, last_name, last_update)
SELECT UPPER(v.first_name), UPPER(v.last_name), current_date
FROM (VALUES
        ('Tim',      'Robbins'),
        ('Morgan',   'Freeman'),
        ('Leonardo', 'DiCaprio'),
        ('Joseph',   'Gordon-Levitt'),
        ('Ralph',    'Fiennes'),
        ('Tony',     'Revolori')
     ) AS v(first_name, last_name)
WHERE NOT EXISTS (SELECT 1
                  FROM public.actor a
                  WHERE UPPER(a.first_name) = UPPER(v.first_name)
                    AND UPPER(a.last_name)  = UPPER(v.last_name))
RETURNING actor_id, first_name, last_name, last_update;

COMMIT;


/* ---------------------------------------------------------------------
   SUBTASK 3: link actors to films (public.film_actor)
   Relationships: both ids come from joining film and actor on their natural keys
     (title, and first+last name), so only real parents can be linked.
   Uniqueness: film_actor has PRIMARY KEY (actor_id, film_id); ON CONFLICT DO NOTHING
     makes a re-run insert nothing.
   --------------------------------------------------------------------- */
BEGIN;

INSERT INTO public.film_actor (actor_id, film_id, last_update)
SELECT a.actor_id, f.film_id, current_date
FROM (VALUES
        ('THE SHAWSHANK REDEMPTION', 'Tim',      'Robbins'),
        ('THE SHAWSHANK REDEMPTION', 'Morgan',   'Freeman'),
        ('INCEPTION',                'Leonardo', 'DiCaprio'),
        ('INCEPTION',                'Joseph',   'Gordon-Levitt'),
        ('THE GRAND BUDAPEST HOTEL', 'Ralph',    'Fiennes'),
        ('THE GRAND BUDAPEST HOTEL', 'Tony',     'Revolori')
     ) AS v(title, first_name, last_name)
JOIN public.film  f ON UPPER(f.title) = UPPER(v.title)
JOIN public.actor a ON UPPER(a.first_name) = UPPER(v.first_name)
                   AND UPPER(a.last_name)  = UPPER(v.last_name)
ON CONFLICT (actor_id, film_id) DO NOTHING
RETURNING actor_id, film_id, last_update;

COMMIT;


/* ---------------------------------------------------------------------
   SUBTASK 4: add the films to a store's inventory (one copy each)
   Store choice: the lowest store_id that has at least one staff member (needed so
     that the rental in subtask 7 can be handled by an employee of that same store).
   Uniqueness: inventory has no unique constraint on (film_id, store_id); WHERE NOT
     EXISTS prevents adding a second copy on re-run.
   Relationships: film_id from film (by title), store_id from store.
   --------------------------------------------------------------------- */
BEGIN;

INSERT INTO public.inventory (film_id, store_id, last_update)
SELECT f.film_id, s.store_id, current_date
FROM public.film f
CROSS JOIN (SELECT st.store_id
            FROM public.store st
            WHERE EXISTS (SELECT 1 FROM public.staff sf WHERE sf.store_id = st.store_id)
            ORDER BY st.store_id
            LIMIT 1) s
WHERE UPPER(f.title) IN ('THE SHAWSHANK REDEMPTION', 'INCEPTION', 'THE GRAND BUDAPEST HOTEL')
  AND NOT EXISTS (SELECT 1
                  FROM public.inventory i
                  WHERE i.film_id = f.film_id
                    AND i.store_id = s.store_id)
RETURNING inventory_id, film_id, store_id, last_update;

COMMIT;


/* ---------------------------------------------------------------------
   SUBTASK 5: turn an existing customer into "me"
   Which customer: the one with the lowest customer_id that has at least 43 rentals
     AND at least 43 payments (counted with GROUP BY ... HAVING, no hardcoded id).
   Address: an existing address that no customer, staff member or store uses; the
     address table itself is NOT modified. If none is free, the customer keeps the
     current address.
   Rerunnable: the UPDATE only runs when no customer with my name/e-mail exists yet.
     After the first run the customer is already me, so a re-run changes nothing
     (and the address cannot flip to a different one).
   Safety check: the SELECT below shows which row will be changed; review it before COMMIT.
   --------------------------------------------------------------------- */
BEGIN;

-- Preview: the customer that will be changed (empty on a re-run, because I already exist)
SELECT c.customer_id, c.first_name, c.last_name, c.email, c.address_id
FROM public.customer c
JOIN (SELECT customer_id FROM public.rental  GROUP BY customer_id HAVING COUNT(*) >= 43) r USING (customer_id)
JOIN (SELECT customer_id FROM public.payment GROUP BY customer_id HAVING COUNT(*) >= 43) p USING (customer_id)
WHERE NOT EXISTS (SELECT 1 FROM public.customer m
                  WHERE UPPER(m.first_name) = UPPER('Hasmitha')
                    AND UPPER(m.last_name)  = UPPER('Sargunam')
                    AND m.email = 'hasmitha.sargunam@example.com')
ORDER BY c.customer_id
LIMIT 1;

UPDATE public.customer c
SET first_name  = 'Hasmitha',
    last_name   = 'Sargunam',
    email       = 'hasmitha.sargunam@example.com',
    address_id  = COALESCE((SELECT a.address_id
                            FROM public.address a
                            WHERE NOT EXISTS (SELECT 1 FROM public.customer x WHERE x.address_id = a.address_id)
                              AND NOT EXISTS (SELECT 1 FROM public.staff    s WHERE s.address_id = a.address_id)
                              AND NOT EXISTS (SELECT 1 FROM public.store    t WHERE t.address_id = a.address_id)
                            ORDER BY a.address_id
                            LIMIT 1),
                           c.address_id),
    last_update = current_date
WHERE c.customer_id = (SELECT c2.customer_id
                       FROM public.customer c2
                       JOIN (SELECT customer_id FROM public.rental  GROUP BY customer_id HAVING COUNT(*) >= 43) r USING (customer_id)
                       JOIN (SELECT customer_id FROM public.payment GROUP BY customer_id HAVING COUNT(*) >= 43) p USING (customer_id)
                       ORDER BY c2.customer_id
                       LIMIT 1)
  AND NOT EXISTS (SELECT 1 FROM public.customer m
                  WHERE UPPER(m.first_name) = UPPER('Hasmitha')
                    AND UPPER(m.last_name)  = UPPER('Sargunam')
                    AND m.email = 'hasmitha.sargunam@example.com')
RETURNING customer_id, first_name, last_name, email, address_id, last_update;

COMMIT;


/* ---------------------------------------------------------------------
   SUBTASK 6: remove every record related to me (as a customer) from all tables
   except customer and inventory: payment and rental (the only tables that
   reference customer).
   Why it is safe:
     - rows are selected ONLY through my customer row (name AND e-mail), never by
       a broad condition, so other customers' history is untouched,
     - order matters: payments first (they reference rentals), then rentals;
       with ON DELETE RESTRICT a wrong order would fail instead of deleting wrongly,
     - both deletes are in one transaction: either both happen or neither.
   No unintended data loss: the preview SELECT shows exactly what will go; compare it
     with the RETURNING output; nothing else references these rows.
   Rollback is possible until COMMIT: it would restore all deleted payments and rentals.
   Rerunnable: with nothing left to delete, the statements remove 0 rows.
   --------------------------------------------------------------------- */
BEGIN;

-- Preview: what will be deleted
SELECT 'payment' AS tbl, COUNT(*) AS rows_to_delete
FROM public.payment p
JOIN public.customer c ON c.customer_id = p.customer_id
WHERE UPPER(c.first_name) = UPPER('Hasmitha') AND UPPER(c.last_name) = UPPER('Sargunam') AND c.email = 'hasmitha.sargunam@example.com'
UNION ALL
SELECT 'rental', COUNT(*)
FROM public.rental r
JOIN public.customer c ON c.customer_id = r.customer_id
WHERE UPPER(c.first_name) = UPPER('Hasmitha') AND UPPER(c.last_name) = UPPER('Sargunam') AND c.email = 'hasmitha.sargunam@example.com';

DELETE FROM public.payment p
USING public.customer c
WHERE c.customer_id = p.customer_id
  AND UPPER(c.first_name) = UPPER('Hasmitha')
  AND UPPER(c.last_name)  = UPPER('Sargunam')
  AND c.email = 'hasmitha.sargunam@example.com'
RETURNING p.payment_id, p.customer_id, p.rental_id, p.amount;

DELETE FROM public.rental r
USING public.customer c
WHERE c.customer_id = r.customer_id
  AND UPPER(c.first_name) = UPPER('Hasmitha')
  AND UPPER(c.last_name)  = UPPER('Sargunam')
  AND c.email = 'hasmitha.sargunam@example.com'
RETURNING r.rental_id, r.customer_id, r.inventory_id;

COMMIT;


/* ---------------------------------------------------------------------
   SUBTASK 7: rent my 3 favorite films and pay for them
   One transaction for rental + payment: a payment must never exist without its
     rental, so both succeed or both are undone.
   Partitions: payment is partitioned by payment_date. Partitions for January-June
     2017 are created if missing; if a partition covering the month already exists
     (same name or overlapping range) the error is caught and skipped.
   Rental: from the store where the film is in stock, handled by an employee of that
     store (lowest active staff_id); return date = rental date + rental_duration days.
   Payment: amount = the film's rental_rate; payment date = rental date (first half of 2017).
   Uniqueness: a rental is skipped if me/this inventory item already has one; a payment
     is skipped if its rental is already paid.
   Relationships: inventory_id, customer_id, staff_id, rental_id and amount are all
     taken from existing rows via joins.
   --------------------------------------------------------------------- */
BEGIN;

DO $$
DECLARE
    m date;
BEGIN
    FOR m IN SELECT generate_series(date '2017-01-01', date '2017-06-01', interval '1 month')::date LOOP
        BEGIN
            EXECUTE format('CREATE TABLE IF NOT EXISTS public.%I PARTITION OF public.payment FOR VALUES FROM (%L) TO (%L)',
                           'payment_p' || to_char(m, 'YYYY_MM'), m, (m + interval '1 month')::date);
        EXCEPTION WHEN invalid_object_definition THEN
            RAISE NOTICE 'A partition covering % already exists, skipped', m;
        END;
    END LOOP;
END $$;

INSERT INTO public.rental (rental_date, inventory_id, customer_id, return_date, staff_id, last_update)
SELECT v.rental_date::timestamptz,
       i.inventory_id,
       c.customer_id,
       v.rental_date::timestamptz + f.rental_duration * INTERVAL '1 day',
       st.staff_id,
       current_date
FROM (VALUES
        ('THE SHAWSHANK REDEMPTION', '2017-01-15 12:00:00'),
        ('INCEPTION',                '2017-03-10 15:30:00'),
        ('THE GRAND BUDAPEST HOTEL', '2017-05-20 18:45:00')
     ) AS v(title, rental_date)
JOIN public.film f ON UPPER(f.title) = UPPER(v.title)
JOIN (SELECT film_id, store_id, MIN(inventory_id) AS inventory_id
      FROM public.inventory
      GROUP BY film_id, store_id) i ON i.film_id = f.film_id
JOIN (SELECT s.store_id
      FROM public.store s
      WHERE EXISTS (SELECT 1 FROM public.staff sf WHERE sf.store_id = s.store_id)
      ORDER BY s.store_id
      LIMIT 1) s ON s.store_id = i.store_id
JOIN public.customer c ON UPPER(c.first_name) = UPPER('Hasmitha')
                      AND UPPER(c.last_name)  = UPPER('Sargunam')
                      AND c.email = 'hasmitha.sargunam@example.com'
CROSS JOIN LATERAL (SELECT sf.staff_id
                    FROM public.staff sf
                    WHERE sf.store_id = s.store_id
                    ORDER BY sf.active DESC, sf.staff_id
                    LIMIT 1) st
WHERE NOT EXISTS (SELECT 1
                  FROM public.rental r
                  WHERE r.inventory_id = i.inventory_id
                    AND r.customer_id  = c.customer_id)
RETURNING rental_id, rental_date, inventory_id, customer_id, staff_id, return_date, last_update;

INSERT INTO public.payment (customer_id, staff_id, rental_id, amount, payment_date)
SELECT r.customer_id, r.staff_id, r.rental_id, f.rental_rate, r.rental_date
FROM public.rental r
JOIN public.customer  c ON c.customer_id = r.customer_id
                       AND UPPER(c.first_name) = UPPER('Hasmitha')
                       AND UPPER(c.last_name)  = UPPER('Sargunam')
                       AND c.email = 'hasmitha.sargunam@example.com'
JOIN public.inventory i ON i.inventory_id = r.inventory_id
JOIN public.film      f ON f.film_id = i.film_id
WHERE UPPER(f.title) IN ('THE SHAWSHANK REDEMPTION', 'INCEPTION', 'THE GRAND BUDAPEST HOTEL')
  AND NOT EXISTS (SELECT 1 FROM public.payment p WHERE p.rental_id = r.rental_id)
RETURNING payment_id, customer_id, staff_id, rental_id, amount, payment_date;

COMMIT;


/* ---------------------------------------------------------------------
   Final check (read-only): what the script produced
   --------------------------------------------------------------------- */
SELECT f.title, f.release_year, f.rental_duration, f.rental_rate, f.last_update
FROM public.film f
WHERE UPPER(f.title) IN ('THE SHAWSHANK REDEMPTION', 'INCEPTION', 'THE GRAND BUDAPEST HOTEL')
ORDER BY f.release_year;

SELECT f.title, a.first_name, a.last_name
FROM public.film_actor fa
JOIN public.film  f ON f.film_id  = fa.film_id
JOIN public.actor a ON a.actor_id = fa.actor_id
WHERE UPPER(f.title) IN ('THE SHAWSHANK REDEMPTION', 'INCEPTION', 'THE GRAND BUDAPEST HOTEL')
ORDER BY f.title, a.last_name;

SELECT c.customer_id, c.first_name, c.last_name, f.title, r.rental_date, p.amount, p.payment_date
FROM public.customer c
JOIN public.rental r    ON r.customer_id  = c.customer_id
JOIN public.inventory i ON i.inventory_id = r.inventory_id
JOIN public.film f      ON f.film_id      = i.film_id
LEFT JOIN public.payment p ON p.rental_id = r.rental_id
WHERE UPPER(c.first_name) = UPPER('Hasmitha') AND UPPER(c.last_name) = UPPER('Sargunam')
ORDER BY r.rental_date;
