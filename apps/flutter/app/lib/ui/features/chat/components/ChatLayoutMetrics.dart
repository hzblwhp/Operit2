// ignore_for_file: file_names

import 'package:operit_ui/operit_ui.dart';

const double chatContentMaxWidth = themeChatContentMaxWidth;
const double chatWideContentMaxWidth = themeChatWideContentMaxWidth;

/// Horizontal gap between transcript content and the screen edge.
///
/// Density 480 means 1dp = 3px, so 1.5mm is 9.45dp. The previous 5dp could only
/// give back ~0.8mm in total, so this is 1dp instead: content gains 8dp
/// (~1.27mm) across both sides, and a 3px gutter still keeps glyphs off the
/// bezel. Vertical rhythm is untouched.
const double chatAreaHorizontalPadding = 1;
