import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

/// One laid-out box: the widget id and the column span the user picked.
class HomeLayoutEntry {
  final String id;
  final int span;

  const HomeLayoutEntry(this.id, this.span);

  @override
  bool operator ==(Object other) =>
      other is HomeLayoutEntry && other.id == id && other.span == span;

  @override
  int get hashCode => Object.hash(id, span);

  @override
  String toString() => 'HomeLayoutEntry($id, $span)';
}

/// The parsed `[home]` section of `config.toml`.
class HomeLayoutConfig {
  /// Whether home opens automatically on launch. `null` means "unset" —
  /// the caller treats that as the default (`true`). Persisted as
  /// `show_on_launch`.
  final bool? showOnLaunch;

  /// The user's box order + spans, in grid order. `null` means "unset"
  /// (use the default layout). Entries referencing unregistered widget
  /// ids are *kept* here and filtered at apply time, so a layout written
  /// by a newer build (with widgets this build doesn't have) round-trips
  /// without data loss.
  final List<HomeLayoutEntry>? layout;

  const HomeLayoutConfig({this.showOnLaunch, this.layout});
}

/// Reads and writes the `[home]` section of `config.toml`.
///
/// Same shape as `ThemeConfigStore`: a read-modify-write over the whole
/// config file (so other sections survive), persisted with an atomic
/// temp-file + rename so a crash mid-write can't corrupt the config.
///
/// The pretty printer emits the layout as a `[[home.layout]]`
/// array-of-tables (one table per entry), which reparses to the same
/// structure — so the file stays hand-editable.
class HomeLayoutStore {
  final File file;

  const HomeLayoutStore(this.file);

  /// Read the `[home]` section. Returns an empty config (all fields
  /// null) when the file doesn't exist, has no `[home]`, or the section
  /// is malformed — the caller falls back to defaults in every case.
  Future<HomeLayoutConfig> read() async {
    if (!await file.exists()) return const HomeLayoutConfig();
    final Map<String, dynamic> root;
    try {
      root = TomlDocument.parse(await file.readAsString()).toMap();
    } catch (_) {
      // Unparseable TOML: treat as no config rather than crash launch.
      return const HomeLayoutConfig();
    }
    final home = root['home'];
    if (home is! Map) return const HomeLayoutConfig();

    final showOnLaunch = home['show_on_launch'];
    final layout = _parseLayout(home['layout']);
    return HomeLayoutConfig(
      showOnLaunch: showOnLaunch is bool ? showOnLaunch : null,
      layout: layout,
    );
  }

  /// Parse the `layout` value into entries, skipping malformed items.
  /// Returns null when there's no usable layout (absent, not a list, or
  /// every item is malformed) so the caller uses the default.
  static List<HomeLayoutEntry>? _parseLayout(dynamic value) {
    if (value is! List) return null;
    final entries = <HomeLayoutEntry>[];
    for (final item in value) {
      if (item is! Map) continue;
      final id = item['id'];
      final span = item['span'];
      if (id is! String || id.isEmpty) continue;
      entries.add(HomeLayoutEntry(id, span is int && span > 0 ? span : 1));
    }
    return entries.isEmpty ? null : entries;
  }

  /// Persist [config] into `[home]`, leaving every other section
  /// untouched. A null field removes that key (so `show_on_launch` only
  /// appears once the user has actually toggled it).
  Future<void> write(HomeLayoutConfig config) async {
    Map<String, dynamic> root = {};
    if (await file.exists()) {
      try {
        root = TomlDocument.parse(await file.readAsString()).toMap();
      } catch (_) {
        // Existing file is unparseable — start the section fresh rather
        // than lose the write. Other sections are unrecoverable anyway.
        root = {};
      }
    }

    final home = root['home'] is Map
        ? Map<String, dynamic>.from(root['home'] as Map)
        : <String, dynamic>{};

    if (config.showOnLaunch != null) {
      home['show_on_launch'] = config.showOnLaunch;
    } else {
      home.remove('show_on_launch');
    }

    if (config.layout != null) {
      home['layout'] = [
        for (final e in config.layout!) {'id': e.id, 'span': e.span},
      ];
    } else {
      home.remove('layout');
    }

    root['home'] = home;

    final document = TomlDocument.fromMap(root);
    final printer = TomlPrettyPrinter();
    document.acceptVisitor(printer);

    await file.parent.create(recursive: true);
    final temporary = File(
      p.join(
        file.parent.path,
        '.${p.basename(file.path)}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    await temporary.writeAsString('${printer.toString()}\n', flush: true);
    try {
      await temporary.rename(file.path);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }
}
