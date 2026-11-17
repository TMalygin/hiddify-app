import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/home/widget/home_page.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/hiddifycore/application_launch.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Core extends CoreInterface {
  final calls = <({List<String> command, String home, bool window, String root})>[];
  Stream<ApplicationEvent> Function() events = () =>
      Stream.value(const ApplicationEvent(kind: ApplicationEventKind.exited));

  @override
  Stream<ApplicationEvent> runApplication({
    required List<String> command,
    required String applicationId,
    required bool privateWayland,
    String executableRoot = '',
  }) {
    calls.add((command: List.of(command), home: applicationId, window: privateWayland, root: executableRoot));
    return events();
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
    final home = const HomePage().build(context, ref) as Scaffold;
    return Scaffold(appBar: AppBar(actions: (home.appBar! as AppBar).actions));
  }
}

void main() {
  final linux = TargetPlatformVariant.only(TargetPlatform.linux);
  late _Core core;

  Finder control(String name) => find.byKey(ValueKey('application_$name'));

  Future<void> showHome(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    core = _Core();
    final container = ProviderContainer(
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
    final target = control(name);
    expect(target, findsOneWidget, reason: 'The launcher must offer $name.');
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String name, String text) async {
    await tester.ensureVisible(control(name));
    await tester.enterText(control(name), text);
    await tester.pump();
  }

  for (final shell in ['bash', 'sh']) {
    testWidgets('$shell dispatches a command by name with the original source in one argument', (tester) async {
      const command = "  printf '%s\\n' \"two  words\" \"\$HOME\" | wc -l\nprintf 'done'  ";
      await showHome(tester);
      await tap(tester, 'launcher');
      expect(control('executable'), findsOneWidget);
      expect(control('shell_command'), findsNothing);
      expect(find.text('Executable'), findsWidgets);
      expect(find.text('Bash'), findsOneWidget);
      expect(find.text('sh'), findsOneWidget);
      await type(tester, 'executable', '/usr/bin/echo');
      await tap(tester, 'add_argument');
      await type(tester, 'argument_0', 'file mode only');
      await tap(tester, 'mode_$shell');
      expect(control('executable'), findsNothing);
      expect(control('add_argument'), findsNothing);
      expect(tester.widget<TextField>(control('shell_command')).maxLines, isNot(1));
      await type(tester, 'shell_command', command);
      if (shell == 'sh') await tap(tester, 'private_wayland');
      await tap(tester, 'launch');
      final call = core.calls.single;
      expect(call.command, ['/bin/$shell', '-c', '--', command]);
      expect(call.root, isEmpty);
      expect(call.window, shell == 'bash');
      expect(find.text('Exited with code 0'), findsOneWidget);
    }, variant: linux);
  }

  testWidgets('blank shell input disables launch and a nonblank command enables it', (tester) async {
    await showHome(tester);
    await tap(tester, 'launcher');
    await tap(tester, 'mode_bash');
    final button = control('launch');
    for (final blank in ['', '   \n\t ']) {
      await type(tester, 'shell_command', blank);
      expect(tester.widget<ButtonStyleButton>(button).onPressed, isNull);
      await tester.tap(button);
      await tester.pump();
      expect(core.calls, isEmpty);
    }
    await type(tester, 'shell_command', 'pwd');
    expect(tester.widget<ButtonStyleButton>(button).onPressed, isNotNull);
    await tap(tester, 'launch');
    expect(core.calls.single.command, ['/bin/bash', '-c', '--', 'pwd']);
  }, variant: linux);

  testWidgets('the private home follows the exact command and interpreter, separate from an executable launch', (
    tester,
  ) async {
    const command = 'printf fixture-shell-marker';
    await showHome(tester);
    await tap(tester, 'launcher');
    await tap(tester, 'mode_bash');
    await type(tester, 'shell_command', command);
    await tap(tester, 'launch');
    await type(tester, 'shell_command', command);
    await tap(tester, 'launch');
    await type(tester, 'shell_command', '$command ');
    await tap(tester, 'launch');
    await tap(tester, 'mode_sh');
    await type(tester, 'shell_command', command);
    await tap(tester, 'launch');
    await tap(tester, 'mode_executable');
    await type(tester, 'executable', '/bin/bash');
    for (final (index, value) in ['-c', '--', command].indexed) {
      await tap(tester, 'add_argument');
      await type(tester, 'argument_$index', value);
    }
    await tap(tester, 'launch');
    expect(core.calls, hasLength(5));
    final homes = core.calls.map((call) => call.home).toList();
    expect(homes[0], matches(RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$')));
    expect(homes[1], homes[0]);
    expect({homes[0], homes[2], homes[3], homes[4]}, hasLength(4));
    expect(core.calls[4].command, core.calls[0].command);
    await tap(tester, 'close_dialog');
    await tap(tester, 'launcher');
    expect(find.text('Exited with code 0'), findsNWidgets(5));
    expect(find.textContaining('fixture-shell-marker', findRichText: true), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      expect(key, isNot(contains('fixture-shell-marker')));
      expect(prefs.get(key).toString(), isNot(contains('fixture-shell-marker')));
    }
  }, variant: linux);

  testWidgets('direct executable mode passes shell metacharacters as literal argv entries', (tester) async {
    const executable = '/opt/Sample App/my tool';
    const arguments = ['two words', r'$HOME | wc -l', "'quoted'", '*', ''];
    await showHome(tester);
    await tap(tester, 'launcher');
    await type(tester, 'executable', executable);
    for (final (index, value) in arguments.indexed) {
      await tap(tester, 'add_argument');
      await type(tester, 'argument_$index', value);
    }
    await tap(tester, 'launch');
    final call = core.calls.single;
    expect(call.command, [executable, ...arguments]);
    expect(call.root, '/opt/Sample App');
    expect(call.window, isTrue);
  }, variant: linux);

  testWidgets('shell failures show the native diagnostic, stderr and exit code', (tester) async {
    await showHome(tester);
    await tap(tester, 'launcher');
    await tap(tester, 'mode_sh');
    await type(tester, 'shell_command', 'missing-test-command');
    core.events = () => Stream.error(const GrpcError.failedPrecondition('Shell executable unavailable'));
    await tap(tester, 'launch');
    expect(find.text('Launch failed'), findsOneWidget);
    expect(find.text('Shell executable unavailable'), findsOneWidget);
    core.events = () => Stream.fromIterable([
      ApplicationEvent(kind: ApplicationEventKind.output, stderr: utf8.encode('fixture command not found')),
      const ApplicationEvent(kind: ApplicationEventKind.exited, exitCode: 127),
    ]);
    await type(tester, 'shell_command', 'missing-test-command');
    await tap(tester, 'launch');
    expect(find.text('Exited with code 127'), findsOneWidget);
    final output = find.text('Program output');
    await tester.ensureVisible(output);
    await tester.tap(output);
    await tester.pumpAndSettle();
    expect(find.text('fixture command not found'), findsOneWidget);
    expect(core.calls, hasLength(2));
  }, variant: linux);

  testWidgets(
    'the Android home keeps the profile action without a shell launch entry',
    (tester) async {
      await showHome(tester);
      expect(find.byKey(const ValueKey('profile_add_button')), findsOneWidget);
      expect(control('launcher'), findsNothing);
      expect(control('mode_bash'), findsNothing);
      expect(control('mode_sh'), findsNothing);
      expect(core.calls, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
