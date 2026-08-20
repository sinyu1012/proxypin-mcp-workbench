/*
 * Copyright 2023 Hongen Wang All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:proxypin/native/process_info.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/channel/channel_dispatcher.dart';
import 'package:proxypin/network/components/host_filter.dart';
import 'package:proxypin/network/handle/relay_handle.dart';
import 'package:proxypin/network/socks/socks5.dart';
import 'package:proxypin/network/util/attribute_keys.dart';
import 'package:proxypin/network/util/crts.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/network/util/process_info.dart';
import 'package:proxypin/network/util/tls.dart';

import '../bin/listener.dart';
import 'host_port.dart';

abstract class Network {
  late Function _channelInitializer;

  Network initChannel(void Function(Channel channel) initializer) {
    _channelInitializer = initializer;
    return this;
  }

  Channel listen(Channel channel, ChannelContext channelContext) {
    _channelInitializer.call(channel);
    channel.dispatcher.channelActive(channelContext, channel);

    channel.socket.listen((data) => onEvent(data, channelContext, channel),
        onError: (error, StackTrace trace) =>
            channel.dispatcher.exceptionCaught(channelContext, channel, error, trace: trace),
        onDone: () => channel.dispatcher.channelInactive(channelContext, channel));

    channel.socket.done.onError((error, StackTrace trace) {
      logger.e('[${channelContext.clientChannel?.id}] socket done error', error: error, stackTrace: trace);
      channel.dispatcher.exceptionCaught(channelContext, channel, error, trace: trace);
    });
    return channel;
  }

  Future<void> onEvent(Uint8List data, ChannelContext channelContext, Channel channel);

  /// 转发请求
  void relay(Channel clientChannel, Channel remoteChannel) {
    var rawCodec = RawCodec();
    clientChannel.dispatcher.channelHandle(rawCodec, RelayHandler(remoteChannel));
    remoteChannel.dispatcher.channelHandle(rawCodec, RelayHandler(clientChannel));
  }
}

class Server extends Network {
  Configuration configuration;

  late ServerSocket serverSocket;
  bool isRunning = false;
  EventListener? listener;
  StreamSubscription? serverSubscription;
  final List<Channel> _connections = [];
  Timer? _connectionCleanupTimer;

  Server(this.configuration, {this.listener});

  Future<ServerSocket> bind(int port) async {
    serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    serverSubscription = serverSocket.listen((socket) {
      var channel = Channel(socket);
      _connections.add(channel);

      socket.done.whenComplete(() => _connections.remove(channel));

      ChannelContext channelContext = ChannelContext();
      channelContext.clientChannel = channel;
      channelContext.listener = listener;
      listen(channel, channelContext);
    });
    isRunning = true;
    _connectionCleanupTimer = Timer.periodic(const Duration(seconds: 120), (timer) {
      if (!isRunning) {
        timer.cancel();
        _connectionCleanupTimer = null;
        return;
      }
      cleanupConnections();
    });
    return serverSocket;
  }

  Future<ServerSocket> stop() async {
    if (!isRunning) return serverSocket;
    isRunning = false;
    for (var channel in _connections) {
      if (channel.isClosed) continue;
      try {
        logger.d('Closing socket: ${channel.remoteSocketAddress.host}:${channel.remoteSocketAddress.port}');
        channel.close();
      } catch (e) {
        logger.e('Error closing socket: $e');
      }
    }
    _connections.clear();
    //关闭监听
    serverSubscription?.cancel();
    serverSubscription = null;
    await serverSocket.close();
    _connectionCleanupTimer?.cancel();
    _connectionCleanupTimer = null;
    return serverSocket;
  }

  void cleanupConnections() {
    _connections.removeWhere((channel) {
      if (channel.isClosed) {
        logger.i('Cleaning up closed channel: ${channel.remoteSocketAddress.host}:${channel.remoteSocketAddress.port}');
        return true;
      }
      return false;
    });
  }

  @override
  Future<void> onEvent(Uint8List data, ChannelContext channelContext, Channel channel) async {
    logger.d('[SSL-DEBUG] onEvent entry: channelId=${channel.id} dataLen=${data.length} '
      'firstBytesHex=${data.length >= 8 ? data.sublist(0, 8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ') : 'short'}');
    //手机扫码转发远程地址
    if (configuration.remoteHost != null) {
      channelContext.putAttribute(AttributeKeys.remote, HostAndPort.of(configuration.remoteHost!));
    }

    //外部代理信息
    if (configuration.externalProxy?.enabled == true) {
      ProxyInfo externalProxy = configuration.externalProxy!;
      channelContext.putAttribute(AttributeKeys.proxyInfo, externalProxy);

      if (externalProxy.capturePacket == false) {
        //不抓包直接转发
        channelContext.putAttribute(AttributeKeys.remote, HostAndPort.host(externalProxy.host, externalProxy.port!));
      }
    }

    HostAndPort? hostAndPort = channelContext.host;

    //黑名单 或 没开启https 直接转发
    if ((HostFilter.filter(hostAndPort?.host)) || (hostAndPort?.isSsl() == true && configuration.enableSsl == false)) {
      logger.d('[SSL-DEBUG] onEvent: short-circuit (host filter or enableSsl=false), relay path');
      var remoteChannel = channelContext.serverChannel ??
          await channelContext.connectServerChannel(hostAndPort!, RelayHandler(channel));
      relay(channel, remoteChannel);
      channel.dispatcher.channelRead(channelContext, channel, data);
      return;
    }

    //ssl握手
    if (hostAndPort?.isSsl() == true || TLS.isTLSClientHello(data)) {
      logger.d('[SSL-DEBUG] onEvent: detected TLS ClientHello or ssl-host, entering ssl() handler');
      ssl(channelContext, channel, data);
      return;
    }

    //socks5
    if (configuration.enableSocks5 && Socks5.isSocks5(data) && channel.dispatcher.handler is! SocksServerHandler) {
      logger.d('[SSL-DEBUG] onEvent: detected SOCKS5 handshake, switching to SocksServerHandler');
      channel.dispatcher.channelHandle(RawCodec(),
          SocksServerHandler(channel.dispatcher.decoder, channel.dispatcher.encoder, channel.dispatcher.handler));
    }

    channel.dispatcher.channelRead(channelContext, channel, data);
  }

  /// ssl握手
  void ssl(ChannelContext channelContext, Channel channel, Uint8List data) async {
    var hostAndPort = channelContext.host;
    logger.d('[SSL-DEBUG] ssl() entry: channelId=${channel.id} '
        'hasHostAndPort=${hostAndPort != null} enableSsl=${configuration.enableSsl} '
        'clientHelloLen=${data.length}');
    try {
      String? serviceName = TLS.getDomain(data) ?? hostAndPort?.host;
      logger.d('[SSL-DEBUG] ssl() resolved serviceName="$serviceName" via '
        'TLS.getDomain=${TLS.getDomain(data) != null ? "yes" : "no"} '
        'or hostAndPort.host=${hostAndPort?.host}');
      bool isHttp = true;

      if (hostAndPort == null) {
        var domain = serviceName;
        var port = 443;

        if (domain == null) {
          logger.d('[SSL-DEBUG] ssl() domain is null, fetching remote address by port=${channel.remoteSocketAddress.port}');
          var remote = await ProcessInfoPlugin.getRemoteAddressByPort(channel.remoteSocketAddress.port);
          domain = remote?.host;
          port = remote?.port ?? port;
          serviceName = domain;
          logger.d('[SSL-DEBUG] ssl() remote lookup: domain="$domain" port=$port');

          // DNS over HTTPS
          if (remote?.port == 853 && TLS.supportProtocols(data)?.contains("http/1.1") == false) {
            isHttp = false;
          }
        }

        if (domain == null) {
          logger.e('[SSL-DEBUG] ssl() ABORT: domain is null, cannot build hostAndPort');
          channelContext.host ??= HostAndPort.host('unknown', 443, scheme: HostAndPort.httpsScheme);
          return;
        }
        hostAndPort = HostAndPort.host(domain!, port, scheme: HostAndPort.httpsScheme);
      }

      hostAndPort.scheme = HostAndPort.httpsScheme;
      channelContext.putAttribute(AttributeKeys.domain, hostAndPort.host);

      Channel? remoteChannel = channelContext.serverChannel;
      logger.d('[SSL-DEBUG] ssl() hostAndPort=${hostAndPort.host}:${hostAndPort.port} '
        'remoteChannel=${remoteChannel != null ? "exists isSsl=${remoteChannel.isSsl}" : "null"} '
        'isHttp=$isHttp enableSsl=${configuration.enableSsl} '
        'inHostFilter=${HostFilter.filter(hostAndPort.host)}');
      if (!isHttp || HostFilter.filter(hostAndPort.host) || !configuration.enableSsl) {
        remoteChannel = remoteChannel ?? await channelContext.connectServerChannel(hostAndPort, RelayHandler(channel));
        relay(channel, remoteChannel);
        channel.dispatcher.channelRead(channelContext, channel, data);
        return;
      }

      if (remoteChannel != null && !remoteChannel.isSsl) {
        var supportProtocols = configuration.enabledHttp2 ? TLS.supportProtocols(data) : ['http/1.1'];
        logger.d('[SSL-DEBUG] ssl() starting upstream TLS to ${hostAndPort.host}:${hostAndPort.port} '
          'alpn=${supportProtocols}');
        await remoteChannel.startSecureSocket(channelContext, host: serviceName, supportedProtocols: supportProtocols);
        logger.d('[SSL-DEBUG] ssl() upstream TLS connected, remoteChannel.isSsl=${remoteChannel.isSsl} '
          'selectedProtocol=${remoteChannel.selectedProtocol}');
      } else if (remoteChannel != null && remoteChannel.isSsl) {
        logger.d('[SSL-DEBUG] ssl() remoteChannel already SSL, selectedProtocol=${remoteChannel.selectedProtocol}');
      }

      //ssl自签证书
      logger.d('[SSL-DEBUG] ssl() requesting leaf cert for serviceName="$serviceName"');
      var certificate = await CertificateManager.getCertificateContext(serviceName!);
      var selectedProtocol = remoteChannel?.selectedProtocol;

      var supportedProtocols = selectedProtocol != null ? [selectedProtocol] : ['http/1.1'];
      logger.d('[SSL-DEBUG] ssl() server TLS handshake: alpn=$supportedProtocols '
        'clientSelectedFromUpstream=${remoteChannel?.selectedProtocol}');

      certificate.setAlpnProtocols(supportedProtocols, true);

      //处理客户端ssl握手
      logger.d('[SSL-DEBUG] ssl() calling SecureSocket.secureServer for client of ${hostAndPort.host}');
      var secureSocket = await SecureSocket.secureServer(channel.socket, certificate,
          bufferedData: data, supportedProtocols: supportedProtocols);
      logger.d('[SSL-DEBUG] ssl() SecureSocket.secureServer success, serverSelectedProtocol=${secureSocket.selectedProtocol}');

      channel.serverSecureSocket(secureSocket, channelContext);
      remoteChannel?.listen(channelContext);

      if (selectedProtocol != secureSocket.selectedProtocol) {
        logger.i(
            '[${channelContext.clientChannel?.id}] $hostAndPort ssl handshake done, clientSelectedProtocol: ${secureSocket.selectedProtocol}, serverSelectedProtocols: $supportedProtocols');
      }
    } catch (error, trace) {
      logger.e('[SSL-DEBUG] ssl() EXCEPTION for ${hostAndPort?.host}: $error', error: error, stackTrace: trace);
      logger.e('[${channelContext.clientChannel?.id}] $hostAndPort ssl error', error: error, stackTrace: trace);

      // fallback to relay if MITM handshake fails (e.g. TLS 1.3 extension incompatibility)
      if (error is HandshakeException && hostAndPort != null) {
        logger.d('[SSL-DEBUG] ssl() TLS MITM failed, falling back to relay for ${hostAndPort.host}');
        try {
          final fallbackChannel = channelContext.serverChannel ?? await channelContext.connectServerChannel(hostAndPort, RelayHandler(channel));
          if (fallbackChannel != null) {
            relay(channel, fallbackChannel);
            channel.dispatcher.channelRead(channelContext, channel, data);
            return;
          }
        } catch (fallbackError) {
          logger.e('[SSL-DEBUG] ssl() relay fallback also failed: $fallbackError');
        }
      }

      try {
        channelContext.processInfo ??=
            await ProcessInfoUtils.getProcessByPort(channel.remoteSocketAddress, hostAndPort?.domain ?? 'unknown');
      } catch (ignore) {
        /*ignore*/
      }

      channelContext.host ??= hostAndPort;
      channel.dispatcher.exceptionCaught(channelContext, channel, error, trace: trace);
    }
  }
}

