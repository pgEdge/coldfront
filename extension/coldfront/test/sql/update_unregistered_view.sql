-- Extension must NOT rewrite DML on views absent from coldfront.tiered_views.
CREATE EXTENSION IF NOT EXISTS coldfront;

CREATE TABLE base_tbl (id int, val text);
INSERT INTO base_tbl VALUES (1, 'original');

CREATE VIEW plain_view AS SELECT * FROM base_tbl;

-- UPDATE via a plain (non-tiered) view must work normally.
-- PG supports UPDATE through simple views without triggers.
UPDATE plain_view SET val = 'updated' WHERE id = 1;
SELECT val FROM base_tbl WHERE id = 1;

DROP VIEW plain_view;
DROP TABLE base_tbl;
