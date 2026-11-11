import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/home/widget/home_page.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _NoProfile extends ActiveProfile {
  @override
  Stream<ProfileEntity?> build() => Stream.value(null);
}

class _Picker extends FilePicker {
  String? selected;
  int visits = 0;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    visits++;
    expect(type, FileType.any);
    expect(allowedExtensions, isNull);
    expect(allowMultiple, isFalse);
    return selected == null
        ? null
        : FilePickerResult([PlatformFile(name: selected!.split('/').last, path: selected, size: 256)]);
  }
}

class _Core extends Fake implements CoreInterface {
  final calls = <Invocation>[];
  int cancellations = 0;
  GrpcError? refusal;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName != #runApplication) return super.noSuchMethod(invocation);
    calls.add(invocation);
    if (refusal != null) return Stream<Never>.error(refusal!);
    return StreamController<Never>(
      onCancel: () {
        cancellations++;
      },
    ).stream;
  }
}

class _Service extends HiddifyCoreService {
  _Service(super.ref, this.core);
  @override
  final CoreInterface core;
}

// Mount the real HomePage actions. The connection animation and its providers
// are unrelated to selecting a program and can remain unmounted in this test.
class _HomeActions extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = const HomePage().build(context, ref) as Scaffold;
    return Scaffold(appBar: AppBar(actions: (page.appBar! as AppBar).actions));
  }
}

void main() {
  late _Core core;
  late _Picker picker;
  late ProviderContainer container;
  const file = '/home/test/My Tools/a previously unlisted program';
  Finder control(String key) => find.byKey(ValueKey(key));
  final linux = TargetPlatformVariant.only(TargetPlatform.linux);

  Future<void> show(WidgetTester tester) async {
    core = _Core();
    picker = _Picker();
    FilePicker.platform = picker;
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

  Future<void> open(WidgetTester tester) async {
    expect(
      control('application_launcher'),
      findsOneWidget,
      reason: 'Linux must offer application launch without a profile',
    );
    await tester.tap(control('application_launcher'));
    await tester.pumpAndSettle();
    expect(control('application_launcher_dialog'), findsOneWidget);
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.ensureVisible(control(key));
    await tester.tap(control(key));
    await tester.pumpAndSettle();
  }

  testWidgets('chooser cancellation keeps the form idle; arguments and sessions survive dialog navigation', (
    tester,
  ) async {
    await show(tester);
    await open(tester);
    await tap(tester, 'application_choose_file');
    expect(picker.visits, 1);
    expect(core.calls, isEmpty);
    expect(tester.widget<ButtonStyleButton>(control('application_launch')).onPressed, isNull);

    picker.selected = file;
    await tap(tester, 'application_choose_file');
    expect(find.text(file), findsOneWidget);
    for (final (index, literal) in ['one two', r'$HOME', ''].indexed) {
      await tap(tester, 'application_add_argument');
      await tester.enterText(control('application_argument_$index'), literal);
    }
    await tap(tester, 'application_private_wayland');
    await tap(tester, 'application_launch');
    expect(core.calls, hasLength(1));
    expect(core.calls.single.namedArguments[#command], [file, 'one two', r'$HOME', '']);
    expect(core.calls.single.namedArguments[#privateWayland], false);

    await tap(tester, 'application_close_dialog');
    expect(control('application_launcher_dialog'), findsNothing);
    expect(core.cancellations, 0);
    await open(tester);
    expect(find.text(file), findsOneWidget);
    final stop = find.byTooltip('Stop application');
    expect(stop, findsOneWidget);
    await tester.ensureVisible(stop);
    await tester.tap(stop);
    await tester.pumpAndSettle();
    expect(core.cancellations, 1);
  }, variant: linux);

  testWidgets('a typed executable requests a window and an older core gives a useful failure', (tester) async {
    await show(tester);
    core.refusal = const GrpcError.unimplemented('RunApplication');
    await open(tester);
    await tester.enterText(control('application_executable'), file);
    await tap(tester, 'application_launch');
    expect(picker.visits, 0);
    expect(core.calls, hasLength(1));
    expect(core.calls.single.namedArguments[#command], [file]);
    expect(core.calls.single.namedArguments[#privateWayland], true);
    expect(find.text('Update the Hiddify core to launch applications.'), findsOneWidget);
  }, variant: linux);

  testWidgets('Android keeps the existing home actions', (tester) async {
    await show(tester);
    expect(control('application_launcher'), findsNothing);
    expect(control('profile_add_button'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
