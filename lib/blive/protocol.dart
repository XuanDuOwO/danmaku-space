import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// B站直播弹幕二进制协议：封包 / 解包 / 解压 / 粘包切分
///
/// 报文格式（大端）：
///     offset  长度  含义
///     0       4     整包长度（头部 + 负载）
///     4       2     头部长度（固定 16）
///     6       2     协议版本 ver
///     8       4     操作码 op
///     12      4     序列号（恒为 1）
///
/// 协议版本（接收侧）：0=JSON 明文，1=人气值，2=zlib 压缩，3=brotli 压缩
/// 发送侧版本恒为 1。
///
/// 注意：客户端一律使用 protover=2（zlib）。Dart 标准库自带 zlib 解码，
/// 而 brotli 需额外依赖，使用 2 可省掉一个原生依赖。

const int packetHeaderSize = 16;

const int opHeartbeat = 2;
const int opHeartbeatReply = 3;
const int opMessage = 5;
const int opAuth = 7;
const int opAuthReply = 8;

const int verJson = 0;
const int verPopularity = 1;
const int verZlib = 2;
const int verBrotli = 3;

class Packet {
  final int ver;
  final int op;
  final Uint8List payload;
  const Packet(this.ver, this.op, this.payload);
}

Uint8List encodePacket(int op, List<int> body, {int ver = 1}) {
  final bytes = Uint8List(packetHeaderSize + body.length);
  final view = ByteData.view(bytes.buffer);
  view.setUint32(0, bytes.length, Endian.big);
  view.setUint16(4, packetHeaderSize, Endian.big);
  view.setUint16(6, ver, Endian.big);
  view.setUint32(8, op, Endian.big);
  view.setUint32(12, 1, Endian.big);
  bytes.setRange(packetHeaderSize, bytes.length, body);
  return bytes;
}

/// 构造进入房间的鉴权报文，须在连接建立后 5 秒内发出。
Uint8List encodeAuth({
  required int roomId,
  required String token,
  String buvid = '',
  int uid = 0,
  int protover = 2,
}) {
  final body = utf8.encode(jsonEncode({
    'uid': uid,
    'roomid': roomId,
    'protover': protover,
    'platform': 'web',
    'type': 2,
    'key': token,
    'buvid': buvid,
  }));
  return encodePacket(opAuth, body);
}

/// 心跳报文，每 30 秒一次。
Uint8List encodeHeartbeat() => encodePacket(opHeartbeat, utf8.encode('[object Object]'));

/// 按整包长度切分粘包。残包直接丢弃，等待后续数据补齐。
List<Packet> iterPackets(Uint8List buf) {
  final out = <Packet>[];
  var offset = 0;
  while (buf.length - offset >= packetHeaderSize) {
    final view = ByteData.sublistView(buf, offset);
    final total = view.getUint32(0, Endian.big);
    final hlen = view.getUint16(4, Endian.big);
    if (hlen < packetHeaderSize || total < hlen || offset + total > buf.length) {
      break; // 残包或异常长度，停止切分
    }
    out.add(Packet(
      view.getUint16(6, Endian.big),
      view.getUint32(8, Endian.big),
      Uint8List.sublistView(buf, offset + hlen, offset + total),
    ));
    offset += total;
  }
  return out;
}

/// 展开压缩层，产出最内层报文。op == 5 的负载即为 JSON 明文。
List<Packet> iterMessages(Uint8List buf, {int depth = 0}) {
  final out = <Packet>[];
  if (depth > 4) return out; // 防御异常递归
  for (final p in iterPackets(buf)) {
    if (p.ver == verZlib) {
      try {
        final data = zlib.decode(p.payload);
        out.addAll(iterMessages(Uint8List.fromList(data), depth: depth + 1));
      } catch (_) {
        // 解压失败则跳过该包，避免单包异常打断整条流
      }
      continue;
    }
    out.add(p);
  }
  return out;
}
