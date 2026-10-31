// ignore_for_file: file_names

import 'package:flutter/material.dart';

/// 品牌标记：显示 PengSong 的官方 logo 图片。
///
/// 历史上这个组件是用 CustomPainter 画 Operit 的矢量图形；改成显示
/// `assets/images/pengsong_logo.png`，一次替换后关于页、开机引导、
/// 启动页、侧边栏收起态、Toast、聊天分享图都会同步生效。
class OperitLogoMark extends StatelessWidget {
  const OperitLogoMark({
    super.key,
    this.size = 32,
    this.contentScale = 0.88,
    this.color = const Color(0xFF3882C7),
    this.shape = BoxShape.circle,
  });

  final double size;

  /// 图标在方框内所占比例（1.0 表示铺满）。保留原名以兼容旧调用点。
  final double contentScale;

  /// 旧接口的颜色参数。logo 使用自身品牌色，此参数不再参与绘制。
  final Color color;

  /// 裁剪形状。默认圆形，与各处的圆形徽标容器一致。
  final BoxShape shape;

  @override
  Widget build(BuildContext context) {
    final inset = size * (1 - contentScale).clamp(0.0, 1.0) / 2;
    return SizedBox.square(
      dimension: size,
      child: Padding(
        padding: EdgeInsets.all(inset),
        child: _clip(
          Image.asset(
            'assets/images/pengsong_logo.png',
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            // logo 只是装饰性品牌标记，读不到时不阻塞界面
            errorBuilder: (context, error, stackTrace) => ColoredBox(
              color: const Color(0xFF13713D),
              child: Center(
                child: Icon(
                  Icons.spa_outlined,
                  size: size * 0.5,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _clip(Widget child) {
    if (shape == BoxShape.circle) {
      return ClipOval(child: child);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.22),
      child: child,
    );
  }
}
