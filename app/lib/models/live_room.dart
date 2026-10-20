/// 直播平台与直播间模型。
library;

enum LivePlatform { xhs, douyin }

extension LivePlatformX on LivePlatform {
  String get key => switch (this) {
        LivePlatform.xhs => 'xhs',
        LivePlatform.douyin => 'douyin',
      };

  String get label => switch (this) {
        LivePlatform.xhs => '小红书',
        LivePlatform.douyin => '抖音',
      };

  static LivePlatform fromKey(String? value) =>
      value == 'douyin' ? LivePlatform.douyin : LivePlatform.xhs;
}

/// 一个可录制的直播间。
class LiveRoom {
  const LiveRoom({
    required this.platform,
    required this.roomId,
    required this.pageUrl,
    required this.rawInput,
    this.title,
    this.anchorName,
    this.webRid,
  });

  /// 平台。
  final LivePlatform platform;

  /// 房间号（小红书为数字房间号，抖音为内部 room_id）。
  final String roomId;

  /// 抖音的 web_rid（`live.douyin.com/<web_rid>` 里的那一段）。
  /// 短链解析后拿到的常是内部 room_id，弹幕页面必须用 web_rid 才能正常渲染。
  final String? webRid;

  /// 归一化后的直播间页面地址（可能带 xsec_token 等参数）。
  final String pageUrl;

  /// 用户原始输入（可能是分享文案）。
  final String rawInput;

  /// 直播间标题（尽力而为，可能为空）。
  final String? title;

  /// 主播昵称（尽力而为，可能为空）。
  final String? anchorName;

  /// 小红书 FLV 直连地址：房间号即可构造，无需签名/登录/浏览器。
  /// 抖音在 [platform] 为 douyin 时返回空串，需要另行解析。
  String get flvUrl => switch (platform) {
        LivePlatform.xhs =>
          'https://live-source-play.xhscdn.com/live/$roomId.flv',
        LivePlatform.douyin => '',
      };

  /// 展示名：优先主播名，其次标题，最后房间号。
  String get displayName {
    final anchor = anchorName?.trim();
    if (anchor != null && anchor.isNotEmpty) return anchor;
    final t = title?.trim();
    if (t != null && t.isNotEmpty) return t;
    return '${platform.label} $roomId';
  }

  LiveRoom copyWith({String? title, String? anchorName}) => LiveRoom(
        platform: platform,
        roomId: roomId,
        pageUrl: pageUrl,
        rawInput: rawInput,
        title: title ?? this.title,
        anchorName: anchorName ?? this.anchorName,
      );

  Map<String, dynamic> toJson() => {
        'platform': platform.key,
        'roomId': roomId,
        'pageUrl': pageUrl,
        'rawInput': rawInput,
        'title': title,
        'anchorName': anchorName,
      };

  static LiveRoom fromJson(Map<String, dynamic> json) => LiveRoom(
        platform: LivePlatformX.fromKey(json['platform'] as String?),
        roomId: '${json['roomId'] ?? ''}',
        pageUrl: '${json['pageUrl'] ?? ''}',
        rawInput: '${json['rawInput'] ?? ''}',
        title: json['title'] as String?,
        anchorName: json['anchorName'] as String?,
      );

  @override
  String toString() => 'LiveRoom(${platform.key}, $roomId, $displayName)';
}

/// 链接解析失败。
class LinkResolveException implements Exception {
  LinkResolveException(this.message);
  final String message;
  @override
  String toString() => message;
}
