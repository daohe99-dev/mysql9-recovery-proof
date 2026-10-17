#!/usr/bin/env bash
# Synthetic, isolated recovery-order proof. Never point this at existing data.
set -euo pipefail
IMAGE='mysql@sha256:1257504944c538da4aedd8ab06f0e280c8716b72ba16ac38fe134b9eb8145168'
run_id="$(cat /proc/sys/kernel/random/uuid)"
volume="mysql9-proof-${run_id}"
container="mysql9-proof-${run_id}"
volume_created=0
old_password='SyntheticOriginal_17Oct2026'
new_password='SyntheticRecovered_17Oct2026'
checks=0
pass() { checks=$((checks + 1)); printf 'PASS %s: %s\n' "$checks" "$1"; }
cleanup() {
  if [ "$(docker inspect --format '{{index .Config.Labels "proof.token"}}' "$container" 2>/dev/null || true)" = "$run_id" ]; then
    docker rm -f "$container" >/dev/null 2>&1 || true
  fi
  if [ "$volume_created" = 1 ] && [ "$(docker volume inspect --format '{{index .Labels "proof.token"}}' "$volume" 2>/dev/null || true)" = "$run_id" ]; then
    docker volume rm "$volume" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
sql() {
  local password="$1" statement="$2"
  docker exec -e MYSQL_PWD="$password" "$container" \
    mysql --protocol=socket --user=root --batch --skip-column-names -e "$statement"
}
wait_ready() {
  local password="$1"
  for attempt in $(seq 1 90); do
    # Official entrypoint ends by exec'ing mysqld. Avoid its temporary init server.
    if docker exec "$container" sh -c 'test "$(cat /proc/1/comm)" = mysqld' 2>/dev/null \
       && sql "$password" 'SELECT 1' >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  docker logs --tail 50 "$container"
  return 1
}
expect_error() {
  local password="$1" statement="$2" code="$3" result
  if result=$(sql "$password" "$statement" 2>&1); then
    printf 'Expected ERROR %s but SQL succeeded\n' "$code" >&2; exit 1
  fi
  if ! grep -q "ERROR $code " <<<"$result"; then
    printf 'Expected ERROR %s; got: %s\n' "$code" "$result" >&2; exit 1
  fi
  # Do not print SQL or passwords, even though these fixture values are public.
  printf 'Observed expected ERROR %s\n' "$code"
}

docker pull "$IMAGE"
if docker volume inspect "$volume" >/dev/null 2>&1 || docker inspect "$container" >/dev/null 2>&1; then
  echo 'Refusing an existing resource name' >&2; exit 1
fi
docker volume create --label "proof.token=$run_id" "$volume" >/dev/null
test "$(docker volume inspect --format '{{index .Labels "proof.token"}}' "$volume")" = "$run_id"
volume_created=1
docker run -d --name "$container" --label "proof.token=$run_id" --network none \
  --mount "type=volume,src=$volume,dst=/var/lib/mysql" \
  -e MYSQL_ROOT_PASSWORD="$old_password" "$IMAGE" >/dev/null
wait_ready "$old_password"
version=$(sql "$old_password" 'SELECT VERSION()')
test "$version" = '9.7.2'
pass "exact official MySQL version $version"
test "$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$container")" = none
test "$(docker inspect --format '{{len .HostConfig.PortBindings}}' "$container")" = 0
pass 'container has no external network and publishes no ports'
sql "$old_password" "CREATE DATABASE proof; CREATE TABLE proof.sentinel (id INT PRIMARY KEY, payload VARCHAR(80) NOT NULL); INSERT INTO proof.sentinel VALUES (1, 'SYNTHETIC_PRESERVATION_SENTINEL'); DROP USER IF EXISTS 'root'@'%';"
test "$(sql "$old_password" "SELECT COUNT(*) FROM mysql.user WHERE User='root' AND Host='%'")" = 0
pass 'fixture deliberately has no wildcard root account'
docker stop "$container" >/dev/null
docker rm "$container" >/dev/null

# Same disposable volume, only one server at a time; no owner or customer data.
docker run -d --name "$container" --label "proof.token=$run_id" --network none \
  --mount "type=volume,src=$volume,dst=/var/lib/mysql" \
  "$IMAGE" mysqld --skip-grant-tables --skip-networking >/dev/null
wait_ready ''
test "$(sql '' 'SELECT @@GLOBAL.skip_networking, @@GLOBAL.skip_grant_tables')" = $'1\t1'
pass 'recovery server has both networking and grant-table loading disabled'
expect_error '' "ALTER USER 'root'@'localhost' IDENTIFIED BY '$new_password'" 1290
pass 'ALTER USER before FLUSH PRIVILEGES reproduces ERROR 1290'
test "$(sql '' "SELECT CONCAT(User,'@',Host,':',plugin,':',account_locked) FROM mysql.user WHERE User='root'")" = 'root@localhost:caching_sha2_password:N'
pass 'account diagnostic finds the actual existing root host without hashes'

sql '' "FLUSH PRIVILEGES; ALTER USER 'root'@'localhost' IDENTIFIED BY '$new_password';"
test "$(sql "$new_password" 'SELECT CURRENT_USER()')" = 'root@localhost'
pass 'FLUSH PRIVILEGES before ALTER USER succeeds for the existing account'
expect_error "$old_password" 'SELECT 1' 1045
pass 'original credential is denied after reset'
expect_error "$new_password" "ALTER USER 'root'@'%' IDENTIFIED BY '$new_password'" 1396
pass 'blindly altering nonexistent root@% reproduces ERROR 1396'
test "$(sql "$new_password" 'SELECT payload FROM proof.sentinel WHERE id=1')" = 'SYNTHETIC_PRESERVATION_SENTINEL'
pass 'synthetic application row remains readable after the account change'
docker stop "$container" >/dev/null
docker rm "$container" >/dev/null

# Back to normal authentication, with the original env var intentionally unchanged.
docker run -d --name "$container" --label "proof.token=$run_id" --network none \
  --mount "type=volume,src=$volume,dst=/var/lib/mysql" \
  -e MYSQL_ROOT_PASSWORD="$old_password" "$IMAGE" >/dev/null
wait_ready "$new_password"
test "$(sql "$new_password" 'SELECT @@GLOBAL.skip_grant_tables')" = 0
test "$(sql "$new_password" 'SELECT payload FROM proof.sentinel WHERE id=1')" = 'SYNTHETIC_PRESERVATION_SENTINEL'
expect_error "$old_password" 'SELECT 1' 1045
pass 'normal restart restores grant checking and retains new password and sentinel'
test "$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$container")" = none
pass 'final normal-mode server remains network-isolated'
printf '\nRESULT: %s checks passed; MySQL %s; image %s\n' "$checks" "$version" "$IMAGE"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '## Synthetic MySQL recovery proof\n\n%s checks passed on MySQL %s.\n\nImage: `%s`\n\nNo Railway or production connection; no owner/customer volume or credentials.\n' "$checks" "$version" "$IMAGE" >> "$GITHUB_STEP_SUMMARY"
fi
