import 'package:nocterm/nocterm.dart';

/// A complete, resolved Crux color palette.
///
/// Theme files define the compact semantic fields below. Component-specific
/// colors are derived so custom themes do not need to duplicate every visual
/// role used by the application.
class CruxThemeData {
  final String id;
  final String name;
  final Brightness brightness;

  final Color background;
  final Color surface;
  final Color surfaceVariant;
  final Color primary;
  final Color onPrimary;
  final Color secondary;
  final Color onSecondary;
  final Color accent;
  final Color error;
  final Color onError;
  final Color warning;
  final Color onWarning;
  final Color success;
  final Color onSuccess;
  final Color info;
  final Color text;
  final Color textMuted;
  final Color border;
  final Color borderActive;
  final Color borderSubtle;
  final Color selection;
  final Color selectedText;

  final Color markdownText;
  final Color markdownHeading;
  final Color markdownLink;
  final Color markdownCode;
  final Color markdownBlockQuote;
  final Color markdownEmphasis;
  final Color markdownStrong;
  final Color markdownRule;
  final Color markdownList;
  final Color markdownCodeBlock;

  final Color syntaxDefault;
  final Color syntaxComment;
  final Color syntaxKeyword;
  final Color syntaxStorage;
  final Color syntaxFunction;
  final Color syntaxType;
  final Color syntaxString;
  final Color syntaxConstant;
  final Color syntaxNumber;
  final Color syntaxVariable;
  final Color syntaxTag;
  final Color syntaxAttribute;
  final Color syntaxOperator;
  final Color syntaxPunctuation;
  final Color syntaxMeta;

  const CruxThemeData({
    required this.id,
    required this.name,
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceVariant,
    required this.primary,
    required this.onPrimary,
    required this.secondary,
    required this.onSecondary,
    required this.accent,
    required this.error,
    required this.onError,
    required this.warning,
    required this.onWarning,
    required this.success,
    required this.onSuccess,
    required this.info,
    required this.text,
    required this.textMuted,
    required this.border,
    required this.borderActive,
    required this.borderSubtle,
    required this.selection,
    required this.selectedText,
    required this.markdownText,
    required this.markdownHeading,
    required this.markdownLink,
    required this.markdownCode,
    required this.markdownBlockQuote,
    required this.markdownEmphasis,
    required this.markdownStrong,
    required this.markdownRule,
    required this.markdownList,
    required this.markdownCodeBlock,
    required this.syntaxDefault,
    required this.syntaxComment,
    required this.syntaxKeyword,
    required this.syntaxStorage,
    required this.syntaxFunction,
    required this.syntaxType,
    required this.syntaxString,
    required this.syntaxConstant,
    required this.syntaxNumber,
    required this.syntaxVariable,
    required this.syntaxTag,
    required this.syntaxAttribute,
    required this.syntaxOperator,
    required this.syntaxPunctuation,
    required this.syntaxMeta,
  });

  Color mix(Color target, double amount) =>
      Color.lerp(background, target, amount)!;

  Color onColor(Color color) {
    final luminance =
        (0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue) / 255;
    return luminance > 0.55 ? const Color(0x111111) : const Color(0xFFFFFF);
  }

  TuiThemeData toTuiThemeData() => TuiThemeData(
    brightness: brightness,
    background: background,
    onBackground: text,
    surface: surface,
    onSurface: text,
    primary: primary,
    onPrimary: onPrimary,
    secondary: secondary,
    onSecondary: onSecondary,
    error: error,
    onError: onError,
    success: success,
    onSuccess: onSuccess,
    warning: warning,
    onWarning: onWarning,
    outline: border,
    outlineVariant: borderSubtle,
    selectionColor: selection,
  );

  // Application roles derived from semantic tokens.
  Color get foreground => text;
  Color get comment => textMuted;
  Color get cyan => accent;
  Color get green => success;
  Color get orange => info;
  Color get pink => secondary;
  Color get purple => primary;
  Color get red => error;
  Color get yellow => warning;
  Color get currentLine => surfaceVariant;
  Color get surfaceBright => Color.lerp(surfaceVariant, text, 0.16)!;
  Color get onSurface => text;
  Color get onSurfaceVariant => Color.lerp(textMuted, text, 0.45)!;
  Color get onSurfaceDim => textMuted;
  Color get outline => border;
  Color get outlineVariant => borderSubtle;
  Color get outlineDim => Color.lerp(background, borderSubtle, 0.75)!;
  Color get outlineBright => borderActive;
  Color get selectionColor => selection;

