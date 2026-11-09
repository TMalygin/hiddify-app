import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/logger/logger_setup.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:logging/logging.dart';

// Keep the real import method, without starting presentation toasts/dialogs.
class _ImportNotifier extends AddProfileNotifier {
  @override
  AsyncValue<Unit?> build() => const AsyncData(null);
}

class _Repository implements ProfileRepository {
  String? imported;

  @override
  TaskEither<ProfileFailure, Unit> upsertRemote(String url, {UserOverride? userOverride, CancelToken? cancelToken}) {
    imported = url;
    return TaskEither.right(unit);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const url =
      'https://fixture-user:fixture-password@subscriptions.example.invalid/private-path-key?token=fixture-token';
  final inputs = {
    'plain subscription': url,
    'install deep link': 'hiddify://install-config?url=${Uri.encodeComponent(url)}',
  };

  setUpAll(() {
    logSetConsoleEnabled(false);
    logStart();
  });
  setUp(logRing.clear);

  for (final entry in inputs.entries) {
    test('${entry.key} reaches the repository unchanged without leaking into logs', () async {
      final repository = _Repository();
      final container = ProviderContainer(
        overrides: [
          profileRepositoryProvider.overrideWith((ref) async => repository),
          addProfileNotifierProvider.overrideWith(_ImportNotifier.new),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(addProfileNotifierProvider, (_, __) {});
      addTearDown(subscription.close);
      final records = <LogRecord>[];
      final logs = Logger.root.onRecord.listen(records.add);
      addTearDown(logs.cancel);
      await container.read(profileRepositoryProvider.future);

      await container.read(addProfileNotifierProvider.notifier).addClipboard(entry.value);
      expect(container.read(addProfileNotifierProvider).hasError, isFalse);
      expect(repository.imported, url);
      expect(records, isNotEmpty, reason: 'The test must observe the actual import logging path');

      final directory = await Directory.systemTemp.createTemp('subscription-log-test-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/shared.log');
      await exportLogRing(file.path);
      final logged = '${records.map(formatRecord).join('\n')}\n${await file.readAsString()}';
      for (final secret in ['fixture-user', 'fixture-password', 'private-path-key', 'fixture-token']) {
        expect(
          logged,
          isNot(contains(secret)),
          reason: 'Logs and shared log exports must omit subscription credentials',
        );
      }
    });
  }
}
