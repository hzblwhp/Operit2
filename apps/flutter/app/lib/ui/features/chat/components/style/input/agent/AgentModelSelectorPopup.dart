// ignore_for_file: file_names

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:operit2/ui/main/navigation/AppNavigationModels.dart';
import 'package:operit2/ui/main/screens/OperitScreens.dart';
import 'package:operit2/ui/main/screens/ScreenRouteRegistry.dart';
import 'package:operit2/ui/features/settings/models/SettingsModels.dart';

import '../../../../../../../core/chat/ChatScopedModelBinding.dart';
import '../../../../../../../core/proxy/generated/CoreProxyClients.g.dart';
import '../../../../../../../core/proxy/generated/CoreProxyModels.g.dart'
    as core_proxy;
import '../../../../viewmodel/ChatViewModel.dart';
import '../../../../../settings/model/ProviderLogo.dart';

class AgentModelSelectorPopup extends StatefulWidget {
  const AgentModelSelectorPopup({
    super.key,
    required this.viewModel,
    required this.onDismiss,
    required this.onModelChanged,
    this.chatId,
  });

  final ChatViewModel viewModel;

  /// 当前会话 id；用于把选中模型只固定到这一个会话。
  /// 为空时「仅本会话」开关不可用。
  final String? chatId;
  final VoidCallback onDismiss;
  final void Function(
    String modelId, {
    String? providerTypeId,
    String? providerName,
  })
  onModelChanged;

  /// Creates the mutable state for the standalone model selector popup.
  @override
  State<AgentModelSelectorPopup> createState() =>
      _AgentModelSelectorPopupState();
}

class _AgentModelSelectorPopupState extends State<AgentModelSelectorPopup> {
  Future<_AgentModelSelectorData>? _settingsFuture;
  String? _expandedProviderId;
  String? _expandedFamilyKey;
  int? _thinkingStop;
  bool _applyToCurrentChatOnly = false;
  ChatScopedModelBinding? _scopedBinding;

  GeneratedCoreProxyClients get _clients => widget.viewModel.clients;

  /// Initializes model selector settings loading.
  @override
  void initState() {
    super.initState();
    _settingsFuture = _loadSettings();
    unawaited(_reloadScopedBinding());
  }

  /// 读取本会话已保存的模型绑定，用于开关与「清除」入口的展示。
  Future<void> _reloadScopedBinding() async {
    final chatId = widget.chatId?.trim() ?? '';
    final binding = chatId.isEmpty
        ? null
        : await ChatScopedModelBinding.read(_clients, chatId);
    if (!mounted) {
      return;
    }
    setState(() {
      _scopedBinding = binding;
      if (binding != null) {
        _applyToCurrentChatOnly = true;
      }
    });
  }

  /// 清除本会话绑定，回到跟随全局对话模型。
  Future<void> _clearScopedBinding() async {
    final chatId = widget.chatId?.trim() ?? '';
    if (chatId.isEmpty) {
      return;
    }
    await ChatScopedModelBinding.clear(_clients, chatId);
    if (!mounted) {
      return;
    }
    setState(() {
      _scopedBinding = null;
      _applyToCurrentChatOnly = false;
    });
  }

  /// Loads model, context, and thinking settings for the popup.
  Future<_AgentModelSelectorData> _loadSettings() {
    return _loadAgentModelSelectorData(_clients);
  }

