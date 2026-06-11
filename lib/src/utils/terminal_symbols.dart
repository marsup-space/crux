import 'dart:io';

bool supportsRichTerminalSymbols({
  Map<String, String>? environment,
  bool? isWindows,
}) {
  final windows = isWindows ?? Platform.isWindows;
  if (!windows) return true;

  final env = environment ?? Platform.environment;
  if (_isSet(env['WT_SESSION']) ||
      _isSet(env['TERM_PROGRAM']) ||
      _isSet(env['ANSICON']) ||
      env['ConEmuANSI']?.toUpperCase() == 'ON') {
    return true;
  }

  final term = env['TERM']?.toLowerCase();
  return term != null && term.isNotEmpty && term != 'dumb';
}

String terminalSymbol(String rich, String ascii) {
  return supportsRichTerminalSymbols() ? rich : ascii;
}

bool _isSet(String? value) => value != null && value.isNotEmpty;
