// ignore_for_file: file_names

import 'dart:async';
import 'dart:io';

/// Owns the temporary browser callback used by an external GitHub login.
class GitHubOAuthLoginCallback {
  GitHubOAuthLoginCallback._(this._server, {required this.redirectUri}) {
    _server.listen(
      _handleRequest,
      onError: _handleServerError,
      cancelOnError: false,
    );
  }

  /// Reserves an available loopback port and preserves the broker callback path.
  static Future<GitHubOAuthLoginCallback> create(
    Uri requestedRedirectUri,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return GitHubOAuthLoginCallback._(
      server,
      redirectUri: Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.host,
        port: server.port,
        path: requestedRedirectUri.path,
      ),
    );
  }

  final HttpServer _server;
  final Completer<Uri?> _completion = Completer<Uri?>();

  /// The callback destination registered with the Core OAuth broker.
  final Uri redirectUri;

  bool _closed = false;

  /// Completes with the exact callback URL reached by the browser.
  Future<Uri?> get completion => _completion.future;

  /// Closes the callback listener and resolves a pending login as cancelled.
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    if (!_completion.isCompleted) {
      _completion.complete(null);
    }
    await _server.close(force: true);
  }

  /// Accepts only the registered callback path and returns the query untouched.
  Future<void> _handleRequest(HttpRequest request) async {
    if (_closed) {
      await _writeResponse(
        request.response,
        HttpStatus.notFound,
        'This GitHub login is no longer active.',
      );
      return;
    }
    if (request.uri.path != redirectUri.path) {
      await _writeResponse(
        request.response,
        HttpStatus.notFound,
        'GitHub login callback destination is not registered.',
      );
      return;
    }

    final completionUri = redirectUri.replace(query: request.uri.query);
    await _writeResponse(
      request.response,
      HttpStatus.ok,
      'GitHub login complete. You can return to PengSong.',
    );
    if (!_completion.isCompleted) {
      _completion.complete(completionUri);
    }
    await close();
  }

  /// Fails the pending login if the operating system closes the listener.
  void _handleServerError(Object error, StackTrace stackTrace) {
    if (!_completion.isCompleted) {
      _completion.completeError(error, stackTrace);
    }
    unawaited(close());
  }

  /// Writes a small browser-visible response without exposing app internals.
  Future<void> _writeResponse(
    HttpResponse response,
    int statusCode,
    String message,
  ) async {
    response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.html
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..write(
        '<!doctype html><html><head><meta charset="utf-8">'
        '<title>PengSong GitHub login</title></head><body>$message</body></html>',
      );
    await response.close();
  }
}

/// Native platforms do not need a startup callback relay.
void consumeGitHubOAuthWebCallbackAtStartup() {}
