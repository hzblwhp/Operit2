// ignore_for_file: file_names
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../link/CoreLinkCodec.dart';
import 'CoreByteTransport.dart';
import 'FfiCoreAddress.dart';

typedef _AttachNative = Bool Function(Pointer<Void>, Pointer<Void>, Int64);
typedef _Attach = bool Function(Pointer<Void>, Pointer<Void>, int);
typedef _SubmitNative =
    Void Function(
      Pointer<Void>,
      Uint32,
      Int64,
      Pointer<Uint8>,
      UintPtr,
      Pointer<Pointer<Void>>,
      UintPtr,
    );
typedef _Submit =
    void Function(
      Pointer<Void>,
      int,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Void>>,
      int,
    );
typedef _AllocateNative = Pointer<Uint8> Function(UintPtr);
typedef _Allocate = Pointer<Uint8> Function(int);
typedef _FreeNative = Void Function(Pointer<Uint8>, UintPtr);
typedef _Free = void Function(Pointer<Uint8>, int);

class FfiCoreTransport implements CoreByteTransport {
  /// Creates a lazily attached connection for this Dart isolate.
  FfiCoreTransport();

  static final FfiCoreTransport instance = FfiCoreTransport();
  Future<_FfiConnection>? _opening;
  bool _closed = false;

