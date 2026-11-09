import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/features/app_update/data/app_update_repository.dart';

class _ReleaseClient extends DioHttpClient {
  _ReleaseClient() : super(timeout: const Duration(seconds: 1), userAgent: 'channel-test', debug: false);

  final requests = <String>[];
  List<Map<String, Object>> releases = [];
  bool fail = false;

  @override
  Future<Response<T>> get<T>(
    String url, {
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    bool proxyOnly = false,
    ResponseType? responseType,
  }) async {
    requests.add(url);
    if (fail) throw StateError('fixture: release service unavailable');
    return Response<T>(
      requestOptions: RequestOptions(path: url),
      statusCode: 200,
      data: releases as T,
    );
  }
}

void main() {
  // Run unchanged with and without the fork build define. This expectation is
  // independent of the production constant and checks the actual repository call.
  const fork = bool.fromEnvironment('expect_fork_updates');
  const repository = fork ? 'TMalygin/hiddify-app' : 'hiddify/hiddify-app';
  const endpoint = 'https://api.github.com/repos/$repository/releases';

  test('requests releases only from the selected distribution repository', () async {
    final client = _ReleaseClient()
      ..releases = [
        {
          'tag_name': 'v99.0.0',
          'draft': false,
          'prerelease': false,
          'html_url': 'https://github.com/$repository/releases/tag/v99.0.0',
          'published_at': '2026-11-01T00:00:00Z',
          'assets': <Object>[],
        },
      ];
    final result = await AppUpdateRepositoryImpl(httpClient: client).getLatestVersion().run();
    expect(client.requests, [endpoint]);
    expect(result.isRight(), isTrue);
    result.match((_) => fail('expected release'), (release) => expect(release.version, '99.0.0'));
  });

  test('an empty channel never falls back to another repository', () async {
    final client = _ReleaseClient();
    final result = await AppUpdateRepositoryImpl(httpClient: client).getLatestVersion().run();
    expect(client.requests, [endpoint]);
    expect(result.isLeft(), isTrue);
  });

  test('a failed channel never falls back to another repository', () async {
    final client = _ReleaseClient()..fail = true;
    final result = await AppUpdateRepositoryImpl(httpClient: client).getLatestVersion().run();
    expect(client.requests, [endpoint]);
    expect(result.isLeft(), isTrue);
  });

  test('the release page stays in the same distribution repository', () {
    expect(Constants.githubLatestReleaseUrl, 'https://github.com/$repository/releases/latest');
  });

  test('store builds still make no custom update request', () async {
    final client = _ReleaseClient();
    final repository = AppUpdateRepositoryImpl(httpClient: client);
    for (final release in [Release.googlePlay, Release.appStore, Release.microsoftStore]) {
      expect((await repository.getLatestVersion(release: release).run()).isLeft(), isTrue);
    }
    expect(client.requests, isEmpty);
  });
}
