// ignore_for_file: file_names

import 'package:operit_ui/operit_ui.dart';

const double chatContentMaxWidth = themeChatContentMaxWidth;
const double chatWideContentMaxWidth = themeChatWideContentMaxWidth;

/// Horizontal gap between transcript content and the screen edge.
///
/// Edge-to-edge with zero gutter felt cramped, so the transcript keeps a small
/// inset of roughly 1 mm on each side: that reads as "uses the full screen"
/// without the glyphs touching the bezel. Vertical rhythm is untouched.
const double chatAreaHorizontalPadding = 5;
