// Default LSP server registry.
//
// One entry per supported language, keyed by the actor's `id`.
// Declarative servers use [WhichServerActor]; languages with custom
// root/binary logic get their own actor files. The set, root markers,
// and install flows mirror OpenCode's `packages/opencode/src/lsp/
// server.ts`, including auto-download into Crux's per-user tool dir
// (`~/.cache/crux/lsp`). Set `CRUX_DISABLE_LSP_DOWNLOAD=1` to opt out.
//
// Installs never block edits: `resolveSpec` runs under the manager's
// normal timeout, and a failed/slow install marks the (serverId, root)
// pair broken for 60s instead of stalling the tool call.

import 'dart:io';

import '../channel.dart';
import '../installer.dart';
import '../spawn_util.dart';
import 'csharp.dart';
import 'dart.dart';
import 'generic.dart';
import 'installers.dart';
import 'java.dart';
import 'python.dart';
import 'rust.dart';
import 'typescript.dart';

const _jsRootMarkers = [
  'package.json',
  'package-lock.json',
  'bun.lock',
  'bun.lockb',
  'pnpm-lock.yaml',
  'yarn.lock',
];

/// Install [packageName] via npm (OpenCode's `Npm.which`).
Future<String?> Function() npmInstaller(
  String packageName, [
  String? binaryName,
]) =>
    () => npmInstall(packageName, binaryName);

/// Install a Go tool via `go install` (OpenCode's Gopls fallback).
Future<String?> Function() goInstaller(String packagePath, String binaryName) =>
    () async {
      final go = whichBinary('go');
      if (go == null) return null;
      final result = await Process.run(
        go,
        ['install', '$packagePath@latest'],
        environment: {...Platform.environment, 'GOBIN': lspBinDir()},
      );
      if (result.exitCode != 0) return null;
      final bin = '${lspBinDir()}/${exeName(binaryName)}';
      return File(bin).existsSync() ? bin : null;
    };

/// Install a Ruby gem into Crux's bin dir (OpenCode's Rubocop).
Future<String?> Function() gemInstaller(String gemName, String binaryName) =>
    () async {
      final gem = whichBinary('gem');
      if (gem == null) return null;
      final result = await Process.run(gem, [
        'install',
        gemName,
        '--bindir',
        lspBinDir(),
      ]);
      if (result.exitCode != 0) return null;
      final bin = '${lspBinDir()}/${exeName(binaryName)}';
      return File(bin).existsSync() ? bin : null;
    };

