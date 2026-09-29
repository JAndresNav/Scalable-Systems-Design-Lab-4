"""
Lab 4 - cache-aside API behind an ALB.

Request path:  ALB -> Lambda -> ElastiCache (Redis) -> RDS (MySQL) on miss.

Everything expensive to build (TCP connections to Redis and MySQL) is created
once per execution environment and reused across invocations, so a warm Lambda
answers a cache hit without opening a single new socket. That is what keeps p99
flat as concurrency climbs.
"""

import json
import os
import time

import pymysql
import pymysql.cursors
import redis

DB_HOST = os.environ["DB_HOST"]
DB_PORT = int(os.environ.get("DB_PORT", "3306"))
DB_USER = os.environ["DB_USER"]
DB_PASSWORD = os.environ["DB_PASSWORD"]
DB_NAME = os.environ["DB_NAME"]

REDIS_HOST = os.environ["REDIS_HOST"]
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))

CACHE_TTL = int(os.environ.get("CACHE_TTL", "60"))
CACHE_VERSION = os.environ.get("CACHE_VERSION", "v1")

# Reused across invocations in the same execution environment.
_db = None
_redis = None


def get_db():
    """Return a live MySQL connection, reconnecting only when the old one died."""
    global _db
    if _db is not None:
        try:
            _db.ping(reconnect=True)
            return _db
        except Exception:
            try:
                _db.close()
            except Exception:
                pass
            _db = None

    _db = pymysql.connect(
        host=DB_HOST,
        port=DB_PORT,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME,
        connect_timeout=5,
        read_timeout=25,
        write_timeout=25,
        autocommit=True,
        cursorclass=pymysql.cursors.DictCursor,
    )
    return _db


def get_cache():
    """Return the Redis client. Callers must tolerate it failing: a dead cache
    should degrade latency, not take the API down."""
    global _redis
    if _redis is None:
        _redis = redis.Redis(
            host=REDIS_HOST,
            port=REDIS_PORT,
            socket_timeout=1.0,
            socket_connect_timeout=1.0,
            socket_keepalive=True,
            health_check_interval=30,
            retry_on_timeout=False,
            decode_responses=True,
        )
    return _redis


# --------------------------------------------------------------------------
# Schema + seed data
# --------------------------------------------------------------------------

SCHEMA_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "schema.sql")


def split_statements(sql):
    """Split a .sql file into executable statements.

    Deliberately simple: strip full-line `--` comments, then split on `;`.
    That is enough for schema.sql, which has no stored routines, no delimiters
    and no semicolons inside string literals. Anything fancier belongs in a
    migration tool, not here.
    """
    lines = [ln for ln in sql.splitlines() if not ln.strip().startswith("--")]
    return [s.strip() for s in "\n".join(lines).split(";") if s.strip()]


def run_schema(conn):
    with open(SCHEMA_FILE, "r", encoding="utf-8") as fh:
        statements = split_statements(fh.read())

    executed = []
    with conn.cursor() as cur:
        for stmt in statements:
            cur.execute(stmt)
            # ANALYZE returns a result set; drain it so the connection stays
            # usable for the next statement.
            while cur.nextset():
                pass
            executed.append(" ".join(stmt.split())[:60])

    return executed


# --------------------------------------------------------------------------
# The expensive read
# --------------------------------------------------------------------------

# Four correlated subqueries over two unindexed columns, so each call is
# several full table scans. Cheap to describe, expensive to run -- exactly the
# kind of read a cache is for.
EXPENSIVE_QUERY = """
SELECT p.id,
       p.name,
       p.category,
       p.price,
       (SELECT COUNT(*)      FROM reviews  r WHERE r.product_id = p.id)       AS review_count,
       (SELECT AVG(r.rating) FROM reviews  r WHERE r.product_id = p.id)       AS avg_rating,
       (SELECT COUNT(*)      FROM products x WHERE x.category   = p.category) AS category_size,
       (SELECT AVG(x.price)  FROM products x WHERE x.category   = p.category) AS category_avg_price
FROM products p
WHERE p.id = %s
"""


def read_from_db(product_id):
    conn = get_db()
    with conn.cursor() as cur:
        cur.execute(EXPENSIVE_QUERY, (product_id,))
        row = cur.fetchone()

    if row is None:
        return None

    # DECIMAL comes back as Decimal, which json cannot serialise.
    return {
        "id": row["id"],
        "name": row["name"],
        "category": row["category"],
        "price": float(row["price"]),
        "review_count": int(row["review_count"]),
        "avg_rating": round(float(row["avg_rating"]), 3) if row["avg_rating"] is not None else None,
        "category_size": int(row["category_size"]),
        "category_avg_price": round(float(row["category_avg_price"]), 2),
    }


def cache_key(product_id):
    return "lab4:{}:product:{}".format(CACHE_VERSION, product_id)


# --------------------------------------------------------------------------
# Routes
# --------------------------------------------------------------------------


