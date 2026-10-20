import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/glass_tokens.dart';
import '../widgets/feedback.dart';
import '../widgets/glass_button.dart';
import '../widgets/glass_pill.dart';
import '../widgets/glass_surface.dart';

/// 首页输入区：支持粘贴整段分享文案，带「粘贴」「清空」与「开始录制」主按钮。
class RecordComposer extends StatefulWidget {
  const RecordComposer({
    super.key,
    required this.onStart,
    this.activeCount = 0,
    this.maxConcurrent = 6,
  });

  /// 返回 null 表示成功；返回字符串表示错误提示（展示在输入区下方）。
  final Future<String?> Function(String rawText, bool withComments) onStart;

  final int activeCount;
  final int maxConcurrent;

  @override
  State<RecordComposer> createState() => _RecordComposerState();
}

class _RecordComposerState extends State<RecordComposer> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _submitting = false;
  bool _withComments = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  bool get _canStart => _controller.text.trim().isNotEmpty && !_submitting;

  Future<void> _pasteFromClipboard() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String text = data?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) {
      showGlassSnack(context, '剪贴板里没有文本', error: true);
      return;
    }
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
    setState(() => _error = null);
    _focusNode.requestFocus();
    HapticFeedback.selectionClick();
  }

  void _clear() {
    _controller.clear();
    setState(() => _error = null);
    _focusNode.requestFocus();
  }

  Future<void> _submit() async {
    final String raw = _controller.text.trim();
    if (raw.isEmpty || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    String? error;
    try {
      error = await widget.onStart(raw, _withComments);
    } catch (e) {
      error = '开始录制失败：$e';
    }
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _error = error;
    });
    if (error == null) {
      _controller.clear();
      _focusNode.unfocus();
      HapticFeedback.lightImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    final GlassColors c = GlassColors.of(context);
    final bool hasText = _controller.text.trim().isNotEmpty;
    final bool full = widget.activeCount >= widget.maxConcurrent;

    return GlassSurface(
      radius: GlassTokens.radiusLg,
      blur: GlassTokens.blur,
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const GlassBadge(icon: Icons.link_rounded, size: 38, radius: 12),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '粘贴直播链接',
                      style: GlassText.title(c).copyWith(fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '支持整段分享文案，自动识别链接',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GlassText.caption(
                        c,
                        color: c.textTertiary,
                      ).copyWith(fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              if (hasText)
                GlassIconButton(
                  icon: Icons.close_rounded,
                  size: 32,
                  iconSize: 16,
                  color: c.textSecondary,
                  semanticLabel: '清空输入',
                  onPressed: _clear,
                ),
            ],
          ),
          const SizedBox(height: 13),
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            minLines: 2,
            maxLines: 4,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            textAlignVertical: TextAlignVertical.top,
            style: GlassText.body(c).copyWith(fontSize: 13.5, height: 1.55),
            cursorColor: c.accent,
            cursorWidth: 2,
            cursorRadius: const Radius.circular(2),
            smartDashesType: SmartDashesType.disabled,
            smartQuotesType: SmartQuotesType.disabled,
            onChanged: (_) {
              if (_error != null) {
                setState(() => _error = null);
              } else {
                setState(() {});
              }
            },
            decoration: InputDecoration(
              hintText: '粘贴小红书直播分享链接…\n例如 https://xhslink.com/xxxx',
              hintMaxLines: 2,
              hintStyle: GlassText.body(
                c,
                color: c.textTertiary,
              ).copyWith(fontSize: 13, height: 1.5),
              filled: true,
              fillColor: c.fieldFill,
              isDense: true,
              contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(GlassTokens.radiusMd),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(GlassTokens.radiusMd),
                borderSide: BorderSide(color: c.divider),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(GlassTokens.radiusMd),
                borderSide: BorderSide(color: c.accent.withValues(alpha: 0.5)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              GlassTextButton(
                label: '粘贴',
                icon: Icons.content_paste_rounded,
                onPressed: _pasteFromClipboard,
              ),
              const SizedBox(width: 2),
              GlassTextButton(
                label: '清空',
                icon: Icons.backspace_outlined,
                color: c.textSecondary,
                onPressed: hasText ? _clear : null,
              ),
              const Spacer(),
              if (full)
                GlassPill(label: '已达并发上限', color: c.warning, dense: true)
              else if (hasText)
                GlassPill(
                  label: '${_controller.text.trim().length} 字',
                  color: c.textTertiary,
                  dense: true,
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Icon(
                _withComments
                    ? Icons.forum_rounded
                    : Icons.forum_outlined,
                size: 16,
                color: _withComments ? c.accent : c.textTertiary,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '同时录弹幕',
                      style: GlassText.body(c).copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _withComments ? c.textPrimary : c.textSecondary,
                      ),
                    ),
                    Text(
                      '小红书 / 抖音 · 占用内存较高，按需开启',
                      style: GlassText.caption(c, color: c.textTertiary)
                          .copyWith(fontSize: 11),
                    ),
                  ],
                ),
              ),
              Switch.adaptive(
                value: _withComments,
                activeTrackColor: c.accent,
                onChanged: (bool v) {
                  HapticFeedback.selectionClick();
                  setState(() => _withComments = v);
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          GlassButton(
            label: _submitting ? '正在开始…' : '开始录制',
            icon: Icons.videocam_rounded,
            loading: _submitting,
            onPressed: _canStart ? _submit : null,
          ),
          AnimatedSize(
            duration: GlassTokens.medium,
            curve: GlassTokens.easeOut,
            alignment: Alignment.topLeft,
            child: _error == null
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(
                          Icons.error_outline_rounded,
                          size: 15,
                          color: c.danger,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _error!,
                            style: GlassText.caption(
                              c,
                              color: c.danger,
                            ).copyWith(fontSize: 12, height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
