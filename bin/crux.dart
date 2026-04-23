import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:crux/crux.dart';

const _version = 'v0.1.0';

void main() async {
  await _showSplashLoading();
  await runApp(const _CruxApp());
}

class _CruxApp extends StatelessComponent {
  const _CruxApp();

  @override
  Component build(BuildContext context) {
    return const ChatPanel();
  }
}

Future<void> _showSplashLoading() async {
  const art = [
    '  ██████╗   ██████╗  ██╗   ██╗ ██╗  ██╗',
    ' ██╔════╝  ██╔══██╗ ██║   ██║  ██╗██╔╝',
    ' ██║      ██████╔╝ ██║   ██║   ███╔╝ ',
    ' ██║      ██╔══██╗ ██║   ██║  ██╔██╗ ',
    '  ██████╗ ██║  ██║  █████╔╝ ██╔╝ ██╗',
  ];

  final artWidth = art.first.length;

  const baseR = 224, baseG = 189, baseB = 255;
  const glossR = 255, glossG = 255, glossB = 255;
  const bandWidth = 12;
  const sweepStep = 2;
  const versionLabelR = 146, versionLabelG = 153, versionLabelB = 166;
  const frameDelayMs = 18;
  const postAnimationPauseMs = 400;

  stdout.write('\x1B[?25l');
  stdout.writeln();
  stdout.writeln();

  for (int sweep = -bandWidth; sweep <= artWidth + bandWidth; sweep += sweepStep) {
    for (int l = 0; l < art.length; l++) {
      final line = art[l];
      final buf = StringBuffer();
      for (int i = 0; i < line.length; i++) {
        final dist = (i - sweep).abs();
        if (dist < bandWidth) {
          final t = 1.0 - dist / bandWidth;
          final ease = t * t * (3 - 2 * t);
          final cr = (baseR + (glossR - baseR) * ease).round();
          final cg = (baseG + (glossG - baseG) * ease).round();
          final cb = (baseB + (glossB - baseB) * ease).round();
          buf
            ..write('\x1B[38;2;')
            ..write(cr)
            ..write(';')
            ..write(cg)
            ..write(';')
            ..write(cb)
            ..write('m')
            ..write(line[i]);
        } else {
          buf
            ..write('\x1B[38;2;')
            ..write(baseR)
            ..write(';')
            ..write(baseG)
            ..write(';')
            ..write(baseB)
            ..write('m')
            ..write(line[i]);
        }
      }
      if (l == art.length - 1) {
        buf
          ..write('\x1B[0m\x1B[1C\x1B[38;2;$versionLabelR;$versionLabelG;$versionLabelB m')
          ..write(_version)
          ..write('\x1B[0m');
      } else {
        buf.write('\x1B[0m');
      }
      stdout.writeln(buf);
    }
    stdout.write('\x1B[${art.length}A');
    await Future.delayed(Duration(milliseconds: frameDelayMs));
  }

  stdout.write('\x1B[${art.length}B');
  stdout.write('\x1B[?25h');

  await Future.delayed(Duration(milliseconds: postAnimationPauseMs));
}
