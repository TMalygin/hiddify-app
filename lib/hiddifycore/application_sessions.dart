import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/hiddifycore/application_launch.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;

typedef ApplicationRunner =
    Stream<ApplicationEvent> Function({
      required List<String> command,
      required String applicationId,
      required bool privateWayland,
      String executableRoot,
    });

enum ApplicationPhase {
  starting,
  offline,
  online,
  stopping,
  stopped,
  exited,
  failed;

  String get name => EnumName(this).name;
}

class ApplicationSession {
  const ApplicationSession(
    this.id,
    this.executable,
    this.phase, {
    this.diagnostic = '',
    this.grpcCode,
    this.exitCode,
    this.output = '',
  });
  final String id;
  final String executable;
  final ApplicationPhase phase;
  final String diagnostic;
  final int? grpcCode;
  final int? exitCode;
  final String output;
  bool get isTerminal =>
      phase == ApplicationPhase.stopped || phase == ApplicationPhase.exited || phase == ApplicationPhase.failed;
}

class _Lease {
  StreamSubscription<ApplicationEvent>? stream;
  final bytes = ListQueue<int>();
  Timer? publish;

  void append(List<int> data) {
    const limit = 4096;
    if (data.length >= limit) bytes.clear();
    bytes.addAll(data.skip(data.length > limit ? data.length - limit : 0));
    while (bytes.length > limit) {
      bytes.removeFirst();
    }
  }

  String get output => utf8.decode(bytes.toList(), allowMalformed: true);
}

/// A subscription is the core's process lease. The application owns these,
/// not the dialog or the currently selected profile. Nothing here starts a host process.
class ApplicationSessions extends StateNotifier<List<ApplicationSession>> {
  ApplicationSessions(this._run) : super(const []);
  final ApplicationRunner _run;
  final _leases = <String, _Lease>{};
  int _sequence = 0;
  List<ApplicationSession> get sessions => state;

  void launch({required String executable, required List<String> arguments, required bool privateWayland}) {
    final id = (++_sequence).toString();
    // Keep only a bounded history of finished commands. Live sessions remain visible.
    var history = 0;
    state = List.unmodifiable([
      ApplicationSession(id, executable, ApplicationPhase.starting),
      ...state.where((s) => !s.isTerminal || ++history < 32),
    ]);
    final command = List<String>.unmodifiable([executable, ...arguments]);
    if (!p.posix.isAbsolute(executable) ||
        p.posix.normalize(executable) != executable ||
        executable == '/' ||
        command.any((arg) => arg.contains('\x00'))) {
      _change(
        id,
        ApplicationPhase.failed,
        grpcCode: StatusCode.invalidArgument,
        diagnostic: 'Select an absolute executable path. Paths and arguments cannot contain NUL.',
      );
      return;
    }
    if (command.length > 1024 || command.fold<int>(0, (n, s) => n + utf8.encode(s).length + 1) > 65536) {
      _change(
        id,
        ApplicationPhase.failed,
        grpcCode: StatusCode.invalidArgument,
        diagnostic: 'Command exceeds the core argument limit.',
      );
      return;
    }
    if (_leases.length >= 16) {
      _change(
        id,
        ApplicationPhase.failed,
        grpcCode: StatusCode.resourceExhausted,
        diagnostic: 'At most 16 applications can run at once.',
      );
      return;
    }

    // Use the path, not a display name or the arguments, so relaunching the
    // same executable retains its private home without sharing similarly named apps.
    final home = sha256.convert(utf8.encode(executable)).toString();
    final parent = p.posix.dirname(executable);
    final lease = _leases[id] = _Lease();
    try {
      final events = _run(
        command: command,
        applicationId: home,
        privateWayland: privateWayland,
        executableRoot: parent.startsWith('/opt/') ? parent : '',
      );
      final subscription = events.listen(
        (event) {
          if (!identical(_leases[id], lease)) return;
          switch (event.kind) {
            case ApplicationEventKind.offline:
              _change(id, ApplicationPhase.offline, diagnostic: event.message);
            case ApplicationEventKind.online:
              _change(id, ApplicationPhase.online, diagnostic: event.message);
            case ApplicationEventKind.error:
              _finish(id, lease, ApplicationPhase.failed, diagnostic: event.message, terminalEvent: true);
            case ApplicationEventKind.exited:
              _finish(id, lease, ApplicationPhase.exited, exitCode: event.exitCode, terminalEvent: true);
            case ApplicationEventKind.output:
              lease.append(event.stdout);
              lease.append(event.stderr);
              // Busy console clients must not rebuild the dialog for every read.
              lease.publish ??= Timer(const Duration(milliseconds: 120), () {
                lease.publish = null;
                final row = _row(id);
                if (row != null && identical(_leases[id], lease)) {
                  _change(id, row.phase, diagnostic: row.diagnostic, output: lease.output);
                }
              });
          }
        },
        onError: (Object error) => _failure(id, lease, error),
        onDone: () => _finish(
          id,
          lease,
          ApplicationPhase.failed,
          diagnostic: 'Core stream closed without an exit status.',
          grpcCode: StatusCode.unavailable,
        ),
        cancelOnError: true,
      );
      lease.stream = subscription;
      if (!identical(_leases[id], lease)) unawaited(subscription.cancel());
    } catch (error) {
      _failure(id, lease, error);
    }
  }

