import 'dart:convert';
import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/features/app_update/data/github_release_parser.dart';
import 'package:hiddify/features/app_update/model/install_kind.dart';
import 'package:hiddify/features/app_update/notifier/app_updater.dart';
import 'package:hiddify/features/window/notifier/window_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const _original = '#!/bin/sh\n# previous working image\nexit 0\n';
const _candidate = '#!/bin/sh\n# candidate image\nexit 0\n';
const _broken = '#!/nonexistent-hiddify-regression-interpreter\n';
const _testPath = 'test/features/app_update/appimage_rollback_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final root = Platform.environment['HIDDIFY_APPIMAGE_TEST_ROOT'];
  if (root == null) {
    test(
      'AppImage install regressions in an isolated process and environment',
      () async {
        final temporary = await Directory.systemTemp.createTemp('hiddify-appimage-regression-');
        addTearDown(() => temporary.delete(recursive: true));
        final bin = await Directory('${temporary.path}/bin').create();
        final chmod = File('${bin.path}/chmod');
        await chmod.writeAsString(
          '#!/bin/sh\n'
          'if [ -f "\$HIDDIFY_APPIMAGE_TEST_ROOT/fail-chmod" ]; then exit 1; fi\n'
          'exec /bin/chmod "\$@"\n',
        );
        expect((await Process.run('/bin/chmod', ['755', chmod.path])).exitCode, 0);
        await File('${temporary.path}/owned-by-regression-test').writeAsString('temporary fixture');
        final packageConfig = File('.dart_tool/package_config.json');
        final packages = (jsonDecode(await packageConfig.readAsString()) as Map<String, dynamic>)['packages'] as List;
        final flutterPackage = packages.cast<Map<String, dynamic>>().singleWhere((entry) => entry['name'] == 'flutter');
        final sdk = Directory.fromUri(packageConfig.uri.resolve(flutterPackage['rootUri'] as String)).parent.parent;
        final result = await Process.run(
          '${sdk.path}/bin/flutter',
          ['--suppress-analytics', 'test', '--no-pub', _testPath, '--reporter', 'expanded'],
          environment: {
            'HIDDIFY_APPIMAGE_TEST_ROOT': temporary.path,
            'APPIMAGE': '${temporary.path}/images/Current.AppImage',
            'PATH': '${bin.path}:${Platform.environment['PATH']}',
          },
        );
        expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: !Platform.isLinux,
    );
    return;
  }

  // Never use an installed AppImage supplied by the developer's environment.
  if (!File('$root/owned-by-regression-test').existsSync() ||
      Platform.environment['APPIMAGE'] != '$root/images/Current.AppImage') {
    throw StateError('Refusing to run without the isolated AppImage fixture.');
  }
  final current = File('$root/images/Current.AppImage');
  final cache = Directory('$root/cache');
  final failedChmod = File('$root/fail-chmod');
  late PathProviderPlatform originalPaths;
  late _Downloads client;
  late ProviderContainer container;
  late int quits;

  setUp(() async {
    if (current.parent.existsSync()) await current.parent.delete(recursive: true);
    if (cache.existsSync()) await cache.delete(recursive: true);
    if (failedChmod.existsSync()) await failedChmod.delete();
    await current.parent.create(recursive: true);
    await cache.create();
    await current.writeAsString(_original);
    expect((await Process.run('/bin/chmod', ['755', current.path])).exitCode, 0);
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(cache.path);
    client = _Downloads();
    quits = 0;
    container = ProviderContainer(
      overrides: [
        installKindProvider.overrideWithValue(InstallKind.linuxAppImage),
        httpClientProvider.overrideWithValue(client),
        windowNotifierProvider.overrideWith(() => _Window(() => quits++)),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    PathProviderPlatform.instance = originalPaths;
  });

  Future<void> update() async {
    final bytes = utf8.encode(client.payload);
    final release = GithubReleaseParser.parse({
      'tag_name': 'v9.9.9',
      'html_url': 'https://example.invalid/release',
      'published_at': '2026-11-01T00:00:00Z',
      'assets': [
        {
          'name': 'Hiddify-Linux-x64-AppImage.AppImage',
          'browser_download_url': 'https://example.invalid/candidate',
          'size': bytes.length,
          'digest': 'sha256:${sha256.convert(bytes)}',
        },
      ],
    })!;
    await container.read(appUpdaterProvider.notifier).update(release);
  }

  Future<List<File>> preservedImages() async {
    final result = <File>[];
    await for (final entity in current.parent.list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path != current.path && await entity.readAsString() == _original) {
        result.add(entity);
      }
    }
    return result;
  }

  test('failed exec restores the working AppImage and its executable mode', () async {
    client.payload = _broken;
    await update();
    expect(container.read(appUpdaterProvider), isA<AppUpdaterFailed>());
    expect(await current.readAsString(), _original);
    expect((await current.stat()).mode & 0x1ff, 0x1ed);
    expect(quits, 0);
  });

  test('a chmod failure leaves the working AppImage untouched', () async {
    await failedChmod.writeAsString('fail');
    await update();
    expect(container.read(appUpdaterProvider), isA<AppUpdaterFailed>());
    expect(await current.readAsString(), _original);
    expect(quits, 0);
  });

  test('successful replacement retains an executable recovery copy', () async {
    await update();
    expect(container.read(appUpdaterProvider), isNot(isA<AppUpdaterFailed>()));
    expect(await current.readAsString(), _candidate);
    final previous = await preservedImages();
    expect(previous, hasLength(1));
    expect((await previous.single.stat()).mode & 0x1ff, 0x1ed);
    expect(quits, 1);
  });

  test('replacement never overwrites an unrelated .new file', () async {
    final unrelated = File('${current.path}.new');
    await unrelated.writeAsString('unrelated file');
    await update();
    expect(container.read(appUpdaterProvider), isNot(isA<AppUpdaterFailed>()));
    expect(await current.readAsString(), _candidate);
    expect(unrelated.existsSync(), isTrue);
    expect(await unrelated.readAsString(), 'unrelated file');
  });

  test('rollback leaves an existing backup file intact', () async {
    final unrelated = File('${current.path}.backup');
    await unrelated.writeAsString('older backup');
    client.payload = _broken;
    await update();
    expect(await current.readAsString(), _original);
    expect(await unrelated.readAsString(), 'older backup');
  });

  test('a replacement that exits with an error still leaves a recovery copy', () async {
    client.payload = '#!/bin/sh\nexit 1\n';
    await update();
    expect(await preservedImages(), hasLength(1));
  });

  test('a download failure leaves the working AppImage untouched', () async {
    client.fail = true;
    await update();
    expect(container.read(appUpdaterProvider), isA<AppUpdaterFailed>());
    expect(await current.readAsString(), _original);
    expect(quits, 0);
  });
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

class _Window extends WindowNotifier {
  _Window(this.onQuit);
  final void Function() onQuit;
  @override
  Future<void> build() async {}
  @override
  Future<void> exit() async => onQuit();
}

class _Downloads extends DioHttpClient {
  _Downloads() : super(timeout: const Duration(seconds: 1), userAgent: 'regression-test', debug: false);
  String payload = _candidate;
  bool fail = false;
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
    if (fail) throw FileSystemException('synthetic download failure');
    await File(path).writeAsString(payload);
    return Response(requestOptions: RequestOptions(path: url), statusCode: 200);
  }
}
