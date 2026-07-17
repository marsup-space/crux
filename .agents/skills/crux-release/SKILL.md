---
name: crux-release
description: Release a new Crux version end-to-end — version bump, quality gates (dart analyze / dart test), CHANGELOG, local release build, annotated git tag, push, and GitHub Release verification. Use when asked to release/publish/ship a version (e.g. "发布 0.15.0", "cut a release", "bump version"), when doing a local release build, or when auditing the release pipeline (install.sh, release.yml, build_release.dart).
---

# Crux Release

Single source of truth for cutting a Crux release. Repo root: the project containing this file.

## Tooling map

| Tool | Role |
|------|------|
| `tool/prepare_release.dart <X.Y.Z>` | Bumps `pubspec.yaml`, regenerates `lib/src/version.dart`, syncs README `CRUX_VERSION=` lines. `--tag` creates an annotated tag, but prefer the manual Phase 5 flow. Does NOT touch CHANGELOG or git. |
| `tool/build_release.dart [--target <os-arch>]` | Builds `build/releases/crux-<target>/` bundle. `--target` must equal the host platform (`dart build cli` cannot cross-compile). |
| `release.sh <X.Y.Z>` | Local-only: bump + build + install to `~/.crux/bin`. Not part of the GitHub release path. |
| `.github/workflows/ci.yml` | PR/push gate: analyze + smoke tests on Ubuntu. |
| `.github/workflows/release.yml` | Tag `v*` → 5-platform matrix build → zip → publish GitHub Release with the CHANGELOG section as body. |
| `install.sh` | User-facing installer; downloads `crux-<target>.zip` from GitHub Releases. |

## Conventions (violations break automation)

- CHANGELOG: entries accumulate under `## [Unreleased]`; at release rename to `## [X.Y.Z] - YYYY-MM-DD` followed by one blank line and the short SHA of the **last substantive commit** (not the release commit). Categories: only `### Features` / `### Fixes`. Entry format: `- **Title** (\`sha\`) — English description`.
- Release commit message: `chore(release): vX.Y.Z — one-line summary`.
- Tag: **annotated**, full semver — `git tag -a vX.Y.Z -m "Release vX.Y.Z — …"`. The release-notes extractor in `release.yml` prefix-matches `## [X.Y.Z]`, so tags must be complete `vX.Y.Z`.
- Version facts live only in `pubspec.yaml`; `lib/src/version.dart` is generated — never hand-edit.
- A version is released only when its annotated tag is pushed AND the GitHub Release exists with all platform zips (v0.13.0 shipped without a tag — do not repeat).

## Release procedure

Run phases in order. Do not skip gates.

### Phase 0 — Pre-flight

```bash
git status                     # tree must be clean; commit or stash in-flight work first
git log origin/master..HEAD    # local/remote in sync
dart run tool/third_party.dart fetch

# Submodule gitlinks MUST exist on their remotes — CI checkout does a
# recursive fetch and dies with "upload-pack: not our ref" otherwise.
# (v0.14.x releases all failed on exactly this.)
for sm in nocterm textmate_highlight dart-jieba semble-dart; do
  link=$(git ls-tree HEAD $sm | awk '{print $3}')
  git -C $sm ls-remote --exit-code origin "$link" >/dev/null 2>&1 \
    || git -C $sm ls-remote origin | grep -q "$link" \
    || echo "PUSH MISSING: $sm $link"
done
```

Fix a missing gitlink by fast-forward pushing the submodule's own branch (e.g. `git -C <sm> push origin main`); never point the gitlink at a different commit just to satisfy CI.

Decide the version: patch = fixes only, minor = new features, per semver.

### Phase 1 — Quality gates

```bash
dart format --set-exit-if-changed lib test bin tool
dart analyze                   # 0 issues outside vendored packages
dart test                      # FULL suite, must be green
```

If the full suite cannot run green, stop — fix or explicitly exclude with a tracked issue before continuing.

### Phase 2 — CHANGELOG

Rewrite `## [Unreleased]` → `## [X.Y.Z] - <today>` + SHA line per the convention above. Keep `Features`/`Fixes` only.

### Phase 3 — Bump

```bash
dart run tool/prepare_release.dart X.Y.Z
```

Verify: `pubspec.yaml` version, `lib/src/version.dart`, README `CRUX_VERSION=` lines all show X.Y.Z.

### Phase 4 — Local build verification (mandatory; CI publishes without a draft)

```bash
dart run tool/build_release.dart
build/releases/crux-$(uname | tr 'A-Z' 'a-z' | sed 's/darwin/macos/')-*/bin/crux --version   # must print vX.Y.Z
ls build/releases/crux-*/{providers,themes,third_party}                                     # assets present
ls build/releases/crux-*/third_party/semblemodel build/releases/crux-*/third_party/bin      # model + native tools present
```

Local prerequisites for a complete bundle: git submodules initialized, `third_party/bin/<target>/libcrux_grammars.*` present (prebuilt in `semble-dart` submodule or via `semble-dart/tool/build_native.dart`), and the embedding model in the HuggingFace cache (`huggingface-cli download minishlab/potion-code-16M`).

### Phase 5 — Commit + annotated tag

```bash
git add -A && git commit -m "chore(release): vX.Y.Z — <summary>"
git tag -a vX.Y.Z -m "Release vX.Y.Z — <summary>"
```

