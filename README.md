# Cache-Aside on AWS — ALB + Lambda + ElastiCache + RDS

A small but complete cache-aside deployment, built with Terraform, designed so
the cost of a cache miss is easy to see and measure.

```
client ──> ALB ──> Lambda ──> ElastiCache (Redis)   hit  ──> return
  :80    (in VPC)       │
                        └─ miss ──> RDS (MySQL 8) ──> fill cache ──> return
```

Ask the API for a product and it tells you where the answer came from and how
long each tier took:

```jsonc
{
  "source": "database",   "cache": "MISS",  "db_ms": 84.64,  "total_ms": 87.54,
  "product": { "id": 42, "name": "Product 42", "category": "cat-42", ... }
}
{
  "source": "cache",      "cache": "HIT",   "db_ms": 0,      "total_ms": 1.40,
  "product": { "id": 42, "name": "Product 42", "category": "cat-42", ... }
}
```

On the hit, `db_ms` is **0** — MySQL was never contacted. That gap, roughly 60x
on the smallest instance classes AWS offers, is the whole point of the project.

## Why it is slow on purpose

`sql/schema.sql` deliberately leaves `products.category` and
`reviews.product_id` unindexed. The read in `app/handler.py` runs four
correlated subqueries over exactly those columns, so every uncached request
costs several full table scans over 50,000 products and 150,000 reviews.

Indexing them would make the uncached path fast and erase the effect this
project exists to demonstrate. The comments saying so in both files are
load-bearing, not leftover TODOs.

## Layout

| Path | What it is |
|---|---|
| `terraform/` | The stack: network, RDS, ElastiCache, Lambda, ALB |
| `app/handler.py` | The function behind the load balancer |
| `sql/schema.sql` | Tables and seed data, applied once at creation |
| `scripts/build_lambda.sh` | Builds the deployment package |
| `scripts/Test-Cache.ps1` | Read a product, see cache-vs-database and timings |
| `scripts/Test-Deployment.ps1` | Eight assertions against a fresh deployment |
| `docs/architecture.html` | Diagrams: topology, request timing, alias chain |

## Requirements

- Terraform >= 1.10
- AWS CLI v2, with a configured profile
- An S3 bucket for remote state
- Bash for the one build script — Git Bash is fine on Windows
- PowerShell 7+ for the test scripts

## Deploy

```bash
# 1. Assemble the Lambda package. Required before plan or apply.
./scripts/build_lambda.sh

# 2. Apply
cd terraform
cp terraform.tfvars.example terraform.tfvars   # optional, edit to taste
terraform init
terraform plan
terraform apply
```

Budget about 12 minutes. RDS takes the longest (~6½ min); ElastiCache and the
ALB build in parallel, and the VPC-attached Lambda adds another ~4.

`apply` finishes by invoking the function with `{"path": "/init"}`, which
executes `sql/schema.sql` against the new database. RDS is not publicly
accessible, so the in-VPC Lambda is the only path to it — there is no step where
you run a `.sql` file by hand. Editing the schema and re-applying re-runs it,
because the file's hash is part of the invocation input.

### Configuration

Everything worth changing is a variable in `terraform/variables.tf`. Anything
that costs real money defaults to off:

| Variable | Default | Notes |
|---|---|---|
| `aws_region` | `us-east-1` | |
| `aws_profile` | `academy` | Change to your own profile |
| `allowed_cidr` | `0.0.0.0/0` | Narrow this to your own address |
| `az_count` | `3` | 2 is the ALB minimum |
| `cache_node_count` | `1` | 2+ adds a replica and automatic failover |
| `db_multi_az` | `false` | |
| `lambda_provisioned_concurrency` | `0` | Bills hourly; see below |

Remote state is configured in `terraform/versions.tf`. It uses S3-native locking
(`use_lockfile = true`), so no DynamoDB table is needed.

## Testing

### One request

```powershell
.\scripts\Test-Cache.ps1 -Id 42
```

```
  HIT    served from cache      db        0 ms   total     1.40 ms   round trip    38.12 ms
```

### The comparison

```powershell
.\scripts\Test-Cache.ps1 -Id 42 -Compare
```

Flushes the cache, then reads the same id three ways:

```
  MISS   served from database   db    84.64 ms   total    87.54 ms
  HIT    served from cache      db     0.00 ms   total     1.40 ms
  BYPASS served from database   db   117.20 ms   total   119.81 ms

  The cached read is 62.5x faster.
  On the hit, db time is 0 ms - MySQL was never touched.
```

