# Third-party binaries

`manifest.json` pins every bundled tool, target archive, and SHA-256 digest.
Fetched binaries live under:

```text
third_party/
  bin/
    macos-arm64/
    macos-x64/
    linux-arm64/
    linux-x64/
    windows-arm64/
    windows-x64/
  licenses/
    <tool>/
```

Fetch the current development target:

```bash
dart run tool/third_party.dart fetch
```

Fetch every supported target:

```bash
dart run tool/third_party.dart fetch --target all
```

Release bundles flatten the selected target to `third_party/bin/` beside the
Crux executable. This lets runtime lookup and child-shell `PATH` handling stay
the same as more tools are added.
