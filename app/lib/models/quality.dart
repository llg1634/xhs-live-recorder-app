/// 录制画质偏好。
enum RecordQuality {
  /// 最高画质：抖音取 `_uhd`/`_or4`（原画），小红书取无后缀直链（实测 1080P）。
  highest('最高画质', '原画/1080P，流量最大'),

  /// 平台默认画质：抖音取 `_hd`（720P），小红书取 `_hcv5401`（540P，失败回退默认）。
  standard('默认画质', '720P/540P，更省流量');

  const RecordQuality(this.label, this.description);

  final String label;
  final String description;
}
