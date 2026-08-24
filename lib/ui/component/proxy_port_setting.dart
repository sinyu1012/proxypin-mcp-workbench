import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/server.dart';

class PortWidget extends StatefulWidget {
  final ProxyServer proxyServer;
  final TextStyle? textStyle;
  final String? title;
  final bool enabled;

  const PortWidget({
    super.key,
    required this.proxyServer,
    this.textStyle,
    this.title,
    this.enabled = true,
  });

  @override
  State<StatefulWidget> createState() {
    return _PortState();
  }
}

class _PortState extends State<PortWidget> {
  final textController = TextEditingController();
  final FocusNode portFocus = FocusNode();

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    textController.text = widget.proxyServer.port.toString();
    portFocus.addListener(() async {
      //失去焦点
      if (!widget.enabled || widget.proxyServer.systemProxyRoutingLocked) {
        textController.text = widget.proxyServer.port.toString();
        return;
      }
      if (!portFocus.hasFocus && textController.text != widget.proxyServer.port.toString()) {
        final port = int.tryParse(textController.text) ?? -1;
        if (port < 1 || port > 65535) {
          textController.text = widget.proxyServer.port.toString();
          FlutterToastr.show("Port out of range 1-65535", context, duration: 3);
          return;
        }

        widget.proxyServer.configuration.port = port;

        if (widget.proxyServer.isRunning) {
          final message = localizations.proxyPortRepeat(widget.proxyServer.port);
          try {
            await widget.proxyServer.restart();
          } catch (_) {
            if (mounted) FlutterToastr.show(message, context, duration: 3);
          }
        }
        await widget.proxyServer.configuration.flushConfig();
      }
    });
  }

  @override
  void dispose() {
    portFocus.dispose();
    textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      const Padding(padding: EdgeInsets.only(left: 15)),
      Text(widget.title ?? localizations.port, style: widget.textStyle),
      SizedBox(
          width: 80,
          child: TextFormField(
            enabled: widget.enabled,
            focusNode: portFocus,
            controller: textController,
            textAlign: TextAlign.center,
            onTapOutside: (event) => portFocus.unfocus(),
            keyboardType: TextInputType.datetime,
            inputFormatters: <TextInputFormatter>[
              LengthLimitingTextInputFormatter(5),
              FilteringTextInputFormatter.allow(RegExp("[0-9]"))
            ],
            decoration: const InputDecoration(),
          ))
    ]);
  }
}
