import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../utils/user_data_directory.dart';

class InstallSlug {
  static String? _cached;

  static String get slug {
    if (_cached != null) return _cached!;
    final dir = _dataDir();
    final file = File(p.join(dir, 'install_slug'));
    if (file.existsSync()) {
      _cached = file.readAsStringSync().trim();
      return _cached!;
    }
    _cached = _generate();
    Directory(dir).createSync(recursive: true);
    file.writeAsStringSync(_cached!);
    return _cached!;
  }

  static String _generate() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rng = Random.secure();
    return List.generate(12, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  static String _dataDir() {
    return resolveUserDataDirectory();
  }
}
