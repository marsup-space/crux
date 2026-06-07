import 'package:nocterm/nocterm.dart';

class CruxTheme {
  static const background = Color(0x282A36);
  static const currentLine = Color(0x44475A);
  static const foreground = Color(0xF8F8F2);
  static const comment = Color(0x6272A4);
  static const cyan = Color(0x8BE9FD);
  static const green = Color(0x50FA7B);
  static const orange = Color(0xFFB86C);
  static const pink = Color(0xFF79C6);
  static const purple = Color(0xBD93F9);
  static const red = Color(0xFF5555);
  static const yellow = Color(0xF1FA8C);

  static const surface = Color(0x44475A);
  static const surfaceVariant = Color(0x343746);
  static const surfaceBright = Color(0x5A5E72);

  static const onSurface = Color(0xF8F8F2);
  static const onSurfaceVariant = Color(0xCCD0DA);
  static const onSurfaceDim = Color(0x6272A4);

  static const outline = Color(0x6272A4);
  static const outlineVariant = Color(0x44475A);
  static const outlineDim = Color(0x343746);
  static const outlineBright = Color(0x7A7F9A);

  static const selectionColor = Color(0x645484);

  static const buttonBackground = Color(0x44475A);
  static const buttonBackgroundHover = Color(0x5A5E72);
  static const buttonBackgroundFocused = Color(0x5A5E72);
  static const buttonBackgroundDisabled = Color(0x343746);
  static const buttonText = foreground;
  static const buttonTextHover = cyan;
  static const buttonTextFocused = cyan;
  static const buttonTextDisabled = comment;

  static const overlayBackground = Color(0x21222C);
  static const overlayBorder = outline;
  static const overlaySurface = surface;

  static const divider = outlineVariant;
  static const dividerDim = outlineDim;

  static const inputPrompt = comment;
  static const inputText = foreground;

  static const aiPrefix = purple;
  static const userPrefix = cyan;
  static const responsePrefix = yellow;
  static const thinkPrefix = Color(0xBD93F9);
  static const toolPrefix = comment;
  static const thinkingPrefix = comment;
  static const thinkingCollapsedText = comment;
  static const thinkingExpandedText = Color(0x6272A4);
  static const thinkingLabelDisabled = Color(0x44475A);

  static const sessionPrefixRunning = green;
  static const sessionPrefixActive = cyan;
  static const sessionPrefixIdle = comment;
  static const sessionPrefixDone = pink;
  static const sessionPrefixNeedsAction = yellow;
  static const sessionPrefixError = red;

  static const toolbarSpacer = comment;
  static const metricsActive = Color(0x8BE9FD);
  static const metricsIdle = comment;

  static const wizardTitle = pink;
  static const wizardHeader = purple;
  static const wizardDivider = outline;
  static const wizardOverlayBg = Color(0x21222C);
  static const wizardRowBgDefault = Color(0x21222C);
  static const wizardRowBgSelected = surfaceVariant;
  static const wizardRowBgHover = surface;
  static const wizardMarkerSelected = yellow;
  static const wizardMarkerUnselected = comment;
  static const wizardTextSelected = cyan;
  static const wizardTextUnselected = foreground;
  static const wizardTextDim = comment;

  static const codeBlockBackground = Color(0x282A36);
  static const codeBlockHeader = comment;
  static const codeBlockGutter = Color(0x6272A4);
  static const codeBlockBorder = outline;

  static const highlightKeyword = pink;
  static const highlightStorage = pink;
  static const highlightFunction = yellow;
  static const highlightType = cyan;
  static const highlightString = orange;
  static const highlightComment = comment;
  static const highlightConstant = purple;
  static const highlightNumeric = green;
  static const highlightVariable = cyan;
  static const highlightTag = green;
  static const highlightAttribute = cyan;
  static const highlightPunctuation = foreground;
  static const highlightMeta = foreground;
  static const highlightDefault = foreground;

  static const mdH1 = pink;
  static const mdH2 = purple;
  static const mdH3 = green;
  static const mdH4 = foreground;
  static const mdH5 = foreground;
  static const mdH6 = foreground;
  static const mdBold = foreground;
  static const mdItalic = foreground;
  static const mdStrikethrough = foreground;
  static const mdInlineCode = orange;
  static const mdInlineCodeBg = surfaceVariant;
  static const mdCodeBlockText = foreground;
  static const mdBlockquote = comment;
  static const mdLink = cyan;
  static const mdListBullet = foreground;

  static const progressFill = purple;
  static const progressEmpty = surfaceVariant;
  static const progressLabelFill = foreground;
  static const progressLabelEmpty = comment;
  static const progressLabelFillHover = Color(0x8BE9FD);
  static const progressLabelEmptyHover = foreground;

  static const toastBackground = surfaceVariant;
  static const toastBorder = outline;
  static const toastText = yellow;

  // Per-mode colour coding so each toast mode is visually distinct.
  static const toastBgError = Color(0x3D2020);
  static const toastBorderError = Color(0xFF4444);
  static const toastTextError = Color(0xFF8888);

  static const toastBgStatus = Color(0x1E3D20);
  static const toastBorderStatus = Color(0x44CC44);
  static const toastTextStatus = Color(0x66EE66);

  static const toastBgInfo = surfaceVariant;
  static const toastBorderInfo = outline;
  static const toastTextInfo = yellow;

  static const deleteWarning = red;
  static const deleteBackground = Color(0x44475A);
  static const confirmText = foreground;
  static const hintText = comment;

  static const errorColor = red;
  static const successColor = green;
  static const warningColor = yellow;

  static const primary = purple;
  static const secondary = pink;

  static const tldrPrefix = Color(0xF1FA8C);
  static const tldrBody = Color(0xF8F8F2);
  static const tldrLink = Color(0x8BE9FD);
  static const tldrLinkHoverFg = Color(0x282A36);
  static const tldrHint = Color(0x6272A4);
}
