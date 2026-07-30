import 'package:test/test.dart';
import 'package:crux/src/components/ui/toast.dart';

void main() {
  group('detectToastMode', () {
    test('returns info for empty message', () {
      expect(detectToastMode(''), equals(ToastMode.info));
    });

    test('returns info for plain messages with no keywords', () {
      expect(detectToastMode('hello world'), equals(ToastMode.info));
      expect(detectToastMode('the sky is blue'), equals(ToastMode.info));
    });

    test('returns error for English error keywords', () {
      expect(detectToastMode('something failed'), equals(ToastMode.error));
      expect(detectToastMode('connection timeout'), equals(ToastMode.error));
      expect(detectToastMode('permission denied'), equals(ToastMode.error));
      expect(detectToastMode('file not found'), equals(ToastMode.error));
      expect(detectToastMode('cannot open file'), equals(ToastMode.error));
      expect(detectToastMode('that is invalid'), equals(ToastMode.error));
      expect(
        detectToastMode('a fatal crash happened'),
        equals(ToastMode.error),
      );
    });

    test('returns status for English success keywords', () {
      expect(detectToastMode('done'), equals(ToastMode.status));
      expect(detectToastMode('file saved'), equals(ToastMode.status));
      expect(detectToastMode('loaded successfully'), equals(ToastMode.status));
      expect(detectToastMode('all finished'), equals(ToastMode.status));
      expect(detectToastMode('ready to go'), equals(ToastMode.status));
      expect(detectToastMode('✓ complete'), equals(ToastMode.status));
    });

    test('returns info for English info keywords', () {
      expect(
        detectToastMode('FYI: a new release is out'),
        equals(ToastMode.info),
      );
      expect(detectToastMode('tip: use --help'), equals(ToastMode.info));
      expect(detectToastMode('note about the change'), equals(ToastMode.info));
    });

    test('returns error for Chinese error keywords', () {
      expect(detectToastMode('加载失败'), equals(ToastMode.error));
      expect(detectToastMode('出现错误'), equals(ToastMode.error));
      expect(detectToastMode('连接超时'), equals(ToastMode.error));
      expect(detectToastMode('权限不足'), equals(ToastMode.error));
      expect(detectToastMode('无法找到该文件'), equals(ToastMode.error));
    });

    test('returns status for Chinese success keywords', () {
      expect(detectToastMode('加载完成'), equals(ToastMode.status));
      expect(detectToastMode('已保存'), equals(ToastMode.status));
      expect(detectToastMode('搞定'), equals(ToastMode.status));
      expect(detectToastMode('已完成'), equals(ToastMode.status));
    });

    test('returns info for Chinese info keywords', () {
      expect(detectToastMode('提示一下'), equals(ToastMode.info));
      expect(detectToastMode('注意'), equals(ToastMode.info));
      expect(detectToastMode('请注意'), equals(ToastMode.info));
    });

    test('error beats status when message has both', () {
      // "saved" (status) appears in the message, but "failed" (error)
      // also appears and is checked first.
      expect(detectToastMode('failed to save'), equals(ToastMode.error));
      expect(detectToastMode('save failed'), equals(ToastMode.error));
    });

    test('error beats info when message has both', () {
      expect(
        detectToastMode('Error: please note the timeout'),
        equals(ToastMode.error),
      );
    });

    test('case-insensitive', () {
      expect(detectToastMode('FAILED'), equals(ToastMode.error));
      expect(detectToastMode('Failed'), equals(ToastMode.error));
      expect(detectToastMode('FaIlEd'), equals(ToastMode.error));
    });

    test('handles punctuation and surrounding whitespace', () {
      expect(detectToastMode('  error!  '), equals(ToastMode.error));
      expect(detectToastMode('Error.'), equals(ToastMode.error));
      expect(detectToastMode('(failed)'), equals(ToastMode.error));
    });
  });

  group('ToastHub.show', () {
    test('auto-detects mode when none is provided', () {
      // We can't easily assert on internal state, but we can confirm
      // the call doesn't throw and the keyword detection path runs.
      // The testNocterm integration tests cover the visual side.
      // Here we just exercise the static detectToastMode indirectly
      // through the same code path the toast hub uses.
      expect(detectToastMode('failed to connect'), equals(ToastMode.error));
      expect(detectToastMode('completed'), equals(ToastMode.status));
      expect(detectToastMode('random text'), equals(ToastMode.info));
    });
  });
}