  void _failure(String id, _Lease lease, Object error) => _finish(
    id,
    lease,
    ApplicationPhase.failed,
    diagnostic: error is GrpcError ? error.message ?? error.codeName : error.toString(),
    grpcCode: error is GrpcError ? error.code : null,
  );

  void _finish(
    String id,
    _Lease lease,
    ApplicationPhase phase, {
    String diagnostic = '',
    int? grpcCode,
    int? exitCode,
    bool terminalEvent = false,
  }) {
    if (!identical(_leases[id], lease)) return;
    _leases.remove(id);
    lease.publish?.cancel();
    _change(id, phase, diagnostic: diagnostic, grpcCode: grpcCode, exitCode: exitCode, output: lease.output);
    // The child is finished. Don't leave a listener attached if the peer delays EOF.
    if (terminalEvent && lease.stream != null) {
      unawaited(
        lease.stream!.cancel().catchError((Object error) {
          _change(
            id,
            phase,
            diagnostic: [diagnostic, error.toString()].where((s) => s.isNotEmpty).join('\n'),
            grpcCode: grpcCode,
            exitCode: exitCode,
          );
        }),
      );
    }
  }

  ApplicationSession? _row(String id) {
    for (final row in state) {
      if (row.id == id) return row;
    }
    return null;
  }

  void _change(
    String id,
    ApplicationPhase phase, {
    String diagnostic = '',
    int? grpcCode,
    int? exitCode,
    String? output,
  }) {
    if (!mounted) return;
    state = List.unmodifiable([
      for (final row in state)
        if (row.id == id)
          ApplicationSession(
            id,
            row.executable,
            phase,
            diagnostic: diagnostic,
            grpcCode: grpcCode,
            exitCode: exitCode,
            output: output ?? row.output,
          )
        else
          row,
    ]);
  }

  Future<void> stop(String id) async {
    final lease = _leases.remove(id);
    if (lease == null) return;
    lease.publish?.cancel();
    _change(id, ApplicationPhase.stopping, output: lease.output);
    try {
      await lease.stream?.cancel();
      _change(id, ApplicationPhase.stopped);
    } catch (error) {
      _change(id, ApplicationPhase.failed, diagnostic: error.toString());
    }
  }

  void dismiss(String id) {
    if (_row(id)?.isTerminal != true) return;
    state = List.unmodifiable(state.where((item) => item.id != id));
  }

  @override
  void dispose() {
    final active = _leases.values.toList();
    _leases.clear();
    for (final lease in active) {
      lease.publish?.cancel();
      unawaited(lease.stream?.cancel());
    }
    super.dispose();
  }
}
