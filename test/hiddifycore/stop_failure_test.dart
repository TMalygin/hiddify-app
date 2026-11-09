import 'dart:async';

// These helpers are supplied by flutter_test's locked dependencies.
// ignore: depend_on_referenced_packages
import 'package:async/async.dart';
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface_desktop_tun.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcommon/common.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/singbox/model/core_status.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  group('desktop stop', () {
    late CoreInterfaceDesktopTun core;
    late List<CoreStatus> events;
    late StreamSubscription<CoreStatus> subscription;
    late ClientChannel channel;

    setUp(() async {
      channel = ClientChannel('127.0.0.1');
      core = CoreInterfaceDesktopTun();
      events = [];
      subscription = core.managedStatus.listen(events.add);
      // Discard the adapter's initial stopped state, before any stop request.
      await Future<void>.delayed(Duration.zero);
      events.clear();
    });

    tearDown(() async {
      await subscription.cancel();
      await core.dispose();
      await channel.shutdown();
    });

    void respond(Future<CoreInfoResponse> Function() response) {
      core.fgClient = _StopClient(channel, response);
      core.bgClient = core.fgClient;
    }

    test('a successful response reports stopped', () async {
      respond(() async => CoreInfoResponse(coreState: CoreStates.STOPPED));
      expect(await core.stop(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(events.last, isA<CoreStopped>());
    });

    test('a failed RPC propagates without reporting stopped', () async {
      final error = StateError('synthetic Stop RPC failure');
      respond(() async => throw error);
      await expectLater(core.stop(), throwsA(same(error)));
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<CoreStopped>(), isEmpty);
    });

    test('an explicit core rejection propagates without reporting stopped', () async {
      respond(
        () async => CoreInfoResponse(
          messageType: MessageType.UNEXPECTED_ERROR,
          message: 'synthetic stop rejection',
          coreState: CoreStates.STARTED,
        ),
      );
      await expectLater(core.stop(), throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<CoreStopped>(), isEmpty);
    });

    test('an RPC timeout propagates without reporting stopped', () {
      fakeAsync((clock) {
        respond(() => Completer<CoreInfoResponse>().future);
        Object? error;
        bool? result;
        core.stop().then<void>((value) { result = value; }, onError: (Object e) { error = e; });
        clock.elapse(const Duration(seconds: 6));
        expect(error, isA<TimeoutException>());
        expect(result, isNull);
        expect(events.whereType<CoreStopped>(), isEmpty);
      });
    });
  });

  group('managed core service stop', () {
    late _ManagedCore core;
    late _Service service;

    setUp(() {
      core = _ManagedCore();
      service = _Service(core);
      service.currentState = const CoreStatus.started();
      service.statusController.add(service.currentState);
    });

    tearDown(() async {
      for (final subscription in service.subscriptions.values) {
        await subscription?.cancel();
      }
      await service.statusController.close();
      await core.events.close();
    });

    test('a confirmed stop succeeds', () async {
      core.onStop = () async => true;
      expect((await service.stop().run()).isRight(), isTrue);
      expect(service.currentState, isA<CoreStopped>());
    });

    test('a false stop result fails and keeps the last known status', () async {
      core.onStop = () async => false;
      expect((await service.stop().run()).isLeft(), isTrue);
      expect(service.currentState, isNot(isA<CoreStopped>()));
    });

    test('a thrown stop error does not fabricate a stopped status', () async {
      core.onStop = () async => throw StateError('synthetic service failure');
      expect((await service.stop().run()).isLeft(), isTrue);
      expect(service.currentState, isNot(isA<CoreStopped>()));
    });

    test('a stop timeout fails without fabricating a stopped status', () {
      fakeAsync((clock) {
        core.onStop = () => Completer<bool>().future;
        bool? failed;
        service.stop().run().then((result) => failed = result.isLeft());
        clock.elapse(const Duration(seconds: 13));
        expect(failed, isTrue);
        expect(service.currentState, isNot(isA<CoreStopped>()));
      });
    });

    test('an authoritative stopped event is still accepted after a stop error', () async {
      final channel = ClientChannel('127.0.0.1');
      addTearDown(channel.shutdown);
      await service.startListeningStatus('bg', CoreClient(channel));
      core.onStop = () async => throw StateError('synthetic service failure');
      expect((await service.stop().run()).isLeft(), isTrue);
      expect(service.currentState, isNot(isA<CoreStopped>()));

      core.events.add(const CoreStatus.stopped());
      await Future<void>.delayed(Duration.zero);
      expect(service.currentState, isA<CoreStopped>());
    });
  });
}

class _StopClient extends CoreClient {
  _StopClient(super.channel, this.response);
  final Future<CoreInfoResponse> Function() response;

  @override
  ResponseFuture<CoreInfoResponse> stop(Empty request, {CallOptions? options}) => _Response(response());
}

class _Response extends DelegatingFuture<CoreInfoResponse> implements ResponseFuture<CoreInfoResponse> {
  _Response(super.future);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ManagedCore extends CoreInterface {
  final events = StreamController<CoreStatus>.broadcast();
  late Future<bool> Function() onStop;

  @override
  bool get managesLifecycle => true;
  @override
  Stream<CoreStatus> get managedStatus => events.stream;
  @override
  Future<bool> stop() => onStop();
}

class _Service extends HiddifyCoreService {
  _Service(this.core) : super(_UnusedRef());
  @override
  final CoreInterface core;
}

class _UnusedRef implements Ref {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('Unexpected provider access: $invocation');
}
