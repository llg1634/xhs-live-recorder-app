import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/glass_tokens.dart';

/// 统一的玻璃风格提示条。
void showGlassSnack(
  BuildContext context,
  String message, {
  bool error = false,
}) {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final GlassColors c = GlassColors.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      duration: Duration(milliseconds: error ? 3200 : 2200),
      content: Row(
        children: <Widget>[
          Icon(
            error
                ? Icons.error_outline_rounded
                : Icons.check_circle_outline_rounded,
            size: 18,
            color: error ? c.danger : c.success,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: GlassText.body(
                c,
                color: Colors.white,
              ).copyWith(fontSize: 13.5, height: 1.35),
            ),
          ),
        ],
      ),
    ),
  );
}

/// 复制文本并提示。
Future<void> copyToClipboard(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    showGlassSnack(context, '已复制到剪贴板');
  }
}
