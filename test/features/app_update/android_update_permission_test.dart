import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppLifecycleState;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/features/app_update/data/github_release_parser.dart';
import 'package:hiddify/features/app_update/model/install_kind.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';
import 'package:hiddify/features/app_update/notifier/app_updater.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const _filename = 'Hiddify-Android-arm64.apk';

RemoteVersionEntity _release(String version, String payload) => GithubReleaseParser.parse({
  'tag_name': 'v$version',
  'html_url': 'https://example.invalid/$version',
  'published_at': '2026-11-01T00:00:00Z',
  'assets': [
    {
      'name': _filename,
      'browser_download_url': 'https://example.invalid/$version/$_filename',
      'size': utf8.encode(payload).length,
      'digest': 'sha256:${sha256.convert(utf8.encode(payload))}',
    },
  ],
})!;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const platform = MethodChannel('com.hiddify.app/platform');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final first = _release('1.0.0', 'first');
  final second = _release('2.0.0', 'other');
  late Directory temp;
  late PathProviderPlatform previousPaths;
  late ProviderContainer container;
  late AppUpdater updater;
  late bool granted;
  late List<String> installed;
  late Completer<void> permissionQueried;
  late Completer<bool> permissionReply;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('hiddify-apk-permission-');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TempPath(temp.path);
    granted = false;
    installed = [];
    permissionQueried = Completer<void>();
    permissionReply = Completer<bool>();
    messenger.setMockMethodCallHandler(platform, (call) async {
      switch (call.method) {
        case 'supported_abis':
          return ['arm64-v8a'];
        case 'can_install_apks':
          if (!permissionQueried.isCompleted) permissionQueried.complete();
          return permissionReply.future;
        case 'install_apk':
          if (!granted) return 'permission';
          installed.add(await File(call.arguments as String).readAsString());
          return 'started';
        default:
          throw StateError('unexpected method ${call.method}');
      }
    });
    container = ProviderContainer(
      overrides: [
        installKindProvider.overrideWithValue(InstallKind.androidApk),
        httpClientProvider.overrideWithValue(
          _Downloads({first.assets.single.url: 'first', second.assets.single.url: 'other'}),
        ),
      ],
    );
    container.listen(appUpdaterProvider, (_, _) {});
    updater = container.read(appUpdaterProvider.notifier);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await updater.update(first);
    expect(container.read(appUpdaterProvider), isA<AppUpdaterNeedsPermission>());
  });

  tearDown(() async {
    container.dispose();
    messenger.setMockMethodCallHandler(platform, null);
    PathProviderPlatform.instance = previousPaths;
    await temp.delete(recursive: true);
  });

  void resume() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }

  Future<void> waitForAttempt() {
    final completed = Completer<void>();
    bool installing = false;
    container.listen(appUpdaterProvider, (_, next) {
      if (next is AppUpdaterInstalling) installing = true;
      if (!completed.isCompleted && (next is AppUpdaterFailed || (installing && next is AppUpdaterIdle))) {
        completed.complete();
      }
    });
    return completed.future.timeout(const Duration(seconds: 5));
  }

  for (final invalid in ['stale', 'truncated']) {
    test('permission resume checks the pending APK again after its bytes change to "$invalid"', () async {
      final pending = container.read(appUpdaterProvider) as AppUpdaterNeedsPermission;
      await pending.file.writeAsString(invalid);
      granted = true;
      final finished = waitForAttempt();
      resume();
      await permissionQueried.future;
      permissionReply.complete(true);
      await finished;
      // It may reject the changed cache or obtain the verified bytes again.
      expect(installed, everyElement('first'));
    });
  }

  test('retrying for a different release installs the newly selected APK', () async {
    granted = true;
    await updater.update(second);
    expect(installed, ['other']);
  });

  test('a delayed permission reply for an old release cannot install a pending replacement', () async {
    resume();
    await permissionQueried.future;
    await updater.update(second);
    final replacement = container.read(appUpdaterProvider);
    expect(replacement, isA<AppUpdaterNeedsPermission>());
    granted = true;
    permissionReply.complete(true);
    // Let the old asynchronous platform reply reach the listener.
    await Future<void>.delayed(Duration.zero);
    expect(container.read(appUpdaterProvider), same(replacement));
    expect(installed, isEmpty);
    final finished = waitForAttempt();
    resume();
    await finished;
    expect(installed, ['other']);
  });
}

class _TempPath extends PathProviderPlatform {
  _TempPath(this.path);
  final String path;

  @override
  Future<String?> getTemporaryPath() async => path;
}

class _Downloads extends DioHttpClient {
  _Downloads(this.payloads) : super(timeout: const Duration(seconds: 1), userAgent: 'test', debug: false);
  final Map<String, String> payloads;

  @override
  Future<Response> download(
    String url,
    String path, {
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    bool proxyOnly = false,
    ProgressCallback? onReceiveProgress,
  }) async {
    await File(path).writeAsString(payloads[url]!);
    return Response(requestOptions: RequestOptions(path: url), statusCode: 200);
  }
}
