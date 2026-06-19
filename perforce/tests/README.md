# perforce/tests — trigger & tool unit tests

Pure-logic tests for the Perforce triggers and the janitor. No live `p4d`, no
network: the `p4` shell-outs (and the P4Python connection) are stubbed, so these
run anywhere Python does. Stdlib `unittest` only — the dependency-free Python
analogue of the repo's throw-on-failure `.ps1` convention (no pytest install).

| File | Covers |
|---|---|
| `test_validate_submit.py` | depot-hygiene trigger: forbidden compiled-output extensions, the `//thirdparty/` prebuilt-binary exemption, the oversized-file rule + `[large-ok]` override, `describe -s` parsing, fail-open on unknown size. |
| `test_require_engine_tag.py` | the `//engine/` gate: tag required / present (case-insensitive) / exempt non-engine change / mixed change still gated, plus `describe -s` parsing. |
| `test_stale_cl_janitor.py` | `age_days` epoch math + fallbacks, `files_in_change`, and the safety contract: dry-run mutates nothing, `--apply` shelves+reverts only non-empty stale CLs. |
| `_triggerlib.py` | helpers: load a hyphenated-name trigger by path; inject a stub `P4` module so the janitor imports without P4Python. |

## Run

```bash
python3 -m unittest discover -s perforce/tests -t perforce/tests -v
```

Or via the repo-wide runner from the root: `./run-tests.sh`.
