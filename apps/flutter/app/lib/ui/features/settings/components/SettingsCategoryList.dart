// ignore_for_file: file_names

import 'package:flutter/material.dart';
import 'package:operit_ui/operit_ui.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../main/navigation/AppNavigationModels.dart';
import '../../../theme/OperitGlassSurface.dart';
import '../models/SettingsModels.dart';

class SettingsCategoryList extends StatelessWidget {
  const SettingsCategoryList({
    super.key,
    required this.selectedCategory,
    required this.onCategorySelected,
    this.pluginEntries = const <NavigationEntrySpec>[],
    this.onPluginEntrySelected,
  });

  final SettingsCategory? selectedCategory;
  final ValueChanged<SettingsCategory> onCategorySelected;

  /// Plugin-owned entries that the main drawer no longer hosts.
  final List<NavigationEntrySpec> pluginEntries;
  final ValueChanged<NavigationEntrySpec>? onPluginEntrySelected;

  /// Shares one control blur across the non-overlapping category tiles.
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final groups = <_SettingsCategoryGroup>[
      _SettingsCategoryGroup(
        title: l10n.settingsCategoryGroupAssistant,
        categories: const <SettingsCategory>[
          SettingsCategory.model,
          SettingsCategory.localModels,
        ],
      ),
      _SettingsCategoryGroup(
        title: l10n.settingsCategoryGroupWorkspace,
        categories: const <SettingsCategory>[
          SettingsCategory.tools,
          SettingsCategory.workspace,
        ],
      ),
      _SettingsCategoryGroup(
        title: l10n.settingsCategoryGroupExperience,
        categories: const <SettingsCategory>[
          SettingsCategory.globalBehavior,
          SettingsCategory.appearance,
        ],
      ),
      _SettingsCategoryGroup(
        title: l10n.settingsCategoryGroupSystem,
        categories: const <SettingsCategory>[
          SettingsCategory.data,
          SettingsCategory.about,
        ],
      ),
    ];
    final theme = Theme.of(context);
    final pluginTiles = <Widget>[
      if (pluginEntries.isNotEmpty) ...<Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 6),
          child: Text(
            '插件应用',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ),
        for (final entry in pluginEntries)
          SettingsEntryTile(
            title: entry.title,
            subtitle: entry.description ?? '插件提供的页面',
            icon: entry.icon,
            selected: false,
            onTap: () => onPluginEntrySelected?.call(entry),
          ),
      ],
    ];
    return ThemeGlassSurfaceGroup(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 16),
        children: <Widget>[
          SettingsCategoryTile(
            spec: SettingsCategorySpec.of(SettingsCategory.accessLinks, l10n),
            selected: selectedCategory == SettingsCategory.accessLinks,
            onTap: () => onCategorySelected(SettingsCategory.accessLinks),
            prominent: true,
          ),
          for (final groupEntry in groups.asMap().entries) ...<Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(
                8,
                groupEntry.key == 0 ? 2 : 12,
                8,
                6,
              ),
              child: Text(
                groupEntry.value.title,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                ),
              ),
            ),
            for (final category in groupEntry.value.categories)
              SettingsCategoryTile(
                spec: SettingsCategorySpec.of(category, l10n),
                selected: selectedCategory == category,
                onTap: () => onCategorySelected(category),
              ),
            if (groupEntry.key == 0) ...pluginTiles,
          ],
        ],
      ),
    );
  }
}

class _SettingsCategoryGroup {
  const _SettingsCategoryGroup({required this.title, required this.categories});

  final String title;
  final List<SettingsCategory> categories;
}

class SettingsCategoryTile extends StatelessWidget {
  const SettingsCategoryTile({
    super.key,
    required this.spec,
    required this.selected,
    required this.onTap,
    this.prominent = false,
  });

  final SettingsCategorySpec spec;
  final bool selected;
  final VoidCallback onTap;
  final bool prominent;

  /// Builds a selectable tile for one settings category.
  @override
  Widget build(BuildContext context) {
    return SettingsEntryTile(
      title: spec.title,
      subtitle: spec.subtitle,
      icon: spec.icon,
      selected: selected,
      onTap: onTap,
      prominent: prominent,
    );
  }
}

/// Shared settings list tile so plugin entries match host category styling.
class SettingsEntryTile extends StatelessWidget {
  const SettingsEntryTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.prominent = false,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final background = selected
        ? colorScheme.primaryContainer
        : colorScheme.surfaceContainerHighest.withValues(alpha: 0.34);
    final foreground = selected
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: OperitGlassSurface(
        color: background,
        layer: OperitGlassSurfaceLayer.control,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected
              ? colorScheme.primary.withValues(alpha: 0.24)
              : colorScheme.outlineVariant.withValues(alpha: 0.18),
        ),
        material: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              12,
              prominent ? 13 : 9,
              10,
              prominent ? 13 : 9,
            ),
            child: Row(
              children: <Widget>[
                CircleAvatar(
                  radius: prominent ? 20 : 16,
                  backgroundColor: selected
                      ? colorScheme.primary.withValues(alpha: 0.16)
                      : colorScheme.surface,
                  child: Icon(
                    icon,
                    size: prominent ? 22 : 18,
                    color: foreground,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: foreground,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: foreground.withValues(alpha: 0.70),
                        ),
                      ),
                    ],
                  ),
                ),
                if (prominent)
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 22,
                    color: foreground,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
