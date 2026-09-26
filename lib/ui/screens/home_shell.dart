import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_info.dart';
import '../../data/prefs_store.dart';
import '../../data/world_book_repository.dart';
import '../../models/app_config.dart';
import '../../models/save_slot.dart';
import '../../models/world_book.dart';
import '../../services/file_export_service.dart';
import '../../services/game_session.dart';
import '../../services/generation_controller.dart';
import '../../services/save_service.dart';
import 'about_screen.dart';
import 'continue_tab.dart';
import 'profile_tab.dart';
import 'quick_create_screen.dart';
import 'reader_screen.dart';
import 'settings_screen.dart';
import 'worldbook_editor_screen.dart';
import 'worlds_tab.dart';

/// 主壳：世界 · 继续 · 我的。
///
/// 用户脑子里的三件事：
/// - 世界 = 我创造什么
/// - 继续 = 我正在经历什么
/// - 我的 = App 设置
class HomeShell extends StatefulWidget {
  final AppConfig config;
  final ValueChanged<AppConfig> onConfigChanged;

  const HomeShell({
    super.key,
    required this.config,
    required this.onConfigChanged,
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const String _kActiveSlot = 'nijing_active_slot';

  int _index = 1; // 默认落在「继续」：用户最想做的事是接着玩

  List<SaveSlot> _slots = <SaveSlot>[];
  List<WorldBook> _books = <WorldBook>[];
  /// 回滚前自动生成的备份。**不计入推演数量**。
  List<SaveSlot> _backups = <SaveSlot>[];
  String? _activeSlotId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final slots = await SaveService.loadAll();
    final books = await WorldBookRepository.loadAll();
    final backups = await SaveService.loadBackups();
    final active = await PrefsStore.getString(_kActiveSlot);
    if (!mounted) return;
    setState(() {
      _slots = slots;
      _books = books;
      _backups = backups;
      _activeSlotId = active;
      _loading = false;
    });
  }

  Future<void> _setActiveSlot(String id) async {
    _activeSlotId = id;
    await PrefsStore.setString(_kActiveSlot, id);
  }

  // ---------- 进入世界 ----------
  //
  // ⚠️ 2026-09-25 修：以前每次「进入这个世界」都无条件 SaveSlot.newId() 建新槽，
  // 于是两件事同时坏掉：
  //   1. 「最近推演」每进一次就多一条（同一本书反复出现）
  //   2. 「继续进入」可能开到一个只到第一幕的旧槽 —— 用户看到的就是「跳回第一幕」
  //
  // 现在改成**一本书一局**：进入时先找这本书已有的存档，有就接着玩，
  // 没有才新建。想重开走「重新开始一局」（会清空当前进度，带确认）。

  /// 这本书已有的存档（最近的、非备份）。
  SaveSlot? _slotForBook(String bookId) {
    for (final s in _slots) {
      if (s.worldBook.id == bookId) return s;
    }
    return null;
  }

  /// 每本书的进度，给世界列表显示「继续 · 第 N 幕」用。
  Map<String, int> get _progressByBook => <String, int>{
        for (final s in _slots) s.worldBook.id: s.chapterCount,
      };

  /// 全部推演加起来有多少条世界线。
  int get _lineCount =>
      _slots.fold(0, (sum, s) => sum + s.lines.length);

  Future<void> _startSessionWith(WorldBook book) async {
    final existing = _slotForBook(book.id);
    if (existing != null) {
      await _openReader(existing);
      return;
    }
    await _createSession(book);
  }

  /// 新建一局（不检查是否已有存档）。
  Future<void> _createSession(WorldBook book) async {
    final slot = SaveSlot(
      id: SaveSlot.newId(),
      title: book.name,
      worldBook: book,
    );

    // ⚠️ 走 GameSession.seedOpening，**不要在这里直接造 ChapterNode** ——
    // 那样会漏掉每幕快照（chronicleAfter / worldStateAfter），
    // 导致从第一幕分岔时状态退不回去。
    if (book.openingScene.trim().isNotEmpty) {
      GameSession(slot).seedOpening(
        content: book.openingScene.trim(),
        date: book.era.trim(),
        choices: book.openingChoices,
      );
    }

    await SaveService.upsert(slot);
    await _setActiveSlot(slot.id);
    await _reload();
    if (!mounted) return;
    await _openReader(slot);
  }

  /// 重新开始一局。
  ///
  /// **清空已有存档的进度，而不是再建一个新槽** —— 再建新槽的话
  /// 「最近推演」又会多出一条，正是之前那个 bug。
  Future<void> _restartBook(WorldBook book, {bool confirm = true}) async {
    final existing = _slotForBook(book.id);
    if (existing == null) {
      await _createSession(book);
      return;
    }

    if (confirm) {
      final ok = await _confirm(
        '重新开始《${book.name}》？\n'
        '当前进度（第 ${existing.chapterCount} 幕）'
        '${existing.lines.length > 1 ? '与全部 ${existing.lines.length} 条世界线' : ''}'
        '会被清空，无法恢复。',
      );
      if (!ok) return;
    }

    // 重开 = 整槽重置成一条全新的主线。
    // ⚠️ 不复用旧 slot 对象：那样会连旧的世界线一起留着。
    final fresh = SaveSlot(
      id: existing.id,
      title: existing.title,
      worldBook: existing.worldBook,
      createdAt: existing.createdAt,
    );
    if (book.openingScene.trim().isNotEmpty) {
      GameSession(fresh).seedOpening(
        content: book.openingScene.trim(),
        date: book.era.trim(),
        choices: book.openingChoices,
      );
    }
    await SaveService.upsert(fresh);
    await _setActiveSlot(fresh.id);
    await _reload();
    if (!mounted) return;
    await _openReader(fresh);
  }

  Future<void> _newSession() async {
    if (_books.isEmpty) {
      _toast('还没有世界。先创建或导入一个，才能进入。');
      setState(() => _index = 0);
      return;
    }
    final playable = _books.where((b) => b.isPlayable).toList();
    if (playable.isEmpty) {
      _toast('现有的世界书还缺必填项，先补全一个。');
      setState(() => _index = 0);
      return;
    }

    final book = await showModalBottomSheet<WorldBook>(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.85,
          ),
          child: ListView(
            shrinkWrap: true,
            physics: const ClampingScrollPhysics(),
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Text('选择要进入的世界', style: TextStyle(fontSize: 14)),
              ),
              for (final b in playable)
                ListTile(
                  title: Text(b.name, style: const TextStyle(fontSize: 14.5)),
                  subtitle: Text(
                    _slotForBook(b.id) == null
                        ? (b.era.trim().isEmpty ? '还没开始' : b.era)
                        : '已有进度 · 第 ${_slotForBook(b.id)!.chapterCount} 幕',
                    style: const TextStyle(fontSize: 12),
                  ),
                  onTap: () => Navigator.pop(ctx, b),
                ),
            ],
          ),
        ),
      ),
    );
    if (book == null || !mounted) return;

    final existing = _slotForBook(book.id);
    if (existing == null) {
      await _createSession(book);
      return;
    }

    // 这本书已经有一局了 —— 让用户明确选，不要默默新建一条
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '《${book.name}》已经有一局了',
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.play_arrow_rounded),
                title: Text('继续 · 第 ${existing.chapterCount} 幕'),
                onTap: () => Navigator.pop(ctx, 'resume'),
              ),
              ListTile(
                leading: const Icon(Icons.restart_alt_rounded),
                title: const Text('重新开始一局'),
                subtitle: const Text('当前进度会被清空'),
                onTap: () => Navigator.pop(ctx, 'restart'),
              ),
            ],
          ),
        ),
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
    await _setActiveSlot(slot.id);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReaderScreen(
          config: widget.config,
          slot: slot,
          onConfigChanged: widget.onConfigChanged,
        ),
      ),
    );
    await _reload();
  }

  // ---------- 世界书 ----------

  Future<WorldBook?> _editBook(WorldBook book) async {
    final saved = await Navigator.of(context).push<WorldBook>(
      MaterialPageRoute<WorldBook>(
        builder: (_) => WorldBookEditorScreen(book: book),
      ),
    );
    await _reload();
    return saved;
  }

  Future<void> _createBook() async {
    final theme = Theme.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: theme.scaffoldBackgroundColor,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.auto_awesome_rounded),
                title: const Text('快速创建'),
                subtitle: const Text('一句话描述，AI 扩写成完整设定（生成后可改）'),
                onTap: () => Navigator.pop(ctx, 'quick'),
              ),
              ListTile(
                leading: const Icon(Icons.edit_note_rounded),
                title: const Text('手动编写'),
                subtitle: const Text('从空白模板开始，逐项自己填'),
                onTap: () => Navigator.pop(ctx, 'blank'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;

    if (choice == 'quick') {
      await Navigator.of(context).push<WorldBook>(
        MaterialPageRoute<WorldBook>(
          builder: (_) => QuickCreateScreen(config: widget.config),
        ),
      );
      await _reload();
      return;
    }

    // ⚠️ **不预先落库** —— 编辑器里点保存时才写。
    // 以前先 upsert 再打开编辑器，用户退出来就留下一本空白世界书，
    // 反复几次「世界书数目」就对不上了。
    final book = WorldBook.blank();
    if (!mounted) return;
    await _editBook(book);
  }

  /// 空白世界书：既没写背景也没写角色，等于创建后没填就退出了。
  List<WorldBook> get _blankBooks => _books
      .where((b) => b.worldview.trim().isEmpty && b.playerRole.trim().isEmpty)
      .toList();

  Future<void> _purgeBlankBooks() async {
    final blanks = _blankBooks;
    if (blanks.isEmpty) {
      _toast('没有空白世界书。');
      return;
    }
    final ok = await _confirm(
      '删除 ${blanks.length} 本空白世界书？\n'
      '${blanks.map((b) => '· ${b.name}').take(8).join('\n')}'
      '${blanks.length > 8 ? '\n…' : ''}\n\n'
      '这些是创建后没填内容就退出的，删掉不影响任何推演。',
    );
    if (!ok) return;
    for (final b in blanks) {
      await WorldBookRepository.delete(b.id);
    }
    await _reload();
    if (mounted) _toast('已清理 ${blanks.length} 本空白世界书');
  }

  Future<void> _importBook() async {
    final ctrl = TextEditingController();
    final text = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
        ),
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
            const Text('导入世界书', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 6),
            Text(
              '粘贴世界书的 JSON，或直接粘贴一段世界观提示词文本。',
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color:
                    Theme.of(ctx).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              maxLines: 8,
              minLines: 5,
              decoration: const InputDecoration(
                hintText: '{"name":"…","worldview":"…","playerRole":"…"}',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final data = await Clipboard.getData('text/plain');
                      ctrl.text = data?.text ?? '';
                    },
                    icon: const Icon(Icons.content_paste_rounded, size: 18),
                    label: const Text('读剪贴板'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, ctrl.text),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
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
    if (text == null || text.trim().isEmpty) return;

    try {
      final book = WorldBook.fromImportText(text);
      await WorldBookRepository.upsert(book);
      await _reload();
      if (!mounted) return;
      _toast('已导入《${book.name}》');
      await _editBook(book);
    } catch (e) {
      if (!mounted) return;
      _toast('导入失败：$e');
    }
  }

  Future<void> _bookMenu(WorldBook book) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.85,
          ),
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.play_arrow_rounded),
                  title: const Text('进入这个世界'),
                  enabled: book.isPlayable,
                  onTap: () {
                    Navigator.pop(ctx);
                    _startSessionWith(book);
                  },
                ),
                if (_slotForBook(book.id) != null)
                  ListTile(
                    leading: const Icon(Icons.restart_alt_rounded),
                    title: const Text('重新开始一局'),
                    subtitle: Text(
                      '当前进度第 ${_slotForBook(book.id)!.chapterCount} 幕，会被清空',
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _restartBook(book);
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.edit_rounded),
                  title: const Text('编辑'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _editBook(book);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.file_present_rounded),
                  title: const Text('导出世界书文件（JSON）'),
                  subtitle: const Text('保存至下载目录，可直接传输、备份与分享'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final json = book.exportToJson();
                    final ts = FileExportService.formatTimestamp();
                    final safeName =
                        FileExportService.sanitizeFileName(book.name);
                    final fileName = '拟境_世界书_${safeName}_$ts.json';
                    final res = await FileExportService.exportFile(
                      fileName: fileName,
                      content: json,
                      mimeType: 'application/json',
                    );
                    await Clipboard.setData(ClipboardData(text: json));
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        duration: const Duration(seconds: 6),
                        content: Text(
                          res.success
                              ? '世界书已保存至：${res.path}\n（已同时复制到剪贴板）'
                              : '保存失败：${res.message}（已复制到剪贴板）',
                        ),
                        action: SnackBarAction(
                          label: '系统分享',
                          onPressed: () => FileExportService.shareText(
                            title: '世界书 · ${book.name}',
                            text: json,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.copy_rounded),
                  title: const Text('复制世界书 JSON 到剪贴板'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await Clipboard.setData(
                      ClipboardData(text: book.exportToJson()),
                    );
                    if (mounted) _toast('已复制到剪贴板');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline_rounded),
                  title: const Text('删除'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final ok = await _confirm('删除世界书《${book.name}》？');
                    if (!ok) return;
                    await WorldBookRepository.delete(book.id);
                    await _reload();
                  },
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 存档 ----------

  Future<void> _slotMenu(SaveSlot slot) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.85,
          ),
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.file_present_rounded),
                  title: const Text('导出推演存档文件（JSON）'),
                  subtitle: const Text('保存至下载目录，包含全部世界线与历史幕次'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final json = SaveService.exportSlot(slot);
                    final ts = FileExportService.formatTimestamp();
                    final safeTitle =
                        FileExportService.sanitizeFileName(slot.title);
                    final fileName = '拟境_推演存档_${safeTitle}_$ts.json';
                    final res = await FileExportService.exportFile(
                      fileName: fileName,
                      content: json,
                      mimeType: 'application/json',
                    );
                    await Clipboard.setData(ClipboardData(text: json));
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        duration: const Duration(seconds: 6),
                        content: Text(
                          res.success
                              ? '存档已保存至：${res.path}\n（已同时复制到剪贴板）'
                              : '保存失败：${res.message}（已复制到剪贴板）',
                        ),
                        action: SnackBarAction(
                          label: '系统分享',
                          onPressed: () => FileExportService.shareText(
                            title: '推演存档 · ${slot.title}',
                            text: json,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.copy_rounded),
                  title: const Text('复制存档 JSON 到剪贴板'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await Clipboard.setData(
                      ClipboardData(text: SaveService.exportSlot(slot)),
                    );
                    if (mounted) _toast('存档 JSON 已复制到剪贴板');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline_rounded),
                  title: const Text('删除这一局'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final ok = await _confirm('删除《${slot.title}》这一局？');
                    if (!ok) return;
                    GenerationController.disposeSlot(slot.id);
                    await SaveService.delete(slot.id);
                    if (_activeSlotId == slot.id) {
                      await PrefsStore.remove(_kActiveSlot);
                      _activeSlotId = null;
                    }
                    await _reload();
                  },
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 数据管理 ----------

  Future<void> _dataManage() async {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.scaffoldBackgroundColor,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.85,
          ),
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '本机数据',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 10),
                      // 数量分开列 —— 回滚备份不是「推演」，
                      // 混在一起会让用户以为凭空多出了几局。
                      Text(
                        '世界书 ${_books.length} 本 · 推演 ${_slots.length} 个'
                        '${_lineCount > _slots.length ? ' · 世界线 $_lineCount 条' : ''}',
                        style: TextStyle(
                          fontSize: 13,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        <String>[
                          if (_blankBooks.isNotEmpty)
                            '${_blankBooks.length} 本世界书是空白的（创建后没填内容就退出）',
                          if (_backups.isNotEmpty)
                            '${_backups.length} 份回滚备份（回滚前自动生成，不计入推演）',
                          if (_blankBooks.isEmpty && _backups.isEmpty)
                            '世界书与存档只保存在本机，不会上传。',
                        ].join('\n'),
                        style: TextStyle(
                            fontSize: 11.5, height: 1.6, color: muted),
                      ),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.file_present_rounded),
                  title: const Text('导出全部世界书为文件（JSON）'),
                  subtitle: Text('共 ${_books.length} 本，保存为单个文件至下载目录'),
                  enabled: _books.isNotEmpty,
                  onTap: () async {
                    Navigator.pop(ctx);
                    final jsonContent = const JsonEncoder.withIndent('  ')
                        .convert(_books.map((b) => b.toJson()).toList());
                    final ts = FileExportService.formatTimestamp();
                    final fileName = '拟境_全部世界书_${_books.length}本_$ts.json';
                    final res = await FileExportService.exportFile(
                      fileName: fileName,
                      content: jsonContent,
                      mimeType: 'application/json',
                    );
                    await Clipboard.setData(ClipboardData(text: jsonContent));
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        duration: const Duration(seconds: 6),
                        content: Text(
                          res.success
                              ? '全部世界书已保存至：${res.path}\n（已同时复制 ${_books.length} 本到剪贴板）'
                              : '保存失败：${res.message}（已复制到剪贴板）',
                        ),
                        action: SnackBarAction(
                          label: '系统分享',
                          onPressed: () => FileExportService.shareText(
                            title: '拟境 · 全部世界书导出',
                            text: jsonContent,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.file_present_rounded),
                  title: const Text('导出全部推演存档为文件（JSON）'),
                  subtitle: Text('共 ${_slots.length} 个存档，保存为单个文件至下载目录'),
                  enabled: _slots.isNotEmpty,
                  onTap: () async {
                    Navigator.pop(ctx);
                    final jsonContent = const JsonEncoder.withIndent('  ')
                        .convert(_slots.map((s) => s.toJson()).toList());
                    final ts = FileExportService.formatTimestamp();
                    final fileName = '拟境_全部推演存档_${_slots.length}个_$ts.json';
                    final res = await FileExportService.exportFile(
                      fileName: fileName,
                      content: jsonContent,
                      mimeType: 'application/json',
                    );
                    await Clipboard.setData(ClipboardData(text: jsonContent));
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        duration: const Duration(seconds: 6),
                        content: Text(
                          res.success
                              ? '全部推演存档已保存至：${res.path}\n（已同时复制 ${_slots.length} 个存档到剪贴板）'
                              : '保存失败：${res.message}（已复制到剪贴板）',
                        ),
                        action: SnackBarAction(
                          label: '系统分享',
                          onPressed: () => FileExportService.shareText(
                            title: '拟境 · 全部推演存档导出',
                            text: jsonContent,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.copy_rounded),
                  title: const Text('复制全部世界书到剪贴板'),
                  enabled: _books.isNotEmpty,
                  onTap: () async {
                    Navigator.pop(ctx);
                    final all = _books
                        .map((b) => b.exportToJson())
                        .join('\n\n=====\n\n');
                    await Clipboard.setData(ClipboardData(text: all));
                    if (mounted) _toast('已复制 ${_books.length} 本世界书');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.copy_rounded),
                  title: const Text('复制全部推演存档到剪贴板'),
                  enabled: _slots.isNotEmpty,
                  onTap: () async {
                    Navigator.pop(ctx);
                    final all = _slots
                        .map((s) => SaveService.exportSlot(s))
                        .join('\n\n=====\n\n');
                    await Clipboard.setData(ClipboardData(text: all));
                    if (mounted) _toast('已复制 ${_slots.length} 个推演存档');
                  },
                ),
                if (_blankBooks.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.cleaning_services_outlined),
                    title: const Text('清理空白世界书'),
                    subtitle: Text('删除 ${_blankBooks.length} 本没填过内容的世界书'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      await _purgeBlankBooks();
                    },
                  ),
                if (_backups.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.cleaning_services_outlined),
                    title: const Text('清理回滚备份'),
                    subtitle: Text('删除 ${_backups.length} 份自动备份，不影响推演进度'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      final ok = await _confirm(
                        '删除 ${_backups.length} 份回滚备份？'
                        '推演进度不受影响，但之后无法再回到回滚前的分支。',
                      );
                      if (!ok) return;
                      final remaining =
                          (await SaveService.loadAll(includeBackups: true))
                              .where((s) => !s.isBackup)
                              .toList();
                      await SaveService.saveAll(remaining);
                      await _reload();
                      if (mounted) _toast('已清理回滚备份');
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.delete_sweep_outlined),
                  title: const Text('清空全部数据'),
                  subtitle: const Text('世界书、存档、备份、API Key 全部删除，不可恢复'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final ok = await _confirm(
                      '确定清空全部数据？世界书、存档、备份与 API Key 都会被删除，无法恢复。',
                    );
                    if (!ok) return;
                    GenerationController.resetAll();
                    await SaveService.saveAll(<SaveSlot>[]);
                    await WorldBookRepository.saveAll(<WorldBook>[]);
                    await PrefsStore.remove(_kActiveSlot);
                    await _reload();
                    if (mounted) _toast('已清空');
                  },
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<bool> _confirm(String message) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(message, style: const TextStyle(fontSize: 14)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- 界面 ----------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : IndexedStack(
                index: _index,
                children: <Widget>[
                  WorldsTab(
                    books: _books,
                    progressByBook: _progressByBook,
                    onCreate: _createBook,
                    onImport: _importBook,
                    onEdit: _editBook,
                    onMenu: _bookMenu,
                    onStartSession: _startSessionWith,
                  ),
                  ContinueTab(
                    slots: _slots,
                    activeSlotId: _activeSlotId,
                    onOpen: _openReader,
                    onMenu: _slotMenu,
                    onNewSession: _newSession,
                  ),
                  ProfileTab(
                    onOpenSection: (section) => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => SettingsScreen(
                          config: widget.config,
                          onConfigChanged: widget.onConfigChanged,
                          section: section,
                        ),
                      ),
                    ),
                    onOpenAbout: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AboutScreen(),
                      ),
                    ),
                    onDataManage: _dataManage,
                    versionLabel: AppInfo.versionLabel,
                    worldCountLabel: '${_books.length} 本世界书',
                    slotCountLabel: '${_slots.length} 个推演',
                  ),
                ],
              ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        backgroundColor: theme.scaffoldBackgroundColor,
        indicatorColor: theme.colorScheme.primary.withValues(alpha: 0.14),
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.public_outlined),
            selectedIcon: Icon(Icons.public),
            label: '世界',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_stories_outlined),
            selectedIcon: Icon(Icons.auto_stories),
            label: '继续',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: '我的',
          ),
        ],
      ),
    );
  }
}
