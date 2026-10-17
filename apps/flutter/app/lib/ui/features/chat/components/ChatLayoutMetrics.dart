// ignore_for_file: file_names

import 'package:operit_ui/operit_ui.dart';

const double chatContentMaxWidth = themeChatContentMaxWidth;
const double chatWideContentMaxWidth = themeChatWideContentMaxWidth;

/// Horizontal gap between transcript content and the screen edge.
///
/// The transcript is meant to use the full width of the device: on a phone the
/// former 16dp gutter on each side visibly wasted screen estate, so the gutter
/// is dropped and the content runs edge to edge. Vertical rhythm is untouched.
const double chatAreaHorizontalPadding = 0;
