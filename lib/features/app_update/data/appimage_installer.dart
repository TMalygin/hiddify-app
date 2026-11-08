import 'dart:io';

import 'package:path/path.dart' as p;

/// Replaces [runningPath], restoring it if the OS refuses to start the update.
/// Returns the retained recovery copy: a detached launch does not prove that
/// the new application's initialization succeeded.
Future<File> installAppImage(File download, String runningPath) async {
  final running = File(runningPath);
  // On the same filesystem for atomic replacement; never reuse a predictable
  // .new or .backup path that might belong to another update or the user.
  final staging = await running.parent.createTemp('${p.basename(runningPath)}.update-');
  final next = File(p.join(staging.path, 'candidate.AppImage'));
  final previous = File(p.join(staging.path, 'previous.AppImage'));
  var replaced = false;
  try {
    await download.copy(next.path);
    final permissions = await Process.run('chmod', ['755', next.path]);
    if (permissions.exitCode != 0) {
      throw ProcessException('chmod', ['755', next.path], permissions.stderr.toString(), permissions.exitCode);
    }
    await running.copy(previous.path);
    await next.rename(runningPath);
    replaced = true;
    await Process.start(runningPath, const [], mode: ProcessStartMode.detached);
    return previous;
  } catch (error, stackTrace) {
    if (replaced) {
      try {
        await previous.rename(runningPath);
      } catch (rollbackError) {
        // Keep the recovery file if restoring it fails; include both failures.
        throw FileSystemException(
          'AppImage update failed: $error. Restore failed: $rollbackError. Recovery copy: ${previous.path}',
          runningPath,
        );
      }
    }
    try {
      await staging.delete(recursive: true);
    } catch (cleanupError) {
      throw FileSystemException('AppImage update failed: $error. Staging cleanup failed: $cleanupError', staging.path);
    }
    Error.throwWithStackTrace(error, stackTrace);
  }
}