  Color get buttonBackground => surface;
  Color get buttonBackgroundHover => surfaceVariant;
  Color get buttonBackgroundFocused => surfaceVariant;
  Color get buttonBackgroundDisabled => mix(surface, 0.55);
  Color get buttonText => text;
  Color get buttonTextHover => accent;
  Color get buttonTextFocused => accent;
  Color get buttonTextDisabled => textMuted;

  Color get overlayBackground => surface;
  Color get overlayBorder => border;
  Color get overlaySurface => surfaceVariant;
  Color get divider => borderSubtle;
  Color get dividerDim => outlineDim;
  Color get inputPrompt => textMuted;
  Color get inputText => text;

  Color get aiPrefix => secondary;
  Color get userPrefix => accent;
  Color get responsePrefix => warning;
  Color get thinkPrefix => secondary;
  Color get toolPrefix => textMuted;
  Color get thinkingPrefix => textMuted;
  Color get thinkingCollapsedText => textMuted;
  Color get thinkingExpandedText => textMuted;
  Color get thinkingLabelDisabled => borderSubtle;

  Color get sessionPrefixRunning => success;
  Color get sessionPrefixActive => accent;
  Color get sessionPrefixIdle => textMuted;
  Color get sessionPrefixDone => secondary;
  Color get sessionPrefixNeedsAction => warning;
  Color get sessionPrefixInterrupted => error;
  Color get sessionPrefixError => error;
  Color get toolbarSpacer => textMuted;
  Color get metricsActive => accent;
  Color get metricsIdle => textMuted;

  Color get wizardTitle => secondary;
  Color get wizardHeader => primary;
  Color get wizardDivider => border;
  Color get wizardOverlayBg => surface;
  Color get wizardRowBgDefault => surface;
  Color get wizardRowBgSelected => surfaceVariant;
  Color get wizardRowBgHover => surfaceVariant;
  Color get wizardMarkerSelected => warning;
  Color get wizardMarkerUnselected => textMuted;
  Color get wizardTextSelected => accent;
  Color get wizardTextUnselected => text;
  Color get wizardTextDim => textMuted;

  Color get codeBlockBackground => surface;
  Color get codeBlockHeader => textMuted;
  Color get codeBlockGutter => border;
  Color get codeBlockBorder => border;

  Color get highlightKeyword => syntaxKeyword;
  Color get highlightStorage => syntaxStorage;
  Color get highlightFunction => syntaxFunction;
  Color get highlightType => syntaxType;
  Color get highlightString => syntaxString;
  Color get highlightComment => syntaxComment;
  Color get highlightConstant => syntaxConstant;
  Color get highlightNumeric => syntaxNumber;
  Color get highlightVariable => syntaxVariable;
  Color get highlightTag => syntaxTag;
  Color get highlightAttribute => syntaxAttribute;
  Color get highlightPunctuation => syntaxPunctuation;
  Color get highlightMeta => syntaxMeta;
  Color get highlightDefault => syntaxDefault;

  Color get mdH1 => markdownHeading;
  Color get mdH2 => markdownHeading;
  Color get mdH3 => markdownHeading;
  Color get mdH4 => markdownHeading;
  Color get mdH5 => markdownHeading;
  Color get mdH6 => markdownHeading;
  Color get mdBold => markdownStrong;
  Color get mdItalic => markdownEmphasis;
  Color get mdStrikethrough => markdownText;
  Color get mdInlineCode => markdownCode;
  Color get mdInlineCodeBg => surfaceVariant;
  Color get mdCodeBlockText => markdownCodeBlock;
  Color get mdBlockquote => markdownBlockQuote;
  Color get mdLink => markdownLink;
  Color get mdListBullet => markdownList;

  Color get progressFill => primary;
  Color get progressEmpty => surfaceVariant;
  Color get progressLabelFill => onPrimary;
  Color get progressLabelEmpty => textMuted;
  Color get progressLabelFillHover => accent;
  Color get progressLabelEmptyHover => text;

