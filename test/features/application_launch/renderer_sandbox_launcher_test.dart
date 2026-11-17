import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/application_launch/application_sessions.dart';
import 'package:hiddify/features/home/widget/home_page.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/hiddifycore/application_launch.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _Core extends Fake implements CoreInterface {
  final requests = <Invocation>[];
  final events = <StreamController<ApplicationEvent>>[];
  int cancellations = 0;
  GrpcError? refusal;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName != #runApplication && invocation.memberName != #runApplicationWithRendererSandbox) {
      return super.noSuchMethod(invocation);
    }
    requests.add(invocation);
    if (refusal != null) return Stream<ApplicationEvent>.error(refusal!);
    final controller = StreamController<ApplicationEvent>(
      onCancel: () {
        cancellations++;
      },
    );
    events.add(controller);
    return controller.stream;
  }
}

class _Service extends HiddifyCoreService {
  _Service(super.ref, this.endpoint);
  final CoreInterface endpoint;

  @override
  CoreInterface get core => endpoint;
}

class _NoProfile extends ActiveProfile {
  @override
  Stream<ProfileEntity?> build() => Stream.value(null);
}

class _HomeActions extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = const HomePage().build(context, ref) as Scaffold;
    return Scaffold(appBar: AppBar(actions: (page.appBar! as AppBar).actions));
  }
}

void main() {
  late _Core core;
  late ProviderContainer container;
  final linux = TargetPlatformVariant.only(TargetPlatform.linux);
  Finder control(String name) => find.byKey(ValueKey('application_$name'));

  Future<void> show(WidgetTester tester) async {
    core = _Core();
    container = ProviderContainer(
      overrides: [
        translationsProvider.overrideWith((ref) => AppLocale.en.build()),
        activeProfileProvider.overrideWith(_NoProfile.new),
        hasAnyProfileProvider.overrideWith((ref) => Stream.value(false)),
        hiddifyCoreServiceProvider.overrideWith((ref) => _Service(ref, core)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(translationsProvider.future);
    tester.view.physicalSize = const Size(1100, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: _HomeActions()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String name) async {
    expect(control(name), findsOneWidget, reason: 'The launcher must offer $name.');
    await tester.ensureVisible(control(name));
    await tester.tap(control(name));
    await tester.pumpAndSettle();
  }

  Future<void> enter(WidgetTester tester, String name, String value) async {
    await tester.ensureVisible(control(name));
    await tester.enterText(control(name), value);
    await tester.pump();
  }

  for (final mode in ['executable', 'bash', 'sh']) {
    testWidgets('$mode uses renderer sandbox only after an explicit selection', (tester) async {
      await show(tester);
      await tap(tester, 'launcher');
      expect(control('renderer_sandbox'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(control('renderer_sandbox')).value, isFalse);
      final List<String> command;
      if (mode == 'executable') {
        command = ['/opt/Example App/unlisted tool', r'literal $HOME | cat', 'two words'];
        await enter(tester, 'executable', command.first);
        for (final (index, value) in command.skip(1).indexed) {
          await tap(tester, 'add_argument');
          await enter(tester, 'argument_$index', value);
        }
        await tap(tester, 'private_wayland');
      } else {
        const source = ' arbitrary-command "two words" | cat\n';
        command = ['/bin/$mode', '-c', '--', source];
        await tap(tester, 'mode_$mode');
        await enter(tester, 'shell_command', source);
      }
      await tap(tester, 'launch');
      expect(core.requests.single.memberName, #runApplication);
      await tap(tester, 'renderer_sandbox');
      await tap(tester, 'launch');
      expect(core.requests[1].memberName, #runApplicationWithRendererSandbox);
      await tap(tester, 'renderer_sandbox');
      await tap(tester, 'launch');
      expect(core.requests[2].memberName, #runApplication);
      expect(core.requests, hasLength(3));
      for (final request in core.requests) {
        expect(request.namedArguments[#command], command);
        expect(request.namedArguments[#privateWayland], mode != 'executable');
        expect(request.namedArguments[#executableRoot], mode == 'executable' ? '/opt/Example App' : '');
        expect(request.namedArguments[#applicationId], core.requests.first.namedArguments[#applicationId]);
      }
    }, variant: linux);
  }

  testWidgets('profile network revocation leaves the renderer lease and child session alive', (tester) async {
    await show(tester);
    await tap(tester, 'launcher');
    await enter(tester, 'executable', '/usr/bin/arbitrary-client');
    await tap(tester, 'renderer_sandbox');
    await tap(tester, 'launch');
    expect(core.requests.single.memberName, #runApplicationWithRendererSandbox);
    final id = container.read(applicationSessionsProvider).single.id;
    for (final event in [
      const ApplicationEvent(kind: ApplicationEventKind.offline),
      const ApplicationEvent(kind: ApplicationEventKind.online),
      const ApplicationEvent(kind: ApplicationEventKind.offline, message: 'Profile revoked'),
    ]) {
      core.events.single.add(event);
      await tester.pumpAndSettle();
      final session = container.read(applicationSessionsProvider).single;
      expect(session.id, id);
      expect(session.phase.name, event.kind.name);
      expect(core.cancellations, 0);
    }
    await tap(tester, 'close_dialog');
    expect(core.cancellations, 0);
    await tap(tester, 'launcher');
    expect(tester.widget<SwitchListTile>(control('renderer_sandbox')).value, isFalse);
    expect(find.text('Profile revoked'), findsOneWidget);
    final stop = find.byTooltip('Stop application');
    await tester.ensureVisible(stop);
    await tester.tap(stop);
    await tester.pumpAndSettle();
    expect(core.cancellations, 1);
    expect(container.read(applicationSessionsProvider).single.phase, ApplicationPhase.stopped);
    expect(core.requests, hasLength(1));
  }, variant: linux);

  testWidgets('an unsupported renderer capability shows its error without a standard launch retry', (tester) async {
    await show(tester);
    core.refusal = const GrpcError.unimplemented('RunRendererApplication is unavailable');
    await tap(tester, 'launcher');
    await enter(tester, 'executable', '/usr/bin/arbitrary-client');
    await tap(tester, 'renderer_sandbox');
    await tap(tester, 'launch');
    expect(core.requests, hasLength(1));
    expect(core.requests.single.memberName, #runApplicationWithRendererSandbox);
    expect(find.text('Update the Hiddify core to launch applications.'), findsOneWidget);
    expect(find.text('RunRendererApplication is unavailable'), findsOneWidget);
    expect(container.read(applicationSessionsProvider).single.phase, ApplicationPhase.failed);
  }, variant: linux);

  testWidgets('Android has no renderer launch entry', (tester) async {
    await show(tester);
    expect(control('launcher'), findsNothing);
    expect(control('renderer_sandbox'), findsNothing);
    expect(find.byKey(const ValueKey('profile_add_button')), findsOneWidget);
    expect(core.requests, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