  /// Attaches once to the runtime owned by the registered platform host.
  Future<_FfiConnection> _connection() {
    if (_closed) throw StateError('Core FFI transport is closed');
    return _opening ??= _connect().catchError((Object error, StackTrace stack) {
      _opening = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  /// Releases this isolate's connection without destroying the platform runtime.
  Future<void> close() async {
    _closed = true;
    final opening = _opening;
    if (opening != null) (await opening).close();
  }

  /// Reads the host function table without selecting a platform or library path.
  Future<_FfiConnection> _connect() async {
    final encoded = await const MethodChannel(
      'operit/runtime',
    ).invokeMethod<String>('connectCoreFfi');
    if (encoded == null) throw StateError('Host returned no FFI descriptor');
    return _FfiConnection(jsonDecode(encoded) as Map<String, dynamic>);
  }

  /// Dispatches directly through the function table after host initialization.
  @override
  Future<Uint8List> request(
    CoreTransportOperation operation,
    CoreLinkMessage payload,
  ) async => (await _connection()).request(operation, payload);

  /// Places ordinary bytes in host-owned immutable storage for constant-cost reuse.
  Future<Uint8List> shareBytes(Uint8List bytes) async =>
      (await _connection())._retainBuffer(bytes).view();

  /// Forwards one watch while preserving cancellation of its native subscription.
  @override
  Stream<Uint8List> watch(
    String subscriptionId,
    CoreLinkMessage payload,
  ) async* {
    final connection = await _connection();
    yield* connection.watch(subscriptionId, payload);
  }
}

class _FfiConnection implements Finalizable {
  /// Binds the versioned ABI and registers a VM-owned port for asynchronous replies.
  _FfiConnection(Map<String, dynamic> descriptor) {
    if (descriptor['version'] != 3 || NativeApi.majorVersion != 2) {
      throw StateError('Unsupported Core FFI or Dart native API version');
    }
    _session = Pointer<Void>.fromAddress(_address(descriptor, 'session'));
    _submit = Pointer<NativeFunction<_SubmitNative>>.fromAddress(
      _address(descriptor, 'submit'),
    ).asFunction<_Submit>();
    _allocate = Pointer<NativeFunction<_AllocateNative>>.fromAddress(
      _address(descriptor, 'allocate'),
    ).asFunction<_Allocate>();
    _free = Pointer<NativeFunction<_FreeNative>>.fromAddress(
      _address(descriptor, 'free'),
    ).asFunction<_Free>();
    _bufferAllocate =
        Pointer<NativeFunction<Pointer<Void> Function(UintPtr)>>.fromAddress(
          _address(descriptor, 'bufferAllocate'),
        ).asFunction<Pointer<Void> Function(int)>();
    _bufferData =
        Pointer<
              NativeFunction<Pointer<Uint8> Function(Pointer<Void>)>
            >.fromAddress(_address(descriptor, 'bufferData'))
            .asFunction<Pointer<Uint8> Function(Pointer<Void>)>();
    _bufferSeal =
        Pointer<NativeFunction<Void Function(Pointer<Void>)>>.fromAddress(
          _address(descriptor, 'bufferSeal'),
        ).asFunction<void Function(Pointer<Void>)>();
    _bufferRetain =
        Pointer<
              NativeFunction<Pointer<Void> Function(Pointer<Void>)>
            >.fromAddress(_address(descriptor, 'bufferRetain'))
            .asFunction<Pointer<Void> Function(Pointer<Void>)>();
    _bufferRelease =
        Pointer<NativeFunction<Void Function(Pointer<Void>)>>.fromAddress(
          _address(descriptor, 'bufferRelease'),
        );
    _finalizer = NativeFinalizer(
      Pointer<NativeFunction<Void Function(Pointer<Void>)>>.fromAddress(
        _address(descriptor, 'release'),
      ),
    );
    _release =
        Pointer<NativeFunction<Void Function(Pointer<Void>)>>.fromAddress(
          _address(descriptor, 'release'),
        ).asFunction<void Function(Pointer<Void>)>();
    _finalizer.attach(this, _session, detach: this);
    final attach = Pointer<NativeFunction<_AttachNative>>.fromAddress(
      _address(descriptor, 'attach'),
    ).asFunction<_Attach>();
    if (!attach(
      _session,
      NativeApi.postCObject.cast(),
      _port.sendPort.nativePort,
    )) {
      close();
      throw StateError('Core FFI connection was already attached');
    }
    _port.listen(_receive);
  }

  /// Decodes one exact native address from the string-based FFI descriptor.
  static int _address(Map<String, dynamic> descriptor, String name) {
    final value = descriptor[name];
    if (value is! String) {
      throw FormatException('FFI descriptor address $name must be a string');
    }
    return decodeCoreFfiAddress(value);
  }

  final ReceivePort _port = ReceivePort('operit-core-ffi');
  late final Pointer<Void> _session;
  late final _Submit _submit;
  late final _Allocate _allocate;
  late final _Free _free;
  late final Pointer<Void> Function(int) _bufferAllocate;
  late final Pointer<Uint8> Function(Pointer<Void>) _bufferData;
  late final void Function(Pointer<Void>) _bufferSeal;
  late final Pointer<Void> Function(Pointer<Void>) _bufferRetain;
  late final Pointer<NativeFunction<Void Function(Pointer<Void>)>>
  _bufferRelease;
  late final NativeFinalizer _finalizer;
  late final void Function(Pointer<Void>) _release;
  bool _closed = false;
  final Map<int, Completer<Uint8List>> _pending = {};
  final Map<int, StreamController<Uint8List>> _watches = {};
  int _nextRequest = 1;
  final _views = <(int, int), WeakReference<CoreLinkSharedBuffer>>{};
  late final _viewFinalizer =
      Finalizer<((int, int), WeakReference<CoreLinkSharedBuffer>)>((entry) {
        if (identical(_views[entry.$1], entry.$2)) {
          _views.remove(entry.$1);
        }
      });

  /// Retains only weak identities so collected buffers do not remain cached.
  CoreLinkSharedBuffer _rememberBuffer(
    Pointer<Uint8> pointer,
    int length,
    Pointer<Void> token,
  ) {
    final bytes = pointer
        .asTypedList(length, finalizer: _bufferRelease, token: token)
        .asUnmodifiableView();
    final buffer = CoreLinkSharedBuffer(
      bytes,
      token.address,
      _bufferRelease.address,
    );
    final key = (pointer.address, length);
    final reference = WeakReference(buffer);
    _views[key] = reference;
    _viewFinalizer.attach(buffer, (key, reference));
    return buffer;
  }

  /// Creates immutable shared ownership with one initial copy from ordinary Dart bytes.
  CoreLinkBufferSpan _retainBuffer(Uint8List source) {
    final shared = coreLinkSharedSpan(source);
    if (shared != null) {
      if (shared.buffer.domain != _bufferRelease.address) {
        throw StateError('Shared buffer belongs to a different host runtime');
      }
      return shared;
    }
    final token = _bufferAllocate(source.length);
    final pointer = _bufferData(token);
    pointer.asTypedList(source.length).setAll(0, source);
    _bufferSeal(token);
    final buffer = _rememberBuffer(pointer, source.length, token);
    return CoreLinkBufferSpan(buffer, 0, source.length);
  }

  /// Fills the final Rust-owned request buffer without a flattened Dart copy.
  Future<Uint8List> _send(
    int id,
    CoreTransportOperation operation,
    CoreLinkMessage payload,
  ) {
    if (_closed) {
      return Future.error(StateError('Core FFI connection is closed'));
    }
    final keepAlive = _FfiMessage(payload.share(_retainBuffer));
    final shared = keepAlive.shared;
    final metadataLength = shared.bytes.length;
    final tableOffset =
        (metadataLength + sizeOf<IntPtr>() - 1) & -sizeOf<IntPtr>();
    final totalLength = tableOffset + shared.buffers.length * sizeOf<IntPtr>();
    final pointer = _allocate(totalLength);
    final completer = Completer<Uint8List>();
    _pending[id] = completer;
    bool submitted = false;
    try {
      pointer.asTypedList(metadataLength).setAll(0, shared.bytes);
      pointer
          .asTypedList(totalLength)
          .fillRange(metadataLength, tableOffset, 0);
      final handles = (pointer + tableOffset).cast<Pointer<Void>>();
      for (var index = 0; index < shared.buffers.length; index++) {
        handles[index] = Pointer<Void>.fromAddress(
          shared.buffers[index].buffer.token as int,
        );
      }
      _submit(
        _session,
        operation.index,
        id,
        pointer,
        metadataLength,
        handles,
        shared.buffers.length,
      );
      submitted = true;
    } catch (error, stack) {
      _pending.remove(id);
      completer.completeError(error, stack);
    } finally {
      if (!submitted) _free(pointer, totalLength);
    }
    return completer.future;
  }

  /// Assigns a connection-local correlation id to one request.
  Future<Uint8List> request(
    CoreTransportOperation operation,
    CoreLinkMessage payload,
  ) => _send(_nextRequest++, operation, payload);

  /// Buffers early frames and cancels the exact generation even during source opening.
  Stream<Uint8List> watch(String subscriptionId, CoreLinkMessage payload) {
    final id = _nextRequest++;
    late final StreamController<Uint8List> controller;
    bool openingFailed = false;
    bool cancelled = false;
    controller = StreamController<Uint8List>(
      onListen: () {
        _watches[id] = controller;
        unawaited(() async {
          try {
            final response = await _send(
              id,
              CoreTransportOperation.watchStream,
              payload,
            );
            final actualId = decodeNativeCoreWatchStreamResult(response);
            if (actualId != subscriptionId) {
              throw StateError('Core FFI watch acknowledgement mismatch');
            }
          } catch (error, stack) {
            openingFailed = true;
            _watches.remove(id);
            if (!cancelled && !controller.isClosed) {
              controller.addError(error, stack);
              unawaited(controller.close());
            }
          }
        }());
      },
      onCancel: () async {
        cancelled = true;
        _watches.remove(id);
        if (!openingFailed && !_closed) {
          decodeNativeCoreVoidResult(
            await request(
              CoreTransportOperation.closeWatchStream,
              encodeCoreLinkMessage([subscriptionId, id]),
            ),
          );
        }
      },
    );
    return controller.stream;
  }

  /// Routes one uniformly batched delivery while retaining each frame's own attachments.
  void _receive(dynamic message) {
    try {
      final frames = message as List<dynamic>;
      if (frames.isEmpty) throw const FormatException('Empty Core FFI batch');
      for (final frame in frames) {
        _receiveFrame(frame as List<dynamic>);
      }
    } catch (error, stack) {
      close(error, stack);
    }
  }

  /// Adopts one frame's receipts and routes its connection-local correlation id.
  void _receiveFrame(List<dynamic> message) {
    final keepAlive = _FfiEnvelope(message);
    final envelope = keepAlive.values;
    if (envelope.isEmpty || (envelope.length - 1) % 4 != 0) {
      throw const FormatException('Invalid Core FFI shared envelope');
    }
    final bytes = _ffiBytesOf(envelope[0]).asUnmodifiableView();
    final buffers = <CoreLinkSharedBuffer>[];
    for (var index = 1; index < envelope.length; index += 4) {
      final token = envelope[index] as int;
      final receipt = _ffiBytesOf(envelope[index + 1]);
      final address = envelope[index + 2] as int;
      final length = envelope[index + 3] as int;
      if (receipt.length != 1 || token == 0 || address == 0 || length < 0) {
        throw const FormatException('Invalid Core FFI buffer receipt');
      }
      final existing = _views[(address, length)]?.target;
      final buffer =
          existing ??
          _rememberBuffer(
            Pointer<Uint8>.fromAddress(address),
            length,
            _bufferRetain(Pointer<Void>.fromAddress(token)),
          );
      buffers.add(buffer);
    }
    attachCoreLinkBuffers(bytes, buffers);
    if (bytes.length < 9) {
      throw const FormatException('Truncated Core FFI frame');
    }
    final kind = bytes[0];
    final id = ByteData.sublistView(bytes, 1, 9).getInt64(0, Endian.little);
    final payload = sliceCoreLinkBytes(bytes, 9);
    switch (kind) {
      case 0:
        final pending = _pending.remove(id);
        if (pending == null) throw StateError('Unknown Core FFI reply: $id');
        pending.complete(payload);
      case 1:
        _watches[id]?.add(payload);
      case 2:
        final controller = _watches[id];
        if (controller != null) {
          try {
            decodeNativeCoreVoidResult(payload);
            throw const FormatException('Expected Core FFI watch error');
          } catch (error, stack) {
            controller.addError(error, stack);
          }
        }
      case 3:
        final controller = _watches.remove(id);
        if (controller != null) unawaited(controller.close());
      default:
        throw FormatException('Unknown Core FFI frame type: $kind');
    }
  }

  /// Fails pending work and detaches native resources exactly once.
  void close([Object? error, StackTrace? stack]) {
    if (_closed) return;
    _closed = true;
    final failure = error ?? StateError('Core FFI connection is closed');
    _port.close();
    _finalizer.detach(this);
    _release(_session);
    for (final pending in _pending.values) {
      pending.completeError(failure, stack);
    }
    _pending.clear();
    _views.clear();
    final controllers = _watches.values.toList();
    _watches.clear();
    for (final controller in controllers) {
      controller.addError(failure, stack);
      unawaited(controller.close());
    }
  }
}

/// Keeps every external byte view alive until synchronous native retention completes.
class _FfiMessage implements Finalizable {
  /// Retains the frame's external allocations throughout the enclosing FFI call.
  _FfiMessage(this.shared);
  final CoreLinkSharedMessage shared;
}

/// Keeps VM-owned receipts alive until synchronous native adoption is complete.
class _FfiEnvelope implements Finalizable {
  /// Retains every receipt throughout this delivery callback.
  _FfiEnvelope(this.values);
  final List<dynamic> values;
}

/// 把 FFI envelope 里的二进制槽位安全转成 Uint8List。
///
/// 原生侧通常给 Uint8List，但个别返回路径会给普通 List（`List<dynamic>`）。
/// 裸 `as Uint8List` 会抛
/// `type 'List<dynamic>' is not a subtype of type 'Uint8List' in type cast`；
/// 一旦发生在主题/资源链上，整个外观加载就会打成「无法加载外观设置」。
Uint8List _ffiBytesOf(Object? value) {
  if (value is Uint8List) {
    return value;
  }
  if (value is List) {
    // 同 CoreLinkCodec：元素可能是 int 或嵌套 Uint8List，统一扁平化。
    final builder = BytesBuilder(copy: false);
    _appendFfiBytes(value, builder);
    return builder.takeBytes();
  }
  throw StateError(
    'Core FFI binary slot has unsupported type: ${value.runtimeType}',
  );
}

void _appendFfiBytes(List<dynamic> values, BytesBuilder builder) {
  // 用显式栈代替递归。
  //
  // 递归版在原生侧返回「嵌套很深」或「自引用」的 List 时会直接打爆 Dart 栈：
  // 实测表现是整个 isolate 连续报 `Stack Overflow`，连外观设置都加载不出来
  // （AppStartup / AIChatScreen / FlutterFramework 一起失败）。
  // 显式栈 + 元素总量上限，让这类输入退化为可报告的异常而不是崩溃。
  final pending = <Object?>[...values.reversed];
  var budget = 8 * 1024 * 1024;
  while (pending.isNotEmpty) {
    final value = pending.removeLast();
    if (budget-- <= 0) {
      throw StateError('Core FFI binary slot is too large or self-referencing');
    }
    if (value is int) {
      builder.addByte(value & 0xFF);
    } else if (value is Uint8List) {
      builder.add(value);
    } else if (value is List) {
      // 逆序压栈以保持原始顺序。
      for (var i = value.length - 1; i >= 0; i--) {
        pending.add(value[i]);
      }
    } else {
      throw StateError(
        'Core FFI binary slot has unsupported element: ${value.runtimeType}',
      );
    }
  }
}
