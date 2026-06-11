import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:crux/src/utils/user_data_directory.dart';

void main() {
  test('Windows uses LOCALAPPDATA without requiring HOME', () {
    final result = resolveUserDataDirectory(
      environment: const {'LOCALAPPDATA': r'C:\Users\tester\AppData\Local'},
      isWindows: true,
      systemTempPath: r'C:\Temp',
    );

    expect(result, p.join(r'C:\Users\tester\AppData\Local', 'crux'));
  });

  test('Windows falls back through APPDATA, USERPROFILE, and temp', () {
    expect(
      resolveUserDataDirectory(
        environment: const {'APPDATA': r'C:\Users\tester\AppData\Roaming'},
        isWindows: true,
        systemTempPath: r'C:\Temp',
      ),
      p.join(r'C:\Users\tester\AppData\Roaming', 'crux'),
    );
    expect(
      resolveUserDataDirectory(
        environment: const {'USERPROFILE': r'C:\Users\tester'},
        isWindows: true,
        systemTempPath: r'C:\Temp',
      ),
      p.join(r'C:\Users\tester', 'crux'),
    );
    expect(
      resolveUserDataDirectory(
        environment: const {},
        isWindows: true,
        systemTempPath: r'C:\Temp',
      ),
      p.join(r'C:\Temp', 'crux'),
    );
  });

  test('Unix preserves XDG and HOME conventions', () {
    expect(
      resolveUserDataDirectory(
        environment: const {'XDG_DATA_HOME': '/data'},
        isWindows: false,
      ),
      p.join('/data', 'crux'),
    );
    expect(
      resolveUserDataDirectory(
        environment: const {'HOME': '/home/tester'},
        isWindows: false,
      ),
      p.join('/home/tester', '.local', 'share', 'crux'),
    );
  });
}
