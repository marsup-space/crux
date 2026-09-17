import 'dart:io';

import '../components/ui/toast.dart';
import '../services/upgrade_service.dart';
import '../version.dart';
import 'command_executor.dart';

/// `/upgrade` — download the latest published release and replace this binary.
///
/// The install directory comes from the running executable, not from
/// `CRUX_INSTALL_DIR` or `$HOME`: the process knows where it was launched from,
/// and guessing is how an upgrade lands in a second location while the old
/// binary keeps being the one that runs.
///
/// Progress is a single status toast rather than a live meter, because that is
/// the only affordance the toast surface has. A release download is short enough
/// that this is not a real gap; the outcome toast always follows.
Future<void> executeUpgrade(CommandContext ctx) async {
  final t = ctx.strings.t;
  ctx.showToast(t('toast.upgradeChecking'), mode: ToastMode.status);

  final service = UpgradeService(
    currentVersion: kCruxVersion,
    executablePath: Platform.resolvedExecutable,
    download: httpDownloadBytes,
    fetchLatestVersion: httpFetchLatestVersion,
  );
  final result = await service.run();

  final (
    String key,
    Map<String, String> args,
    ToastMode mode,
  ) = switch (result.status) {
    UpgradeStatus.upgraded => (
      'toast.upgradeDone',
      {'version': result.version ?? ''},
      ToastMode.info,
    ),
    UpgradeStatus.upToDate => (
      'toast.upgradeUpToDate',
      {'version': result.version ?? kCruxVersion},
      ToastMode.info,
    ),
    UpgradeStatus.unsupportedPlatform => (
      'toast.upgradeUnsupported',
      {'target': service.target, 'published': result.detail ?? ''},
      ToastMode.error,
    ),
    // A compiled build whose directory is missing is a broken install; a JIT
    // build reports no detail at all. Same status, different advice.
    UpgradeStatus.notAnInstalledBuild =>
      result.detail == null
          ? ('toast.upgradeDevBuild', const <String, String>{}, ToastMode.error)
          : (
              'toast.upgradeInstallMissing',
              {'directory': result.detail!},
              ToastMode.error,
            ),
    UpgradeStatus.installDirNotWritable => (
      'toast.upgradeNotWritable',
      {'directory': result.detail ?? ''},
      ToastMode.error,
    ),
    UpgradeStatus.failed => (
      'toast.upgradeFailed',
      {'detail': result.detail ?? ''},
      ToastMode.error,
    ),
  };

  ctx.showToast(t(key, args), mode: mode);
}
