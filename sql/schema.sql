-- Lab 4 schema and seed data.
--
-- Terraform runs this once, right after the RDS instance comes up, by invoking
-- the Lambda with {"path": "/init"}. The file is plain MySQL 8 and can also be
-- pasted into any client by hand.
--
-- To change the data volume, edit the two `n < ...` bounds near the bottom.

DROP TABLE IF EXISTS reviews;
DROP TABLE IF EXISTS products;

CREATE TABLE products (
    id       INT PRIMARY KEY,
    name     VARCHAR(100)   NOT NULL,
    category VARCHAR(32)    NOT NULL,
    price    DECIMAL(10, 2) NOT NULL
) ENGINE = InnoDB;

CREATE TABLE reviews (
    id         INT PRIMARY KEY,
    product_id INT     NOT NULL,
    rating     TINYINT NOT NULL
) ENGINE = InnoDB;

-- Deliberately no index on products.category or reviews.product_id. The read
-- in the API aggregates over both columns, so without indexes it costs several
-- full table scans. That is what makes the cached and uncached latencies differ
-- by an order of magnitude instead of a few percent -- which is the whole point
-- of the lab. Adding indexes here would hide the effect the cache is meant to
-- demonstrate.

-- The recursive CTE generates rows inside MySQL. Sending 200k INSERTs from
-- Lambda over the wire would be far slower and would risk the function timeout.
SET SESSION cte_max_recursion_depth = 5000000;

INSERT INTO products (id, name, category, price)
WITH RECURSIVE seq(n) AS (
    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 50000
)
SELECT n,
       CONCAT('Product ', n),
       CONCAT('cat-', n % 50),
       ROUND(RAND() * 990 + 10, 2)
FROM seq;

INSERT INTO reviews (id, product_id, rating)
WITH RECURSIVE seq(n) AS (
    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 150000
)
SELECT n,
       FLOOR(RAND() * 50000) + 1,
       FLOOR(RAND() * 5) + 1
FROM seq;

ANALYZE TABLE products;
ANALYZE TABLE reviews;
