import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 文件导出执行结果。
class FileExportResult {
  final bool success;
  final String? path;
  final String message;

  const FileExportResult({
    required this.success,
    this.path,
    required this.message,
  });

  @override
  String toString() =>
      'FileExportResult(success: $success, path: $path, message: $message)';
}

/// 物理文件导出与系统分享服务。
///
/// 支持将推演故事（.md / .txt）、世界书（.json）、推演存档（.json）以物理文件形式
/// 直接保存到公共下载目录（Download/nijing/），并支持系统原生分享与剪贴板兜底。
class FileExportService {
  FileExportService._();

  static const MethodChannel _channel =
      MethodChannel('io.github.makisekurse.nijing/file_export');

  /// 测试自定义导出目录
  @visibleForTesting
  static Directory? testExportDirectory;

  /// 过滤文件名中的非法字符，避免在各种文件系统上报错
  static String sanitizeFileName(String name) {
    var safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), '_').trim();
    safe = safe.replaceAll(RegExp(r'[. ]+$'), '');
    if (safe.isEmpty) safe = '未命名';
    if (safe.length > 50) safe = safe.substring(0, 50);
    return safe;
  }

  /// 格式化时间戳 YYYYMMDD_HHmmss
  static String formatTimestamp([DateTime? date]) {
    final d = date ?? DateTime.now();
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    final h = d.hour.toString().padLeft(2, '0');
    final min = d.minute.toString().padLeft(2, '0');
    final s = d.second.toString().padLeft(2, '0');
    return '$y$m${day}_$h$min$s';
  }

  /// 导出物理文件到公共下载目录。
  ///
  /// 在 Android 上优先通过 MediaStore / 下载目录写入到公共 Download/nijing/；
  /// 在非 Android 或降级场景通过本地文件系统落盘。
  static Future<FileExportResult> exportFile({
    required String fileName,
    required String content,
    String mimeType = 'text/plain',
  }) async {
    final safeName = sanitizeFileName(fileName);

    if (testExportDirectory != null) {
      try {
        final file = File(
            '${testExportDirectory!.path}${Platform.pathSeparator}$safeName');
        await file.writeAsString(content, flush: true);
        return FileExportResult(
          success: true,
          path: file.path,
          message: '文件已保存至：${file.path}',
        );
      } catch (e) {
        return FileExportResult(
          success: false,
          message: '保存文件失败：$e',
        );
      }
    }

    // 1. Android 原生通道尝试
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        final result = await _channel
            .invokeMethod<String>('saveFile', <String, dynamic>{
          'fileName': safeName,
          'content': content,
          'mimeType': mimeType,
        });
        if (result != null && result.isNotEmpty) {
          return FileExportResult(
            success: true,
            path: result,
            message: '文件已保存至：$result',
          );
        }
      } catch (e) {
        debugPrint(
            'FileExportService: MethodChannel saveFile failed: $e, falling back to dart:io');
      }
    }

    // 2. dart:io 本地文件系统回落
    try {
      final file = await _saveWithDartIo(safeName, content);
      return FileExportResult(
        success: true,
        path: file.path,
        message: '文件已保存至：${file.path}',
      );
    } catch (e) {
      return FileExportResult(
        success: false,
        message: '保存文件失败：$e',
      );
    }
  }

  static Future<File> _saveWithDartIo(String fileName, String content) async {
    Directory targetDir;
    if (Platform.isAndroid) {
      final publicDownload = Directory('/storage/emulated/0/Download/nijing');
      if (publicDownload.existsSync() || _canCreateDir(publicDownload)) {
        targetDir = publicDownload;
      } else {
        final fallbackDownload = Directory('/storage/emulated/0/Download');
        if (fallbackDownload.existsSync()) {
          targetDir = fallbackDownload;
        } else {
          targetDir = Directory.systemTemp;
        }
      }
    } else if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null &&
          Directory('$userProfile\\Downloads').existsSync()) {
        targetDir = Directory('$userProfile\\Downloads\\nijing');
      } else {
        targetDir = Directory.systemTemp;
      }
    } else {
      final home = Platform.environment['HOME'];
      if (home != null && Directory('$home/Downloads').existsSync()) {
        targetDir = Directory('$home/Downloads/nijing');
      } else {
        targetDir = Directory.systemTemp;
      }
    }

    if (!targetDir.existsSync()) {
      targetDir.createSync(recursive: true);
    }

    final file = File('${targetDir.path}${Platform.pathSeparator}$fileName');
    await file.writeAsString(content, flush: true);
    return file;
  }

  static bool _canCreateDir(Directory dir) {
    try {
      dir.createSync(recursive: true);
      return dir.existsSync();
    } catch (_) {
      return false;
    }
  }

  /// 调起系统原生分享面板
  static Future<bool> shareText({
    required String title,
    required String text,
  }) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        final ok = await _channel
            .invokeMethod<bool>('shareText', <String, dynamic>{
          'title': title,
          'text': text,
        });
        return ok ?? false;
      } catch (e) {
        debugPrint('FileExportService: shareText failed: $e');
      }
    }
    return false;
  }

  /// 调起系统原生文件分享面板（通过 FileProvider 发送真实物理文件附件，在微信/QQ/邮件等场景下不超限不卡死）
  static Future<bool> shareFile({
    required String filePath,
    required String title,
    String mimeType = 'text/plain',
  }) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        final ok = await _channel
            .invokeMethod<bool>('shareFile', <String, dynamic>{
          'filePath': filePath,
          'title': title,
          'mimeType': mimeType,
        });
        return ok ?? false;
      } catch (e) {
        debugPrint('FileExportService: shareFile failed: $e');
      }
    }
    return false;
  }
}
