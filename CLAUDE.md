# CLAUDE.md

Read [AGENTS.md](AGENTS.md) first: it is the guide for this repository (layout, how to change
dmc through `.deps/dmc` and `tool/export_patches.dart`, Doc's rules, and the gates). Then read
[STATUS.md](STATUS.md) and keep it current, as AGENTS.md says, and
[HACKATHON.md](HACKATHON.md).

This is the Meta AI Developer Hackathon 2026 entry, and it holds **event work only**. dmc lives in
its own repository (github.com/EvilMetaMonkey/dmc). Never copy its code or history here, and never
push to it.

Quick start:

```bash
dart run tool/setup_dmc.dart       # dmc in .deps/dmc, patched and built
cd doc && dart pub get --enforce-lockfile && dart analyze --fatal-infos
DMC_TEST_BIN=../.deps/dmc/build/dmc/bundle/bin/dmc dart test --concurrency=1
```