class Client extends Network {
  Future<Channel> connect(HostAndPort hostAndPort, ChannelContext channelContext,
      {Duration timeout = const Duration(seconds: 3)}) async {
    String host = hostAndPort.host;
    //说明支持ipv6
    // if (host.startsWith("[") && host.endsWith(']')) {
    //   host = host.substring(1, host.length - 1);
    // }

    // logger.d('Connecting to $host:${hostAndPort.port}');
    return Socket.connect(host, hostAndPort.port, timeout: timeout).then((socket) {
      if (socket.address.type != InternetAddressType.unix) {
        socket.setOption(SocketOption.tcpNoDelay, true);
      }
      var channel = Channel(socket);
      channelContext.serverChannel = channel;
      return listen(channel, channelContext);
    });
  }

  /// ssl连接
  Future<Channel> secureConnect(HostAndPort hostAndPort, ChannelContext channelContext) async {
    return SecureSocket.connect(hostAndPort.host, hostAndPort.port,
        timeout: const Duration(seconds: 3), onBadCertificate: (certificate) => true).then((socket) {
      var channel = Channel(socket);
      channelContext.serverChannel = channel;
      return listen(channel, channelContext);
    });
  }

  @override
  Future<void> onEvent(Uint8List data, ChannelContext channelContext, Channel channel) async {
    channel.dispatcher.channelRead(channelContext, channel, data);
  }
}
