import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _Endpoint implements CoreInterface {
  final requests = <Invocation>[];
  final calls = <StreamController<Never>>[];
  final cancelled = <int>[];

  @override
  dynamic noSuchMethod(Invocation call) {
    if (call.memberName != #runApplication) return super.noSuchMethod(call);
    final index = calls.length;
    requests.add(call);
    final events = StreamController<Never>(onCancel: () => cancelled.add(index));
    calls.add(events);
    return events.stream;
  }
}

class _Service extends HiddifyCoreService {
  _Service(super.ref, this.endpoint);
  final _Endpoint endpoint;
  @override
  CoreInterface get core => endpoint;
}

void main() {
  late _Endpoint endpoint;
  late ProviderContainer container;
  late HiddifyCoreService service;
  setUp(() {
    endpoint = _Endpoint();
    container = ProviderContainer();
    service = container.read(Provider<HiddifyCoreService>((ref) => _Service(ref, endpoint)));
  });
  tearDown(() => container.dispose());

  dynamic sessions() {
    // The old service had no application sessions at all. Keep that baseline
    // runnable so the regression is an observable failed assertion.
    final dynamic api = service;
    dynamic result;
    try {
      result = api.createApplicationSessions();
    } on NoSuchMethodError {
      // Report exactly which capability the original client lacks.
    }
    expect(result, isNotNull, reason: 'the core service must offer application sessions');
    addTearDown(() => result.dispose());
    return result;
  }

  test('a session has a stable private home for the selected path and passes literal arguments', () async {
    final first = sessions();
    final args = ['two words', r'$HOME', '*', '', 'a"b'];
    first.launch(executable: '/opt/vendor/my app', arguments: args, privateWayland: true);
    final request = endpoint.requests.single.namedArguments;
    expect(request[#command], ['/opt/vendor/my app', ...args]);
    expect(request[#privateWayland], true);
    expect(request[#executableRoot], '/opt/vendor');
    final home = request[#applicationId] as String;
    expect(home, matches(RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$')));
    await first.stop(first.sessions.single.id);
    final reopened = sessions();
    reopened.launch(executable: '/opt/vendor/my app', arguments: <String>[], privateWayland: false);
    reopened.launch(executable: '/home/user/my app', arguments: <String>[], privateWayland: false);
    expect(endpoint.requests[1].namedArguments[#applicationId], home);
    expect(endpoint.requests[2].namedArguments[#applicationId], isNot(home));
    expect(endpoint.requests[2].namedArguments[#executableRoot], '');
  });

  test('only explicit stop cancels the selected live lease; no fabricated online or exit event', () async {
    final registry = sessions();
    for (final path in ['/usr/bin/one', '/usr/bin/two']) {
      registry.launch(executable: path, arguments: <String>[], privateWayland: false);
    }
    final first = registry.sessions.firstWhere((dynamic row) => row.executable == '/usr/bin/one');
    expect(first.phase.name, 'starting');
    registry.dismiss(first.id);
    expect(registry.sessions.length, 2);
    expect(endpoint.cancelled, isEmpty);
    await registry.stop(first.id);
    expect(endpoint.cancelled, [0]);
    expect(registry.sessions.firstWhere((dynamic row) => row.id == first.id).phase.name, 'stopped');
    await endpoint.calls[1].close();
    await Future<void>.delayed(Duration.zero);
    final second = registry.sessions.firstWhere((dynamic row) => row.executable == '/usr/bin/two');
    expect(second.phase.name, 'failed', reason: 'EOF with no EXITED is not a successful command');
    registry.dismiss(first.id);
    expect(registry.sessions.length, 1);
  });

  test('older core and missing selected program retain separate actionable native failures', () async {
    final registry = sessions();
    for (final failure in [
      const GrpcError.unimplemented('older core'),
      const GrpcError.failedPrecondition('no such file'),
    ]) {
      registry.launch(executable: '/home/u/bin/demo', arguments: <String>[], privateWayland: true);
      endpoint.calls.last.addError(failure);
      await Future<void>.delayed(Duration.zero);
      final row = registry.sessions.single;
      expect(row.phase.name, 'failed');
      expect(row.grpcCode, failure.code);
      expect(row.diagnostic, contains(failure.message));
      registry.dismiss(row.id);
    }
    expect(endpoint.requests.length, 2, reason: 'never retry an unrestricted or older launch method');
  });

  test('invalid paths and NUL arguments never reach the core', () {
    final registry = sessions();
    for (final path in ['relative-program', '/home/u/../other', '/']) {
      registry.launch(executable: path, arguments: <String>[], privateWayland: false);
    }
    registry.launch(executable: '/usr/bin/true', arguments: ['a\x00b'], privateWayland: false);
    expect(endpoint.requests, isEmpty);
    expect(registry.sessions.every((dynamic row) => row.phase.name == 'failed' && row.diagnostic.isNotEmpty), true);
    expect(registry.sessions.length, 4);
  });
}
