import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/application_launch/application_sessions.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as path;

class ApplicationLauncherDialog extends ConsumerStatefulWidget {
  const ApplicationLauncherDialog({super.key});

  @override
  ConsumerState<ApplicationLauncherDialog> createState() => _ApplicationLauncherDialogState();
}

class _Argument {
  _Argument(this.id);
  final int id;
  String text = '';
}

class _ApplicationLauncherDialogState extends ConsumerState<ApplicationLauncherDialog> {
  final executable = TextEditingController();
  final executableFocus = FocusNode();
  final scroll = ScrollController();
  final arguments = <_Argument>[];
  int nextArgument = 0;
  bool privateWayland = true;
  bool choosingFile = false;
  String? pathError;

  @override
  void initState() {
    super.initState();
    executableFocus.addListener(_onExecutableFocus);
  }

  void _onExecutableFocus() => setState(() {});

  @override
  void dispose() {
    executableFocus.dispose();
    executable.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> chooseFile() async {
    final t = ref.read(translationsProvider).requireValue.pages.applicationLauncher;
    executableFocus.unfocus();
    setState(() => choosingFile = true);
    try {
      final selection = await FilePicker.platform.pickFiles(dialogTitle: t.choose);
      if (!mounted || selection == null) return;
      final selected = selection.files.single.path;
      if (selected == null) {
        setState(() => pathError = t.pickerFailed);
      } else {
        setState(() {
          executable.text = selected;
          pathError = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => pathError = t.pickerFailed);
    } finally {
      if (mounted) setState(() => choosingFile = false);
    }
  }

  void launch() {
    final selected = executable.text;
    if (!path.posix.isAbsolute(selected)) {
      setState(() => pathError = ref.read(translationsProvider).requireValue.pages.applicationLauncher.absolutePath);
      return;
    }
    ref
        .read(applicationSessionsProvider.notifier)
        .launch(
          executable: selected,
          arguments: [for (final item in arguments) item.text],
          privateWayland: privateWayland,
        );
    FocusScope.of(context).unfocus();
    if (scroll.hasClients) scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final translations = ref.watch(translationsProvider).requireValue;
    final t = translations.pages.applicationLauncher;
    final sessions = ref.watch(applicationSessionsProvider);
    final theme = Theme.of(context);
    return Dialog(
      key: const ValueKey('application_launcher_dialog'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(24, 12, 12, 4),
              child: Row(
                children: [
                  Expanded(child: Text(t.title, style: theme.textTheme.titleLarge)),
                  IconButton(
                    key: const ValueKey('application_close_dialog'),
                    tooltip: translations.common.close,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                controller: scroll,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (sessions.isNotEmpty) ...[
                      Text(t.sessions, style: theme.textTheme.titleSmall),
                      for (final session in sessions) _SessionRow(key: ValueKey(session.id), session: session),
                      const Divider(height: 24),
                    ],
                    Text(t.hint, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 16),
                    TextField(
                      key: const ValueKey('application_executable'),
                      controller: executable,
                      focusNode: executableFocus,
                      autofocus: true,
                      textDirection: TextDirection.ltr,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: t.executable,
                        errorText: pathError,
                        errorMaxLines: 3,
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          key: const ValueKey('application_choose_file'),
                          tooltip: t.choose,
                          onPressed: choosingFile ? null : chooseFile,
                          icon: const Icon(Icons.folder_open_rounded),
                        ),
                      ),
                      onChanged: (_) => setState(() => pathError = null),
                      onSubmitted: (_) => launch(),
                    ),
                    for (final (index, item) in arguments.indexed)
                      Padding(
                        key: ValueKey(item.id),
                        padding: const EdgeInsets.only(top: 12),
                        child: TextFormField(
                          key: ValueKey('application_argument_${item.id}'),
                          initialValue: item.text,
                          textDirection: TextDirection.ltr,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            labelText: t.argument(number: index + 1),
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              tooltip: t.removeArgument(number: index + 1),
                              onPressed: () => setState(() => arguments.remove(item)),
                              icon: const Icon(Icons.remove_circle_outline_rounded),
                            ),
                          ),
                          onChanged: (value) => item.text = value,
                        ),
                      ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        key: const ValueKey('application_add_argument'),
                        icon: const Icon(Icons.add_rounded),
                        label: Text(t.addArgument),
                        onPressed: () => setState(() => arguments.add(_Argument(nextArgument++))),
                      ),
                    ),
                    SwitchListTile(
                      key: const ValueKey('application_private_wayland'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(t.window),
                      value: privateWayland,
                      onChanged: (value) => setState(() => privateWayland = value),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(24, 4, 24, 16),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton.icon(
                  key: const ValueKey('application_launch'),
                  onPressed: choosingFile || (executable.text.isEmpty && !executableFocus.hasFocus) ? null : launch,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(t.launch),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionRow extends ConsumerWidget {
  const _SessionRow({super.key, required this.session});
  final ApplicationSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue.pages.applicationLauncher;
    final manager = ref.read(applicationSessionsProvider.notifier);
    final theme = Theme.of(context);
    final status = switch (session.phase) {
      ApplicationPhase.starting => t.starting,
      ApplicationPhase.online => t.online,
      ApplicationPhase.offline => t.offline,
      ApplicationPhase.stopping => t.stopping,
      ApplicationPhase.stopped => t.stopped,
      ApplicationPhase.exited => t.exited(code: session.exitCode!),
      ApplicationPhase.failed => switch (session.grpcCode) {
        StatusCode.unimplemented => t.incompatible,
        StatusCode.unavailable => t.unavailable,
        _ => t.failed,
      },
    };
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(session.executable, textDirection: TextDirection.ltr, style: theme.textTheme.bodyMedium),
                        Text(
                          status,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: session.phase == ApplicationPhase.failed ? theme.colorScheme.error : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (session.isTerminal)
                    IconButton(
                      tooltip: t.dismiss,
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => manager.dismiss(session.id),
                    )
                  else
                    IconButton(
                      tooltip: t.stop,
                      icon: const Icon(Icons.stop_circle_outlined),
                      onPressed: session.phase == ApplicationPhase.stopping ? null : () => manager.stop(session.id),
                    ),
                ],
              ),
              if (session.diagnostic.isNotEmpty) SelectableText(session.diagnostic, style: theme.textTheme.bodySmall),
              if (session.output.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(t.output, style: theme.textTheme.bodySmall),
                  children: [Align(alignment: AlignmentDirectional.centerStart, child: SelectableText(session.output))],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
