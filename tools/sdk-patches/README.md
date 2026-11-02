# Flutter SDK 补丁

## 应用方式

```powershell
$sdk = 'D:\flutter-ohos\packages\flutter\lib\src\widgets'
# 先把 .patch 里的 a/ b/ 路径去掉，再 patch：
#   git apply --directory=... 不适用于 flutter-ohos（它没有 git 元数据）
# 实际做法：直接按 patch 内容手工改，或
cd $sdk
patch -p0 --dry-run < <patchfile>   # 需要 GNU patch（WSL 里有）
```

更省事的做法：在 WSL 里

```bash
cd /mnt/d/flutter-ohos/packages/flutter/lib/src/widgets
patch -p0 < /mnt/d/52224/Documents/PengSong2-src/tools/sdk-patches/selection_container.dart.patch
patch -p0 < /mnt/d/52224/Documents/PengSong2-src/tools/sdk-patches/selectable_region.dart.patch
```

## 为什么必须补

`Bad state: RenderBox was not laid out: RenderParagraph#...`，
以 `Unhandled error source: Zone` 弹窗形式出现，堆栈：

```
RenderBox.size (box.dart:2304)
RenderBox.paintBounds (box.dart:3109)
_SelectionContainerState.boundingBoxes (selection_container.dart:218)
MultiSelectableSelectionContainerDelegate._getBoundingBox (selectable_region.dart:2565)
MultiSelectableSelectionContainerDelegate._compareScreenOrder (:2580)
Sort.sort
MultiSelectableSelectionContainerDelegate._flushAdditions (:2477)
MultiSelectableSelectionContainerDelegate._updateSelectables
```

`_flushAdditions` 在 postFrame/microtask 里对新加入的 Selectable 排序，
而此刻刚插入的 Selectable（例如流式 Markdown 新增的段落）可能还没 layout。
`boundingBoxes` 直接读 `paintBounds`，后者会取 `size`，于是抛错。

## 补法

1. `selection_container.dart` — `boundingBoxes` 在未 attached / 无 size /
   needsLayout 时返回 `const <Rect>[]`，把「尚未就绪」如实表达出去。
2. `selectable_region.dart` — `_getBoundingBox` 遇到空列表返回 `Rect.zero` 占位。
   排序暂时把它放最前，等它完成 layout 后会由 `layoutDidChange` 重新触发排序，
   结果自然恢复正确。

## 风险与边界

- 这是**第三方 fork**（`3.41.10-ohos-0.0.2-beta.operit.2`），不是上游 Flutter。
  升级 SDK 时这两处补丁会被覆盖，必须重新应用。
- `Rect.zero` 占位只影响「同一帧内尚未 layout 的 selectable」的排序顺序，
  不改变任何已布局元素的顺序，也不影响选择行为本身。