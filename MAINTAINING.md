# Maintaining getout

`getout.sh` is still the release artifact: one self-contained script for raw GitHub install/update, copy-paste recovery, and `getout.sh.sha256` verification.

Development sources now live in `src/*.sh`. Run `./build.sh` to concatenate them into `getout.sh` and regenerate `getout.sh.sha256`.

`getout.sh` contains a generated-file notice near the top. Do not edit that release artifact directly during normal development.

## Source layout

```text
src/
  00_prelude.sh
  01_constants.sh
  02_logging.sh
  03_update.sh
  04_config.sh
  05_resolver.sh
  06_rollback.sh
  07_deps_downloads.sh
  08_helpers.sh
  09_runtime_safety.sh
  10_route_scripts.sh
  11_server.sh
  12_client.sh
  13_lifecycle_status_doctor.sh
  14_cli.sh

build.sh
getout.sh
getout.sh.sha256
tests/
```

## Module responsibilities

- `00_prelude.sh`: shebang and shell options.
- `01_constants.sh`: version, paths, URLs, DNS lists, routing marks, service names, and the release maintainer map.
- `02_logging.sh`: log/fatal helpers.
- `03_update.sh`: self-install, update, downloads used by update, and SHA256 verification.
- `04_config.sh`: config directory setup, private file permissions, safe config checks, and file metadata helpers.
- `05_resolver.sh`: managed resolver/gai restore helpers and conflict handling.
- `06_rollback.sh`: runtime/server snapshots and rollback trap guard.
- `07_deps_downloads.sh`: Debian/root checks, apt deps, TUN checks, gost/tun2socks downloads.
- `08_helpers.sh`: quoting, escaping, IP/address helpers, SSH detection, and main IP detection.
- `09_runtime_safety.sh`: fallback cleanup, tun preflight, and restart-with-rollback wrappers.
- `10_route_scripts.sh`: generation of `routes-up.sh` and `routes-down.sh`.
- `11_server.sh`: entry/server mode service/config flows.
- `12_client.sh`: outlet/client mode config, tun config/service, priority switching.
- `13_lifecycle_status_doctor.sh`: cleanup, restart, uninstall, status, and doctor/check.
- `14_cli.sh`: menu, usage, command dispatch, and `main "$@"`.

## Rules for future changes

- Edit `src/*.sh`, not `getout.sh`, unless you are intentionally debugging generated output.
- Run `./build.sh` after changing `src/*.sh`.
- Keep committing generated `getout.sh` and `getout.sh.sha256`; they are part of the release surface.
- If you add, remove, or rename a source module, update the `modules=(...)` list in `build.sh`. The build fails when `src/*.sh` contains an unlisted module, a listed module is missing, or a module appears twice.
- Do not change `status` plaintext password output unless the project owner explicitly changes that design decision.
- Prefer adding tests in `tests/run.sh` before or with behavior changes.
- Keep `getout.sh` single-file install/update behavior intact unless the install/update flow is explicitly redesigned.

## Validation gate

Run before committing:

```bash
./build.sh
bash -n getout.sh
bash -n tests/run.sh
tests/run.sh
git diff --check
```

`tests/run.sh` also checks that `build.sh` output is current, so forgetting to regenerate `getout.sh` or `getout.sh.sha256` should fail the test gate.
