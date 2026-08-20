import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

import 'package:es_compression/brotli.dart';
import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/channel/channel_dispatcher.dart';
import 'package:proxypin/network/handle/relay_handle.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/sse.dart';
import 'package:proxypin/network/http/websocket.dart';
import 'package:proxypin/network/util/logger.dart';

/// SSE (text/event-stream) handler: forwards raw bytes and emits parsed message frames.
class SseChannelHandler extends ChannelHandler<Uint8List> {
  final SseDecoder decoder = SseDecoder();

  final Channel proxyChannel;
  final HttpMessage message; // HttpResponse on server->client, HttpRequest on client->server

  // Track if response uses chunked encoding and brotli compression
  late final bool _isChunked;
  late final bool _isBrotli;

  // 流式 Brotli 解码器（es_compression 库支持真正的流式解压）
  BrotliDecoder? _brotliDecoder;
  ByteConversionSink? _brotliSink;
  final List<int> _brotliOutput = [];
  // Accumulated decompressed data waiting to be fed to SSE decoder
  final BytesBuilder _decompressedAccumulated = BytesBuilder();

  // 保存 channel (服务端连接) 和 remoteChannel (客户端连接) 的原始 dispatcher 状态
  // SSE 流结束后需要恢复，让后续 keep-alive 请求能正常被解析和添加到请求列表
  // 使用 dynamic 类型避免导入额外的 codec 模块
  final dynamic _channelOriginalDecoder;
  final dynamic _channelOriginalEncoder;
  final ChannelHandler? _channelOriginalHandler;
  final dynamic _remoteChannelOriginalDecoder;
  final dynamic _remoteChannelOriginalEncoder;
  final ChannelHandler? _remoteChannelOriginalHandler;

  SseChannelHandler(this.proxyChannel, this.message,
      [this._channelOriginalDecoder,
       this._channelOriginalEncoder,
       this._channelOriginalHandler,
       this._remoteChannelOriginalDecoder,
       this._remoteChannelOriginalEncoder,
       this._remoteChannelOriginalHandler]) {
    _isChunked = message.headers.isChunked ||
        message.headers.contentType.toLowerCase().contains('text/event-stream');
    _isBrotli = message.headers.contentEncoding == 'br';

    // 初始化流式 Brotli 解码器
    if (_isBrotli) {
      _brotliDecoder = BrotliDecoder();
      _brotliSink = _brotliDecoder!.startChunkedConversion(_BrotliOutputSink(_brotliOutput));
      logger.d("[SseChannelHandler] Using es_compression BrotliDecoder for streaming decompression");
    }

    logger.d("[SseChannelHandler] init: isChunked=$_isChunked isBrotli=$_isBrotli");
    logger.d("[SseChannelHandler] transferEncoding=${message.headers.get('Transfer-Encoding')} contentEncoding=${message.headers.contentEncoding}");
    logger.d("[SseChannelHandler] headers: ${message.headers.headerLines()}");
  }

  @override
  Future<void> channelRead(ChannelContext channelContext, Channel channel, Uint8List msg) async {
    logger.d("[SseChannelHandler] channelRead called with ${msg.length} bytes, chunked=$_isChunked brotli=$_isBrotli");

    // 关键修复：检测 chunked 结束标记 "0\r\n\r\n"
    // 如果检测到，立即恢复 channel.dispatcher 到原始状态
    // 否则后续请求的响应会被错误地作为 SSE 流处理
    bool isChunkedEnd = _isChunkedEndMarker(msg);
    if (isChunkedEnd) {
      logger.d("[SseChannelHandler] detected chunked end marker (0\\r\\n\\r\\n) in ${msg.length} bytes");
      // 转发原始字节到客户端
      proxyChannel.writeBytes(msg);
      // 恢复 channel.dispatcher 到原始状态，并重置 codec 状态
      // 这是关键修复：SSE 流期间 codec 的 _state 保持 State.body，
      // 必须重置为 State.readInitial，否则下一个响应的 headers 会被错误处理
      _restoreDispatcher(channel);
      return;
    }
    // IMPORTANT: Forward ORIGINAL chunked-encoded data to client FIRST
    // because client expects chunked-encoded data (HTTP headers contain Transfer-Encoding: chunked)
    proxyChannel.writeBytes(msg);

    Uint8List dataToDecode = msg;

    // Detect chunked encoding: data starts with hex digits followed by \r\n
    bool looksLikeChunked = _isChunked || _looksLikeChunkedData(msg);
    if (looksLikeChunked) {
      Uint8List chunkDecoded = _decodeChunked(msg);
      if (chunkDecoded.isNotEmpty) {
        dataToDecode = chunkDecoded;
        logger.d("[SseChannelHandler] After chunked decode: ${dataToDecode.length} bytes from ${msg.length}");
      }
    }

    // If brotli compressed, decompress using streaming decoder
    if (_isBrotli && _brotliSink != null) {
      // 使用 es_compression 的流式解码器实时解压
      _brotliSink!.add(dataToDecode);

      // 处理已解码的数据
      if (_brotliOutput.isNotEmpty) {
        final decoded = Uint8List.fromList(_brotliOutput);
        _brotliOutput.clear();
        logger.d("[SseChannelHandler] es_compression Brotli decoded: ${decoded.length} bytes");
        _processDecompressedData(channelContext, channel, decoded);
      }
    }
    // 更新 message body
    // 性能修复：对于 Brotli 压缩的 SSE 响应，channelRead 中收到的是 Brotli 编码字节，
    // 不应该直接写入 message.body（否则 getBodyString 会重复同步 brDecode，阻塞主线程）
    // 正确的做法：message.body 只存解压后的明文，由 _processDecompressedData 负责
    // 对于非 Brotli 响应，dataToDecode 已经是 chunked-decoded 明文，可以直接写入
    if (!_isBrotli && message is HttpResponse) {
      if (message.body == null) {
        message.body = dataToDecode.toList();
      } else {
        List<int> existing = List<int>.from(message.body!);
        existing.addAll(dataToDecode);
        message.body = existing;
      }
    }
    // For brotli, SSE decoding is handled in _processDecompressedData
    if (!_isBrotli) {
      _decodeSseAndNotify(channelContext, channel, dataToDecode);
    }
  }