/// The default actor factories wired into `LspManager`.
Map<String, LspActorFactory> defaultLspActorFactories() => {
  'dart': DartServerActor.new,
  'typescript': TypescriptServerActor.new,
  'pyright': PythonServerActor.new,
  'rust': RustServerActor.new,
  'jdtls': JavaServerActor.new,
  'csharp': CSharpServerActor.new,

  'gopls': () => WhichServerActor(
    id: 'gopls',
    extensions: const ['.go'],
    rootMarkers: const ['go.work', 'go.mod', 'go.sum'],
    commandCandidates: const [
      ['gopls'],
    ],
    install: goInstaller('golang.org/x/tools/gopls', 'gopls'),
  ),

  'clangd': () => WhichServerActor(
    id: 'clangd',
    extensions: const [
      '.c',
      '.cpp',
      '.cc',
      '.cxx',
      '.c++',
      '.h',
      '.hpp',
      '.hh',
      '.hxx',
      '.h++',
    ],
    rootMarkers: const [
      'compile_commands.json',
      'compile_flags.txt',
      '.clangd',
    ],
    commandCandidates: const [
      ['clangd', '--background-index', '--clang-tidy'],
    ],
    install: installClangd,
  ),

  'kotlin-ls': () => WhichServerActor(
    id: 'kotlin-ls',
    extensions: const ['.kt', '.kts'],
    rootMarkers: const [
      'settings.gradle.kts',
      'settings.gradle',
      'gradlew',
      'build.gradle.kts',
      'build.gradle',
      'pom.xml',
    ],
    commandCandidates: const [
      ['kotlin-lsp', '--stdio'],
      ['kotlin-language-server'],
    ],
    install: installKotlinLs,
  ),

  'sourcekit-lsp': () => WhichServerActor(
    id: 'sourcekit-lsp',
    extensions: const ['.swift'],
    rootMarkers: const ['Package.swift'],
    commandCandidates: const [
      ['sourcekit-lsp'],
    ],
    // Ships with the Swift toolchain / Xcode — no download.
  ),

  'ruby-lsp': () => WhichServerActor(
    id: 'ruby-lsp',
    extensions: const ['.rb', '.rake', '.gemspec', '.ru'],
    rootMarkers: const ['Gemfile'],
    commandCandidates: const [
      ['ruby-lsp'],
      ['rubocop', '--lsp'],
    ],
    install: gemInstaller('rubocop', 'rubocop'),
  ),

  'intelephense': () => WhichServerActor(
    id: 'intelephense',
    extensions: const ['.php'],
    rootMarkers: const ['composer.json', 'composer.lock'],
    commandCandidates: const [
      ['intelephense', '--stdio'],
    ],
    install: npmInstaller('intelephense'),
    initializationOptions: const {
      'telemetry': {'enabled': false},
    },
  ),

  'lua-ls': () => WhichServerActor(
    id: 'lua-ls',
    extensions: const ['.lua'],
    rootMarkers: const [
      '.luarc.json',
      '.luarc.jsonc',
      '.luacheckrc',
      '.stylua.toml',
      'stylua.toml',
      'selene.toml',
      'selene.yml',
    ],
    commandCandidates: const [
      ['lua-language-server'],
    ],
    install: installLuaLs,
  ),

  'bash': () => WhichServerActor(
    id: 'bash',
    extensions: const ['.sh', '.bash', '.zsh', '.ksh'],
    // No root markers — analyzes standalone scripts from the
    // session root, same as OpenCode's BashLS.
    commandCandidates: const [
      ['bash-language-server', 'start'],
    ],
    install: npmInstaller('bash-language-server'),
  ),

  'yaml-ls': () => WhichServerActor(
    id: 'yaml-ls',
    extensions: const ['.yaml', '.yml'],
    rootMarkers: _jsRootMarkers,
    commandCandidates: const [
      ['yaml-language-server', '--stdio'],
    ],
    install: npmInstaller('yaml-language-server'),
  ),

  'zls': () => WhichServerActor(
    id: 'zls',
    extensions: const ['.zig', '.zon'],
    rootMarkers: const ['build.zig'],
    commandCandidates: const [
      ['zls'],
    ],
    install: installZls,
  ),

  'vue': () => WhichServerActor(
    id: 'vue',
    extensions: const ['.vue'],
    rootMarkers: _jsRootMarkers,
    commandCandidates: const [
      ['vue-language-server', '--stdio'],
    ],
    install: npmInstaller('@vue/language-server', 'vue-language-server'),
  ),

  'svelte': () => WhichServerActor(
    id: 'svelte',
    extensions: const ['.svelte'],
    rootMarkers: _jsRootMarkers,
    commandCandidates: const [
      ['svelteserver', '--stdio'],
    ],
    install: npmInstaller('svelte-language-server', 'svelteserver'),
  ),

  'astro': () => WhichServerActor(
    id: 'astro',
    extensions: const ['.astro'],
    rootMarkers: _jsRootMarkers,
    commandCandidates: const [
      ['astro-ls', '--stdio'],
    ],
    install: npmInstaller('@astrojs/language-server', 'astro-ls'),
  ),

  'dockerfile': () => WhichServerActor(
    id: 'dockerfile',
    extensions: const ['.dockerfile'],
    bareFilenames: const ['Dockerfile'],
    commandCandidates: const [
      ['docker-langserver', '--stdio'],
    ],
    install: npmInstaller(
      'dockerfile-language-server-nodejs',
      'docker-langserver',
    ),
  ),

  'terraform': () => WhichServerActor(
    id: 'terraform',
    extensions: const ['.tf', '.tfvars'],
    rootMarkers: const ['.terraform.lock.hcl'],
    commandCandidates: const [
      ['terraform-ls', 'serve'],
    ],
    install: installTerraformLs,
    initializationOptions: const {
      'experimentalFeatures': {
        'prefillRequiredFields': true,
        'validateOnSave': true,
      },
    },
  ),

  'nixd': () => WhichServerActor(
    id: 'nixd',
    extensions: const ['.nix'],
    rootMarkers: const ['flake.nix'],
    commandCandidates: const [
      ['nixd'],
    ],
    // Only sane install path is nix itself — skip download.
  ),

  'ocaml-lsp': () => WhichServerActor(
    id: 'ocaml-lsp',
    extensions: const ['.ml', '.mli'],
    rootMarkers: const ['dune-project', 'dune-workspace', '.merlin'],
    commandCandidates: const [
      ['ocamllsp'],
    ],
    // Install is `opam install ocaml-lsp-server` — skip.
  ),

  'haskell-language-server': () => WhichServerActor(
    id: 'haskell-language-server',
    extensions: const ['.hs', '.lhs'],
    rootMarkers: const ['stack.yaml', 'cabal.project', 'hie.yaml'],
    commandCandidates: const [
      ['haskell-language-server-wrapper', '--lsp'],
    ],
    // Installed via ghcup — skip download.
  ),

  'clojure-lsp': () => WhichServerActor(
    id: 'clojure-lsp',
    extensions: const ['.clj', '.cljs', '.cljc', '.edn'],
    rootMarkers: const [
      'deps.edn',
      'project.clj',
      'shadow-cljs.edn',
      'bb.edn',
      'build.boot',
    ],
    commandCandidates: const [
      ['clojure-lsp', 'listen'],
    ],
  ),

  'gleam': () => WhichServerActor(
    id: 'gleam',
    extensions: const ['.gleam'],
    rootMarkers: const ['gleam.toml'],
    commandCandidates: const [
      ['gleam', 'lsp'],
    ],
  ),

  'prisma': () => WhichServerActor(
    id: 'prisma',
    extensions: const ['.prisma'],
    rootMarkers: const ['schema.prisma'],
    commandCandidates: const [
      ['prisma', 'language-server'],
    ],
  ),

  'tinymist': () => WhichServerActor(
    id: 'tinymist',
    extensions: const ['.typ', '.typc'],
    rootMarkers: const ['typst.toml'],
    commandCandidates: const [
      ['tinymist'],
    ],
    install: installTinymist,
  ),

  'texlab': () => WhichServerActor(
    id: 'texlab',
    extensions: const ['.tex', '.bib'],
    rootMarkers: const ['.latexmkrc', 'latexmkrc', '.texlabroot', 'texlabroot'],
    commandCandidates: const [
      ['texlab'],
    ],
    install: installTexlab,
  ),

  'fsharp': () => WhichServerActor(
    id: 'fsharp',
    extensions: const ['.fs', '.fsi', '.fsx', '.fsscript'],
    rootMarkers: const ['.fsproj', 'global.json'],
    commandCandidates: const [
      ['fsautocomplete'],
    ],
    install: dotnetToolInstaller('fsautocomplete'),
  ),

  'elixir-ls': () => WhichServerActor(
    id: 'elixir-ls',
    extensions: const ['.ex', '.exs'],
    rootMarkers: const ['mix.exs', 'mix.lock'],
    commandCandidates: const [
      ['elixir-ls'],
    ],
    // OpenCode builds from source — too fragile; skip.
  ),
};

/// Install a .NET global tool into Crux's bin dir (OpenCode's
/// FSharp / roslyn install path).
Future<String?> Function() dotnetToolInstaller(String toolName) => () async {
  final dotnet = whichBinary('dotnet');
  if (dotnet == null) return null;
  final result = await Process.run(dotnet, [
    'tool',
    'install',
    toolName,
    '--tool-path',
    lspBinDir(),
  ]);
  if (result.exitCode != 0) return null;
  final bin = '${lspBinDir()}/${exeName(toolName)}';
  return File(bin).existsSync() ? bin : null;
};