def route_product(params):
    product_id = int(params.get("id", "1"))
    bypass = params.get("nocache", "0") in ("1", "true", "yes")
    ttl = int(params.get("ttl", str(CACHE_TTL)))

    started = time.perf_counter()
    key = cache_key(product_id)
    cache_ms = 0.0
    cache_ok = True

    if not bypass:
        t0 = time.perf_counter()
        try:
            cached = get_cache().get(key)
        except Exception:
            cached, cache_ok = None, False
        cache_ms = (time.perf_counter() - t0) * 1000

        if cached is not None:
            total_ms = (time.perf_counter() - started) * 1000
            return 200, {
                "source": "cache",
                "cache": "HIT",
                "cache_ms": round(cache_ms, 2),
                "db_ms": 0.0,
                "total_ms": round(total_ms, 2),
                "product": json.loads(cached),
            }

    t0 = time.perf_counter()
    product = read_from_db(product_id)
    db_ms = (time.perf_counter() - t0) * 1000

    if product is None:
        return 404, {"error": "product {} not found".format(product_id)}

    if not bypass and cache_ok:
        try:
            get_cache().setex(key, ttl, json.dumps(product))
        except Exception:
            pass

    total_ms = (time.perf_counter() - started) * 1000
    return 200, {
        "source": "database",
        "cache": "BYPASS" if bypass else ("MISS" if cache_ok else "UNAVAILABLE"),
        "cache_ms": round(cache_ms, 2),
        "db_ms": round(db_ms, 2),
        "total_ms": round(total_ms, 2),
        "ttl": ttl,
        "product": product,
    }


def route_init(_params):
    """Apply sql/schema.sql. Terraform calls this once after the RDS instance
    is available; it is also safe to re-run by hand, since the file starts by
    dropping both tables."""
    t0 = time.perf_counter()
    executed = run_schema(get_db())
    seed_ms = (time.perf_counter() - t0) * 1000

    conn = get_db()
    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) AS n FROM products")
        products = cur.fetchone()["n"]
        cur.execute("SELECT COUNT(*) AS n FROM reviews")
        reviews = cur.fetchone()["n"]

    result = {
        "statements": len(executed),
        "executed": executed,
        "products": products,
        "reviews": reviews,
        "seed_ms": round(seed_ms, 2),
    }

    # Stale keys from a previous seed would serve rows that no longer exist.
    try:
        get_cache().flushdb()
        result["cache_flushed"] = True
    except Exception:
        result["cache_flushed"] = False

    return 200, result


def route_flush(_params):
    try:
        get_cache().flushdb()
        return 200, {"flushed": True}
    except Exception as exc:
        return 503, {"flushed": False, "error": str(exc)}


def route_stats(_params):
    out = {"cache": {}, "database": {}}

    try:
        client = get_cache()
        info = client.info()
        hits = int(info.get("keyspace_hits", 0))
        misses = int(info.get("keyspace_misses", 0))
        out["cache"] = {
            "reachable": True,
            "redis_version": info.get("redis_version"),
            "connected_clients": info.get("connected_clients"),
            "used_memory_human": info.get("used_memory_human"),
            "keyspace_hits": hits,
            "keyspace_misses": misses,
            "hit_rate": round(hits / (hits + misses), 4) if (hits + misses) else None,
            "keys": client.dbsize(),
        }
    except Exception as exc:
        out["cache"] = {"reachable": False, "error": str(exc)}

    try:
        conn = get_db()
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) AS n FROM products")
            products = cur.fetchone()["n"]
            cur.execute("SELECT COUNT(*) AS n FROM reviews")
            reviews = cur.fetchone()["n"]
            cur.execute("SHOW STATUS LIKE 'Threads_connected'")
            threads = cur.fetchone()["Value"]
        out["database"] = {
            "reachable": True,
            "products": products,
            "reviews": reviews,
            "threads_connected": int(threads),
        }
    except Exception as exc:
        out["database"] = {"reachable": False, "error": str(exc)}

    return 200, out


def route_health(_params):
    return 200, {"status": "ok"}


def route_index(_params):
    return 200, {
        "service": "lab4-cache-api",
        "routes": {
            "GET /health": "liveness probe",
            "GET /init": "apply sql/schema.sql (Terraform calls this once after apply)",
            "GET /product?id=<n>": "cache-aside read",
            "GET /product?id=<n>&nocache=1": "same read, always hits RDS",
            "GET /product?id=<n>&ttl=<s>": "override cache TTL for this write",
            "GET /stats": "cache hit rate, key count, DB row counts",
            "GET /flush": "empty the cache",
        },
    }


ROUTES = {
    "/": route_index,
    "/health": route_health,
    "/init": route_init,
    "/product": route_product,
    "/stats": route_stats,
    "/flush": route_flush,
}


# The ALB requires statusDescription to be "<code> <reason>". Given a bare
# "404" it discards the response and returns 502 to the client instead, which
# turns every genuine 404 into a confusing gateway error.
REASONS = {
    200: "OK",
    404: "Not Found",
    500: "Internal Server Error",
    503: "Service Unavailable",
}


def status_description(status):
    return "{} {}".format(status, REASONS.get(status, "OK"))


def handler(event, _context):
    path = (event.get("path") or "/").rstrip("/") or "/"
    params = event.get("queryStringParameters") or {}

    fn = ROUTES.get(path)
    if fn is None:
        status, body = 404, {"error": "no route for {}".format(path), "routes": sorted(ROUTES)}
    else:
        try:
            status, body = fn(params)
        except Exception as exc:
            status = 500
            body = {"error": type(exc).__name__, "detail": str(exc)}

    headers = {"Content-Type": "application/json", "Cache-Control": "no-store"}
    if isinstance(body, dict) and isinstance(body.get("cache"), str):
        headers["X-Cache"] = body["cache"]
        headers["X-Total-Ms"] = str(body.get("total_ms", ""))

    return {
        "statusCode": status,
        "statusDescription": status_description(status),
        "headers": headers,
        "isBase64Encoded": False,
        "body": json.dumps(body),
    }
