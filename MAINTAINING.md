# Maintaining getout

`getout.sh` is intentionally released as a single self-contained script. This keeps raw GitHub install/update, copy-paste recovery, and `getout.sh.sha256` simple.

To keep the single file reviewable, maintain changes inside the section map at the top of `getout.sh`:

1. constants / globals
2. logging helpers
3. self install / update / checksum
4. config permissions and file metadata
5. runtime/server rollback snapshots
6. host prerequisites and binary downloads
7. encoding, address, and SSH helpers
8. cleanup, preflight, and restart wrappers
9. generated route scripts
10. service state and entry/server mode
11. outlet/client mode
12. lifecycle, status, diagnostics, and CLI

## Rules for future changes

- Keep release output as a single `getout.sh` unless the install/update flow is redesigned.
- Do not change `status` plaintext password output unless the project owner explicitly changes that design decision.
- Prefer adding tests in `tests/run.sh` before or with behavior changes.
- Regenerate `getout.sh.sha256` whenever `getout.sh` changes.
- Run this gate before committing:

```bash
bash -n getout.sh
bash -n tests/run.sh
tests/run.sh
git diff --check
```

## When to split files

If a section keeps growing, split in development only:

```text
src/
  00_constants.sh
  01_logging.sh
  02_update.sh
  03_config.sh
  04_rollback.sh
  05_deps_downloads.sh
  06_helpers.sh
  07_runtime_wrappers.sh
  08_routes_template.sh
  09_server.sh
  10_client.sh
  11_cli.sh
build.sh
getout.sh
```

`build.sh` should concatenate `src/*.sh` into the release `getout.sh`, then regenerate `getout.sh.sha256`. Tests should continue to validate the generated release file.