  /// 处理解压后的数据
  void _processDecompressedData(ChannelContext channelContext, Channel channel, Uint8List decompressedData) {
    // 累积解压后的数据（用于 SSE 解码）
    _decompressedAccumulated.add(decompressedData);

    // 更新 message body
    if (message is HttpResponse) {
      if (message.body == null) {
        message.body = decompressedData.toList();
      } else {
        List<int> existing = List<int>.from(message.body!);
        existing.addAll(decompressedData);
        message.body = existing;
      }
    }

    // 处理 SSE 消息
    _processDecompressed(channelContext, channel);
  }

  void _processDecompressed(ChannelContext channelContext, Channel channel) {
    if (_decompressedAccumulated.isEmpty) {
      logger.d("[SseChannelHandler] _processDecompressed: _decompressedAccumulated is empty, returning");
      return;
    }
    Uint8List data = _decompressedAccumulated.toBytes();
    _decompressedAccumulated.clear();
    logger.d("[SseChannelHandler] _processDecompressed: processing ${data.length} bytes, calling _decodeSseAndNotify");

    _decodeSseAndNotify(channelContext, channel, data);
  }

  void _decodeSseAndNotify(ChannelContext channelContext, Channel channel, Uint8List data) {
    try {
      final frames = decoder.feed(data);
      logger.d("[SseChannelHandler] _decodeSseAndNotify: decoded ${frames.length} frames from ${data.length} bytes");
      if (frames.isNotEmpty) {
        for (final WebSocketFrame frame in frames) {
          frame.isFromClient = message is HttpRequest;
        }
        // 批量添加，只触发一次 UI 更新
        message.addMessages(frames);
        // 通知每个帧（直接调用，Dart单线程保证在主线程执行）
        for (final WebSocketFrame frame in frames) {
          channelContext.listener?.onMessage(channel, message, frame);
        }
      }
    } catch (e, stackTrace) {
      log.e("sse decode error", error: e, stackTrace: stackTrace);
    }
  }

  @override
  void channelInactive(ChannelContext channelContext, Channel channel) async {
    logger.d("[SseChannelHandler] channelInactive");

    // 关闭 Brotli 流式解码器，刷新剩余数据
    if (_isBrotli && _brotliSink != null) {
      _brotliSink!.close();

      // 处理剩余输出
      if (_brotliOutput.isNotEmpty) {
        final decoded = Uint8List.fromList(_brotliOutput);
        _brotliOutput.clear();
        logger.d("[SseChannelHandler] es_compression Brotli final flush: ${decoded.length} bytes");
        _processDecompressedData(channelContext, channel, decoded);
      }
    }

    // 不关闭 proxyChannel，保持 keep-alive 连接
    // HttpResponseProxyHandler.channelInactive 会处理 clientChannel 关闭
  }

