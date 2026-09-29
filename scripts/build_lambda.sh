#!/usr/bin/env bash
# Assemble build/lambda/ so Terraform's archive_file can zip it.
#
# pymysql and redis are both pure-Python "py3-none-any" wheels, and a wheel is
# just a zip, so this pulls them straight from PyPI and unpacks them. No pip,
# no virtualenv, no Docker -- it runs the same in Git Bash, WSL and CI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build/lambda"

PYMYSQL_VERSION="${PYMYSQL_VERSION:-1.1.1}"
REDIS_VERSION="${REDIS_VERSION:-5.2.1}"

echo "==> Cleaning $BUILD"
rm -rf "$ROOT/build"
mkdir -p "$BUILD"

# A stock WSL Ubuntu has python3 but no unzip, while Git Bash has unzip but no
# python3. Use whichever is present rather than making the user install one.
extract() {
  local zip="$1" dest="$2"
  if command -v unzip >/dev/null 2>&1; then
    unzip -qo "$zip" -d "$dest"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m zipfile -e "$zip" "$dest"
  else
    echo "need either unzip or python3 to unpack wheels" >&2
    exit 1
  fi
}

fetch_wheel() {
  local project="$1" version="$2" pattern="$3"
  local url

  echo "==> Resolving $project $version"
  url="$(curl -fsSL "https://pypi.org/simple/${project}/" \
    | grep -oE "https://files\.pythonhosted\.org/[^\"#]*${pattern}" \
    | tail -1)"

  if [[ -z "$url" ]]; then
    echo "could not find a wheel for $project $version on PyPI" >&2
    exit 1
  fi

  echo "    $url"
  curl -fsSL "$url" -o "$BUILD/.wheel.zip"
  extract "$BUILD/.wheel.zip" "$BUILD"
  rm -f "$BUILD/.wheel.zip"
}

fetch_wheel pymysql "$PYMYSQL_VERSION" "PyMySQL-${PYMYSQL_VERSION}-py3-none-any\.whl"
fetch_wheel redis   "$REDIS_VERSION"   "redis-${REDIS_VERSION}-py3-none-any\.whl"

# Wheel metadata directories are dead weight in a Lambda package.
rm -rf "$BUILD"/*.dist-info "$BUILD"/*.data

# Byte-caches embed the absolute path they were compiled at, which would put a
# local machine's directory layout inside the uploaded artifact. Lambda
# recompiles on cold start anyway, so drop them.
find "$BUILD" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$BUILD" -name '*.pyc' -delete 2>/dev/null || true

echo "==> Adding handler and schema"
cp "$ROOT/app/handler.py" "$BUILD/handler.py"
# Shipped inside the package so /init can apply it without reaching outside
# the VPC; RDS is not publicly accessible, so this is the only path in.
cp "$ROOT/sql/schema.sql" "$BUILD/schema.sql"

echo
echo "Package contents:"
ls -1 "$BUILD"
echo
echo "Size: $(du -sh "$BUILD" | cut -f1)"
echo "Done. Run 'terraform plan' from $ROOT/terraform next."
