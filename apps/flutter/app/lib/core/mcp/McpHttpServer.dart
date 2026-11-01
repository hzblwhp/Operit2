// ignore_for_file: file_names

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// PengSong 自己的 MCP 服务端（HTTP + JSON-RPC 2.0）。
///
/// 为什么需要：DSH 那边要直接驱动小吴的工具只能走 MCP，而这个 APP 原本
/// **一个监听端口都没开**（`/proc/net/tcp` 里没有它的 socket），所以设备侧
/// `http://127.0.0.1:8898/` 从来没有服务在听 —— `ps_mcp.py` 报
/// `RemoteDisconnected` 就是这个原因。
///
/// 设计取舍：
/// - 只绑 `127.0.0.1`，靠 `adb forward tcp:8898 tcp:8898` 给 PC 用，
///   不监听局域网，避免同网段任何人可调工具。
/// - Bearer token 做最小鉴权（默认 `pengsong-local`，与 ps_mcp.py 对齐）。
/// - 普通 `application/json` 一问一答，不是 MCP 标准的 SSE 流。DSH 的
///   streamable-http 需要 SSE，所以它那边仍要 `pengsong-mcp-bridge.py`
///   转一层 stdio —— 这是有意的分层，不是缺陷。
///
/// 第一阶段只提供连通性工具（`app_ping`），用最小依赖把链路打通；
/// 工具目录随后续接入逐步扩展。
class McpHttpServer {
  McpHttpServer._();

  static final McpHttpServer instance = McpHttpServer._();

  static const int defaultPort = 8898;
  static const String defaultToken = 'pengsong-local';

  HttpServer? _server;
  String _token = defaultToken;
  int _port = defaultPort;
  bool _starting = false;

  bool get isRunning => _server != null;
  int get port => _port;

  /// 启动服务。重复调用幂等。
  Future<void> start({
    int port = defaultPort,
    String token = defaultToken,
  }) async {
    if (_server != null || _starting) {
      return;
    }
    _starting = true;
    _port = port;
    _token = token.isEmpty ? defaultToken : token;
    try {
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
      _server = server;
      server.listen(
        _handle,
        onError: (Object error) => _log('server error: $error'),
      );
      _log('listening on 127.0.0.1:$port');
    } catch (error) {
      _log('bind failed on $port: $error');
      rethrow;
    } finally {
      _starting = false;
    }
  }

  /// 停止服务。
  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  void _log(String message) {
    stderr.writeln('[McpHttpServer] $message');
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      // 健康检查：最廉价的连通性判据
      if (request.method == 'GET' && request.uri.path == '/health') {
        response.statusCode = HttpStatus.ok;
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode(<String, Object?>{
            'ok': true,
            'app': 'PengSong',
            'port': _port,
            'protocol': 'mcp-json-rpc-2.0',
          }),
        );
        await response.close();
        return;
      }

      if (request.method != 'POST') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }

      final auth =
          request.headers.value(HttpHeaders.authorizationHeader) ?? '';
      if (auth != 'Bearer $_token') {
        response.statusCode = HttpStatus.unauthorized;
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': null,
            'error': <String, Object?>{
              'code': -32001,
              'message': 'unauthorized',
            },
          }),
        );
        await response.close();
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      Map<String, Object?> message;
      try {
        message = Map<String, Object?>.from(
          jsonDecode(body) as Map<dynamic, dynamic>,
        );
      } catch (error) {
        response.statusCode = HttpStatus.badRequest;
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': null,
            'error': <String, Object?>{
              'code': -32700,
              'message': 'parse error',
            },
          }),
        );
        await response.close();
        return;
      }

      final reply = await _dispatch(message);
      response.statusCode = HttpStatus.ok;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(reply));
      await response.close();
    } catch (error, stackTrace) {
      _log('request failed: $error\n$stackTrace');
      try {
        response.statusCode = HttpStatus.internalServerError;
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': null,
            'error': <String, Object?>{'code': -32603, 'message': '$error'},
          }),
        );
        await response.close();
      } catch (_) {
        // 连接已断，忽略
      }
    }
  }

  Future<Map<String, Object?>> _dispatch(Map<String, Object?> message) async {
    final id = message['id'];
    final method = message['method']?.toString() ?? '';
    final rawParams = message['params'];
    final params = rawParams is Map
        ? Map<String, Object?>.from(rawParams)
        : const <String, Object?>{};

    Map<String, Object?> ok(Object? result) => <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    };
    Map<String, Object?> err(int code, String text) => <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'error': <String, Object?>{'code': code, 'message': text},
    };

    switch (method) {
      case 'initialize':
        return ok(<String, Object?>{
          'protocolVersion': '2024-11-05',
          'capabilities': <String, Object?>{
            'tools': <String, Object?>{},
          },
          'serverInfo': <String, Object?>{
            'name': 'pengsong-device',
            'version': '2.0.0',
          },
        });
      case 'notifications/initialized':
      case 'initialized':
        return ok(null);
      case 'ping':
        return ok(<String, Object?>{});
      case 'tools/list':
        return ok(<String, Object?>{'tools': _toolCatalog});
      case 'tools/call':
        return _callTool(id, params);
      default:
        return err(-32601, 'method not found: $method');
    }
  }

  /// 工具目录（第一阶段只有连通性探针）。
  static const List<Map<String, Object?>> _toolCatalog = <Map<String, Object?>>[
    <String, Object?>{
      'name': 'app_ping',
      'description': '确认 MCP 链路已连到 PengSong APP，返回 {"pong": true, "ts": 毫秒时间戳}。',
      'inputSchema': <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
      },
    },
  ];

  Future<Map<String, Object?>> _callTool(
    Object? id,
    Map<String, Object?> params,
  ) async {
    final name = params['name']?.toString() ?? '';
    Map<String, Object?> ok(Object? result) => <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    };
    Map<String, Object?> err(int code, String text) => <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'error': <String, Object?>{'code': code, 'message': text},
    };

    if (name == 'app_ping') {
      return ok(<String, Object?>{
        'content': <Object?>[
          <String, Object?>{
            'type': 'text',
            'text': jsonEncode(<String, Object?>{
              'pong': true,
              'ts': DateTime.now().millisecondsSinceEpoch,
            }),
          },
        ],
        'isError': false,
      });
    }
    return err(-32602, 'unknown tool: $name');
  }
}
