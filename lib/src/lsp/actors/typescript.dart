// TypeScript / JavaScript language server actor.
//
// Mirrors OpenCode's Typescript entry (packages/opencode/src/lsp/
// server.ts): if the project is a Deno project (`deno.json` /
// `deno.jsonc` at or above the file), hand off to `deno lsp` instead —
// typescript-language-server and Deno disagree on module resolution.
//
// Otherwise prefer the project's own `typescript-language-server`
// under `node_modules/.bin` (walks up, so monorepo root installs
// work), then PATH, then typescript's bundled `tsserver` via
// `typescript-language-server` on PATH is skipped — tsserver itself
// isn't LSP without the wrapper, so without any of these we return
// null (no auto-install, same as OpenCode's disableLspDownload mode).

import 'dart:io';

import 'package:path/path.dart' as p;

import '../actor.dart';
import '../find_up.dart';
import '../installer.dart';
import '../protocol.dart';
import '../spawn_util.dart';

class TypescriptServerActor extends LspServerActor {
  @override
  String get id => 'typescript';

  @override
  List<String> get extensions => const [
    '.ts',
    '.tsx',
    '.js',
    '.jsx',
    '.mjs',
    '.cjs',
    '.mts',
    '.cts',
  ];

  static const _jsRootMarkers = [
    'package.json',
    'package-lock.json',
    'bun.lock',
    'bun.lockb',
    'pnpm-lock.yaml',
    'yarn.lock',
  ];

  @override
  Future<LspServerSpec?> resolveSpec(String root, String file) async {
    // Deno override: nearest deno.json / deno.jsonc wins.
    final denoRoot = await findUp(
      markers: const ['deno.json', 'deno.jsonc'],
      start: file,
      stop: root,
    );
    if (denoRoot != null) {
      final deno = whichBinary('deno');
      if (deno != null) {
        return LspServerSpec(
          root: denoRoot,
          command: [deno, 'lsp'],
          env: const {},
          initialization: const {'enable': true, 'lint': true},
        );
      }
      // Fall through to the Node path — a Deno project can still be
      // type-checked by typescript-language-server if deno is absent.
    }

    // Prefer the project-local install (monorepo-aware walk-up).
    final localDir = await findUp(
      markers: [
        p.join(
          'node_modules',
          '.bin',
          Platform.isWindows
              ? 'typescript-language-server.cmd'
              : 'typescript-language-server',
        ),
      ],
      start: file,
      stop: root,
    );

    final String bin;
    if (localDir != null) {
      bin = p.join(
        localDir,
        'node_modules',
        '.bin',
        Platform.isWindows
            ? 'typescript-language-server.cmd'
            : 'typescript-language-server',
      );
    } else {
      final onPath =
          whichBinary('typescript-language-server') ??
          npmInstalled('typescript-language-server');
      if (onPath == null) {
        // Auto-install like OpenCode's `Npm.which`.
        final installed = await installOnce(
          key: id,
          existing: () => npmInstalled('typescript-language-server'),
          install: () => npmInstall('typescript-language-server'),
        );
        if (installed == null) return null;
        bin = installed;
      } else {
        bin = onPath;
      }
    }

    final projectRoot = await findUpOrStop(
      markers: _jsRootMarkers,
      start: file,
      stop: root,
    );

    return LspServerSpec(
      root: projectRoot,
      command: [bin, '--stdio'],
      env: const {},
      initialization: const {},
    );
  }
}
