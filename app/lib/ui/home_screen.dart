import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/record_task.dart';
import '../services/local_server.dart';
import '../services/recording_manager.dart';
import 'preview/live_preview_page.dart';

/// 首页占位实现。UI 子代理负责整体重写（液态玻璃风格）。
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<RecordingManager>();
    final server = context.read<LocalStreamServer>();
    return Scaffold(
      appBar: AppBar(title: const Text('直播录制')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('任务数：${manager.tasks.length}'),
          for (final t in manager.tasks)
            ListTile(
              title: Text(t.title),
              subtitle: Text('${t.state.label} · ${t.segmentCount} 段'),
              trailing: t.isActive
                  ? IconButton(
                      icon: const Icon(Icons.stop),
                      onPressed: () => manager.stopTask(t.id),
                    )
                  : IconButton(
                      icon: const Icon(Icons.play_arrow),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => LivePreviewPage(
                            title: t.title,
                            url: server.playerUrlForLive(t.id),
                          ),
                        ),
                      ),
                    ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await manager.startTask(
            'https://www.xiaohongshu.com/livestream/570501740524334550',
          );
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}
