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
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/http/content_type.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/utils/lang.dart';

import 'model/search_model.dart';

/// @author wanghongen
/// 2023/8/6
class SearchConditions extends StatefulWidget {
  final SearchModel searchModel;
  final Function(SearchModel searchModel)? onSearch;
  final EdgeInsetsGeometry? padding;

  const SearchConditions({super.key, required this.searchModel, this.onSearch, this.padding});

  @override
  State<StatefulWidget> createState() {
    return SearchConditionsState();
  }
}

class SearchConditionsState extends State<SearchConditions> {
  final Map<String, ContentType?> requestContentMap = {
    'JSON': ContentType.json,
    'FORM-URL': ContentType.formUrl,
    'FORM-DATA': ContentType.formData,
  };

  final Map<String, ContentType?> responseContentMap = {
    'JSON': ContentType.json,
    'IMAGE': ContentType.image,
    'HTML': ContentType.html,
    'XML': ContentType.xml,
    'JS': ContentType.js,
    'CSS': ContentType.css,
    'TEXT': ContentType.text,
  };

  late SearchModel searchModel;

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    searchModel = widget.searchModel.clone();
  }

  @override
  Widget build(BuildContext context) {
    requestContentMap[localizations.all] = null;
    responseContentMap[localizations.all] = null;
    Color primaryColor = ColorScheme.of(context).primary;
    return Container(
      padding: widget.padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // keyword
          TextFormField(
            initialValue: searchModel.keyword,
            onChanged: (val) => searchModel.keyword = val,
            onTapOutside: (event) => FocusManager.instance.primaryFocus?.unfocus(),
            decoration: InputDecoration(
              isCollapsed: true,
              contentPadding: const EdgeInsets.all(10),
              filled: true,
              fillColor: Color.alphaBlend(primaryColor.withValues(alpha: 0.05), Theme.of(context).colorScheme.surface),
              border: const OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(10)),
                borderSide: BorderSide.none,
              ),
              enabledBorder: const OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(10)),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: const BorderRadius.all(Radius.circular(10)),
                borderSide: BorderSide(color: primaryColor.withValues(alpha: 0.4), width: 1),
              ),
              hintText: localizations.keyword,
              suffixIcon: Obx(() => IconButton(
                    tooltip: "Case Sensitive",
                    icon: Text('Aa',
                        style: TextStyle(
                            fontWeight: FontWeight.w500, color: searchModel.caseSensitive.value ? primaryColor : null)),
                    onPressed: () {
                      searchModel.caseSensitive.value = !searchModel.caseSensitive.value;
                    },
                  )),
            ),
          ),
          const SizedBox(height: 10),
          // protocol quick selectors placed under the keyword input (very compact)
          protocolsWidget(),
          const SizedBox(height: 10),
          // keyword scope
          Text(localizations.keywordSearchScope),
          const SizedBox(height: 10),
          Wrap(
            children: [
              options('URL', Option.url),
              options(localizations.requestHeader, Option.requestHeader),
              options(localizations.requestBody, Option.requestBody),
              options(localizations.responseHeader, Option.responseHeader),
              options(localizations.responseBody, Option.responseBody),
            ],
          ),
          const SizedBox(height: 10),

          // request method
          row(
            Text('${localizations.requestMethod}:'),
            DropdownMenu(
              initialValue: searchModel.requestMethod?.name ?? localizations.all,
              items: HttpMethod.methods().map((e) => e.name).toList()..insert(0, localizations.all),
              onSelected: (String value) {
                searchModel.requestMethod = value == localizations.all ? null : HttpMethod.valueOf(value);
              },
            ),
          ),
          const SizedBox(height: 10),
          // request type
          row(
            Text('${localizations.requestType}:'),
            DropdownMenu(
              initialValue: Maps.getKey(requestContentMap, searchModel.requestContentType) ?? localizations.all,
              items: requestContentMap.keys,
              onSelected: (String value) {
                searchModel.requestContentType = requestContentMap[value];
              },
            ),
          ),
          const SizedBox(height: 10),

          // response type
          row(
            Text('${localizations.responseType}:'),
            DropdownMenu(
              initialValue: Maps.getKey(responseContentMap, searchModel.responseContentType) ?? localizations.all,
              items: responseContentMap.keys,
              onSelected: (String value) {
                searchModel.responseContentType = responseContentMap[value];
              },
            ),
          ),
          const SizedBox(height: 10),

          // status code range
          row(
            Text('${localizations.statusCode}: '),
            Row(children: [
              SizedBox(
                  width: 55,
                  height: 32,
                  child: textField(
                      initialValue: searchModel.statusCodeFrom?.toString(),
                      onChanged: (val) => searchModel.statusCodeFrom = int.tryParse(val))),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 5), child: Text(" - ")),
              SizedBox(
                  width: 55,
                  height: 32,
                  child: textField(
                      initialValue: searchModel.statusCodeTo?.toString(),
                      onChanged: (val) => searchModel.statusCodeTo = int.tryParse(val))),
            ]),
          ),
          const SizedBox(height: 10),

          // duration range (ms)
          row(
            Text('${localizations.duration} (ms): '),
            Row(children: [
              SizedBox(
                  width: 55,
                  height: 32,
                  child: textField(
                      initialValue: searchModel.durationFromMs?.toString(),
                      onChanged: (val) => searchModel.durationFromMs = int.tryParse(val))),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 5), child: Text(" - ")),
              SizedBox(
                  width: 55,
                  height: 32,
                  child: textField(
                      initialValue: searchModel.durationToMs?.toString(),
                      onChanged: (val) => searchModel.durationToMs = int.tryParse(val))),
            ]),
          ),
          const SizedBox(height: 15),

          // action buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(localizations.cancel, style: const TextStyle(fontSize: 14)),
              ),
              TextButton(
                onPressed: () {
                  widget.onSearch?.call(SearchModel());
                  Navigator.pop(context);
                },
                child: Text(localizations.clearSearch, style: const TextStyle(fontSize: 14)),
              ),
              TextButton(
                onPressed: () {
                  widget.onSearch?.call(searchModel);
                  Navigator.pop(context);
                },
                child: Text(localizations.confirm, style: const TextStyle(fontSize: 14)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _protocolChip(
    String label,
    Protocol protocol, {
    required Color primaryColor,
    required Color surface,
  }) {
    final selected = searchModel.protocols.contains(protocol);
    final selectedBg = Color.alphaBlend(primaryColor.withValues(alpha: 0.16), surface);
    final unselectedBg = Color.alphaBlend(primaryColor.withValues(alpha: 0.05), surface);
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => setState(() {
        if (selected) {
          searchModel.protocols.remove(protocol);
        } else {
          searchModel.protocols.add(protocol);
        }
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? selectedBg : unselectedBg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? primaryColor : primaryColor.withValues(alpha: 0.65),
          ),
        ),
      ),
    );
  }

  Widget protocolsWidget() {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 5,
      children: <Widget>[
        _protocolChip('HTTP', Protocol.http, primaryColor: theme.colorScheme.primary, surface: theme.colorScheme.surface),
        _protocolChip('HTTPS', Protocol.https, primaryColor: theme.colorScheme.primary, surface: theme.colorScheme.surface),
        _protocolChip('WS', Protocol.ws, primaryColor: theme.colorScheme.primary, surface: theme.colorScheme.surface),
        _protocolChip('HTTP/1', Protocol.http1, primaryColor: theme.colorScheme.primary, surface: theme.colorScheme.surface),
        _protocolChip('H2', Protocol.h2, primaryColor: theme.colorScheme.primary, surface: theme.colorScheme.surface),
      ],
    );
  }

  Widget _optionPill(String title, Option option, {required Color primaryColor, required Color surface}) {
    final selected = searchModel.searchOptions.contains(option);
    final selectedBg = Color.alphaBlend(primaryColor.withValues(alpha: 0.16), surface);
    final unselectedBg = Color.alphaBlend(primaryColor.withValues(alpha: 0.05), surface);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => setState(() {
        if (selected) {
          searchModel.searchOptions.remove(option);
        } else {
          searchModel.searchOptions.add(option);
        }
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: selected ? selectedBg : unselectedBg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? primaryColor : primaryColor.withValues(alpha: 0.65),
          ),
        ),
      ),
    );
  }

  Widget options(String title, Option option) {
    final theme = Theme.of(context);
    return _optionPill(title, option, primaryColor: theme.colorScheme.primary, surface: theme.colorScheme.surface);
  }

  Widget row(Widget child, Widget child2) {
    return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [Expanded(flex: 4, child: child), Expanded(flex: 6, child: child2)]);
  }

  Widget textField({String? initialValue, final ValueChanged<String>? onChanged, TextStyle? style}) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    final surface = theme.colorScheme.surface;
    final fill = Color.alphaBlend(primaryColor.withValues(alpha: 0.05), surface);

    return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 32),
        child: TextFormField(
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onTapOutside: (event) => FocusManager.instance.primaryFocus?.unfocus(),
          initialValue: initialValue,
          onChanged: onChanged,
          style: style,
          decoration: InputDecoration(
            contentPadding: const EdgeInsets.only(left: 10, right: 10, top: 2, bottom: 2),
            filled: true,
            fillColor: fill,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: primaryColor.withValues(alpha: 0.4), width: 1),
            ),
          ),
        ));
  }
}