  /// Applies a provider model as the chat model.
  Future<void> _selectModel(
    core_proxy.ProviderProfile provider,
    core_proxy.ModelProfile model,
  ) async {
    if (_isDisallowedChatModel(model.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('禁止使用autoglm作为对话主模型。对话模型和ui控制模型是分离的，请选择任意一个别的聪明的大模型。'),
        ),
      );
      return;
    }
    final chatId = widget.chatId?.trim() ?? '';
    if (_applyToCurrentChatOnly && chatId.isNotEmpty) {
      // 仅本会话：写会话级绑定，不动全局对话模型
      await ChatScopedModelBinding.write(
        _clients,
        chatId,
        providerId: provider.id,
        modelId: model.id,
      );
      _scopedBinding = ChatScopedModelBinding(
        providerId: provider.id,
        modelId: model.id,
      );
    } else {
      await _clients.preferencesFunctionalConfigManager.setModelForFunction(
        functionType: core_proxy.FunctionType.chat,
        providerId: provider.id,
        modelId: model.id,
      );
    }
    widget.onModelChanged(
      model.id,
      providerTypeId: provider.providerTypeId,
      providerName: provider.name,
    );
    widget.onDismiss();
  }

  /// Returns whether the provider exposes discrete thinking quality levels.
  bool _hasThinkingLevels(_AgentModelSelectorData data) {
    final settings = data.thinkingSettings;
    return settings.control == core_proxy.ThinkingControl.levels &&
        settings.options.length > 1;
  }

  /// Resolves the merged slider stop for the current thinking state.
  int _resolveThinkingStop(_AgentModelSelectorData data, bool levels) {
    final settings = data.thinkingSettings;
    if (!data.enableThinkingMode && !settings.requiredValue) {
      return 0;
    }
    if (!levels) {
      return 1;
    }
    final index = settings.options.indexWhere(
      (option) => option.id == data.currentConfig.thinkingOptionId,
    );
    return (index < 0 ? 0 : index) + 1;
  }

  /// Applies one merged slider stop and persists the thinking changes.
  Future<void> _setThinkingStop(
    _AgentModelSelectorData data,
    bool levels,
    int stop,
  ) async {
    final settings = data.thinkingSettings;
    final maxStop = levels ? settings.options.length : 1;
    final value = stop.clamp(settings.requiredValue ? 1 : 0, maxStop);
    final current = _thinkingStop ?? _resolveThinkingStop(data, levels);
    if (value == current) {
      return;
    }
    setState(() {
      _thinkingStop = value;
    });
    final enable = value > 0;
    if (enable != data.enableThinkingMode) {
      await _clients.preferencesApiPreferences.updateThinkingSettings(
        enableThinkingMode: enable,
        thinkingQualityLevel: null,
      );
    }
    if (enable && levels) {
      final optionId = settings.options[value - 1].id;
      if (optionId != data.currentConfig.thinkingOptionId) {
        await _clients.preferencesModelConfigManager
            .updateThinkingOptionForProvider(
              providerId: data.currentBinding.providerId,
              modelId: data.currentBinding.modelId,
              thinkingOptionId: optionId,
            );
      }
    }
  }

  /// Navigates to the model settings screen.
  void _openModelSettings() {
    widget.onDismiss();
    final entry = ScreenRouteRegistry.toEntry(
      screen: const SettingsScreenRoute(category: SettingsCategory.model),
    );
    AppRouterGateway.navigate(
      routeId: entry.routeId,
      args: entry.args,
      source: entry.source,
    );
  }

  /// Builds the model selector popup card.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final popupContainerColor = colorScheme.surfaceContainer;
    return Material(
      color: Colors.transparent,
      child: Card(
        margin: EdgeInsets.zero,
        color: popupContainerColor,
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300, maxHeight: 420),
          child: FutureBuilder<_AgentModelSelectorData>(
            future: _settingsFuture,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                Error.throwWithStackTrace(
                  snapshot.error!,
                  snapshot.stackTrace!,
                );
              }
              final data = snapshot.data;
              if (data == null) {
                return const SizedBox(
                  width: 300,
                  height: 96,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final levels = _hasThinkingLevels(data);
              final stops = <String>[
                '关',
                if (levels)
                  ...data.thinkingSettings.options.map((option) => option.label)
                else
                  '开',
              ];
              return SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _ChatModelScopeRow(
                      chatId: widget.chatId,
                      checked: _applyToCurrentChatOnly,
                      scopedBinding: _scopedBinding,
                      onToggle: (value) {
                        setState(() {
                          _applyToCurrentChatOnly = value;
                        });
                      },
                      onClear: _clearScopedBinding,
                    ),
                    AgentThinkingSliderRow(
                      stops: stops,
                      stop: _thinkingStop ?? _resolveThinkingStop(data, levels),
                      minStop: data.thinkingSettings.requiredValue ? 1 : 0,
                      onChanged: (stop) => _setThinkingStop(data, levels, stop),
                    ),
                    _ModelSelectorItem(
                      popupContainerColor: popupContainerColor,
                      providers: data.providers,
                      currentBinding: data.currentBinding,
                      expanded: true,
                      expandedProviderId: _expandedProviderId,
                      expandedFamilyKey: _expandedFamilyKey,
                      onExpandedChanged: (_) {},
                      onExpandedProviderChanged: (providerId) {
                        setState(() {
                          _expandedProviderId = providerId;
                          if (providerId == null) {
                            _expandedFamilyKey = null;
                          }
                        });
                      },
                      onFamilyExpandedChanged: (familyKey) {
                        setState(() {
                          _expandedFamilyKey = familyKey;
                        });
                      },
                      onSelectModel: _selectModel,
                      onManageClick: _openModelSettings,
                      onInfoClick: () {},
                      showChevron: false,
                      showInfoButton: false,
                      manageInHeader: true,
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

class AgentModelMenuSection extends StatefulWidget {
  const AgentModelMenuSection({
    super.key,
    required this.viewModel,
    required this.onDismiss,
    this.chatId,
  });

  final ChatViewModel viewModel;
  final VoidCallback onDismiss;

  /// 当前会话 id；为空时「仅本会话」开关不可用。
  final String? chatId;

  /// Creates the mutable state for the embedded model menu section.
  @override
  State<AgentModelMenuSection> createState() => _AgentModelMenuSectionState();
}

class _AgentModelMenuSectionState extends State<AgentModelMenuSection> {
  Future<_AgentModelSelectorData>? _settingsFuture;
  String? _expandedProviderId;
  String? _expandedFamilyKey;
  bool _modelSectionExpanded = false;
  bool _modelDropdownExpanded = false;
  bool? _enableThinkingMode;
  bool _applyToCurrentChatOnly = false;
  ChatScopedModelBinding? _scopedBinding;

  GeneratedCoreProxyClients get _clients => widget.viewModel.clients;

  /// Loads the current model selector data when the menu section mounts.
  @override
  void initState() {
    super.initState();
    _settingsFuture = _loadSettings();
    unawaited(_reloadScopedBinding());
  }

  /// 读取本会话已保存的模型绑定。
  Future<void> _reloadScopedBinding() async {
    final chatId = widget.chatId?.trim() ?? '';
    final binding = chatId.isEmpty
        ? null
        : await ChatScopedModelBinding.read(_clients, chatId);
    if (!mounted) {
      return;
    }
    setState(() {
      _scopedBinding = binding;
      if (binding != null) {
        _applyToCurrentChatOnly = true;
      }
    });
  }

  /// 清除本会话绑定，回到跟随全局对话模型。
  Future<void> _clearScopedBinding() async {
    final chatId = widget.chatId?.trim() ?? '';
    if (chatId.isEmpty) {
      return;
    }
    await ChatScopedModelBinding.clear(_clients, chatId);
    if (!mounted) {
      return;
    }
    setState(() {
      _scopedBinding = null;
      _applyToCurrentChatOnly = false;
    });
  }

  /// Loads model selector state for the embedded input menu section.
  Future<_AgentModelSelectorData> _loadSettings() {
    return _loadAgentModelSelectorData(_clients);
  }

  /// Selects one configured model for chat from the embedded menu.
  Future<void> _selectModel(
    core_proxy.ProviderProfile provider,
    core_proxy.ModelProfile model,
  ) async {
    if (_isDisallowedChatModel(model.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('禁止使用autoglm作为对话主模型。对话模型和ui控制模型是分离的，请选择任意一个别的聪明的大模型。'),
        ),
      );
      return;
    }
    final chatId = widget.chatId?.trim() ?? '';
    if (_applyToCurrentChatOnly && chatId.isNotEmpty) {
      // 仅本会话：写会话级绑定，不动全局对话模型
      await ChatScopedModelBinding.write(
        _clients,
        chatId,
        providerId: provider.id,
        modelId: model.id,
      );
      _scopedBinding = ChatScopedModelBinding(
        providerId: provider.id,
        modelId: model.id,
      );
    } else {
      await _clients.preferencesFunctionalConfigManager.setModelForFunction(
        functionType: core_proxy.FunctionType.chat,
        providerId: provider.id,
        modelId: model.id,
      );
    }
    widget.onDismiss();
  }

  /// Toggles thinking mode from the embedded menu.
  Future<void> _toggleThinking(_AgentModelSelectorData data) async {
    if (data.thinkingSettings.requiredValue) {
      return;
    }
    final enableThinkingMode =
        !(_enableThinkingMode ?? data.enableThinkingMode);
    setState(() {
      _enableThinkingMode = enableThinkingMode;
    });
    await _clients.preferencesApiPreferences.updateThinkingSettings(
      enableThinkingMode: enableThinkingMode,
      thinkingQualityLevel: null,
    );
  }

  /// Stores the selected provider/model thinking option from the embedded menu.
  Future<void> _updateThinkingOption(
    _AgentModelSelectorData data,
    String optionId,
  ) async {
    await _clients.preferencesModelConfigManager
        .updateThinkingOptionForProvider(
          providerId: data.currentBinding.providerId,
          modelId: data.currentBinding.modelId,
          thinkingOptionId: optionId,
        );
  }

  /// Navigates to the model settings screen from the embedded menu.
  void _openModelSettings() {
    widget.onDismiss();
    final entry = ScreenRouteRegistry.toEntry(
      screen: const SettingsScreenRoute(category: SettingsCategory.model),
    );
    AppRouterGateway.navigate(
      routeId: entry.routeId,
      args: entry.args,
      source: entry.source,
    );
  }

  /// Builds the embedded model selector row and its inline list.
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return FutureBuilder<_AgentModelSelectorData>(
      future: _settingsFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          Error.throwWithStackTrace(snapshot.error!, snapshot.stackTrace!);
        }
        final data = snapshot.data;
        if (data == null) {
          return _SettingsHeaderRow(
            icon: Icons.data_object_outlined,
            title: '模型',
            value: '加载中...',
            expanded: _modelSectionExpanded,
            onTap: () {
              setState(() {
                _modelSectionExpanded = !_modelSectionExpanded;
              });
            },
            onInfoClick: () {},
            showInfoButton: false,
          );
        }
        final embeddedPanelColor = colorScheme.surface.withValues(alpha: 0.42);
        final displayData = data.copyWith(
          enableThinkingMode: _enableThinkingMode ?? data.enableThinkingMode,
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _SettingsHeaderRow(
              icon: Icons.data_object_outlined,
              title: '模型',
              value: data.currentBinding.modelId,
              expanded: _modelSectionExpanded,
              onTap: () {
                setState(() {
                  _modelSectionExpanded = !_modelSectionExpanded;
                  if (_modelSectionExpanded == false) {
                    _modelDropdownExpanded = false;
                    _expandedProviderId = null;
                  }
                });
              },
              onInfoClick: () {},
              showInfoButton: false,
            ),
            if (_modelSectionExpanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 8, 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: ColoredBox(
                    color: embeddedPanelColor,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        _ChatModelScopeRow(
                          chatId: widget.chatId,
                          checked: _applyToCurrentChatOnly,
                          scopedBinding: _scopedBinding,
                          onToggle: (value) {
                            setState(() {
                              _applyToCurrentChatOnly = value;
                            });
                          },
                          onClear: _clearScopedBinding,
                        ),
                        _ModelSelectorItem(
                          popupContainerColor: embeddedPanelColor,
                          headerIcon: Icons.tune_outlined,
                          headerTitle: '选择模型',
                          providers: data.providers,
                          currentBinding: data.currentBinding,
                          expanded: _modelDropdownExpanded,
                          expandedProviderId: _expandedProviderId,
                          expandedFamilyKey: _expandedFamilyKey,
                          onExpandedChanged: (expanded) {
                            setState(() {
                              _modelDropdownExpanded = expanded;
                            });
                          },
                          onExpandedProviderChanged: (providerId) {
                            setState(() {
                              _expandedProviderId = providerId;
                              if (providerId == null) {
                                _expandedFamilyKey = null;
                              }
                            });
                          },
                          onFamilyExpandedChanged: (familyKey) {
                            setState(() {
                              _expandedFamilyKey = familyKey;
                            });
                          },
                          onSelectModel: _selectModel,
                          onManageClick: _openModelSettings,
                          onInfoClick: () {},
                          showInfoButton: false,
                        ),
                        const SizedBox(height: 2),
                        _ThinkingSettingsItem(
                          popupContainerColor: embeddedPanelColor,
                          data: displayData,
                          onToggleThinkingMode: () =>
                              _toggleThinking(displayData),
                          onThinkingOptionChanged: (optionId) =>
                              _updateThinkingOption(displayData, optionId),
                          onInfoClick: () {},
                          onThinkingModeInfoClick: () {},
                          onThinkingQualityInfoClick: () {},
                          showInfoButton: false,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Merged thinking toggle/quality slider row used by the model selector popup.
/// Exposed for widget tests; not meant to be reused elsewhere.
@visibleForTesting
class AgentThinkingSliderRow extends StatefulWidget {
  const AgentThinkingSliderRow({
    super.key,
    required this.stops,
    required this.stop,
    required this.minStop,
    required this.onChanged,
  });

  final List<String> stops;
  final int stop;
  final int minStop;
  final ValueChanged<int> onChanged;

  /// Test hooks for locating the track and thumb in widget tests.
  @visibleForTesting
  static const Key trackKey = ValueKey<String>('agent-thinking-track');
  @visibleForTesting
  static const Key thumbKey = ValueKey<String>('agent-thinking-thumb');

  /// Creates the mutable state for the merged thinking slider.
  @override
  State<AgentThinkingSliderRow> createState() => _AgentThinkingSliderRowState();
}

class _AgentThinkingSliderRowState extends State<AgentThinkingSliderRow> {
  static const Duration _morphDuration = Duration(milliseconds: 380);
  static const Curve _morphCurve = Curves.easeOutCubic;

  int _stop = 0;
  bool _dragging = false;

  /// Initializes the selected stop position.
  @override
  void initState() {
    super.initState();
    _stop = widget.stop;
  }

  /// Syncs the stop when the resolved thinking selection changes.
  @override
  void didUpdateWidget(covariant AgentThinkingSliderRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging && oldWidget.stop != widget.stop) {
      _stop = widget.stop;
    }
  }

  /// Maps one track tap or drag position onto the nearest stop.
  void _applyPosition(double dx, double trackWidth) {
    final last = widget.stops.length - 1;
    // The 1.5px track border insets the positioned children, so the thumb
    // center travels between 12.5px (border + inset + half thumb) and the
    // mirrored right edge of the outer track width.
    final fraction = ((dx - 12.5) / (trackWidth - 25)).clamp(0.0, 1.0);
    var next = (fraction * last).round();
    if (next < widget.minStop) {
      next = widget.minStop;
    }
    if (next > last) {
      next = last;
    }
    if (next == _stop) {
      return;
    }
    setState(() {
      _stop = next;
    });
    widget.onChanged(next);
  }

  /// Builds the merged thinking toggle and quality slider row.
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final on = _stop > 0;
    final last = widget.stops.length - 1;
    final fraction = last > 0 ? _stop / last : 1.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SizedBox(
        height: 40,
        child: Row(
          children: <Widget>[
            Icon(
              Icons.psychology,
              size: 16,
              color: on
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
            const SizedBox(width: 4),
            Text('思考程度:', style: textTheme.bodySmall),
            const SizedBox(width: 6),
            AnimatedDefaultTextStyle(
              duration: _morphDuration,
              style: textTheme.bodySmall!.copyWith(
                color: on ? colorScheme.primary : colorScheme.onSurfaceVariant,
                fontWeight: on ? FontWeight.bold : FontWeight.normal,
              ),
              child: SizedBox(
                width: 48,
                child: Text(
                  widget.stops[_stop],
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final trackWidth = constraints.maxWidth;
                  final travel = trackWidth - 25;
                  final thumbLeft = 3 + fraction * travel;
                  // The fill reaches past the thumb's trailing edge so the track
                  // reads fully covered, meeting the pill's inner end at the
                  // last stop (19 = 3 inset + 16 thumb; +3 closes the tail gap).
                  final fillWidth = 19 + fraction * (travel + 3);
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) =>
                        _applyPosition(details.localPosition.dx, trackWidth),
                    onHorizontalDragDown: (details) {
                      _dragging = true;
                      _applyPosition(details.localPosition.dx, trackWidth);
                    },
                    onHorizontalDragUpdate: (details) =>
                        _applyPosition(details.localPosition.dx, trackWidth),
                    onHorizontalDragEnd: (_) => _dragging = false,
                    onHorizontalDragCancel: () => _dragging = false,
                    child: Center(
                      child: AnimatedContainer(
                        key: AgentThinkingSliderRow.trackKey,
                        duration: _morphDuration,
                        curve: _morphCurve,
                        height: 21,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            width: 1.5,
                            color: on
                                ? Colors.transparent
                                : colorScheme.outline,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: <Widget>[
                              Positioned(
                                left: 0,
                                top: 0,
                                bottom: 0,
                                child: AnimatedContainer(
                                  duration: _dragging
                                      ? const Duration(milliseconds: 60)
                                      : const Duration(milliseconds: 300),
                                  width: on ? fillWidth : 0,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(999),
                                    gradient: LinearGradient(
                                      begin: Alignment.centerLeft,
                                      end: Alignment.centerRight,
                                      colors: <Color>[
                                        colorScheme.primary.withValues(
                                          alpha: 0.30,
                                        ),
                                        colorScheme.primary.withValues(
                                          alpha: 0.92,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              // Closed-state layer: the highlight block sits
                              // on the left half like a switch. On open it
                              // first slides to the right, then dissolves
                              // while the gradient track morphs in.
                              Positioned.fill(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 2,
                                    vertical: 3,
                                  ),
                                  child: AnimatedAlign(
                                    alignment: on
                                        ? Alignment.centerRight
                                        : Alignment.centerLeft,
                                    duration: const Duration(milliseconds: 260),
                                    curve: Curves.easeInOutCubic,
                                    child: AnimatedOpacity(
                                      duration: const Duration(
                                        milliseconds: 460,
                                      ),
                                      curve: Curves.easeInCubic,
                                      opacity: on ? 0.0 : 1.0,
                                      child: FractionallySizedBox(
                                        widthFactor: 0.5,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: colorScheme.primary
                                                .withValues(alpha: 0.55),
                                            borderRadius: BorderRadius.circular(
                                              5,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              for (var j = 0; j < widget.stops.length; j++)
                                Positioned(
                                  left: 11 + (j / last) * travel - 2,
                                  // Centered within the 18px inner height
                                  // left after the 1.5px border inset.
                                  top: 7,
                                  child: AnimatedOpacity(
                                    duration: const Duration(milliseconds: 240),
                                    opacity: on ? 1 : 0,
                                    child: AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 200,
                                      ),
                                      width: 4,
                                      height: 4,
                                      decoration: BoxDecoration(
                                        color: on && j <= _stop
                                            ? colorScheme.onSurfaceVariant
                                            : colorScheme.outlineVariant,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ),
                                ),
                              // The knob stays hidden while closed; once the
                              // switch turns on it pops out in place with a
                              // springy scale-and-fade emergence.
                              Positioned(
                                key: AgentThinkingSliderRow.thumbKey,
                                left: thumbLeft,
                                top: 1,
                                child: AnimatedScale(
                                  scale: on ? 1.0 : 0.0,
                                  duration: _morphDuration,
                                  curve: _morphCurve,
                                  child: AnimatedOpacity(
                                    duration: const Duration(milliseconds: 240),
                                    opacity: on ? 1.0 : 0.0,
                                    child: Container(
                                      width: 16,
                                      height: 16,
                                      decoration: BoxDecoration(
                                        color: colorScheme.onSurfaceVariant,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AgentModelSelectorData {
  const _AgentModelSelectorData({
    required this.providers,
    required this.currentBinding,
    required this.currentConfig,
    required this.thinkingSettings,
    required this.enableThinkingMode,
  });

  final List<core_proxy.ProviderProfile> providers;
  final core_proxy.FunctionModelBinding currentBinding;
  final core_proxy.ResolvedModelConfig currentConfig;
  final core_proxy.ThinkingSettingsDescriptor thinkingSettings;
  final bool enableThinkingMode;

  /// Returns a copy with selected display fields replaced.
  _AgentModelSelectorData copyWith({bool? enableThinkingMode}) {
    return _AgentModelSelectorData(
      providers: providers,
      currentBinding: currentBinding,
      currentConfig: currentConfig,
      thinkingSettings: thinkingSettings,
      enableThinkingMode: enableThinkingMode ?? this.enableThinkingMode,
    );
  }
}

class _ThinkingSettingsItem extends StatefulWidget {
  const _ThinkingSettingsItem({
    required this.popupContainerColor,
    required this.data,
    required this.onToggleThinkingMode,
    required this.onThinkingOptionChanged,
    required this.onInfoClick,
    required this.onThinkingModeInfoClick,
    required this.onThinkingQualityInfoClick,
    this.showInfoButton = true,
  });

  final Color popupContainerColor;
  final _AgentModelSelectorData data;
  final VoidCallback onToggleThinkingMode;
  final ValueChanged<String> onThinkingOptionChanged;
  final VoidCallback onInfoClick;
  final VoidCallback onThinkingModeInfoClick;
  final VoidCallback onThinkingQualityInfoClick;
  final bool showInfoButton;

  /// Creates the mutable state for thinking controls.
  @override
  State<_ThinkingSettingsItem> createState() => _ThinkingSettingsItemState();
}

class _ThinkingSettingsItemState extends State<_ThinkingSettingsItem> {
  bool _expanded = false;
  int _sliderIndex = 0;

  /// Initializes the selected position from the resolved thinking descriptor.
  @override
  void initState() {
    super.initState();
    final settings = widget.data.thinkingSettings;
    if (settings.control == core_proxy.ThinkingControl.levels &&
        settings.options.isNotEmpty) {
      _sliderIndex = _selectedOptionIndex(widget.data);
    }
  }

  /// Syncs the slider when the resolved thinking option changes.
  @override
  void didUpdateWidget(covariant _ThinkingSettingsItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.currentConfig.thinkingOptionId ==
        widget.data.currentConfig.thinkingOptionId) {
      return;
    }
    final settings = widget.data.thinkingSettings;
    if (settings.control == core_proxy.ThinkingControl.levels &&
        settings.options.isNotEmpty) {
      _sliderIndex = _selectedOptionIndex(widget.data);
    }
  }

  /// Builds the expandable thinking settings block.
  @override
  Widget build(BuildContext context) {
    final required = widget.data.thinkingSettings.requiredValue;
    final enabled = required || widget.data.enableThinkingMode;
    final thinkingTypeText = enabled ? 'mode' : 'off';
    return Column(
      children: <Widget>[
        _SettingsHeaderRow(
          icon: Icons.psychology,
          title: '思考:',
          value: thinkingTypeText,
          expanded: _expanded,
          onTap: () => setState(() => _expanded = !_expanded),
          onInfoClick: widget.onInfoClick,
          showInfoButton: widget.showInfoButton,
        ),
        if (_expanded)
          ColoredBox(
            color: widget.popupContainerColor,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                children: <Widget>[
                  _SwitchSettingRow(
                    icon: widget.data.enableThinkingMode
                        ? Icons.psychology
                        : Icons.psychology_outlined,
                    title: '思考模式',
                    checked: enabled,
                    highlightWhenChecked: true,
                    onToggle: required ? null : widget.onToggleThinkingMode,
                    onInfoClick: widget.onThinkingModeInfoClick,
                    showInfoButton: widget.showInfoButton,
                  ),
                  if (enabled &&
                      widget.data.thinkingSettings.control ==
                          core_proxy.ThinkingControl.levels &&
                      widget.data.thinkingSettings.options.length > 1)
                    _ThinkingQualitySettingRow(
                      options: widget.data.thinkingSettings.options,
                      index: _sliderIndex,
                      onChanged: (index) {
                        setState(() {
                          _sliderIndex = index;
                        });
                      },
                      onChangeEnd: (index) {
                        widget.onThinkingOptionChanged(
                          widget.data.thinkingSettings.options[index].id,
                        );
                      },
                      onInfoClick: widget.onThinkingQualityInfoClick,
                      showInfoButton: widget.showInfoButton,
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _ThinkingQualitySettingRow extends StatelessWidget {
  const _ThinkingQualitySettingRow({
    required this.options,
    required this.index,
    required this.onChanged,
    required this.onChangeEnd,
    required this.onInfoClick,
    required this.showInfoButton,
  });

  final List<core_proxy.ThinkingOptionDescriptor> options;
  final int index;
  final ValueChanged<int> onChanged;
  final ValueChanged<int> onChangeEnd;
  final VoidCallback onInfoClick;
  final bool showInfoButton;

  /// Builds the thinking quality row and slider as one peer setting.
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final selectedOption = options[index];
    return Column(
      children: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.speed_outlined,
                  size: 16,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
                if (showInfoButton) _InfoIconButton(onPressed: onInfoClick),
                const SizedBox(width: 12),
                Text(
                  '思考程度',
                  style: textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const Spacer(),
                Text(
                  selectedOption.label,
                  style: textTheme.bodySmall!.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 0, 12, 6),
          child: Column(
            children: <Widget>[
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 16,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                    elevation: 0,
                    pressedElevation: 0,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 10,
                  ),
                  tickMarkShape: const RoundSliderTickMarkShape(
                    tickMarkRadius: 2,
                  ),
                  thumbColor: colorScheme.onSurfaceVariant,
                  activeTrackColor: colorScheme.primary.withValues(alpha: 0.72),
                  inactiveTrackColor: colorScheme.surfaceContainerHighest,
                  activeTickMarkColor: colorScheme.onSurfaceVariant,
                  inactiveTickMarkColor: colorScheme.outlineVariant,
                ),
                child: SizedBox(
                  height: 36,
                  child: Slider(
                    value: index.toDouble(),
                    min: 0,
                    max: (options.length - 1).toDouble(),
                    divisions: options.length - 1,
                    onChanged: (value) => onChanged(value.round()),
                    onChangeEnd: (value) => onChangeEnd(value.round()),
                  ),
                ),
              ),
              Row(
                children: <Widget>[
                  for (
                    var optionIndex = 0;
                    optionIndex < options.length;
                    optionIndex++
                  )
                    Expanded(
                      child: Text(
                        options[optionIndex].label,
                        textAlign: TextAlign.center,
                        style: textTheme.labelSmall?.copyWith(
                          color: optionIndex == index
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                          fontWeight: optionIndex == index
                              ? FontWeight.w700
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ModelSelectorItem extends StatelessWidget {
  const _ModelSelectorItem({
    required this.popupContainerColor,
    this.headerIcon = Icons.data_object_outlined,
    this.headerTitle = '模型:',
    required this.providers,
    required this.currentBinding,
    required this.expanded,
    required this.expandedProviderId,
    required this.expandedFamilyKey,
    required this.onExpandedChanged,
    required this.onExpandedProviderChanged,
    required this.onFamilyExpandedChanged,
    required this.onSelectModel,
    required this.onManageClick,
    required this.onInfoClick,
    this.showChevron = true,
    this.showInfoButton = true,
    this.manageInHeader = false,
  });

  final Color popupContainerColor;
  final IconData headerIcon;
  final String headerTitle;
  final List<core_proxy.ProviderProfile> providers;
  final core_proxy.FunctionModelBinding currentBinding;
  final bool expanded;
  final String? expandedProviderId;
  final String? expandedFamilyKey;
  final ValueChanged<bool> onExpandedChanged;
  final ValueChanged<String?> onExpandedProviderChanged;
  final ValueChanged<String?> onFamilyExpandedChanged;
  final void Function(
    core_proxy.ProviderProfile provider,
    core_proxy.ModelProfile model,
  )
  onSelectModel;
  final VoidCallback onManageClick;
  final VoidCallback onInfoClick;
  final bool showChevron;
  final bool showInfoButton;
  final bool manageInHeader;

  /// Builds the model selector header and inline provider list.
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final currentProvider = providers
        .where((provider) => provider.id == currentBinding.providerId)
        .firstOrNull;
    final currentModel = currentProvider?.models
        .where((model) => model.id == currentBinding.modelId)
        .firstOrNull;
    return Column(
      children: <Widget>[
        if (manageInHeader && currentProvider != null && currentModel != null)
          _CurrentModelLine(
            provider: currentProvider,
            model: currentModel,
            onManageClick: onManageClick,
          )
        else
          _SettingsHeaderRow(
            icon: headerIcon,
            title: headerTitle,
            value: currentBinding.modelId,
            expanded: expanded,
            onTap: () => onExpandedChanged(!expanded),
            onInfoClick: onInfoClick,
            showChevron: showChevron,
            showInfoButton: showInfoButton,
            trailing: manageInHeader
                ? _ManageIconButton(onPressed: onManageClick)
                : null,
          ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
            child: Column(
              children: <Widget>[
                if (providers.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      '没有可用的模型',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                for (final provider in providers)
                  AgentModelProviderRow(
                    provider: provider,
                    selected:
                        provider.id == currentBinding.providerId &&
                        provider.models.any(
                          (model) => model.id == currentBinding.modelId,
                        ),
                    selectedProviderId: currentBinding.providerId,
                    selectedModelId: currentBinding.modelId,
                    expanded: expandedProviderId == provider.id,
                    expandedFamilyKey: expandedFamilyKey,
                    onExpandedChanged: onExpandedProviderChanged,
                    onFamilyExpandedChanged: onFamilyExpandedChanged,
                    onSelectModel: onSelectModel,
                  ),
                if (!manageInHeader) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.center,
                    child: InkWell(
                      mouseCursor: SystemMouseCursors.click,
                      borderRadius: BorderRadius.circular(4),
                      hoverColor: colorScheme.primary.withValues(alpha: 0.08),
                      splashColor: colorScheme.primary.withValues(alpha: 0.12),
                      highlightColor: colorScheme.primary.withValues(
                        alpha: 0.06,
                      ),
                      onTap: onManageClick,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Text(
                          '管理配置',
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// One flat provider row in the directory tree and its family/model children.
class AgentModelProviderRow extends StatelessWidget {
  const AgentModelProviderRow({
    super.key,
    required this.provider,
    required this.selected,
    required this.selectedProviderId,
    required this.selectedModelId,
    required this.expanded,
    required this.expandedFamilyKey,
    required this.onExpandedChanged,
    required this.onFamilyExpandedChanged,
    required this.onSelectModel,
  });

  final core_proxy.ProviderProfile provider;
  final bool selected;
  final String selectedProviderId;
  final String selectedModelId;
  final bool expanded;
  final String? expandedFamilyKey;
  final ValueChanged<String?> onExpandedChanged;
  final ValueChanged<String?> onFamilyExpandedChanged;
  final void Function(
    core_proxy.ProviderProfile provider,
    core_proxy.ModelProfile model,
  )
  onSelectModel;

  /// Builds one flat provider row plus its expandable family sections.
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final models = provider.models;
    final hasMultipleModels = models.length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        InkWell(
          borderRadius: BorderRadius.circular(6),
          hoverColor: colorScheme.onSurface.withValues(alpha: 0.08),
          splashColor: colorScheme.onSurface.withValues(alpha: 0.05),
          highlightColor: colorScheme.onSurface.withValues(alpha: 0.06),
          onTap: () {
            if (hasMultipleModels) {
              onExpandedChanged(expanded ? null : provider.id);
            } else if (models.isNotEmpty) {
              onSelectModel(provider, models.first);
            } else {
              onExpandedChanged(expanded ? null : provider.id);
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: selected
                ? BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  )
                : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 22),
              child: Row(
                children: <Widget>[
                  ProviderLogo(
                    providerTypeId: provider.providerTypeId,
                    fallbackName: provider.name,
                    size: 16,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      provider.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall!.copyWith(
                        color: selected
                            ? colorScheme.primary
                            : colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (hasMultipleModels) ...<Widget>[
                    Text(
                      '${models.length}',
                      style: textTheme.labelSmall!.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      expanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 14,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ] else ...<Widget>[
                    Flexible(
                      child: Text(
                        models.isEmpty
                            ? provider.providerTypeId
                            : models.first.id,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelSmall!.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (selected) ...<Widget>[
                      const SizedBox(width: 4),
                      Icon(Icons.check, size: 12, color: colorScheme.primary),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
        if (hasMultipleModels && expanded) ..._familySections(context),
      ],
    );
  }

  /// Builds the family (or direct model) sections for the expanded provider.
  List<Widget> _familySections(BuildContext context) {
    final families = _modelFamilies(provider.models);
    if (families.length <= 1) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final model in provider.models)
                _ModelNameRow(
                  model: model,
                  selected:
                      provider.id == selectedProviderId &&
                      model.id == selectedModelId,
                  onTap: () => onSelectModel(provider, model),
                ),
            ],
          ),
        ),
      ];
    }
    return <Widget>[
      for (final (label, familyModels) in families) ...<Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 14),
          child: _ModelFamilyRow(
            label: label,
            count: familyModels.length,
            open: expandedFamilyKey == '${provider.id}||$label',
            onToggle: () => onFamilyExpandedChanged(
              expandedFamilyKey == '${provider.id}||$label'
                  ? null
                  : '${provider.id}||$label',
            ),
          ),
        ),
        if (expandedFamilyKey == '${provider.id}||$label')
          Padding(
            padding: const EdgeInsets.only(left: 26),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final model in familyModels)
                  _ModelNameRow(
                    model: model,
                    selected:
                        provider.id == selectedProviderId &&
                        model.id == selectedModelId,
                    onTap: () => onSelectModel(provider, model),
                  ),
              ],
            ),
          ),
      ],
    ];
  }
}

/// One collapsible model-family row inside an expanded provider.
class _ModelFamilyRow extends StatelessWidget {
  const _ModelFamilyRow({
    required this.label,
    required this.count,
    required this.open,
    required this.onToggle,
  });

  final String label;
  final int count;
  final bool open;
  final VoidCallback onToggle;

  /// Builds one indented family row with its model count and chevron.
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      borderRadius: BorderRadius.circular(5),
      hoverColor: colorScheme.onSurface.withValues(alpha: 0.08),
      splashColor: colorScheme.onSurface.withValues(alpha: 0.05),
      highlightColor: colorScheme.onSurface.withValues(alpha: 0.06),
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 20),
          child: Row(
            children: <Widget>[
              Text(
                label,
                style: textTheme.labelSmall!.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                '$count',
                style: textTheme.labelSmall!.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                open ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                size: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Derives a model family label from the model id prefix.
String? _modelFamilyOf(String modelId) {
  const rules = <(String, String)>[
    (r'^(gpt|o[134])', 'GPT'),
    (r'^claude', 'Claude'),
    (r'^gemini', 'Gemini'),
    (r'^deepseek', 'DeepSeek'),
    (r'^llama', 'Llama'),
    (r'^qwen', 'Qwen'),
    (r'^glm', 'GLM'),
    (r'^kimi', 'Kimi'),
    (r'^doubao', 'Doubao'),
    (r'^minimax', 'MiniMax'),
  ];
  final lower = modelId.toLowerCase();
  for (final (pattern, label) in rules) {
    if (RegExp(pattern).hasMatch(lower)) {
      return label;
    }
  }
  return null;
}

/// Groups models into insertion-ordered families derived from id prefixes.
List<(String, List<core_proxy.ModelProfile>)> _modelFamilies(
  List<core_proxy.ModelProfile> models,
) {
  final families = <String, List<core_proxy.ModelProfile>>{};
  for (final model in models) {
    final family = _modelFamilyOf(model.id) ?? '其他';
    families.putIfAbsent(family, () => <core_proxy.ModelProfile>[]).add(model);
  }
  return families.entries.map((entry) => (entry.key, entry.value)).toList();
}

/// The flat single-line header showing the active chat model identity.
class _CurrentModelLine extends StatelessWidget {
  const _CurrentModelLine({
    required this.provider,
    required this.model,
    required this.onManageClick,
  });

  final core_proxy.ProviderProfile provider;
  final core_proxy.ModelProfile model;
  final VoidCallback onManageClick;

  /// Builds the flat current-model header line with the manage button.
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 30),
        child: Row(
          children: <Widget>[
            Text(
              '模型',
              style: textTheme.labelSmall!.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Row(
                children: <Widget>[
                  Flexible(
                    flex: 3,
                    child: Text(
                      model.id,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall!.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '·',
                    style: textTheme.labelSmall!.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    flex: 1,
                    child: Text(
                      provider.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelSmall!.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            InkWell(
              borderRadius: BorderRadius.circular(999),
              hoverColor: colorScheme.primary.withValues(alpha: 0.18),
              splashColor: colorScheme.primary.withValues(alpha: 0.14),
              highlightColor: colorScheme.primary.withValues(alpha: 0.10),
              onTap: onManageClick,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '配置管理',
                  style: textTheme.labelSmall!.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelNameRow extends StatelessWidget {
  const _ModelNameRow({
    required this.model,
    required this.selected,
    required this.onTap,
  });

  final core_proxy.ModelProfile model;
  final bool selected;
  final VoidCallback onTap;

  /// Builds one flat selectable model row with metadata and hover only.
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      borderRadius: BorderRadius.circular(5),
      hoverColor: colorScheme.onSurface.withValues(alpha: 0.08),
      splashColor: colorScheme.onSurface.withValues(alpha: 0.05),
      highlightColor: colorScheme.onSurface.withValues(alpha: 0.06),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        constraints: const BoxConstraints(minHeight: 20),
        decoration: BoxDecoration(
          color: selected
              ? colorScheme.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                model.id,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelSmall!.copyWith(
                  color: selected ? colorScheme.primary : colorScheme.onSurface,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
            ..._modelMetaChips(context, model),
            if (selected) ...<Widget>[
              const SizedBox(width: 4),
              Icon(Icons.check, size: 11, color: colorScheme.primary),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModelMetaChip extends StatelessWidget {
  const _ModelMetaChip({required this.label, this.outlined = false});

  final String label;
  final bool outlined;

  /// Builds one compact model metadata chip.
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final decoration = outlined
        ? BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: colorScheme.outlineVariant),
          )
        : BoxDecoration(
            color: Colors.white.withValues(alpha: 0.045),
            borderRadius: BorderRadius.circular(4),
          );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: decoration,
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall!.copyWith(
          fontSize: 10,
          letterSpacing: 0.3,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Builds the metadata chips (capability tag and context length) for one model.
List<Widget> _modelMetaChips(
  BuildContext context,
  core_proxy.ModelProfile model,
) {
  final contextLabel = _formatContextChip(
    model.contextOverride?.maxContextLength,
  );
  final chips = <Widget>[
    if (model.capabilitiesOverride?.directImage == true)
      const _ModelMetaChip(label: '视觉', outlined: true),
    if (contextLabel != null) _ModelMetaChip(label: contextLabel),
  ];
  if (chips.isEmpty) {
    return chips;
  }
  return chips
      .expand((chip) => <Widget>[const SizedBox(width: 4), chip])
      .toList();
}

/// Formats a context length token count as a compact chip label.
String? _formatContextChip(double? length) {
  if (length == null || length <= 0) {
    return null;
  }
  final k = length >= 10000 ? length / 1000.0 : length;
  if (k >= 950) {
    final millions = k / 1000.0;
    final millionsRounded = millions.round();
    if ((millions - millionsRounded).abs() < 0.08) {
      return '${millionsRounded}M';
    }
    return '${millions.toStringAsFixed(1)}M';
  }
  return '${k.round()}K';
}

class _SettingsHeaderRow extends StatelessWidget {
  const _SettingsHeaderRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.expanded,
    required this.onTap,
    required this.onInfoClick,
    this.showChevron = true,
    this.showInfoButton = true,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String value;
  final bool expanded;
  final VoidCallback onTap;
  final VoidCallback onInfoClick;
  final bool showChevron;
  final bool showInfoButton;
  final Widget? trailing;

  /// Builds a settings header row with a value and optional chevron.
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 36),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: <Widget>[
              Icon(
                icon,
                size: 16,
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
              if (showInfoButton) _InfoIconButton(onPressed: onInfoClick),
              const SizedBox(width: 12),
              Text(title, style: textTheme.bodySmall),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: textTheme.bodySmall!.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (showChevron)
                Icon(
                  expanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 20,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}

class _SwitchSettingRow extends StatelessWidget {
  const _SwitchSettingRow({
    required this.icon,
    required this.title,
    required this.checked,
    required this.onToggle,
    required this.onInfoClick,
    this.highlightWhenChecked = false,
    this.showInfoButton = true,
  });

  final IconData icon;
  final String title;
  final bool checked;
  final VoidCallback? onToggle;
  final VoidCallback onInfoClick;
  final bool highlightWhenChecked;
  final bool showInfoButton;

  /// Builds a switch row inside a settings block.
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onToggle,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 36),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: <Widget>[
              Icon(
                icon,
                size: 16,
                color: checked
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
              if (showInfoButton) _InfoIconButton(onPressed: onInfoClick),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    color: checked && highlightWhenChecked
                        ? colorScheme.primary
                        : colorScheme.onSurface,
                    fontWeight: checked && highlightWhenChecked
                        ? FontWeight.w700
                        : FontWeight.normal,
                  ),
                ),
              ),
              Transform.scale(
                scale: 0.65,
                child: Switch(
                  value: checked,
                  onChanged: onToggle == null ? null : (_) => onToggle!(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ManageIconButton extends StatelessWidget {
  const _ManageIconButton({required this.onPressed});

  final VoidCallback onPressed;

  /// Builds the compact manage-configurations header icon button.
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 22,
      height: 22,
      child: IconButton(
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        iconSize: 14,
        tooltip: '管理配置',
        visualDensity: VisualDensity.compact,
        icon: Icon(
          Icons.settings_outlined,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _InfoIconButton extends StatelessWidget {
  const _InfoIconButton({required this.onPressed});

  final VoidCallback onPressed;

  /// Builds the compact information icon button.
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 24,
      height: 24,
      child: IconButton(
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        iconSize: 16,
        icon: Icon(
          Icons.info_outline,
          color: Theme.of(
            context,
          ).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}

Future<_AgentModelSelectorData> _loadAgentModelSelectorData(
  GeneratedCoreProxyClients clients,
) async {
  final binding = await clients.preferencesFunctionalConfigManager
      .getModelBindingForFunction(functionType: core_proxy.FunctionType.chat);
  final config = await clients.preferencesModelConfigManager
      .getResolvedModelConfig(
        providerId: binding.providerId,
        modelId: binding.modelId,
      );
  final thinkingSettings = await clients.preferencesModelConfigManager
      .getThinkingSettingsForProvider(
        providerId: binding.providerId,
        modelId: binding.modelId,
      );
  return _AgentModelSelectorData(
    providers: await clients.preferencesModelConfigManager
        .getProviderProfiles(),
    currentBinding: binding,
    currentConfig: config,
    thinkingSettings: thinkingSettings,
    enableThinkingMode: await clients.preferencesApiPreferences
        .enableThinkingModeFlow()
        .first,
  );
}

/// Returns the selected option position for the current thinking descriptor.
int _selectedOptionIndex(_AgentModelSelectorData data) {
  final selectedOptionId = data.currentConfig.thinkingOptionId;
  final index = data.thinkingSettings.options.indexWhere(
    (option) => option.id == selectedOptionId,
  );
  if (index < 0) {
    throw StateError('Resolved thinking option is absent from its descriptor');
  }
  return index;
}

/// Returns whether the model is reserved for UI control instead of chat.
bool _isDisallowedChatModel(String modelId) {
  return modelId.toLowerCase().contains('autoglm');
}

/// 会话级模型作用范围开关。
///
/// 打开后，在下面选中的模型只写进当前会话的绑定，不影响全局对话模型；
/// 已有会话级绑定时额外提供「清除」入口以恢复跟随全局。
class _ChatModelScopeRow extends StatelessWidget {
  const _ChatModelScopeRow({
    required this.chatId,
    required this.checked,
    required this.scopedBinding,
    required this.onToggle,
    required this.onClear,
  });

  final String? chatId;
  final bool checked;
  final ChatScopedModelBinding? scopedBinding;
  final ValueChanged<bool> onToggle;
  final Future<void> Function() onClear;

  /// Builds the scope switch row.
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final hasChat = (chatId ?? '').trim().isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        InkWell(
          onTap: hasChat ? () => onToggle(!checked) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 8, 2),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.filter_alt_outlined,
                  size: 16,
                  color: hasChat
                      ? (checked
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant.withValues(
                                alpha: 0.7,
                              ))
                      : colorScheme.onSurfaceVariant.withValues(alpha: 0.35),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        '仅对本会话生效',
                        style: textTheme.bodySmall?.copyWith(
                          color: hasChat
                              ? (checked
                                    ? colorScheme.primary
                                    : colorScheme.onSurface)
                              : colorScheme.onSurfaceVariant.withValues(
                                  alpha: 0.5,
                                ),
                          fontWeight: checked
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                      Text(
                        hasChat
                            ? '打开后所选模型只作用于当前会话，其他会话不变'
                            : '当前没有可用的会话',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.75,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: checked,
                  onChanged: hasChat ? onToggle : null,
                ),
              ],
            ),
          ),
        ),
        if (scopedBinding != null)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                onPressed: () {
                  unawaited(onClear());
                },
                icon: const Icon(Icons.restart_alt, size: 16),
                label: Text(
                  '清除本会话模型（当前 ${scopedBinding!.modelId}）',
                  style: textTheme.labelSmall,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
