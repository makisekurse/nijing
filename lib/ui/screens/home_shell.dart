import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_info.dart';
import '../../models/app_config.dart';
import '../../models/save_slot.dart';
import '../../models/world_book.dart';
import '../../services/file_export_service.dart';
import '../../services/save_service.dart';
import '../../state/config_provider.dart';
import '../../state/library_provider.dart';
import '../themes/app_theme.dart';
import 'about_screen.dart';
import 'continue_tab.dart';
import 'profile_tab.dart';
import 'quick_create_screen.dart';
import 'reader_screen.dart';
import 'settings_screen.dart';
import 'worldbook_editor_screen.dart';
import 'worlds_tab.dart';

/// 主壳：世界 · 继续 · 我的（v2.0 瘦身重构：`forui` `FScaffold` + `FBottomNavigationBar` + `Provider` 状态解耦）。
class HomeShell extends StatefulWidget {
  /// 保留可选构造参数以兼容历史测试或直接挂载；生产环境直接由 [ConfigProvider] 驱动。
  final AppConfig? config;
  final ValueChanged<AppConfig>? onConfigChanged;

  const HomeShell({
    super.key,
    this.config,
    this.onConfigChanged,
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 1; // 默认落在「继续」

  LibraryProvider get _lib => context.read<LibraryProvider>();
  ConfigProvider get _cfg => context.read<ConfigProvider>();

  // ---------- 进入推演 ----------

  Future<void> _startSessionWith(WorldBook book) async {
    final slot = await _lib.ensureSlotForBook(book);
    if (!mounted) return;
    await _openReader(slot);
  }

  Future<void> _restartBook(WorldBook book, {bool confirm = true}) async {
    final existing = _lib.slotForBook(book.id);
    if (existing != null && confirm) {
      final ok = await _confirm(
        title: '重新开始《${book.name}》？',
        message: '当前进度（第 ${existing.chapterCount} 幕）'
            '${existing.lines.length > 1 ? '与全部 ${existing.lines.length} 条世界线' : ''}'
            '会被清空，无法恢复。',
        destructive: true,
        confirmLabel: '清空并重开',
      );
      if (!ok) return;
    }
    final fresh = await _lib.restartBook(book);
    if (!mounted) return;
    await _openReader(fresh);
  }

  Future<void> _newSession() async {
    final books = _lib.books;
    if (books.isEmpty) {
      _toast('还没有世界。先创建、导入或一键加载示例世界书吧。');
      setState(() => _index = 0);
      return;
    }
    final playable = books.where((b) => b.isPlayable).toList();
    if (playable.isEmpty) {
      _toast('现有的世界书还缺必填项，请先补全。');
      setState(() => _index = 0);
      return;
    }

    final book = await _showSheet<WorldBook>(
      title: '选择要进入的世界',
      child: FTileGroup(
        children: <FTileMixin>[
          for (final b in playable)
            FTile(
              prefix: const Icon(LucideIcons.bookOpen, size: 17),
              title: Text(b.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                _lib.slotForBook(b.id) == null
                    ? (b.era.trim().isEmpty ? '尚未开始' : b.era.trim())
                    : '已有进度 · 第 ${_lib.slotForBook(b.id)!.chapterCount} 幕',
              ),
              suffix: const Icon(LucideIcons.chevronRight, size: 16),
              onPress: () => Navigator.pop(context, b),
            ),
        ],
      ),
    );
    if (book == null || !mounted) return;

    final existing = _lib.slotForBook(book.id);
    if (existing == null) {
      final slot = await _lib.createSession(book);
      if (!mounted) return;
      await _openReader(slot);
      return;
    }

    final choice = await _showSheet<String>(
      title: '《${book.name}》已有进行中的一局',
      child: FTileGroup(
        children: <FTileMixin>[
          FTile(
            prefix: const Icon(LucideIcons.play, size: 17),
            title: Text('继续 · 第 ${existing.chapterCount} 幕'),
            onPress: () => Navigator.pop(context, 'resume'),
          ),
          FTile(
            variant: FItemVariant.destructive,
            prefix: const Icon(LucideIcons.rotateCcw, size: 17),
            title: const Text('重新开始一局'),
            subtitle: const Text('当前进度会被清空'),
            onPress: () => Navigator.pop(context, 'restart'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'resume') {
      await _openReader(existing);
    } else {
      await _restartBook(book, confirm: false);
    }
  }

  Future<void> _openReader(SaveSlot slot) async {
    await _lib.setActiveSlot(slot.id);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReaderScreen(
          slot: slot,
          config: _cfg.config,
          onConfigChanged: (c) => _cfg.updateConfig(c, immediate: true),
        ),
      ),
    );
    await _lib.reload();
  }

  // ---------- 世界书 ----------

  Future<WorldBook?> _editBook(WorldBook book) async {
    final saved = await Navigator.of(context).push<WorldBook>(
      MaterialPageRoute<WorldBook>(
        builder: (_) => WorldBookEditorScreen(book: book),
      ),
    );
    await _lib.reload();
    return saved;
  }

  Future<void> _createBook() async {
    final choice = await _showSheet<String>(
      title: '创建世界书',
      child: FTileGroup(
        children: <FTileMixin>[
          FTile(
            prefix: const Icon(LucideIcons.sparkles, size: 17),
            title: const Text('AI 一句话快速创建'),
            subtitle: const Text('用一句自然语言由模型扩写成完整设定（先预览后保存）'),
            suffix: const Icon(LucideIcons.chevronRight, size: 16),
            onPress: () => Navigator.pop(context, 'quick'),
          ),
          FTile(
            prefix: const Icon(LucideIcons.penLine, size: 17),
            title: const Text('手动编写'),
            subtitle: const Text('填写核心三项即可开局，进阶设定按需展开'),
            suffix: const Icon(LucideIcons.chevronRight, size: 16),
            onPress: () => Navigator.pop(context, 'blank'),
          ),
          FTile(
            prefix: const Icon(LucideIcons.bookmarkPlus, size: 17),
            title: const Text('一键导入示例《决胜西南1949》'),
            subtitle: const Text('完整历史正剧世界书与开篇，立刻体验引擎能力'),
            suffix: const Icon(LucideIcons.chevronRight, size: 16),
            onPress: () => Navigator.pop(context, 'sample'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;

    if (choice == 'quick') {
      await Navigator.of(context).push<WorldBook>(
        MaterialPageRoute<WorldBook>(
          builder: (_) => QuickCreateScreen(config: _cfg.config),
        ),
      );
      await _lib.reload();
      return;
    }
    if (choice == 'sample') {
      await _importSample();
      return;
    }
    await _editBook(WorldBook.blank());
  }

  Future<void> _importSample() async {
    try {
      final book = await _lib.importSampleWorldBook();
      if (!mounted) return;
      _toast('已导入示例《${book.name}》，可以直接开始推演');
    } catch (e) {
      if (mounted) _toast('导入示例失败：$e');
    }
  }

  Future<void> _importBook() async {
    final mode = await _showSheet<String>(
      title: '导入世界书',
      child: FTileGroup(
        children: <FTileMixin>[
          FTile(
            prefix: const Icon(LucideIcons.fileUp, size: 17),
            title: const Text('从本地文件选择（.json / .txt）'),
            subtitle: const Text('直接打开手机文件管理器导入'),
            suffix: const Icon(LucideIcons.chevronRight, size: 16),
            onPress: () => Navigator.pop(context, 'file'),
          ),
          FTile(
            prefix: const Icon(LucideIcons.clipboardPaste, size: 17),
            title: const Text('粘贴 JSON 或世界观文本'),
            subtitle: const Text('从剪贴板或手动粘贴导入'),
            suffix: const Icon(LucideIcons.chevronRight, size: 16),
            onPress: () => Navigator.pop(context, 'paste'),
          ),
          FTile(
            prefix: const Icon(LucideIcons.bookmarkPlus, size: 17),
            title: const Text('一键导入示例《决胜西南1949》'),
            suffix: const Icon(LucideIcons.chevronRight, size: 16),
            onPress: () => Navigator.pop(context, 'sample'),
          ),
        ],
      ),
    );
    if (mode == null || !mounted) return;

    if (mode == 'sample') {
      await _importSample();
      return;
    }

    String? rawText;
    if (mode == 'file') {
      try {
        rawText = await _lib.pickLocalTextFile();
      } catch (e) {
        if (mounted) _toast('读取文件失败：$e');
        return;
      }
    } else {
      rawText = await _showPasteDialog(
        title: '粘贴世界书内容',
        hint: '{"name":"…","worldview":"…","playerRole":"…"} 或纯文本世界观',
      );
    }

    if (rawText == null || rawText.trim().isEmpty || !mounted) return;
    try {
      final book = await _lib.importBookFromText(rawText);
      if (!mounted) return;
      _toast('已导入《${book.name}》');
      await _editBook(book);
    } catch (e) {
      if (mounted) _toast('导入失败：$e');
    }
  }

  Future<void> _bookMenu(WorldBook book) async {
    final slot = _lib.slotForBook(book.id);
    await _showSheet<void>(
      title: book.name,
      child: FTileGroup(
        children: <FTileMixin>[
          FTile(
            prefix: const Icon(LucideIcons.play, size: 17),
            title: const Text('进入这个世界'),
            enabled: book.isPlayable,
            onPress: () {
              Navigator.pop(context);
              _startSessionWith(book);
            },
          ),
          if (slot != null)
            FTile(
              prefix: const Icon(LucideIcons.rotateCcw, size: 17),
              title: const Text('重新开始一局'),
              subtitle: Text('清空当前第 ${slot.chapterCount} 幕进度'),
              onPress: () {
                Navigator.pop(context);
                _restartBook(book);
              },
            ),
          FTile(
            prefix: const Icon(LucideIcons.pencil, size: 17),
            title: const Text('编辑世界书'),
            onPress: () {
              Navigator.pop(context);
              _editBook(book);
            },
          ),
          FTile(
            prefix: const Icon(LucideIcons.share2, size: 17),
            title: const Text('导出 JSON 文件'),
            subtitle: const Text('保存至下载目录并同步复制到剪贴板'),
            onPress: () async {
              Navigator.pop(context);
              final json = book.exportToJson();
              final ts = FileExportService.formatTimestamp();
              final safe = FileExportService.sanitizeFileName(book.name);
              await _exportAndNotify(
                fileName: '拟境_世界书_${safe}_$ts.json',
                content: json,
                shareTitle: '世界书 · ${book.name}',
                okLabel: '世界书已导出',
              );
            },
          ),
          FTile(
            variant: FItemVariant.destructive,
            prefix: const Icon(LucideIcons.trash2, size: 17),
            title: const Text('删除世界书'),
            onPress: () async {
              Navigator.pop(context);
              final ok = await _confirm(
                title: '删除世界书',
                message: '确定删除《${book.name}》？已有推演存档不受影响。',
                destructive: true,
              );
              if (!ok) return;
              await _lib.deleteBook(book.id);
            },
          ),
        ],
      ),
    );
  }

  // ---------- 存档 ----------

  Future<void> _slotMenu(SaveSlot slot) async {
    await _showSheet<void>(
      title: slot.title,
      child: FTileGroup(
        children: <FTileMixin>[
          FTile(
            prefix: const Icon(LucideIcons.share2, size: 17),
            title: const Text('导出推演存档（JSON）'),
            subtitle: const Text('包含全部世界线与历史幕次'),
            onPress: () async {
              Navigator.pop(context);
              final json = SaveService.exportSlot(slot);
              final ts = FileExportService.formatTimestamp();
              final safe = FileExportService.sanitizeFileName(slot.title);
              await _exportAndNotify(
                fileName: '拟境_推演存档_${safe}_$ts.json',
                content: json,
                shareTitle: '推演存档 · ${slot.title}',
                okLabel: '推演存档已导出',
              );
            },
          ),
          FTile(
            variant: FItemVariant.destructive,
            prefix: const Icon(LucideIcons.trash2, size: 17),
            title: const Text('删除这一局'),
            onPress: () async {
              Navigator.pop(context);
              final ok = await _confirm(
                title: '删除推演',
                message: '确定删除《${slot.title}》这一局的全部世界线进度？不可恢复。',
                destructive: true,
              );
              if (!ok) return;
              await _lib.deleteSlot(slot.id);
            },
          ),
        ],
      ),
    );
  }

  // ---------- 本机数据管理 ----------

  Future<void> _dataManage() async {
    final lib = _lib;
    final palette = AppTheme.readingOf(context);
    await _showSheet<void>(
      title: '本机数据管理',
      subtitle: '世界书 ${lib.books.length} 本 · 推演 ${lib.slots.length} 个'
          '${lib.totalLineCount > lib.slots.length ? ' · 世界线 ${lib.totalLineCount} 条' : ''}',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FTileGroup(
            children: <FTileMixin>[
              FTile(
                prefix: const Icon(LucideIcons.fileUp, size: 17),
                title: const Text('从文件导入推演存档（.json）'),
                onPress: () async {
                  Navigator.pop(context);
                  try {
                    final text = await _lib.pickLocalTextFile();
                    if (text == null || text.trim().isEmpty || !mounted) return;
                    final slot = await _lib.importSaveFromText(text);
                    if (mounted) _toast('已导入存档《${slot.title}》');
                  } catch (e) {
                    if (mounted) _toast('导入存档失败：$e');
                  }
                },
              ),
              FTile(
                prefix: const Icon(LucideIcons.download, size: 17),
                title: const Text('导出全部世界书（JSON）'),
                subtitle: Text('共 ${lib.books.length} 本'),
                enabled: lib.books.isNotEmpty,
                onPress: () async {
                  Navigator.pop(context);
                  final jsonContent = const JsonEncoder.withIndent('  ')
                      .convert(lib.books.map((b) => b.toJson()).toList());
                  final ts = FileExportService.formatTimestamp();
                  await _exportAndNotify(
                    fileName: '拟境_全部世界书_${lib.books.length}本_$ts.json',
                    content: jsonContent,
                    shareTitle: '拟境 · 全部世界书',
                    okLabel: '全部世界书已导出',
                  );
                },
              ),
              FTile(
                prefix: const Icon(LucideIcons.download, size: 17),
                title: const Text('导出全部推演存档（JSON）'),
                subtitle: Text('共 ${lib.slots.length} 个'),
                enabled: lib.slots.isNotEmpty,
                onPress: () async {
                  Navigator.pop(context);
                  final jsonContent = const JsonEncoder.withIndent('  ')
                      .convert(lib.slots.map((s) => s.toJson()).toList());
                  final ts = FileExportService.formatTimestamp();
                  await _exportAndNotify(
                    fileName: '拟境_全部推演存档_${lib.slots.length}个_$ts.json',
                    content: jsonContent,
                    shareTitle: '拟境 · 全部推演存档',
                    okLabel: '全部推演存档已导出',
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          FTileGroup(
            children: <FTileMixin>[
              if (lib.blankBooks.isNotEmpty)
                FTile(
                  prefix: Icon(LucideIcons.eraser, size: 17, color: palette.accent),
                  title: const Text('清理空白世界书'),
                  subtitle: Text('删除 ${lib.blankBooks.length} 本未填写的世界书'),
                  onPress: () async {
                    Navigator.pop(context);
                    final n = await _lib.purgeBlankBooks();
                    if (mounted) _toast('已清理 $n 本空白世界书');
                  },
                ),
              if (lib.backups.isNotEmpty)
                FTile(
                  prefix: Icon(LucideIcons.archive, size: 17, color: palette.accent),
                  title: const Text('清理旧版回滚备份'),
                  subtitle: Text('删除 ${lib.backups.length} 份旧备份'),
                  onPress: () async {
                    Navigator.pop(context);
                    await _lib.purgeBackups();
                    if (mounted) _toast('已清理回滚备份');
                  },
                ),
              FTile(
                variant: FItemVariant.destructive,
                prefix: const Icon(LucideIcons.trash2, size: 17),
                title: const Text('清空全部本机数据与密钥'),
                subtitle: const Text('世界书、存档与全部加密 API Key 一并清除'),
                onPress: () async {
                  Navigator.pop(context);
                  final ok = await _confirm(
                    title: '清空全部数据',
                    message: '确定清空全部世界书、存档、备份以及所有服务商的加密 API Key？此操作不可恢复。',
                    destructive: true,
                    confirmLabel: '全部清空',
                  );
                  if (!ok) return;
                  await _lib.clearAllData();
                  if (mounted) _toast('已清空全部本地数据与加密密钥');
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------- 公共弹窗与提示工具 ----------

  Future<T?> _showSheet<T>({
    required String title,
    String? subtitle,
    required Widget child,
  }) {
    final palette = AppTheme.readingOf(context);
    return showFSheet<T>(
      context: context,
      side: FLayout.btt,
      mainAxisMaxRatio: 0.85,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: palette.page,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border(top: BorderSide(color: palette.rule, width: 0.8)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: palette.muted.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: palette.ink,
                  ),
                ),
                if (subtitle != null && subtitle.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12.5, color: palette.muted),
                  ),
                ],
                const SizedBox(height: 14),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<String?> _showPasteDialog({
    required String title,
    required String hint,
  }) async {
    final ctrl = TextEditingController();
    final res = await showFDialog<String>(
      context: context,
      builder: (ctx, style, anim) => FDialog(
        animation: anim,
        style: style,
        builder: (c, s) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: s.titleTextStyle),
              const SizedBox(height: 12),
              FTextField.multiline(
                control: FTextFieldControl.managed(controller: ctrl),
                hint: hint,
                minLines: 4,
                maxLines: 8,
              ),
              const SizedBox(height: 14),
              Row(
                children: <Widget>[
                  Expanded(
                    child: FButton(
                      variant: FButtonVariant.outline,
                      size: FButtonSizeVariant.sm,
                      prefix: const Icon(LucideIcons.clipboardPaste, size: 15),
                      onPress: () async {
                        final data = await Clipboard.getData('text/plain');
                        ctrl.text = data?.text ?? '';
                      },
                      child: const Text('读剪贴板'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FButton(
                      size: FButtonSizeVariant.sm,
                      onPress: () => Navigator.pop(c, ctrl.text),
                      child: const Text('导入'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    ctrl.dispose();
    return res;
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    bool destructive = false,
    String confirmLabel = '确定',
  }) async {
    final ok = await showFDialog<bool>(
      context: context,
      builder: (ctx, style, anim) => FDialog(
        animation: anim,
        style: style,
        builder: (c, s) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: s.titleTextStyle),
              const SizedBox(height: 10),
              Text(message, style: s.bodyTextStyle),
              const SizedBox(height: 18),
              Row(
                children: <Widget>[
                  Expanded(
                    child: FButton(
                      variant: FButtonVariant.outline,
                      size: FButtonSizeVariant.sm,
                      onPress: () => Navigator.pop(c, false),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FButton(
                      variant: destructive
                          ? FButtonVariant.destructive
                          : FButtonVariant.primary,
                      size: FButtonSizeVariant.sm,
                      onPress: () => Navigator.pop(c, true),
                      child: Text(confirmLabel),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return ok ?? false;
  }

  Future<void> _exportAndNotify({
    required String fileName,
    required String content,
    required String shareTitle,
    required String okLabel,
  }) async {
    final res = await FileExportService.exportFile(
      fileName: fileName,
      content: content,
      mimeType: 'application/json',
    );
    await Clipboard.setData(ClipboardData(text: content));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(
          res.success
              ? '$okLabel：${res.path}\n（已同时复制到剪贴板）'
              : '保存失败：${res.message}（已复制到剪贴板）',
        ),
        action: SnackBarAction(
          label: '系统分享',
          onPressed: () => FileExportService.shareText(
            title: shareTitle,
            text: content,
          ),
        ),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryProvider>();

    return FScaffold(
      childPad: false,
      footer: FBottomNavigationBar(
        index: _index,
        safeAreaBottom: true,
        onChange: (i) {
          HapticFeedback.selectionClick();
          setState(() => _index = i);
        },
        children: const <Widget>[
          FBottomNavigationBarItem(
            icon: Icon(LucideIcons.library, size: 20),
            label: Text('世界'),
          ),
          FBottomNavigationBarItem(
            icon: Icon(LucideIcons.bookOpen, size: 20),
            label: Text('继续'),
          ),
          FBottomNavigationBarItem(
            icon: Icon(LucideIcons.user, size: 20),
            label: Text('我的'),
          ),
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: lib.loading
            ? const Center(child: CircularProgressIndicator())
            : IndexedStack(
                index: _index,
                children: <Widget>[
                  WorldsTab(
                    books: lib.books,
                    progressByBook: lib.progressByBook,
                    onCreate: _createBook,
                    onImport: _importBook,
                    onImportSample: _importSample,
                    onEdit: _editBook,
                    onMenu: _bookMenu,
                    onStartSession: _startSessionWith,
                  ),
                  ContinueTab(
                    slots: lib.slots,
                    activeSlotId: lib.activeSlotId,
                    onOpen: _openReader,
                    onMenu: _slotMenu,
                    onNewSession: _newSession,
                    onImportSample: _importSample,
                  ),
                  ProfileTab(
                    onOpenSection: (section) => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => SettingsScreen(section: section),
                      ),
                    ),
                    onOpenAbout: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AboutScreen(),
                      ),
                    ),
                    onDataManage: _dataManage,
                    versionLabel: AppInfo.versionLabel,
                    worldCountLabel: '${lib.books.length} 本世界书',
                    slotCountLabel: '${lib.slots.length} 个推演',
                  ),
                ],
              ),
      ),
    );
  }
}
