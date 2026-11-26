import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

/// 应用级统一轻量提示（优先走 `forui` 原生 [FToaster] / [showFToast]，完全不依赖 Material [Scaffold]）。
class AppToast {
  AppToast._();

  static void show(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 4),
  }) {
    if (message.trim().isEmpty) return;

    final toaster = context.findAncestorStateOfType<FToasterState>();
    if (toaster != null) {
      showFToast(
        context: context,
        title: Text(message),
        duration: duration,
        suffixBuilder: (actionLabel != null && onAction != null)
            ? (ctx, entry) => FButton(
                  variant: FButtonVariant.outline,
                  size: FButtonSizeVariant.xs,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () {
                    entry.dismiss();
                    onAction();
                  },
                  child: Text(actionLabel),
                )
            : null,
      );
      return;
    }

    // 兜底：仅在树中同时存在 Scaffold 与 ScaffoldMessenger 时退回 SnackBar，避免孤立组件单测抛断言错。
    final messenger = ScaffoldMessenger.maybeOf(context);
    final hasScaffold = Scaffold.maybeOf(context) != null;
    if (messenger != null && hasScaffold) {
      messenger.showSnackBar(
        SnackBar(
          duration: duration,
          content: Text(message),
          action: (actionLabel != null && onAction != null)
              ? SnackBarAction(label: actionLabel, onPressed: onAction)
              : null,
        ),
      );
    }
  }
}
