// ignore_for_file: file_names

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../bridge/ProxyCoreRuntimeBridge.dart';
import '../proxy/generated/CoreProxyClients.g.dart';

/// Serves this device's PengSong runtime over MCP.
///
/// The on-device assistant keeps its state inside the application sandbox,
/// which an external operator cannot read. This endpoint exposes a deliberately
/// small read-only surface so another agent can inspect the same conversations
/// the phone is having, without granting filesystem or shell access.
class PengSongMcpServer {
  /// Default loopback-visible port. Kept off 8899 so it never collides with
  /// the OmniBot device service.
  static const int defaultPort = 8898;

  /// Creates the server bound to the ordinary native core proxy.
  PengSongMcpServer({
    GeneratedCoreProxyClients? clients,
    this.port = defaultPort,
    this.token = 'pengsong-local',
  }) : _clients =
           clients ?? const GeneratedCoreProxyClients(ProxyCoreRuntimeBridge());

  final GeneratedCoreProxyClients _clients;

  /// Loopback-visible port. Kept off 8899 so it never collides with OmniBot.
  final int port;

  /// Bearer token required on every request; empty disables the check.
  final String token;

  HttpServer? _server;

  /// Starts listening once; repeated calls are ignored.
  Future<void> start() async {
    if (_server != null) {
      return;
    }
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: true);
    _server!.listen(
      (request) {
        unawaited(_serve(request));
      },
      onError: (Object error) {
        stderr.writeln('PengSong MCP server socket error: $error');
      },
      cancelOnError: false,
    );
  }

  /// Closes the listener and releases the port.
  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  /// Accepts only the configured bearer token.
  bool _isAuthorized(HttpRequest request) {
    if (token.isEmpty) {
      return true;
    }
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    return header == 'Bearer $token';
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    try {
      if (!_isAuthorized(request)) {
        response.statusCode = HttpStatus.unauthorized;
        return;
      }
      if (request.method != 'POST') {
        response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      final decoded = jsonDecode(body);
      final reply = decoded is Map<String, Object?>
          ? await _dispatch(decoded)
          : _errorReply(null, -32600, 'MCP requires a JSON-RPC object');
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(reply));
    } catch (error) {
      response.statusCode = HttpStatus.badRequest;
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode(_errorReply(null, -32700, 'Malformed request: $error')),
      );
    } finally {
      await response.close();
    }
  }

  Map<String, Object?> _errorReply(Object? id, int code, String message) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  };

  Future<Map<String, Object?>> _dispatch(Map<String, Object?> request) async {
    final id = request['id'];
    final method = request['method'] as String? ?? '';
    switch (method) {
      case 'initialize':
        return {
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion': '2024-11-05',
            'capabilities': {'tools': <String, Object?>{}},
            'serverInfo': {'name': 'pengsong', 'version': '1.0'},
          },
        };
      case 'notifications/initialized':
        return {'jsonrpc': '2.0', 'id': id, 'result': <String, Object?>{}};
      case 'tools/list':
        return {
          'jsonrpc': '2.0',
          'id': id,
          'result': {'tools': _toolDefinitions},
        };
      case 'tools/call':
        final params = request['params'];
        final map = params is Map<String, Object?> ? params : const <String, Object?>{};
        final name = map['name'] as String? ?? '';
        final arguments = map['arguments'];
        try {
          final text = await _invoke(
            name,
            arguments is Map<String, Object?>
                ? arguments
                : const <String, Object?>{},
          );
          return {
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'content': [
                {'type': 'text', 'text': text},
              ],
            },
          };
        } catch (error) {
          return {
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'isError': true,
              'content': [
                {'type': 'text', 'text': '$error'},
              ],
            },
          };
        }
      default:
        return _errorReply(id, -32601, 'Unknown method: $method');
    }
  }

  List<Map<String, Object?>> get _toolDefinitions => [
    {
      'name': 'export_chats',
      'description':
          'Export every chat history stored on this device as one JSON document.',
      'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
    },
    {
      'name': 'chat_summary',
      'description':
          'Read token and context statistics for one chat on this device.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'chatId': {'type': 'string', 'description': 'Chat identity.'},
        },
        'required': ['chatId'],
      },
    },
    {
      'name': 'read_log',
      'description':
          'Read the tail of this device application log to diagnose failures.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'maxChars': {
            'type': 'integer',
            'description': 'How many trailing characters to return.',
          },
        },
      },
    },
    {
      'name': 'list_dir',
      'description':
          'List one directory inside this application private storage.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Absolute directory path.'},
        },
        'required': ['path'],
      },
    },
    {
      'name': 'read_file',
      'description': 'Read one text file inside this application private storage.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Absolute file path.'},
          'maxChars': {
            'type': 'integer',
            'description': 'How many trailing characters to return.',
          },
        },
        'required': ['path'],
      },
    },
    {
      'name': 'package_log',
      'description':
          'Read the ToolPkg loader log, which records why a package failed to load.',
      'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
    },
    {
      'name': 'package_status',
      'description':
          'Report whether named ToolPkg packages are enabled, activated and exposing tools.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'names': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Package names to inspect.',
          },
        },
        'required': ['names'],
      },
    },
    {
      'name': 'use_package',
      'description':
          'Activate one ToolPkg package and return the tools it exposes.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': 'Package name to activate.'},
        },
        'required': ['name'],
      },
    },
    {
      'name': 'enable_package',
      'description':
          'Enable one ToolPkg package so use_package can resolve it later.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': 'Package name to enable.'},
        },
        'required': ['name'],
      },
    },
    {
      'name': 'set_package_scope',
      'description':
          'Move one package installation to the scope its manifest requires.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': 'Package name to move.'},
          'scope': {
            'type': 'string',
            'description': 'Target scope: device or space.',
          },
        },
        'required': ['name', 'scope'],
      },
    },
  ];

  Future<String> _invoke(String name, Map<String, Object?> arguments) async {
    switch (name) {
      case 'export_chats':
        return await _clients.chatRuntimeHolderMain
            .exportChatHistoriesToJson();
      case 'chat_summary':
        final chatId = (arguments['chatId'] as String? ?? '').trim();
        if (chatId.isEmpty) {
          throw StateError('chat_summary requires a chatId');
        }
        final summary = await _clients.chatRuntimeHolderMain
            .chatInputMenuSummary(chatId: chatId);
        return jsonEncode({
          'chatId': chatId,
          'currentWindowSize': summary.currentWindowSize,
          'inputTokens': summary.inputTokenCount,
          'outputTokens': summary.outputTokenCount,
          'maxContextLength': summary.maxContextLength,
        });
      case 'read_log':
        final rawLimit = arguments['maxChars'];
        final limit = rawLimit is int && rawLimit > 0
            ? rawLimit
            : 20000;
        return await _readLogTail(limit);
      case 'list_dir':
        return await _listDirectory(
          (arguments['path'] as String? ?? '').trim(),
        );
      case 'read_file':
        return await _readTextFile(
          (arguments['path'] as String? ?? '').trim(),
          arguments['maxChars'],
        );
      case 'package_log':
        return await _clients.application.packageLogText();
      case 'package_status':
        final raw = arguments['names'];
        final names = raw is List
            ? raw.whereType<String>().where((n) => n.trim().isNotEmpty).toList()
            : <String>[];
        if (names.isEmpty) {
          throw StateError('package_status requires a non-empty names list');
        }
        return await _reportPackageStatus(names);
      case 'use_package':
        final name = (arguments['name'] as String? ?? '').trim();
        if (name.isEmpty) {
          throw StateError('use_package requires a name');
        }
        final message = await _clients.application.packageManager()
            .usePackage(packageName: name);
        return jsonEncode({'package': name, 'result': message});
      case 'enable_package':
        final name = (arguments['name'] as String? ?? '').trim();
        if (name.isEmpty) {
          throw StateError('enable_package requires a name');
        }
        final message = await _clients.application.packageManager()
            .enablePackage(packageName: name);
        return jsonEncode({'package': name, 'result': message});
      case 'set_package_scope':
        final name = (arguments['name'] as String? ?? '').trim();
        final scope = (arguments['scope'] as String? ?? '').trim();
        if (name.isEmpty || scope.isEmpty) {
          throw StateError('set_package_scope requires name and scope');
        }
        await _clients.application.packageManager()
            .setPackageScope(packageName: name, scope: scope);
        return jsonEncode({'package': name, 'scope': scope, 'moved': true});
      default:
        throw StateError('Unknown tool: $name');
    }
  }

  /// Reports enablement and tool counts for each requested package.
  Future<String> _reportPackageStatus(List<String> names) async {
    final manager = _clients.application.packageManager();
    final report = <Map<String, Object?>>[];
    for (final name in names) {
      final entry = <String, Object?>{'name': name};
      try {
        entry['enabled'] = await manager.isPackageEnabled(packageName: name);
      } catch (error) {
        entry['enabled'] = 'error: $error';
      }
      try {
        entry['activated'] = await manager.isPackageActivated(packageName: name);
      } catch (error) {
        entry['activated'] = 'error: $error';
      }
      try {
        final tools = await manager.getEffectivePackageTools(packageName: name);
        entry['toolCount'] = tools?.tools.length;
        entry['tools'] = tools?.tools
            .map((tool) => tool.name)
            .take(40)
            .toList();
      } catch (error) {
        entry['tools'] = 'error: $error';
      }
      report.add(entry);
    }
    return jsonEncode(report);
  }

  /// Lists one directory so the caller can discover where the runtime keeps
  /// its logs and extension records on this build.
  Future<String> _listDirectory(String path) async {
    if (path.isEmpty) {
      throw StateError('list_dir requires a path');
    }
    final directory = Directory(path);
    if (!await directory.exists()) {
      throw StateError('No such directory: $path');
    }
    final entries = <Map<String, Object?>>[];
    await for (final entity in directory.list(followLinks: false)) {
      entries.add({
        'name': entity.uri.pathSegments.lastWhere(
          (segment) => segment.isNotEmpty,
          orElse: () => entity.path,
        ),
        'path': entity.path,
        'type': entity is Directory ? 'dir' : 'file',
      });
      if (entries.length >= 300) {
        break;
      }
    }
    return jsonEncode({
      'path': path,
      'count': entries.length,
      'entries': entries,
    });
  }

  /// Reads a text file and returns its trailing slice.
  Future<String> _readTextFile(String path, Object? rawLimit) async {
    if (path.isEmpty) {
      throw StateError('read_file requires a path');
    }
    final file = File(path);
    if (!await file.exists()) {
      throw StateError('No such file: $path');
    }
    final text = await file.readAsString();
    final limit = rawLimit is int && rawLimit > 0 ? rawLimit : 20000;
    return jsonEncode({
      'path': path,
      'totalChars': text.length,
      'tail': text.length > limit ? text.substring(text.length - limit) : text,
    });
  }

  /// Root that holds one identity directory per installation.
  static const String _identitiesRoot =
      '/data/data/app.operit/files/runtime/identities';

  /// Fallback log locations for layouts that predate the identity directory.
  static const List<String> _logCandidates = [
    '/data/data/app.operit/files/runtime/logs/operit.log',
    '/data/data/app.operit/files/logs/operit.log',
  ];

  /// Returns the trailing slice of the first log file that exists.
  ///
  /// The runtime keeps its data under an identity directory whose name carries a
  /// build-time token, so the directory is resolved instead of hardcoded.
  Future<String> _readLogTail(int limit) async {
    final identities = Directory(_identitiesRoot);
    if (await identities.exists()) {
      await for (final entity in identities.list(followLinks: false)) {
        if (entity is! Directory) {
          continue;
        }
        final candidate = File('${entity.path}/logs/operit.log');
        if (!await candidate.exists()) {
          continue;
        }
        final text = await candidate.readAsString();
        return jsonEncode({
          'path': candidate.path,
          'totalChars': text.length,
          'tail': text.length > limit
              ? text.substring(text.length - limit)
              : text,
        });
      }
    }
    for (final path in _logCandidates) {
      final file = File(path);
      if (!await file.exists()) {
        continue;
      }
      final text = await file.readAsString();
      return jsonEncode({
        'path': path,
        'totalChars': text.length,
        'tail': text.length > limit
            ? text.substring(text.length - limit)
            : text,
      });
    }
    throw StateError(
      'No application log found under $_identitiesRoot or ${_logCandidates.join(', ')}',
    );
  }
}
