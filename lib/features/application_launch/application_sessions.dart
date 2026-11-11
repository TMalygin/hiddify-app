import 'package:hiddify/hiddifycore/application_sessions.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

export 'package:hiddify/hiddifycore/application_sessions.dart' show ApplicationPhase, ApplicationSession;

final applicationSessionsProvider = StateNotifierProvider<ApplicationSessions, List<ApplicationSession>>(
  (ref) => ref.watch(hiddifyCoreServiceProvider).createApplicationSessions(),
  dependencies: [hiddifyCoreServiceProvider],
);
