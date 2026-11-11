import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface_desktop.dart';
import 'package:hiddify/hiddifycore/core_interface/grpc_client_identity.dart';
import 'package:hiddify/hiddifycore/core_interface/mtls_channel_cred.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore_service.pbgrpc.dart';

class _Desktop extends CoreInterfaceDesktop {
  _Desktop(this.foregroundChannel);
  @override
  final ClientChannel? foregroundChannel;
}

class _Tls extends ServerCredentials {
  _Tls(this.securityContext);
  @override
  final SecurityContext securityContext;
}

class _Peer extends Service {
  @override
  String get $name => 'hcore.Core';

  final requests = <List<int>>[];
  late Stream<List<int>> Function(ServiceCall) events;

  _Peer() {
    $addMethod(ServiceMethod<List<int>, List<int>>('Check', _check, false, false, (bytes) => bytes, (bytes) => bytes));
    $addMethod(
      ServiceMethod<List<int>, List<int>>('RunApplication', _run, false, true, (bytes) => bytes, (bytes) => bytes),
    );
  }

  Future<List<int>> _check(ServiceCall call, Future<List<int>> input) => input;

  Stream<List<int>> _run(ServiceCall call, Future<List<int>> input) async* {
    requests.add(await input);
    yield* events(call);
  }
}

const command = ['/opt/example/My App', '', r'$HOME', 'файл с пробелом'];

Stream<dynamic> _run(CoreInterfaceDesktop desktop) {
  // Dynamic dispatch lets the same behavioral tests run against the pre-launcher API.
  return Stream<dynamic>.multi((controller) {
    try {
      final stream =
          (desktop as dynamic).runApplication(
                command: command,
                applicationId: 'example-app',
                executableRoot: '/opt/example',
                privateWayland: true,
              )
              as Stream<dynamic>;
      final subscription = stream.listen(
        controller.addSync,
        onError: controller.addErrorSync,
        onDone: controller.closeSync,
      );
      controller.onCancel = subscription.cancel;
    } catch (error, stack) {
      controller.addErrorSync(error, stack);
      controller.closeSync();
    }
  });
}

// The strings in this fixture use single-byte protobuf lengths.
List<int> _string(int tag, String value) => [tag, utf8.encode(value).length, ...utf8.encode(value)];

void main() {
  late Server server;
  late ClientChannel channel;
  late _Peer peer;
  late _Desktop desktop;

  setUpAll(() async {
    final identity = GrpcClientIdentity.generate();
    final pair = CryptoUtils.generateRSAKeyPair();
    final key = pair.privateKey as RSAPrivateKey;
    final csr = X509Utils.generateRsaCsrPem({'CN': 'localhost'}, key, pair.publicKey as RSAPublicKey);
    final cert = utf8.encode(
      X509Utils.generateSelfSignedCertificate(
        key,
        csr,
        1,
        extKeyUsage: [ExtendedKeyUsage.SERVER_AUTH],
        sans: ['localhost'],
      ),
    );
    final context = SecurityContext()
      ..setAlpnProtocols(['h2'], true)
      ..useCertificateChainBytes(cert)
      ..usePrivateKeyBytes(utf8.encode(CryptoUtils.encodeRSAPrivateKeyToPem(key)))
      ..setTrustedCertificatesBytes(utf8.encode(identity.certificatePem));
    peer = _Peer();
    server = Server.create(services: [peer]);
    await server.serve(
      address: InternetAddress.loopbackIPv4,
      port: 0,
      security: _Tls(context),
      requestClientCertificate: true,
      requireClientCertificate: true,
    );
    final credentials = MTLSChannelCredentials.fromPem(
      serverCertificatePem: Uint8List.fromList(cert),
      clientCertificatePem: identity.certificatePem,
      clientPrivateKeyPem: identity.privateKeyPem,
    );
    channel = ClientChannel(
      '127.0.0.1',
      port: server.port!,
      options: ChannelOptions(credentials: credentials),
    );
    final check = ClientMethod<List<int>, List<int>>('/hcore.Core/Check', (bytes) => bytes, (bytes) => bytes);
    expect(
      await Client(channel).$createUnaryCall(check, [7]).timeout(const Duration(seconds: 5)),
      [7],
      reason: 'the independently generated client and server identities must complete mutual TLS',
    );
  });

  setUp(() {
    peer.requests.clear();
    desktop = _Desktop(channel)..fgClient = CoreClient(channel);
    // Leave bgClient uninitialized. A launch must use only the app's foreground user core.
  });

  tearDownAll(() async {
    await channel.terminate();
    await server.shutdown();
  });

  test('sends literal argv and GUI fields to RunApplication and reads every event kind', () async {
    peer.events = (_) => Stream.fromIterable([
      <int>[],
      [8, 1, 16, 7],
      [8, 4, 26, 2, 0, 255, 34, 1, 128, 122, 1, 0],
      [8, 2, ..._string(50, 'no profile')],
      [8, 3, 40, 7],
    ]);
    final events = await _run(desktop).toList();
    expect(peer.requests.single, [
      for (final argument in command) ..._string(10, argument),
      ..._string(18, 'example-app'),
      ..._string(26, '/opt/example'),
      40,
      1,
    ]);
    expect(events.map((dynamic e) => e.kind.name), ['offline', 'online', 'output', 'error', 'exited']);
    expect(events[2].stdout, [0, 255]);
    expect(events[2].stderr, [128]);
    expect(events[3].message, 'no profile');
    expect(events[4].exitCode, 7);
  });

  test('forwards a missing native capability without retrying the launch', () async {
    peer.events = (_) => Stream.error(const GrpcError.unimplemented('older core'));
    await expectLater(
      _run(desktop),
      emitsError(
        isA<GrpcError>()
            .having((e) => e.code, 'status', StatusCode.unimplemented)
            .having((e) => e.message, 'message', 'older core'),
      ),
    );
    expect(peer.requests, hasLength(1));
  });

  test('unknown protocol state cannot be presented as offline or online', () async {
    peer.events = (_) => Stream.value([8, 99]);
    await expectLater(_run(desktop), emitsError(anyOf(isA<FormatException>(), isA<GrpcError>())));
  });

  test('canceling the event subscription cancels the native RunApplication call', () async {
    final ended = Completer<void>();
    peer.events = (call) async* {
      try {
        while (!call.isCanceled) {
          yield <int>[];
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      } finally {
        ended.complete();
      }
    };
    expect((await _run(desktop).first).kind.name, 'offline');
    await ended.future.timeout(const Duration(seconds: 3));
    expect(peer.requests, hasLength(1));
  });

  test('missing or insecure foreground transport never falls back to the background service', () async {
    final insecure = ClientChannel(
      '127.0.0.1',
      port: server.port!,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    addTearDown(insecure.terminate);
    for (final entry in [(null, StatusCode.unavailable), (insecure, StatusCode.unauthenticated)]) {
      final candidate = _Desktop(entry.$1)
        ..fgClient = CoreClient(channel)
        ..bgClient = CoreClient(channel);
      await expectLater(
        _run(candidate),
        emitsError(isA<GrpcError>().having((error) => error.code, 'status', entry.$2)),
      );
      expect(peer.requests, isEmpty);
    }
  });
}
