import 'package:flutter/material.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/configuration.dart';

///缓存时间菜单
/// @author wanghongen
class HistoryCacheTime extends StatefulWidget {
  final Configuration configuration;
  final Function(int) onSelected;

  const HistoryCacheTime(this.configuration, {super.key, required this.onSelected});

  @override
  State<StatefulWidget> createState() => _HistoryCacheTimeState();
}

class _HistoryCacheTimeState extends State<HistoryCacheTime> {
  AppLocalizations get localizations => AppLocalizations.of(context)!;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeColor = theme.colorScheme.primary;
    final menuBg = Color.alphaBlend(themeColor.withValues(alpha: 0.08), theme.colorScheme.surface);
    final menuBorder = themeColor.withValues(alpha: 0.2);
    return PopupMenuButton(
        tooltip: localizations.historyCacheTime,
        offset: const Offset(0, 35),
        icon: const Icon(Icons.av_timer, size: 19),
        initialValue: widget.configuration.historyCacheTime,
        constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
        color: menuBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: menuBorder, width: 0.5),
        ),
        elevation: 8,
        onSelected: (val) {
          widget.configuration.historyCacheTime = val;
          widget.configuration.flushConfig();
          setState(() {
            widget.onSelected.call(val);
          });
        },
        itemBuilder: (BuildContext context) {
          return [
            PopupMenuItem(value: 0, height: 35, child: Text(localizations.historyManualSave)),
            PopupMenuItem(value: 7, height: 35, child: Text(localizations.historyDay(7))),
            PopupMenuItem(value: 30, height: 35, child: Text(localizations.historyDay(30))),
            PopupMenuItem(value: 99999, height: 35, child: Text(localizations.historyForever)),
          ];
        });
  }
}
