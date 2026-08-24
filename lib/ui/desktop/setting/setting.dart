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
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/components/manager/hosts_manager.dart';
import 'package:proxypin/network/components/manager/request_block_manager.dart';
import 'package:proxypin/network/util/system_proxy.dart';
import 'package:proxypin/ui/component/multi_window.dart';
import 'package:proxypin/ui/component/proxy_port_setting.dart';
import 'package:proxypin/ui/component/widgets.dart';
import 'package:proxypin/ui/desktop/setting/about.dart';
import 'package:proxypin/ui/desktop/setting/external_proxy.dart';
import 'package:proxypin/ui/desktop/setting/hosts.dart';
import 'package:proxypin/ui/desktop/setting/request_block.dart';

import 'filter.dart';

///设置菜单
/// @author wanghongen
/// 2023/10/8
class Setting extends StatefulWidget {
  final ProxyServer proxyServer;

  const Setting({super.key, required this.proxyServer});

  @override
  State<Setting> createState() => _SettingState();
}

class _SettingState extends State<Setting> {
  late Configuration configuration;
  AppLocalizations get localizations => AppLocalizations.of(context)!;

  MenuStyle get _menuStyle {
    final theme = Theme.of(context);
    final themeColor = theme.colorScheme.primary;
    final bg = Color.alphaBlend(themeColor.withValues(alpha: 0.08), theme.colorScheme.surface);
    final border = themeColor.withValues(alpha: 0.2);
    return MenuStyle(
      backgroundColor: WidgetStatePropertyAll(bg),
      elevation: const WidgetStatePropertyAll(8),
      shadowColor: const WidgetStatePropertyAll(Colors.black54),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: border, width: 0.5),
        ),
      ),
    );
  }

  @override
  void initState() {
    configuration = widget.proxyServer.configuration;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      style: _menuStyle,
      builder: (context, controller, child) {
        return IconButton(
            icon: const Icon(Icons.settings, size: 21),
            tooltip: localizations.setting,
            onPressed: () {
              if (controller.isOpen) {
                controller.close();
              } else {
                controller.open();
              }
            });
      },
      menuChildren: [
        _ProxyMenu(
          proxyServer: widget.proxyServer,
          onFirstHopChanged: () => setState(() {}),
        ),
        item(localizations.domainFilter, onPressed: hostFilter),
        item(localizations.hosts, onPressed: hosts),
        item(localizations.requestBlock, onPressed: showRequestBlock),
        item(localizations.requestRewrite, onPressed: requestRewrite),
        item(localizations.requestMap, onPressed: requestMap),
        item(localizations.requestCrypto, onPressed: showRequestCrypto),
        item(localizations.script,
            onPressed: () => MultiWindow.openWindow(localizations.script, 'ScriptWidget', size: const Size(800, 780))),
        item(localizations.breakpoint, onPressed: requestBreakpoint),
        item(localizations.externalProxy,
            onPressed: widget.proxyServer.systemProxyRoutingLocked ? null : setExternalProxy),
        item(localizations.about, onPressed: showAbout),
      ],
    );
  }

  Widget item(String text, {VoidCallback? onPressed}) {
    return MenuItemButton(
        trailingIcon: const Icon(Icons.arrow_right),
        onPressed: onPressed,
        child: Padding(
            padding: const EdgeInsets.only(left: 10, right: 5),
            child: Text(text, style: const TextStyle(fontSize: 14))));
  }

  void showAbout() {
    showDialog(context: context, builder: (context) => DesktopAbout());
  }

  ///设置外部代理地址
  void setExternalProxy() {
    if (widget.proxyServer.systemProxyRoutingLocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(localizations.firstHopUpstreamLocked)),
      );
      return;
    }
    showDialog(
        barrierDismissible: false,
        context: context,
        builder: (context) {
          return ExternalProxyDialog(
            configuration: widget.proxyServer.configuration,
            localProxyPort: widget.proxyServer.port,
            onChanged: widget.proxyServer.refreshRuntimeUpstream,
            routingLocked: () => widget.proxyServer.systemProxyRoutingLocked,
          );
        });
  }

  ///请求重写Dialog
  void requestRewrite() async {
    MultiWindow.openWindow(localizations.requestRewrite, 'RequestRewriteWidget', size: const Size(800, 750));
  }

  void requestBreakpoint() async {
    MultiWindow.openWindow(localizations.breakpoint, 'RequestBreakpointPage', size: const Size(800, 750));
  }

  ///请求本地映射
  void requestMap() async {
    if (!mounted) return;
    MultiWindow.openWindow(localizations.requestMap, 'RequestMapPage', size: const Size(800, 720));
  }

  ///show域名过滤Dialog
  void hostFilter() {
    showDialog(
        barrierDismissible: false, context: context, builder: (context) => FilterDialog(configuration: configuration));
  }

  ///show域名过滤Dialog
  void hosts() async {
    var hosts = await HostsManager.instance;
    if (!mounted) return;
    showDialog(barrierDismissible: false, context: context, builder: (context) => HostsDialog(hostsManager: hosts));
  }

  //请求屏蔽
  void showRequestBlock() async {
    var requestBlockManager = await RequestBlockManager.instance;
    if (!mounted) return;
    showDialog(
        barrierDismissible: false,
        context: context,
        builder: (context) => RequestBlock(requestBlockManager: requestBlockManager));
  }

  void showRequestCrypto() {
    MultiWindow.openWindow(localizations.requestCrypto, 'RequestCryptoPage', size: const Size(820, 750));
  }
}