`BYPASS` is the control: same query, same data, cache deliberately skipped with
`&nocache=1`. It is what the endpoint would cost with no cache at all.

Other switches: `-NoCache`, `-Flush`, `-Repeat <n>`, `-BaseUrl <url>`.

### Full check after a deploy

```powershell
.\scripts\Test-Deployment.ps1
```

Eight requests, one per assertion: the ALB answers, the tables hold 50,000 and
150,000 rows, the first read misses and the second hits, `nocache=1` bypasses,
both paths return byte-identical payloads, the hit is more than 5x faster, and
unknown routes return 404 rather than a gateway error.

### By hand

```powershell
$b = "http://<alb-dns-name>"
curl.exe -s "$b/flush" | Out-Null
curl.exe -s "$b/product?id=42" | ConvertFrom-Json | Select-Object source, cache, db_ms, total_ms
curl.exe -s "$b/product?id=42" | ConvertFrom-Json | Select-Object source, cache, db_ms, total_ms
```

Use `curl.exe`, not `curl` — the bare name is ambiguous in PowerShell.

## Endpoints

| Route | Behaviour |
|---|---|
| `GET /` | Route list |
| `GET /health` | Liveness |
| `GET /product?id=<n>` | Cache-aside read. `X-Cache: HIT` or `MISS` |
| `GET /product?id=<n>&nocache=1` | Same query, always hits MySQL. `X-Cache: BYPASS` |
| `GET /product?id=<n>&ttl=<s>` | Override the cache TTL for this write |
| `GET /stats` | Redis hit rate and key count, MySQL row counts, connection count |
| `GET /flush` | Empty the cache |
| `GET /init` | Apply `sql/schema.sql` (Terraform calls this for you) |

## How it holds up under concurrent load

Lambda will scale to 200 concurrent executions. Everything below exists to make
sure RDS is not what happens next.

- **Connections are reused.** The MySQL and Redis clients are built once per
  execution environment and held in module scope, so a warm invocation opens no
  sockets. Constructing them inside the handler would turn 200 concurrent
  requests into 200 new MySQL connections.
- **The cache absorbs the reads.** `db.t3.micro` caps out around 150
  connections, and the query is several full table scans. Redis serves the same
  payload in single-digit milliseconds without touching the database.
- **Cache failures degrade latency, not availability.** Every Redis call is
  wrapped and falls through to MySQL, reporting `X-Cache: UNAVAILABLE`.
- **`volatile-lru`** on the Redis parameter group, so a full cache evicts its
  coldest key instead of returning OOM errors — which would silently push every
  request back to MySQL while the cache still looked healthy.
- **Reserved concurrency** caps how hard Lambda can hit RDS and guarantees that
  capacity is available to this function.
- **Provisioned concurrency** (`lambda_provisioned_concurrency`, default `0`)
  pre-warms execution environments, taking cold starts out of the tail. It bills
  hourly, so raise it only while you are measuring.
- **1024 MB of memory**, which on Lambda is really a CPU setting: compute scales
  in proportion to memory.

## Design notes

**The ALB targets a Lambda alias, not the function.** Provisioned concurrency
cannot attach to `$LATEST`, so the function publishes a version, an alias named
`live` points at it, and both the target group attachment and the invoke
permission reference that alias. Break any one of those links and the stack
still applies cleanly, then serves 502s.

**The Lambda security group has no ingress rule.** The ALB invokes the function
through the Lambda API rather than over the network, so nothing ever connects to
its ENIs. That is correct, not an omission.

**RDS is not publicly accessible**, and its security group admits only the
Lambda security group. The same is true of ElastiCache on 6379.

**No pip in the build.** `pymysql` and `redis` are pure-Python wheels, and a
wheel is a zip, so `build_lambda.sh` fetches them from the PyPI simple index with
`curl` and unpacks them. This behaves identically in Git Bash, WSL, Linux and
CI. A dependency with compiled extensions would need Docker or a Lambda layer
built on Amazon Linux instead.

## Tear down

```bash
cd terraform
terraform destroy
```

Backups and final snapshots are disabled, so this is quick and leaves nothing
billable behind.

## Notes for AWS Academy accounts

The stack is written to work inside the Learner Lab, which shapes a few choices:

- Lambda reuses the pre-provisioned `LabRole`; the account cannot create IAM
  roles, so do not add an `aws_iam_role` resource.
- It uses the default VPC. Private subnets would need a NAT gateway for nothing —
  the data tier requires no outbound internet.
- The account-wide concurrency ceiling is 400.
- Credentials are temporary and expire when the lab session ends.
