import 'dart:convert';
import 'dart:typed_data';

import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/websocket.dart';
import 'package:proxypin/network/util/logger.dart';

/// NDJSON (Newline Delimited JSON) decoder for streaming JSON responses.
/// Handles responses where Content-Type is application/json and
/// Transfer-Encoding is chunked, with each line being a complete JSON object.
class NdjsonDecoder {
  final StringBuffer _lineBuf = StringBuffer();

  /// Feed a chunk of bytes and return zero or more parsed JSON objects.
  List<WebSocketFrame> feed(Uint8List bytes) {
    final List<WebSocketFrame> frames = [];

    // Append decoded text to buffer; allowMalformed to survive split UTF-8 sequences.
    _lineBuf.write(utf8.decode(bytes, allowMalformed: true));

    while (true) {
      final String current = _lineBuf.toString();
      final int nl = current.indexOf('\n');
      if (nl == -1) break;

      String line = current.substring(0, nl);
      _lineBuf.clear();
      if (nl + 1 < current.length) _lineBuf.write(current.substring(nl + 1));

      // Remove trailing \r if present
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);

      // Skip empty lines
      if (line.isEmpty) continue;

      // Try to parse as JSON
      try {
        // Validate it's likely JSON (starts with { or [)
        final trimmed = line.trim();
        if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
          // This is a valid NDJSON line, create a frame
          frames.add(_createFrame(line));
        }
      } catch (e) {
        // If parsing fails, log and skip
        logger.w('[NdjsonDecoder] Failed to parse line: $e');
      }
    }

    return frames;
  }

  WebSocketFrame _createFrame(String jsonLine) {
    final bytes = utf8.encode(jsonLine);
    return WebSocketFrame(
      fin: true,
      opcode: 0x01, // text
      mask: false,
      payloadLength: bytes.length,
      maskingKey: 0,
      payloadData: Uint8List.fromList(bytes),
    );
  }
}

/// NDJSON (Newline Delimited JSON) channel handler for streaming JSON responses.
/// Forwards raw bytes and emits parsed JSON objects as message frames.
class NdjsonChannelHandler extends ChannelHandler<Uint8List> {
  final NdjsonDecoder decoder = NdjsonDecoder();

  final Channel proxyChannel;
  final HttpMessage message; // HttpResponse on server->client, HttpRequest on client->server

  NdjsonChannelHandler(this.proxyChannel, this.message);

  @override
  Future<void> channelRead(ChannelContext channelContext, Channel channel, Uint8List msg) async {
    // Always forward the raw bytes first
    proxyChannel.writeBytes(msg);

    try {
      final frames = decoder.feed(msg);
      for (final WebSocketFrame frame in frames) {
        frame.isFromClient = message is HttpRequest;
        message.addMessage(frame);
        channelContext.listener?.onMessage(channel, message, frame);
        logger.d(
            '[${channelContext.clientChannel?.id}] ndjson channelRead ${frame.payloadLength} ${frame.payloadDataAsString}');
      }
    } catch (e, stackTrace) {
      log.e('ndjson decode error', error: e, stackTrace: stackTrace);
    }
  }
}