///代理菜单
class _ProxyMenu extends StatefulWidget {
  final ProxyServer proxyServer;
  final VoidCallback? onFirstHopChanged;

  const _ProxyMenu({required this.proxyServer, this.onFirstHopChanged});

  @override
  State<StatefulWidget> createState() => _ProxyMenuState();
}

class _ProxyMenuState extends State<_ProxyMenu> {
  var textEditingController = TextEditingController();

  late Configuration configuration;
  bool changed = false;
  bool _systemProxyTransitioning = false;

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  @override
  void initState() {
    configuration = widget.proxyServer.configuration;
    textEditingController.text = configuration.proxyPassDomains;
    super.initState();
  }

  @override
  void dispose() {
    if (!widget.proxyServer.systemProxyRoutingLocked && configuration.proxyPassDomains != textEditingController.text) {
      changed = true;
      configuration.proxyPassDomains = textEditingController.text;
      // Passive macOS coexistence never writes system proxy state. The value
      // is only a preference for the next explicit first-hop transaction.
      if (!Platform.isMacOS && configuration.enableSystemProxy) {
        SystemProxy.setProxyPassDomains(configuration.proxyPassDomains);
      }
    }

    if (changed) {
      configuration.flushConfig();
    }
    textEditingController.dispose();
    super.dispose();
  }

