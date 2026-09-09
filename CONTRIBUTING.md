# Contributing to Crux

Thanks for helping improve Crux. The project currently prioritizes reliability,
polish, and focused bug fixes over expanding the feature surface.

## Bug fixes

Small, well-scoped bug fixes are welcome as pull requests. Before starting:

1. Search the existing issues and pull requests for related work.
2. Open a bug report when the expected behavior or scope is not already clear.
3. Keep the change focused and include a regression test when practical.

A good bug report includes the Crux version, operating system, terminal,
reproduction steps, expected behavior, actual behavior, and relevant logs with
secrets removed.

## New features and larger changes

Please open an issue and discuss the proposal with the maintainers **before**
writing code or opening a pull request. This includes new user-facing features,
public APIs, dependencies, storage or protocol changes, and substantial UI or
architecture work.

Explain the problem, the intended user experience, possible alternatives, and
the expected maintenance cost. Wait for maintainer agreement on the direction
and scope before implementation. Unsolicited feature pull requests may be
closed without a detailed review.

## Development checks

Set up the repository and its submodules, then run:

```bash
git submodule update --init --recursive
dart pub get
dart run tool/third_party.dart fetch
dart format --output=none --set-exit-if-changed bin lib test tool
dart analyze --fatal-infos
dart test
```

Keep commits focused, update documentation when behavior changes, and do not
include generated files, credentials, private data, or unrelated formatting
changes.

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).

All contributors must follow the [Code of Conduct](CODE_OF_CONDUCT.md).
