// ignore_for_file: file_names

import '../proxy/generated/CoreProxyClients.g.dart' as core_proxy;

/// 单个会话的模型绑定（会话级覆盖）。
///
/// 存储走通用 preference 通道，不新增数据库字段：
/// - fileName：`chat_scoped_model_binding`
/// - key：chatId
/// - value：`{"providerId": "...", "modelId": "..."}`
///
/// **Rust 侧同名常量必须逐字一致**，见
/// `core/crates/runtime/application/src/services/core/MessageCoordinationDelegate.rs`
/// 里的 `CHAT_SCOPED_MODEL_PREFERENCES`。改任一侧都要同步另一侧。
class ChatScopedModelBinding {
  const ChatScopedModelBinding({
    required this.providerId,
    required this.modelId,
  });

  final String providerId;
  final String modelId;

  /// preference 文件名（两侧共用）。
  static const String preferenceFileName = 'chat_scoped_model_binding';

  /// 从一条 preference 记录里解析绑定；格式不符时返回 null。
  static ChatScopedModelBinding? parse(Object? value) {
    if (value is! Map) {
      return null;
    }
    final providerId = value['providerId']?.toString().trim() ?? '';
    final modelId = value['modelId']?.toString().trim() ?? '';
    if (providerId.isEmpty || modelId.isEmpty) {
      return null;
    }
    return ChatScopedModelBinding(providerId: providerId, modelId: modelId);
  }

  /// 读取某个会话单独配置的模型；没有配置时返回 null（表示跟随全局）。
  static Future<ChatScopedModelBinding?> read(
    core_proxy.GeneratedCoreProxyClients clients,
    String chatId,
  ) async {
    if (chatId.trim().isEmpty) {
      return null;
    }
    final value = await clients.preferencesPreferenceStorageManager
        .getPreference(fileName: preferenceFileName, key: chatId);
    return parse(value);
  }

  /// 把某个会话固定到指定模型。
  static Future<void> write(
    core_proxy.GeneratedCoreProxyClients clients,
    String chatId, {
    required String providerId,
    required String modelId,
  }) {
    return clients.preferencesPreferenceStorageManager.setPreference(
      fileName: preferenceFileName,
      key: chatId,
      value: <String, Object?>{
        'providerId': providerId,
        'modelId': modelId,
      },
    );
  }

  /// 清除会话级绑定，回落到全局对话模型。
  static Future<void> clear(
    core_proxy.GeneratedCoreProxyClients clients,
    String chatId,
  ) {
    return clients.preferencesPreferenceStorageManager.removePreference(
      fileName: preferenceFileName,
      key: chatId,
    );
  }

  /// 监听某个会话的绑定变化（配置变化后输入区标签能立刻更新）。
  static Stream<ChatScopedModelBinding?> watch(
    core_proxy.GeneratedCoreProxyClients clients,
    String chatId,
  ) {
    return clients.preferencesPreferenceStorageManager
        .preferencesFlow(fileName: preferenceFileName)
        .map((values) => parse(values[chatId]));
  }
}
