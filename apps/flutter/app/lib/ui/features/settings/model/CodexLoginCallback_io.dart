// ignore_for_file: file_names

import 'dart:async';
import 'dart:io';

/// Authorization code delivered to the fixed Codex callback port.
class CodexLoginCallback {
  const CodexLoginCallback({required this.code, required this.state});

  final String code;
  final String state;
}

/// Listens on the fixed Codex callback port for both localhost address families.
class CodexLoginCallbackListener {
  CodexLoginCallbackListener._(this._servers) {
    for (final server in _servers) {
      server.listen(
        _handleRequest,
        onError: _handleServerError,
        cancelOnError: false,
      );
    }
  }

  static Future<CodexLoginCallbackListener> bind() async {
    final servers = <HttpServer>[];
    Object? failure;
    for (final address in <InternetAddress>[
      InternetAddress.loopbackIPv4,
      InternetAddress.loopbackIPv6,
    ]) {
      try {
        servers.add(await HttpServer.bind(address, 1455));
      } catch (error) {
        failure = error;
      }
    }
    if (servers.isEmpty) {
      throw StateError('Codex callback listener could not start: $failure');
    }
    return CodexLoginCallbackListener._(servers);
  }

  final List<HttpServer> _servers;
  final Completer<CodexLoginCallback?> _completion =
      Completer<CodexLoginCallback?>();
  bool _closed = false;

  Future<CodexLoginCallback?> get completion => _completion.future;

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    if (!_completion.isCompleted) {
      _completion.complete(null);
    }
    for (final server in _servers) {
      await server.close(force: true);
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.uri.path != '/auth/callback') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final code = request.uri.queryParameters['code'] ?? '';
    final state = request.uri.queryParameters['state'] ?? '';
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(
        '<!doctype html><html><body>Codex login complete. You can return to PengSong.</body></html>',
      );
    await request.response.close();
    if (code.isEmpty || state.isEmpty) {
      if (!_completion.isCompleted) {
        _completion.completeError(
          StateError('Codex callback did not include an authorization code'),
        );
      }
      await close();
      return;
    }
    if (!_completion.isCompleted) {
      _completion.complete(CodexLoginCallback(code: code, state: state));
    }
    await close();
  }

  void _handleServerError(Object error, StackTrace stackTrace) {
    if (!_completion.isCompleted) {
      _completion.completeError(error, stackTrace);
    }
    unawaited(close());
  }
}
