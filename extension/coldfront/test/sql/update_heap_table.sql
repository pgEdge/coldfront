-- Extension must NOT touch DML on regular heap tables.
CREATE EXTENSION IF NOT EXISTS coldfront;

CREATE TABLE heap_tbl (id int PRIMARY KEY, val text);
INSERT INTO heap_tbl VALUES (1, 'original'), (2, 'other');

UPDATE heap_tbl SET val = 'updated' WHERE id = 1;
SELECT id, val FROM heap_tbl ORDER BY id;

DELETE FROM heap_tbl WHERE id = 2;
SELECT count(*) FROM heap_tbl;

DROP TABLE heap_tbl;