### Phase 6 — Push → CI publishes

```bash
git push origin master && git push origin vX.Y.Z
gh run list --workflow=release.yml --limit 1   # then: gh run watch
```

**Rehearse before tagging when the workflow changed**: a tag-triggered run uses the workflow YAML *from the tag commit* — fixing `release.yml` on master does nothing for an already-pushed tag. If `release.yml` was touched since the last release, first dry-run it via Actions → Release → Run workflow (no `publish_tag`) from master. If a tag-triggered run still fails on workflow bugs minutes after tagging and the Release is incomplete, fix master, then move the tag: `git tag -fa vX.Y.Z -m "…" && git push -f origin vX.Y.Z`. Never move a tag once the release is old enough to have consumers.

### Phase 7 — Post-release verification

```bash
gh release view vX.Y.Z --repo marsup-space/crux          # all platform zips present, body = CHANGELOG section
```

Then smoke-test the real installer in a clean environment (`curl … install.sh | bash -s -- --version vX.Y.Z`) and open a fresh empty `## [Unreleased]` section at the top of CHANGELOG.

### Phase 8 — Update the local install

The GitHub release does not touch the developer machine — `~/.crux/bin/crux` keeps running the previous version until explicitly updated. Sync the Phase 4 bundle (same bits CI shipped) instead of reinstalling:

```bash
BUNDLE=build/releases/crux-<os>-<arch>    # the bundle verified in Phase 4
DEST=~/.crux/bin
install -m 0755 "$BUNDLE/bin/crux" "$DEST/crux"
for d in providers themes third_party; do
  rm -rf "$DEST/$d" && cp -R "$BUNDLE/$d" "$DEST/"
done
hash -r && crux --version                  # must print vX.Y.Z
```

(`./release.sh X.Y.Z --skip-bump` does bump+build+install in one shot, but rebuilds from scratch — prefer the sync above right after a release.)

## Known pipeline gotchas

- `dart run` does not propagate exit codes in GitHub Actions bash steps — any `dart run` step in `release.yml` must verify success explicitly (the grammars step shows the pattern).
- CI runners start with an empty HuggingFace cache: the release workflow must download `minishlab/potion-code-16M` before `build_release.dart`, or the bundle silently ships without the semantic-search model.
- Release bundles must contain the jieba dictionary; runtime dict resolution is executable-relative (see `lib/src/utils/bundled_directory.dart`), never CWD-relative.
- `install.sh` must tolerate both zip layouts: `crux-<target>/crux` (legacy) and `crux-<target>/bin/crux` (current `dart build cli` output). If either side changes, re-verify against a real published zip.
- 5 matrix jobs publish to the same Release concurrently with `overwrite_files: true`; asset names are distinct per target, so this is safe, but a failed CHANGELOG extraction only warns — check the body in Phase 7.
- The repo is **private**: unauthenticated `install.sh` gets 404 from GitHub even for existing releases. Smoke-test the installer with valid GitHub auth in the environment, or accept API-level asset verification (`gh release view`) as the Phase 7 evidence until the repo goes public.

## Troubleshooting playbook (learned cutting v0.15.0)

| Symptom in the release run | Root cause | Fix |
|---|---|---|
| All jobs die at `Check out repository`: `upload-pack: not our ref <sha>`, `Fetched in submodule path '<sm>', but it did not contain <sha>` | Submodule gitlink commit never pushed to the submodule's remote | FF-push the submodule branch (`git -C <sm> push origin main`); re-run. This is why v0.14.x has tags but no Releases — Phase 0 now checks it. |
| Windows job dies in the model download: `'charmap' codec can't encode character '\u2713'` | huggingface_hub prints a Unicode ✓; default Windows codepage can't encode it | `PYTHONUTF8: '1'` env on the download step (already in `release.yml`; keep it). |
| Windows job dies in build: `libcrux_grammars: dylib not found` | `build_native` needs MSVC `cl.exe`; windows-latest can't build it | By design: `build_release.dart` warns and ships Windows without semantic_search (other targets still hard-fail). Do not "fix" the warning back into an error; the real fix is a Windows-friendly dylib build. |
| Build dies copying `…/snapshots/<hash>/model.safetensors` with ENOENT while bash `[ -f ]` sees the same file | HF cache snapshot entries are symlink-like on Windows; Dart's `File.copy` chokes where bash succeeds | The `Stage embedding model` step copies with `cp -L` into `build/semblemodel` and exports `CRUX_SEMBLE_MODEL_DIR` (runs on cache hits too); `build_release.dart` prefers it. Keep this path. |
| Model download skipped though cache looks partial (prior run crashed mid-download but saved cache) | actions/cache saves even on failure → poisoned cache hit | Bump the cache-key suffix (`…-v2`, `v3`…) and re-run; the download step verifies snapshot *files*, not just `refs/main`. |

Also learned outside CI:

- **Do not mix a repo-wide `dart format` into a release.** Local SDK (3.12) reformats ~240 files written under 3.11; always revert format-only churn before committing release work (`git checkout -- <files>`), and run repo-wide reformat as its own commit, its own decision.
- **Full-suite flakes are real but nondeterministic** (lsp channel, ticker, session timing tests fail ~0.2% under parallel load). Gate verdict: re-run each failing test file solo — solo-green + varying failure sets across runs = pre-existing flakes, not a release blocker; a failure that repeats on the same test = stop and fix.
