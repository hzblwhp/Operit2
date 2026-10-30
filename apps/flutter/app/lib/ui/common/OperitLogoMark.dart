// ignore_for_file: file_names

import 'package:flutter/material.dart';

/// Renders the PengSong brand mark.
///
/// Uses the shipped brand artwork rather than a single-colour vector path so
/// every surface that shows the identity (about page, bootstrap screen,
/// onboarding, collapsed drawer, toasts, share cards) matches the launcher
/// icon instead of the inherited Operit whale silhouette.
class OperitLogoMark extends StatelessWidget {
  const OperitLogoMark({
    super.key,
    this.size = 32,
    this.contentScale = 0.88,
    this.color = const Color(0xFF13713D),
  });

  final double size;
  final double contentScale;

  /// Retained for call-site compatibility; the brand artwork carries its own
  /// colours, so the value no longer tints the mark.
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: Image.asset(
        'assets/images/operit_avatar.png',
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}