  MenuStyle get _menuStyle {
    final theme = Theme.of(context);
    final themeColor = theme.colorScheme.primary;
    final bg = Color.alphaBlend(themeColor.withValues(alpha: 0.08), theme.colorScheme.surface);
    final border = themeColor.withValues(alpha: 0.2);
    return MenuStyle(
      backgroundColor: WidgetStatePropertyAll(bg),
      elevation: const WidgetStatePropertyAll(8),
      shadowColor: const WidgetStatePropertyAll(Colors.black54),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: border, width: 0.5),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    bool isEn = localizations.localeName.startsWith("en");
    return SubmenuButton(
      menuStyle: _menuStyle,
      menuChildren: [
        PortWidget(
          proxyServer: widget.proxyServer,
          textStyle: const TextStyle(fontSize: 13),
          enabled: !_systemProxyTransitioning && !widget.proxyServer.systemProxyRoutingLocked,
        ),
        const Divider(thickness: 0.3, height: 8),
        setSystemProxy(),
        const Divider(thickness: 0.3, height: 8),
        if (Platform.isMacOS) _firstHopProxyMode(),
        if (Platform.isMacOS) const Divider(thickness: 0.3, height: 8),
        _chainSystemProxy(),
        const Divider(thickness: 0.3, height: 8),
        Row(children: [
          Expanded(
              child: Padding(
                  padding: const EdgeInsets.only(left: 15),
                  child: Text("SOCKS5", style: const TextStyle(fontSize: 14)))),
          SwitchWidget(
              value: configuration.enableSocks5,
              scale: 0.75,
              onChanged: (val) {
                configuration.enableSocks5 = val;
                changed = true;
              }),
          SizedBox(width: 10)
        ]),
        const Divider(thickness: 0.3, height: 8),
        Row(children: [
          Expanded(
              child: Padding(
                  padding: const EdgeInsets.only(left: 15),
                  child: Text(localizations.enabledHTTP2, style: const TextStyle(fontSize: 14)))),
          SwitchWidget(
              value: configuration.enabledHttp2,
              scale: 0.75,
              onChanged: (val) {
                configuration.enabledHttp2 = val;
                changed = true;
              }),
          SizedBox(width: 10)
        ]),
        const Divider(thickness: 0.3, height: 8),
        const SizedBox(height: 3),
        Padding(
            padding: const EdgeInsets.only(left: 15),
            child: Row(children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(localizations.proxyIgnoreDomain, style: const TextStyle(fontSize: 14)),
                  const SizedBox(height: 3),
                  Text(isEn ? "Use ';' to separate multiple entries" : "多个使用;分割",
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                ],
              ),
              Padding(
                  padding: const EdgeInsets.only(left: 35),
                  child: TextButton(
                    onPressed: widget.proxyServer.systemProxyRoutingLocked
                        ? null
                        : () {
                            textEditingController.text = SystemProxy.proxyPassDomains;
                          },
                    child: Text(localizations.reset),
                  ))
            ])),
        const SizedBox(height: 5),
        Padding(
            padding: const EdgeInsets.only(left: 15, right: 5),
            child: TextField(
                enabled: !_systemProxyTransitioning && !widget.proxyServer.systemProxyRoutingLocked,
                textInputAction: TextInputAction.done,
                style: const TextStyle(fontSize: 13),
                controller: textEditingController,
                decoration: const InputDecoration(
                    contentPadding: EdgeInsets.all(10),
                    border: OutlineInputBorder(),
                    constraints: BoxConstraints(minWidth: 190, maxWidth: 190)),
                maxLines: 5,
                minLines: 1)),
        const SizedBox(height: 10),
      ],
      child: Padding(
          padding: const EdgeInsets.only(left: 10),
          child: Text(localizations.proxy, style: const TextStyle(fontSize: 14))),
    );
  }

  ///设置系统代理
  Widget setSystemProxy() {
    return Row(children: [
      Expanded(
          child: Padding(
              padding: const EdgeInsets.only(left: 15, right: 20),
              child: Text(localizations.setAs + localizations.systemProxy, style: const TextStyle(fontSize: 14)))),
      Transform.scale(
          scale: 0.75,
          child: Switch(
              hoverColor: Colors.transparent,
              value: configuration.enableSystemProxy,
              onChanged: _systemProxyTransitioning || widget.proxyServer.isStarting
                  ? null
                  : (val) async {
                      final previousValue = configuration.enableSystemProxy;
                      setState(() {
                        configuration.enableSystemProxy = val;
                        _systemProxyTransitioning = true;
                      });
                      try {
                        final result = await widget.proxyServer.setSystemProxyEnable(val);
                        if (!mounted) return;
                        setState(() {
                          changed = true;
                        });
                        if (result.isOverridden) {
                          final effective = result.effectiveProxy;
                          final endpoint =
                              effective == null ? localizations.other : '${effective.host}:${effective.port}';
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(localizations.systemProxyOverridden(endpoint)),
                              duration: const Duration(seconds: 9),
                            ),
                          );
                        }
                      } catch (error) {
                        configuration.enableSystemProxy = widget.proxyServer.systemProxyActivation.state ==
                                SystemProxyActivationState.recoveryRequired
                            ? true
                            : previousValue;
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(error.toString())),
                        );
                      } finally {
                        if (mounted) {
                          setState(() {
                            _systemProxyTransitioning = false;
                          });
                        }
                      }
                    })),
      SizedBox(width: 10)
    ]);
  }

  Widget _firstHopProxyMode() {
    return Row(children: [
      Expanded(
          child: Padding(
              padding: const EdgeInsets.only(left: 15, right: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(localizations.firstHopProxyMode, style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 2),
                Text(localizations.firstHopProxyModeDescription,
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
              ]))),
      Transform.scale(
          scale: 0.75,
          child: Switch(
              hoverColor: Colors.transparent,
              value: widget.proxyServer.systemProxyRoutingLocked,
              onChanged: _systemProxyTransitioning || widget.proxyServer.isStarting
                  ? null
                  : (val) async {
                      setState(() {
                        _systemProxyTransitioning = true;
                      });
                      try {
                        await widget.proxyServer.setFirstHopProxyMode(val);
                        if (!mounted) return;
                        setState(() {
                          changed = true;
                        });
                        widget.onFirstHopChanged?.call();
                      } catch (error) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(error.toString()),
                            duration: const Duration(seconds: 9),
                          ),
                        );
                      } finally {
                        if (mounted) {
                          setState(() {
                            _systemProxyTransitioning = false;
                          });
                          widget.onFirstHopChanged?.call();
                        }
                      }
                    })),
      const SizedBox(width: 10)
    ]);
  }

  Widget _chainSystemProxy() {
    return Row(children: [
      Expanded(
          child: Padding(
              padding: const EdgeInsets.only(left: 15, right: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(localizations.chainSystemProxy, style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 2),
                Text(localizations.chainSystemProxyDescription,
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
              ]))),
      Transform.scale(
          scale: 0.75,
          child: Switch(
              hoverColor: Colors.transparent,
              value: configuration.chainSystemProxy,
              onChanged: _systemProxyTransitioning || widget.proxyServer.systemProxyRoutingLocked
                  ? null
                  : (val) {
                      setState(() {
                        configuration.chainSystemProxy = val;
                        widget.proxyServer.refreshRuntimeUpstream();
                        changed = true;
                      });
                    })),
      const SizedBox(width: 10)
    ]);
  }
}
