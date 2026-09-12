import 'package:flutter/material.dart';

import 'anim.dart';
import 'store.dart';

/// 收藏批量管理页：集中管理「爱播 / 技播」名单，不占用弹幕区域。
/// - 点某一行：选中该直播间（返回其房间号，由弹幕页切换连接）
/// - 右侧「×」：删除单条
/// - 右上角多选：批量删除 / 批量切换分类
class ManagePage extends StatefulWidget {
  const ManagePage({super.key, this.initialType = 'love'});

  /// 初始分类：'love' | 'tech'
  final String initialType;

  @override
  State<ManagePage> createState() => _ManagePageState();
}

class _ManagePageState extends State<ManagePage>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  List<FavRoom> _favs = [];
  bool _loading = true;

  /// 多选模式
  bool _selecting = false;
  final Set<int> _selected = {};

  static const _loveColor = Color(0xFFF85149);
  static const _techColor = Color(0xFFE3B341);

  @override
  void initState() {
    super.initState();
    _tab = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialType == 'tech' ? 1 : 0,
    );
    _tab.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final list = await Store.loadFavorites();
    if (!mounted) return;
    setState(() {
      _favs = list;
      _loading = false;
    });
  }

  Future<void> _persist() async {
    await Store.saveFavorites(_favs);
  }

  List<FavRoom> get _loveFavs => _favs.where((f) => f.type == 'love').toList();
  List<FavRoom> get _techFavs => _favs.where((f) => f.type == 'tech').toList();

  Future<void> _removeOne(FavRoom f) async {
    setState(() {
      _favs.removeWhere((e) => e.roomId == f.roomId);
      _selected.remove(f.roomId);
    });
    await _persist();
  }

  Future<void> _removeSelected() async {
    final n = _selected.length;
    if (n == 0) return;
    setState(() {
      _favs.removeWhere((e) => _selected.contains(e.roomId));
      _selected.clear();
      _selecting = false;
    });
    await _persist();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已删除 $n 个收藏')));
    }
  }

  /// 把选中项整体切到另一分类（爱播 <-> 技播）。
  Future<void> _switchSelectedType(String target) async {
    if (_selected.isEmpty) return;
    setState(() {
      _favs = _favs
          .map((f) => _selected.contains(f.roomId)
              ? FavRoom(
                  roomId: f.roomId, name: f.name, face: f.face, type: target)
              : f)
          .toList();
      _selected.clear();
      _selecting = false;
    });
    await _persist();
  }

  Future<void> _switchOne(FavRoom f) async {
    final target = f.type == 'love' ? 'tech' : 'love';
    setState(() {
      _favs = _favs
          .map((e) => e.roomId == f.roomId
              ? FavRoom(roomId: e.roomId, name: e.name, face: e.face, type: target)
              : e)
          .toList();
    });
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isLove = _tab.index == 0;
    final accent = isLove ? _loveColor : _techColor;
    final list = isLove ? _loveFavs : _techFavs;

    return Scaffold(
      appBar: AppBar(
        title: const Text('收藏管理', style: TextStyle(fontSize: 16)),
        actions: [
          if (_selecting) ...[
            IconButton(
              tooltip: '全选',
              icon: const Icon(Icons.select_all),
              onPressed: () => setState(() {
                _selected
                  ..clear()
                  ..addAll(list.map((e) => e.roomId));
              }),
            ),
            IconButton(
              tooltip: '删除所选',
              icon: const Icon(Icons.delete_outline),
              onPressed: _selected.isEmpty ? null : _removeSelected,
            ),
            PopupMenuButton<String>(
              tooltip: '批量改分类',
              onSelected: (v) => _switchSelectedType(v),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'love', child: Text('标为爱播')),
                PopupMenuItem(value: 'tech', child: Text('标为技播')),
              ],
            ),
          ],
          TextButton(
            onPressed: () => setState(() {
              _selecting = !_selecting;
              _selected.clear();
            }),
            child: Text(_selecting ? '取消' : '多选'),
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          tabs: [
            Tab(text: '爱播 ${_loveFavs.length}'),
            Tab(text: '技播 ${_techFavs.length}'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tab,
              children: [
                _listView(cs, _loveFavs, _loveColor),
                _listView(cs, _techFavs, _techColor),
              ],
            ),
      floatingActionButton: _selecting && _selected.isNotEmpty
          ? FloatingActionButton.extended(
              backgroundColor: accent,
              onPressed: _removeSelected,
              icon: const Icon(Icons.delete),
              label: Text('删除 ${_selected.length} 项'),
            )
          : null,
    );
  }

  Widget _listView(ColorScheme cs, List<FavRoom> list, Color color) {
    if (list.isEmpty) {
      return Center(
        child: Text(
          '暂无收藏\n在弹幕页点红心 / 闪电即可加入',
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13, height: 1.8),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 84),
      itemCount: list.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 68),
      itemBuilder: (_, i) {
        final f = list[i];
        final checked = _selected.contains(f.roomId);
        return StaggerIn(
          index: i > 3 ? 4 : i,
          child: ListTile(
          leading: _avatar(f, color),
          title: Text(f.name.isNotEmpty ? f.name : '${f.roomId}',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${f.roomId}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF6E7681))),
          trailing: _selecting
              ? Checkbox(
                  value: checked,
                  activeColor: color,
                  onChanged: (_) => setState(() {
                    if (checked) {
                      _selected.remove(f.roomId);
                    } else {
                      _selected.add(f.roomId);
                    }
                  }),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: f.type == 'love' ? '标为技播' : '标为爱播',
                      icon: Icon(
                        f.type == 'love' ? Icons.favorite : Icons.bolt,
                        size: 18,
                        color: color,
                      ),
                      onPressed: () => _switchOne(f),
                    ),
                    IconButton(
                      tooltip: '删除',
                      icon: const Icon(Icons.close, size: 18),
                      color: cs.onSurfaceVariant,
                      onPressed: () => _removeOne(f),
                    ),
                  ],
                ),
          onTap: () {
            if (_selecting) {
              setState(() {
                if (checked) {
                  _selected.remove(f.roomId);
                } else {
                  _selected.add(f.roomId);
                }
              });
            } else {
              Navigator.of(context).pop(f.roomId);
            }
          },
        ),
        );
      },
    );
  }

  Widget _avatar(FavRoom f, Color color) {
    return CircleAvatar(
      radius: 20,
      backgroundColor: const Color(0xFF1B2129),
      backgroundImage: f.face.isNotEmpty ? NetworkImage(f.face) : null,
      onBackgroundImageError: (_, __) {},
      child: f.face.isEmpty
          ? Text(
              f.name.isNotEmpty ? f.name.characters.first : '${f.roomId}',
              style: const TextStyle(fontSize: 14),
            )
          : null,
    );
  }
}
