# GitHub CI

Crux uses GitHub Actions for cloud CI. You do not need to keep your own
computer running: GitHub starts a temporary runner, executes the workflow, and
then destroys the runner.

This setup is intentionally conservative for a private repository. It keeps
automatic runs cheap and predictable, while still catching the most useful
regressions.

## Workflows

### CI

File: `.github/workflows/ci.yml`

Runs automatically on:

- Pull requests
- Pushes to `main`

It can also be started manually from the **Actions** tab (select **CI**, then
**Run workflow**); it takes no inputs.

What it does:

- Checks out the repository and submodules
- Installs Dart
- Restores pub and third-party tool caches
- Runs `dart pub get`
- Runs `dart run tool/third_party.dart fetch`
- Reports formatting drift
- Runs `dart analyze --no-fatal-warnings bin lib test tool`
- Runs a stable smoke-test suite

Current policy:

- Analyzer warnings are reported but do not fail CI.
- Formatting drift is reported but does not fail CI.
- The smoke-test suite must pass.

Why not full `dart test` in CI:

The full test suite runs as a local release gate before every release (see
the release runbook in `.agents/skills/crux-release/SKILL.md`). CI runs a
stable smoke-test list that will be expanded over time.

### Release

File: `.github/workflows/release.yml`

Runs automatically when you push a version tag:

```bash
dart run tool/prepare_release.dart 0.15.0
git add pubspec.yaml lib/src/version.dart README.md
git commit -m "chore(release): v0.15.0 — <summary>"
git tag -a v0.15.0 -m "Release v0.15.0 — <summary>"
git push origin main
git push origin v0.15.0
```

The final `git push origin v0.15.0` triggers the release workflow. Use an
annotated tag (`git tag -a`); do not pass `--tag` to
`tool/prepare_release.dart` — it creates a lightweight tag. The full release
runbook lives in `.agents/skills/crux-release/SKILL.md`.

Tag builds package these targets and publish the archives to the GitHub Release
for that tag:

- `linux-x64`
- `linux-arm64`
- `macos-x64`
- `macos-arm64`
- `windows-x64`

It can also be started manually from GitHub:

1. Open the repository on GitHub.
2. Go to the **Actions** tab.
3. Select **Release**.
4. Click **Run workflow**.
5. Choose `all` or a single target.
6. Optionally set `publish_tag` to an existing tag such as `v0.7.0` if you want
   the manual run to upload assets to that GitHub Release.

What it does:

- Checks out the repository and submodules
- Installs Dart
- Restores pub, third-party tool, and embedding-model caches
- Runs `dart pub get` (root and the `semble-dart` submodule)
- Precompiles `libcrux_grammars` from source for every target except
  `windows-x64` (only macOS arm64 ships a prebuilt dylib in the submodule;
  Windows bundles currently ship without it, so `semantic_search` /
  `find_similar_code` are unavailable there)
- Downloads the `minishlab/potion-code-16M` embedding model into the
  HuggingFace cache so the bundle ships the semantic-search model — CI
  runners start with an empty cache, and the build would otherwise only warn
  and publish a bundle without it
- Runs `dart run tool/build_release.dart --target <target>`, which uses
  `dart build cli` on the matching platform runner, then verifies the bundle
  explicitly (executable and model files) because `dart run` does not
  propagate the script's exit code in GitHub Actions steps
- Packs the release directory into `crux-<target>.zip`
- Uploads the archive as a workflow artifact
- Publishes the archive to GitHub Releases when the workflow was triggered by a
  `v*` tag, or when a manual run provides `publish_tag`

Manual runs without `publish_tag` only upload workflow artifacts, so you can test
packaging without creating a release.

## Private Repository Cost

GitHub-hosted runners consume Actions minutes for private repositories. This
setup keeps automatic usage small by running only one Ubuntu job on pushes and
PRs. Linux runners are usually the cheapest and fastest option.

Manual release jobs consume minutes only when you click **Run workflow**.
Automatic release jobs consume minutes only when you push a `v*` tag.

## Submodules

The workflows use:

```yaml
submodules: recursive
```

This is required because Crux uses local path dependencies for `nocterm`,
`textmate_highlight`, and `dart-jieba`.

If those submodules become private later, GitHub Actions will need access to
them through a deploy key or a token. Public submodules should work without
extra configuration.

## Tightening CI Later

When the repository is ready, upgrade CI in this order:

1. Fix analyzer warnings and make `dart analyze` strict again.
2. Format the codebase and make formatting fail CI.
3. Expand the smoke-test list toward the full `dart test` suite.
4. Add per-platform smoke tests after release packaging.
5. Add release checksums once the artifact set stabilizes.
6. Add `windows-arm64` once GitHub makes private-repo Windows ARM runners
   generally available, or after moving release builds to a paid larger runner.

The current workflows are a practical starting point, not the final ceiling.