  /// 恢复 channel (服务端连接) 和 remoteChannel (客户端连接) 的 dispatcher 到原始状态
  /// 这是 SSE 流结束后必须做的关键修复：
  /// - channel 恢复为 HttpClientCodec + HttpResponseProxyHandler (能解析 HTTP 响应)
  /// - remoteChannel 恢复为 HttpRequestCodec + HttpResponseCodec + HttpProxyChannelHandler
  ///   (能解析 HTTP 请求，触发 onRequest 事件，请求列表就会显示)
  /// 同时重置 codec 状态：SSE 流期间 codec 的 _state 一直保持 State.body，
  /// 必须重置为 State.readInitial，否则下一个响应的 headers 会被错误处理
  void _restoreDispatcher(Channel channel) {
    // 恢复 channel (服务端连接) 的原始状态
    if (_channelOriginalDecoder != null && _channelOriginalEncoder != null && _channelOriginalHandler != null) {
      channel.dispatcher.handle(_channelOriginalDecoder!, _channelOriginalEncoder!, _channelOriginalHandler!);
      // 重置 codec 状态：SSE 流期间 codec 的 _state 一直保持 State.body，
      // 必须重置为 State.readInitial。这是最关键的修复！
      _resetCodecState(_channelOriginalDecoder!);
      logger.d("[SseChannelHandler] restored channel.dispatcher to original state "
          "(decoder=${_channelOriginalDecoder.runtimeType} handler=${_channelOriginalHandler.runtimeType})");
    }
    // 恢复 remoteChannel (客户端连接) 的原始状态
    if (_remoteChannelOriginalDecoder != null && _remoteChannelOriginalEncoder != null && _remoteChannelOriginalHandler != null) {
      proxyChannel.dispatcher.handle(_remoteChannelOriginalDecoder!, _remoteChannelOriginalEncoder!, _remoteChannelOriginalHandler!);
      // 重置 codec 状态
      _resetCodecState(_remoteChannelOriginalDecoder!);
      logger.d("[SseChannelHandler] restored proxyChannel.dispatcher to original state "
          "(decoder=${_remoteChannelOriginalDecoder.runtimeType} handler=${_remoteChannelOriginalHandler.runtimeType})");
    }
  }

  /// 重置 codec 状态，让 codec 准备好解析新消息
  /// 这是关键的修复：HttpCodec 在 SSE 流期间 _state 保持 State.body，
  /// 必须重置为 State.readInitial，否则下一个响应的 headers 会被错误处理
  void _resetCodecState(dynamic codec) {
    if (codec == null) return;
    try {
      // 调用 codec 的 init() 方法重置状态
      final initMethod = codec.runtimeType.toString();
      // 通过反射调用 init 方法
      final dynamic result = (codec as dynamic).init?.call();
      logger.d("[SseChannelHandler] reset codec state for $initMethod, result=$result");
    } catch (e) {
      logger.w("[SseChannelHandler] reset codec state error: $e");
    }
  }

  /// 检测 chunked transfer encoding 结束标记 "0\r\n\r\n"
  /// 当 SSE 流结束（chunked 编码完成）时，标记会出现
  bool _isChunkedEndMarker(Uint8List data) {
    // 查找 "0\r\n\r\n" 模式 (5 字节)
    for (int i = 0; i <= data.length - 5; i++) {
      if (data[i] == 0x30 && // '0'
          data[i + 1] == 0x0d && // \r
          data[i + 2] == 0x0a && // \n
          data[i + 3] == 0x0d && // \r
          data[i + 4] == 0x0a) // \n
      {
        return true;
      }
    }
    return false;
  }

  /// Heuristic: data starts with hex digits followed by \r\n
  bool _looksLikeChunkedData(Uint8List data) {
    if (data.length < 5) return false;
    // Find first \r\n
    int crlfIdx = -1;
    for (int i = 0; i < data.length - 1 && i < 20; i++) {
      if (data[i] == 13 && data[i + 1] == 10) {
        crlfIdx = i;
        break;
      }
    }
    if (crlfIdx == -1 || crlfIdx == 0) return false;

    // Check if chars before \r\n are valid hex digits
    for (int i = 0; i < crlfIdx; i++) {
      int c = data[i];
      if (!((c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102))) {
        return false;
      }
    }
    return true;
  }

  /// Decode chunked transfer encoding
  Uint8List _decodeChunked(Uint8List msg) {
    final result = BytesBuilder();
    int offset = 0;

    while (offset < msg.length) {
      // Find chunk size line end (\r\n)
      int lineEnd = -1;
      for (int i = offset; i < msg.length - 1; i++) {
        if (msg[i] == 13 && msg[i + 1] == 10) {
          lineEnd = i;
          break;
        }
      }

      if (lineEnd == -1 || lineEnd == offset) {
        break; // Incomplete chunk or empty line
      }

      // Parse chunk size (hex)
      String sizeHex = utf8.decode(msg.sublist(offset, lineEnd));
      int? chunkSize = int.tryParse(sizeHex, radix: 16);
      if (chunkSize == null) {
        break;
      }

      if (chunkSize == 0) {
        // End of chunked encoding
        return result.toBytes();
      }

      int dataStart = lineEnd + 2;
      int dataEnd = dataStart + chunkSize;
      if (dataEnd + 2 > msg.length) {
        break; // Not enough data
      }

      result.add(msg.sublist(dataStart, dataEnd));
      offset = dataEnd + 2;
    }

    return result.toBytes();
  }
}

/// Brotli 输出收集器
class _BrotliOutputSink implements Sink<List<int>> {
  final List<int> output;

  _BrotliOutputSink(this.output);

  @override
  void add(List<int> data) {
    output.addAll(data);
  }

  @override
  void close() {
    // nothing to do
  }
}
