import 'dart:io';

import 'package:grpc/grpc.dart';
import 'package:hiddify/hiddifycore/core_interface/mtls_channel_cred.dart';
import 'package:hiddify/hiddifycore/grpc_stream_cancel.dart';
import 'package:protobuf/protobuf.dart';

enum ApplicationEventKind {
  offline,
  online,
  error,
  exited,
  output;

  String get name => EnumName(this).name;
}

class ApplicationEvent {
  const ApplicationEvent({
    required this.kind,
    this.message = '',
    this.exitCode = 0,
    this.stdout = const [],
    this.stderr = const [],
  });

  final ApplicationEventKind kind;
  final String message;
  final int exitCode;
  final List<int> stdout;
  final List<int> stderr;
}

// The shared Dart stubs predate the fork's RunApplication method. The field numbers come from
// v2/hcore/hcore.proto, messages SandboxRunRequest and SandboxEvent.
final _runApplication = ClientMethod<CodedBufferWriter, ApplicationEvent>(
  '/hcore.Core/RunApplication',
  (request) => request.toBuffer(),
  _decodeEvent,
);

Stream<ApplicationEvent> launchOnForegroundCore(
  ClientChannel? channel, {
  required List<String> command,
  required String applicationId,
  required bool privateWayland,
  required String executableRoot,
}) async* {
  if (!Platform.isLinux) throw const GrpcError.unimplemented('Isolated application launch requires Linux.');
  if (channel == null) throw const GrpcError.unavailable('The foreground core is not ready.');
  if (channel.options.credentials is! MTLSChannelCredentials) {
    throw const GrpcError.unauthenticated('Isolated application launch requires mutual TLS.');
  }
  final request = CodedBufferWriter()
    ..writeField(1, PbFieldType.PS, command)
    ..writeField(2, PbFieldType.OS, applicationId);
  if (executableRoot.isNotEmpty) request.writeField(3, PbFieldType.OS, executableRoot);
  if (privateWayland) request.writeField(5, PbFieldType.OB, true);
  yield* Client(channel).$createStreamingCall(_runApplication, Stream.value(request)).cancelOnUnsubscribe;
}

ApplicationEvent _decodeEvent(List<int> bytes) {
  final input = CodedBufferReader(bytes);
  // An omitted state has the proto3 default SANDBOX_OFFLINE (0).
  var state = 0;
  var message = '';
  var exitCode = 0;
  List<int> stdout = const [];
  List<int> stderr = const [];
  while (!input.isAtEnd()) {
    final tag = input.readTag();
    switch (tag) {
      case 8: // state, enum
        state = input.readEnum();
      case 26: // stdout, bytes
        stdout = input.readBytes();
      case 34: // stderr, bytes
        stderr = input.readBytes();
      case 40: // exit_code, int32
        exitCode = input.readInt32();
      case 50: // message, string
        message = input.readString();
      default:
        if (!input.skipField(tag)) throw const FormatException('Invalid RunApplication event');
    }
  }

  final kind = switch (state) {
    0 => ApplicationEventKind.offline,
    1 => ApplicationEventKind.online,
    2 => ApplicationEventKind.error,
    3 => ApplicationEventKind.exited,
    4 => ApplicationEventKind.output,
    _ => throw FormatException('Unknown RunApplication state $state'),
  };
  return ApplicationEvent(kind: kind, message: message, exitCode: exitCode, stdout: stdout, stderr: stderr);
}