  Color get toastBackground => surfaceVariant;
  Color get toastBorder => border;
  Color get toastText => warning;
  Color get toastBgError => Color.lerp(background, error, 0.20)!;
  Color get toastBorderError => error;
  Color get toastTextError => error;
  Color get toastBgStatus => Color.lerp(background, success, 0.18)!;
  Color get toastBorderStatus => success;
  Color get toastTextStatus => success;
  Color get toastBgInfo => surfaceVariant;
  Color get toastBorderInfo => border;
  Color get toastTextInfo => info;

  Color get deleteWarning => error;
  Color get deleteBackground => surface;
  Color get confirmText => text;
  Color get hintText => textMuted;
  Color get errorColor => error;
  Color get successColor => success;
  Color get warningColor => warning;
  Color get tldrPrefix => warning;
  Color get tldrBody => text;
  Color get tldrLink => markdownLink;
  Color get tldrLinkHoverFg => selectedText;
  Color get tldrHint => textMuted;

  Color get btwBackground => surface;
  Color get btwBorder => borderSubtle;
  Color get btwUserPrefix => textMuted;
  Color get btwAiPrefix => secondary;
  Color get queueBackground => surface;
  Color get queueBorder => borderSubtle;
  Color get queuePrefix => warning;
  Color get queueText => onSurfaceVariant;
  Color get queueDiscardText => error;
  Color get queueDiscardHoverText => Color.lerp(error, text, 0.25)!;

  static const draculaFallback = CruxThemeData(
    id: 'dracula',
    name: 'Dracula',
    brightness: Brightness.dark,
    background: Color(0x282A36),
    surface: Color(0x21222C),
    surfaceVariant: Color(0x44475A),
    primary: Color(0xBD93F9),
    onPrimary: Color(0x111111),
    secondary: Color(0xFF79C6),
    onSecondary: Color(0x111111),
    accent: Color(0x8BE9FD),
    error: Color(0xFF5555),
    onError: Color(0x111111),
    warning: Color(0xF1FA8C),
    onWarning: Color(0x111111),
    success: Color(0x50FA7B),
    onSuccess: Color(0x111111),
    info: Color(0xFFB86C),
    text: Color(0xF8F8F2),
    textMuted: Color(0x6272A4),
    border: Color(0x44475A),
    borderActive: Color(0xBD93F9),
    borderSubtle: Color(0x191A21),
    selection: Color(0xBD93F9),
    selectedText: Color(0x282A36),
    markdownText: Color(0xF8F8F2),
    markdownHeading: Color(0xBD93F9),
    markdownLink: Color(0x8BE9FD),
    markdownCode: Color(0x50FA7B),
    markdownBlockQuote: Color(0x6272A4),
    markdownEmphasis: Color(0xF1FA8C),
    markdownStrong: Color(0xFFB86C),
    markdownRule: Color(0x6272A4),
    markdownList: Color(0xBD93F9),
    markdownCodeBlock: Color(0xF8F8F2),
    syntaxDefault: Color(0xF8F8F2),
    syntaxComment: Color(0x6272A4),
    syntaxKeyword: Color(0xFF79C6),
    syntaxStorage: Color(0xFF79C6),
    syntaxFunction: Color(0x50FA7B),
    syntaxType: Color(0x8BE9FD),
    syntaxString: Color(0xF1FA8C),
    syntaxConstant: Color(0xBD93F9),
    syntaxNumber: Color(0xBD93F9),
    syntaxVariable: Color(0xF8F8F2),
    syntaxTag: Color(0x8BE9FD),
    syntaxAttribute: Color(0xF8F8F2),
    syntaxOperator: Color(0xFF79C6),
    syntaxPunctuation: Color(0xF8F8F2),
    syntaxMeta: Color(0xF8F8F2),
  );
}

/// Provides the active [CruxThemeData] to the TUI.
class CruxTheme extends InheritedComponent {
  final CruxThemeData data;

  CruxTheme({super.key, required this.data, required super.child});

  static CruxThemeData of(BuildContext context) {
    final theme = context.dependOnInheritedComponentOfExactType<CruxTheme>();
    return theme?.data ?? CruxThemeData.draculaFallback;
  }

  @override
  bool updateShouldNotify(CruxTheme oldComponent) => data != oldComponent.data;
}
