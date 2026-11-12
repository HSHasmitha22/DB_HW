/* =====================================================================
   SQL_DML_HW  |  Task 2  |  DELETE vs TRUNCATE vs VACUUM FULL
  
SELECT *, pg_size_pretty(total_bytes) AS total, pg_size_pretty(index_bytes) AS INDEX,
       pg_size_pretty(toast_bytes) AS toast, pg_size_pretty(table_bytes) AS TABLE
FROM (SELECT *, total_bytes-index_bytes-COALESCE(toast_bytes,0) AS table_bytes
      FROM (SELECT c.oid, nspname AS table_schema, relname AS TABLE_NAME, c.reltuples AS row_estimate,
                   pg_total_relation_size(c.oid) AS total_bytes,
                   pg_indexes_size(c.oid) AS index_bytes,
                   pg_total_relation_size(reltoastrelid) AS toast_bytes
            FROM pg_class c
            LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE relkind = 'r') a) a
WHERE table_name LIKE '%table_to_delete%';


/* ---------------------------------------------------------------------
   STEP 1: create and fill the table (10^7 rows)
   Dropping first makes the script rerunnable.
   Result: 575 MB (602,415,104 bytes), 0 indexes; creation took about 7-11 s.
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS public.table_to_delete;

CREATE TABLE public.table_to_delete AS
SELECT 'veeeeeeery_long_string' || x AS col
FROM generate_series(1, (10^7)::int) x;   -- 10^7 rows


/* STEP 2: space consumed: run the helper query above.  -> 575 MB */


/* ---------------------------------------------------------------------
   STEP 3a: DELETE 1/3 of the rows (note the execution time)
   Result: 3,333,333 rows deleted, 5.2 s (4.8 s on a second run).
   WAL written: about 755 MB (more than the table itself).
   --------------------------------------------------------------------- */
DELETE FROM public.table_to_delete
WHERE REPLACE(col, 'veeeeeeery_long_string', '')::int % 3 = 0;

/* STEP 3b: space after DELETE: run the helper query.
   Result: STILL 575 MB (602,415,104 bytes). Live rows 6,666,667;
   pg_stat_user_tables shows n_dead_tup = 3,333,333. */

/* STEP 3c: rewrite the table. Result: 2.8 s, 73,536 pages processed. */
VACUUM FULL VERBOSE public.table_to_delete;

/* STEP 3d: space after VACUUM FULL: run the helper query.
   Result: 383 MB (401,580,032 bytes) = 200,835,072 bytes (33.3 %) freed,
   which matches the one third of the rows that were deleted. */

-- STEP 3e: recreate the table (same statement as step 1)
DROP TABLE IF EXISTS public.table_to_delete;

CREATE TABLE public.table_to_delete AS
SELECT 'veeeeeeery_long_string' || x AS col
FROM generate_series(1, (10^7)::int) x;


/* ---------------------------------------------------------------------
   STEP 4a: TRUNCATE (note the execution time)
   Result: 0.257 s (about 20x faster than the DELETE, and it removed ALL rows,
   3x more than the DELETE). WAL written: about 20 KB (vs about 755 MB for DELETE).
   The table file was swapped (filenode 16394 -> 16399).
   --------------------------------------------------------------------- */
TRUNCATE public.table_to_delete;

/* STEP 4c: space after TRUNCATE: run the helper query.
   Result: 8 KB total (heap 0 bytes; the 8 KB is the empty TOAST table). 0 rows.
   The space was returned to the operating system immediately. */


/* =====================================================================
   RESULTS SUMMARY: space consumption (table_to_delete)
   ---------------------------------------------------------------------
   after CREATE            10,000,000 rows   575 MB
   after DELETE (1/3)       6,666,667 live   575 MB   (3,333,333 dead rows kept)
   after VACUUM FULL        6,666,667 rows   383 MB
   after re-CREATE         10,000,000 rows   575 MB
   after TRUNCATE                   0 rows   8 KB

   DELETE vs TRUNCATE
   ---------------------------------------------------------------------
   Execution time     DELETE 5.2 s (1/3 of rows)        | TRUNCATE 0.26 s (all rows)
   WAL volume         about 755 MB                      | about 20 KB
   Disk space         not released (dead tuples remain) | released immediately
   Locking            ROW EXCLUSIVE (others keep working)| ACCESS EXCLUSIVE (blocks everyone)
   Transaction        fully transactional (MVCC)        | fully transactional in PostgreSQL
   Rollback           yes: tested, 1000 rows restored   | yes: tested, 1000 rows restored
   WHERE clause       yes                               | no, whole table only

   WHY DELETE DOES NOT FREE SPACE IMMEDIATELY
   PostgreSQL uses MVCC. DELETE only marks each row version as deleted by the current
   transaction; transactions that started earlier may still need to see it, so the
   version stays in the table file as a dead tuple. The file never shrinks by itself.
   Dead tuples are cleaned up later by (auto)VACUUM, which makes the space reusable
   inside the same file but normally does not give it back to the operating system
   (tested: after plain VACUUM and re-inserting 3.3M rows the table stayed at 575 MB).

   WHY VACUUM FULL CHANGES TABLE SIZE
   It writes a brand-new copy of the table containing only live rows, rebuilds the
   indexes, then replaces the old file. Dead space is not copied, so the file shrinks.
   Cost: ACCESS EXCLUSIVE lock for the whole run, extra disk space for the new copy while
   the old one exists, and a full rewrite of the table.

   WHY TRUNCATE BEHAVES DIFFERENTLY
   TRUNCATE does not process rows. It creates a new empty file for the table and discards
   the old one, so it logs almost nothing, is fast and frees the space at once. It
   requires an ACCESS EXCLUSIVE lock, cannot filter rows, and (per the PostgreSQL docs,
   not tested here) does not fire row-level DELETE triggers and needs CASCADE when other
   tables reference the table.

   PERFORMANCE AND STORAGE EFFECTS
   DELETE: slow for big deletes, heavy WAL, leaves bloat that scans must skip until VACUUM.
   VACUUM FULL: only option here that returns space to the OS, but blocks the table.
   TRUNCATE: best to empty a whole table; minimal WAL; exclusive lock.
   Rule of thumb: partial removal = DELETE + regular VACUUM; remove everything = TRUNCATE;
   VACUUM FULL only in a maintenance window when disk space must really be reclaimed.
   ===================================================================== */
