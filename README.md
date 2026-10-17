# Synthetic MySQL 9 recovery-order proof

This is an AI-assisted test fixture for the SQL ordering in a public MySQL recovery discussion. It does **not** diagnose the cause of a production `ERROR 1045`, recover a customer database, or prove that a customer's volume is backed up or undamaged.

The official MySQL 9.7 recovery instructions require `FLUSH PRIVILEGES` **before** `ALTER USER` when the server has been started with `--skip-grant-tables`. Account names also include a host: `root@localhost` and `root@%` are distinct, and either may be absent.

## What the test actually does

`bash proof.sh` creates one disposable Docker volume with one synthetic application row. It uses the official Linux/amd64 MySQL 9.7.2 image, pinned to:

```
mysql@sha256:1257504944c538da4aedd8ab06f0e280c8716b72ba16ac38fe134b9eb8145168
```

The test checks that the premature `ALTER USER` fails with error 1290, the corrected order succeeds, a nonexistent wildcard account fails with error 1396, the old password is denied, and a normal restart preserves both the new credential and the synthetic row. It also demonstrates that an unchanged initialization environment variable does not override the altered stored credential on restart.

All containers use `--network none` and publish no ports. Only one MySQL process uses the disposable volume at a time. The fixture never connects to Railway and has no production data, secrets or host-directory mounts. Resource names use a random token, existing names are refused, and cleanup checks ownership labels before removing this run's resources. The sample passwords are public synthetic fixture values.

**Do not adapt this script to mount an existing database volume.** Real recovery modifies grant tables and needs an operator-reviewed backup, downtime and recovery procedure. Do not create `root@%` merely to make a sample command succeed. Do not expose an authentication-disabled recovery server or leave recovery flags enabled.

The public standard GitHub Actions Ubuntu runner executes the Docker test without paid deployments, cache uploads or stored artifacts. An actual successful run must be inspected before claiming the proof passed. The exact tested image does not establish which MySQL 9 build the requester uses.

## Primary references

- [MySQL 9.7: reset the root password](https://dev.mysql.com/doc/refman/9.7/en/resetting-permissions.html)
- [MySQL 9.7: account names](https://dev.mysql.com/doc/refman/9.7/en/account-names.html)
- [MySQL 9.7: ALTER USER](https://dev.mysql.com/doc/refman/9.7/en/alter-user.html)
- [Docker official MySQL image source](https://github.com/docker-library/mysql)