class DropdownMenu<T> extends StatefulWidget {
  final String? initialValue;
  final Iterable<String> items;
  final Function(String value) onSelected;

  const DropdownMenu({super.key, this.initialValue, required this.items, required this.onSelected});

  @override
  State<StatefulWidget> createState() {
    return DropdownMenuState();
  }
}

class DropdownMenuState extends State<DropdownMenu> {
  String? selectValue;

  @override
  void initState() {
    super.initState();
    selectValue = widget.initialValue;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeColor = theme.colorScheme.primary;
    final menuBg = Color.alphaBlend(themeColor.withValues(alpha: 0.08), theme.colorScheme.surface);
    final menuBorder = themeColor.withValues(alpha: 0.2);
    return PopupMenuButton(
      tooltip: '',
      initialValue: selectValue,
      color: menuBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: menuBorder, width: 0.5),
      ),
      elevation: 8,
      child: Wrap(runAlignment: WrapAlignment.center, children: [
        Text(selectValue ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
        const Icon(Icons.arrow_drop_down, size: 20)
      ]),
      onSelected: (String value) {
        setState(() {
          widget.onSelected.call(value);
          selectValue = value;
        });
      },
      itemBuilder: (BuildContext context) {
        return widget.items
            .map((it) =>
                PopupMenuItem<String>(height: 35, value: it, child: Text(it, style: const TextStyle(fontSize: 12))))
            .toList();
      },
    );
  }
}
