// ignore_for_file: file_names

import 'package:flutter/material.dart';

/// Keeps command-style messages and metadata on the original content column.
class CursorMessageLayout extends StatelessWidget {
  /// Creates a message layout with the original transcript inset.
  const CursorMessageLayout({
    super.key,
    required this.child,
    this.verticalPadding = 4,
  });

  final Widget child;
  final double verticalPadding;

  /// Applies the original transcript inset to user and assistant messages.
  @override
  Widget build(BuildContext context) {
    return Padding(
      // 聊天内容贴边显示：外层不再保留左右 16dp 内边距，
      // 气泡/编辑器自己的内部留白仍在，但整列文字能吃满屏幕宽度。
      padding: EdgeInsets.symmetric(horizontal: 0, vertical: verticalPadding),
      child: child,
    );
  }
}
