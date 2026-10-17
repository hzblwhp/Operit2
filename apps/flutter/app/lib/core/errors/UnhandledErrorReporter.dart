// ignore_for_file: file_names

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Describes an unhandled error without ending the application session.
class UnhandledErrorReport {
  /// Creates a diagnostic report for an unhandled application error.
  const UnhandledErrorReport({
    required this.source,
    required this.error,
    required this.stackTrace,
  });

  final String source;
  final Object error;
  final StackTrace? stackTrace;

  /// Formats the report for the error dialog and clipboard export.
  String get details {
    final buffer = StringBuffer()
      ..writeln('Unhandled error source: $source')
      ..writeln()
      ..writeln(error);
    if (stackTrace != null) {
      buffer
        ..writeln()
        ..writeln('Dart stack trace:')
        ..writeln(stackTrace);
    }
    return buffer.toString();
  }
}

/// Delivers unhandled errors to the active application dialog host.
class UnhandledErrorReporter {
  /// Prevents instances of this process-wide reporter.
  UnhandledErrorReporter._();

  static final ValueNotifier<UnhandledErrorReport?> pendingError =
      ValueNotifier<UnhandledErrorReport?>(null);
  static bool _errorDeliveryScheduled = false;

  /// Schedules one error notification without mutating widgets during a frame.
  static void report({
    required String source,
    required Object error,
    required StackTrace? stackTrace,
  }) {
    if (pendingError.value != null || _errorDeliveryScheduled) {
      return;
    }
    final report = UnhandledErrorReport(
      source: source,
      error: error,
      stackTrace: stackTrace,
    );
    _errorDeliveryScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _errorDeliveryScheduled = false;
      if (pendingError.value == null) {
        pendingError.value = report;
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }
}

/// Presents dismissible error dialogs while keeping the product tree mounted.
class UnhandledErrorHost extends StatefulWidget {
  /// Creates a dialog host beneath the application's Material navigator.
  const UnhandledErrorHost({required this.child, super.key});

  final Widget child;

  /// Creates the listener that presents errors on the existing navigator.
  @override
  State<UnhandledErrorHost> createState() => _UnhandledErrorHostState();
}

class _UnhandledErrorHostState extends State<UnhandledErrorHost> {
  bool _dialogPending = false;

  /// Subscribes to reports, including errors received before the host mounts.
  @override
  void initState() {
    super.initState();
    UnhandledErrorReporter.pendingError.addListener(_handleError);
    _handleError();
  }

  /// Removes the report listener without disposing the application's navigator.
  @override
  void dispose() {
    UnhandledErrorReporter.pendingError.removeListener(_handleError);
    super.dispose();
  }

  /// Defers route changes until the frame completes and prevents stacked dialogs.
  void _handleError() {
    if (_dialogPending || UnhandledErrorReporter.pendingError.value == null) {
      return;
    }
    _dialogPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(_presentError());
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  /// Shows one report and releases it when the user dismisses the dialog.
  Future<void> _presentError() async {
    final report = UnhandledErrorReporter.pendingError.value;
    try {
      if (report != null) {
        await showDialog<void>(
          context: context,
          builder: (context) => UnhandledErrorDialog(report: report),
        );
      }
    } finally {
      if (identical(UnhandledErrorReporter.pendingError.value, report)) {
        UnhandledErrorReporter.pendingError.value = null;
      }
      _dialogPending = false;
      if (mounted) {
        _handleError();
      }
    }
  }

  /// Keeps the same application child mounted throughout error reporting.
  @override
  Widget build(BuildContext context) => widget.child;
}

/// Displays diagnostics in a dialog that never invokes a native crash screen.
class UnhandledErrorDialog extends StatelessWidget {
  /// Creates a dismissible error dialog with selectable diagnostic details.
  const UnhandledErrorDialog({required this.report, super.key});

  final UnhandledErrorReport report;

  /// Copies diagnostics while leaving the current dialog and app state intact.
  Future<void> _copyDetails() {
    return Clipboard.setData(ClipboardData(text: report.details));
  }

  /// Builds a scrollable dialog with an explicit continue action.
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      constraints: const BoxConstraints(maxWidth: 840),
      scrollable: true,
      icon: Icon(
        Icons.error_outline,
        color: Theme.of(context).colorScheme.error,
      ),
      title: const Text('PengSong encountered an error'),
      content: SizedBox(
        width: 760,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'An unexpected error occurred. You can close this dialog and '
              'continue using the app. The affected operation may not have completed.',
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.4,
              child: _ErrorDetails(report: report),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton.icon(
          onPressed: _copyDetails,
          icon: const Icon(Icons.copy),
          label: const Text('Copy details'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Continue using app'),
        ),
      ],
    );
  }
}

/// Displays startup diagnostics when no application tree has been started.
class StartupErrorApplication extends StatelessWidget {
  /// Creates the startup error container for incomplete initialization.
  const StartupErrorApplication({super.key});

  /// Builds a diagnostic screen without claiming the application is usable.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PengSong',
      home: Scaffold(
        body: SafeArea(
          child: ValueListenableBuilder<UnhandledErrorReport?>(
            valueListenable: UnhandledErrorReporter.pendingError,
            builder: (context, report, _) {
              if (report == null) {
                return const SizedBox.expand();
              }
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'PengSong could not start',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'An error prevented application initialization.',
                    ),
                    const SizedBox(height: 16),
                    Expanded(child: _ErrorDetails(report: report)),
                    const SizedBox(height: 16),
                    TextButton.icon(
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: report.details),
                      ),
                      icon: const Icon(Icons.copy),
                      label: const Text('Copy details'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Renders selectable diagnostics within a bounded scrolling surface.
class _ErrorDetails extends StatelessWidget {
  /// Creates the shared diagnostic surface for dialogs and startup errors.
  const _ErrorDetails({required this.report});

  final UnhandledErrorReport report;

  /// Builds the report using the surrounding application's Material theme.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          report.details,
          style: theme.textTheme.bodySmall?.copyWith(
            fontFamily: 'OperitTerminalMono',
          ),
        ),
      ),
    );
  }
}
