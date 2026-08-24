/*
 * Copyright 2023 Hongen Wang
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
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/native/vpn.dart';
import 'package:proxypin/native/app_lifecycle.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/ui/desktop/ssl/pc_cert.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/utils/lang.dart';
import 'package:proxypin/utils/desktop_tray.dart';
import 'package:proxypin/utils/platform.dart';
import 'package:window_manager/window_manager.dart';

import '../mobile/setting/ssl.dart';

///启动按钮
///@author wanghongen
///2023/10/8
class SocketLaunch extends StatefulWidget {
  static ValueNotifier<ValueWrap<bool>> startStatus = ValueNotifier(ValueWrap());

  final ProxyServer proxyServer;
  final int size;
  final bool startup; //默认是否启动
  final Function? onStart;
  final Function? onStop;

  final bool serverLaunch; //是否启动代理服务器

  const SocketLaunch(
      {super.key,
      required this.proxyServer,
      this.size = 25,
      this.onStart,
      this.onStop,
      this.startup = true,
      this.serverLaunch = true});

  @override
  State<StatefulWidget> createState() => _SocketLaunchState();
}

class _SocketLaunchState extends State<SocketLaunch>
    with WindowListener, WidgetsBindingObserver
    implements LifecycleListener {
  AppLocalizations get localizations => AppLocalizations.of(context)!;
  bool started = false;
  bool _exiting = false;
  Future<bool>? _terminationFuture;
  int? _terminationRequestId;
  bool _terminationCancelled = false;
  bool _terminationOperationCompleted = false;

  @override
  void initState() {
    super.initState();
    if (Platforms.isDesktop()) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
      DesktopTrayManager.instance.setQuitHandler(() async {
        await _requestSafeExit();
      });
      AppLifecycleBinding.instance.addListener(this);
    }

    WidgetsBinding.instance.addObserver(this);
    //启动代理服务器
    if (widget.startup) {
      start();
    }

    SocketLaunch.startStatus.addListener(() {
      if (SocketLaunch.startStatus.value.get() == started) {
        return;
      }
      setState(() {
        started = SocketLaunch.startStatus.value.get() ?? started;
      });
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    if (Platforms.isDesktop()) {
      DesktopTrayManager.instance.setQuitHandler(null);
      AppLifecycleBinding.instance.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowClose() async {
    logger.d("onWindowClose");
    await _handleWindowClose();
  }

  Future<void> _handleWindowClose() async {
    final appConfiguration = AppConfiguration.current;
    if (Platforms.isDesktop() && appConfiguration?.minimizeToTray == null || appConfiguration?.minimizeToTray == true) {
      if (appConfiguration?.minimizeToTray == null) {
        final minimize = await _showTrayClosePrompt();
        if (!mounted) {
          return;
        }

        appConfiguration?.minimizeToTray = minimize;
        await appConfiguration?.flushConfig();

        if (!minimize) {
          await _requestSafeExit();
          return;
        }
      }

      try {
        await DesktopTrayManager.instance.showToTray();
        return;
      } catch (e) {
        logger.e('show to tray failed, fallback to exit', error: e);
      }
    }

    await _requestSafeExit();
  }

  Future<bool> _showTrayClosePrompt() async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) {
            return AlertDialog(
              title: Text(localizations.minimizeToTrayTitle),
              content: SizedBox(width: 320, child: Text(maxLines: 3, localizations.trayClosePromptContent)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(localizations.trayCloseExitAnyway),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(localizations.trayCloseMinimizeToTray),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  Future<void> appExit() async {
    if (_exiting) return;
    _exiting = true;
    const localTerminationRequestId = -1;
    widget.proxyServer.beginAppTermination(localTerminationRequestId);
    logger.d("appExit");
    try {
      await widget.proxyServer.stop();
      started = false;
      if (Platforms.isDesktop()) {
        await DesktopTrayManager.instance.exitApp();
        await windowManager.setPreventClose(false);
        await windowManager.destroy();
      }

      if (!Platform.isWindows && !Platform.isLinux) {
        try {
          await SystemNavigator.pop(animated: true).timeout(const Duration(milliseconds: 150));
        } catch (_) {
          //
        }
      }

      exit(0);
    } catch (_) {
      widget.proxyServer.cancelAppTermination(localTerminationRequestId);
      _exiting = false;
      rethrow;
    }
  }

  Future<bool> _requestSafeExit() async {
    try {
      await appExit();
      return true;
    } catch (error, stackTrace) {
      logger.e('安全退出已取消，ProxyPin 将继续监听', error: error, stackTrace: stackTrace);
      if (Platforms.isDesktop()) {
        try {
          await DesktopTrayManager.instance.restoreWindow();
        } catch (_) {
          // Keep the listener alive even if restoring the window fails.
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString()), duration: const Duration(seconds: 9)),
        );
      }
      return false;
    }
  }

  @override
  Future<bool> onAppTerminateRequested(int requestId) {
    final activeTermination = _terminationFuture;
    if (activeTermination != null) {
      // A native timeout can be followed by another AppKit quit request while
      // the same idempotent stop is still running. The newest request owns the
      // result; cancellation of an older request must not unlock Start.
      _terminationRequestId = requestId;
      _terminationCancelled = false;
      widget.proxyServer.beginAppTermination(requestId);
      return activeTermination;
    }

    _terminationRequestId = requestId;
    _terminationCancelled = false;
    _terminationOperationCompleted = false;
    widget.proxyServer.beginAppTermination(requestId);
    final operation = _performAppTermination().then((safeToTerminate) {
      _terminationOperationCompleted = true;
      // A successful operation deliberately stays latched until AppKit exits.
      // It is only safe to unlock when native rejected/timed out this request.
      if (!safeToTerminate || _terminationCancelled) {
        _resetTerminationState();
      }
      return safeToTerminate;
    });
    _terminationFuture = operation;
    return operation;
  }

  @override
  void onAppTerminationCancelled(int requestId) {
    if (_terminationRequestId != requestId) return;
    _terminationCancelled = true;
    if (_terminationOperationCompleted) {
      _resetTerminationState();
    }
  }

  void _resetTerminationState() {
    final requestId = _terminationRequestId;
    if (requestId != null) {
      widget.proxyServer.cancelAppTermination(requestId);
    }
    _terminationFuture = null;
    _terminationRequestId = null;
    _terminationCancelled = false;
    _terminationOperationCompleted = false;
    _exiting = false;
  }

  Future<bool> _performAppTermination() async {
    _exiting = true;
    try {
      widget.onStop?.call();
      await widget.proxyServer.stop();
      started = false;
      return true;
    } catch (error, stackTrace) {
      logger.e('macOS 外部退出已取消，系统代理恢复未完成', error: error, stackTrace: stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString()), duration: const Duration(seconds: 9)),
        );
      }
      return false;
    }
  }

  @override
  void onUserLeaveHint() {}

  @override
  void onPictureInPictureModeChanged(bool isInPictureInPictureMode) {}

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    bool isPreventClose = await windowManager.isPreventClose();
    if (!isPreventClose || Platform.isMacOS) {
      final safeToExit = await _requestSafeExit();
      if (!safeToExit) return AppExitResponse.cancel;
    }
    return AppExitResponse.cancel;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (widget.proxyServer.isRunning) {
        widget.proxyServer.retryBind();
      }

      if (Platforms.isMobile() && started == false) {
        Vpn.isRunning().then((value) {
          Vpn.isVpnStarted = value;
          SocketLaunch.startStatus.value = ValueWrap.of(value);
        });
      }
    }

    if (state == AppLifecycleState.detached) {
      logger.d('AppLifecycleState.detached');
      widget.onStop?.call();
      widget.proxyServer.stop();
      started = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    Color primaryColor = Theme.of(context).colorScheme.primary;
    return IconButton(
        tooltip: started ? localizations.stop : localizations.start,
        icon: Icon(started ? Icons.stop : Icons.play_arrow_sharp,
            color: started ? Colors.red : primaryColor, size: widget.size.toDouble()),
        onPressed: () async {
          if (started) {
            if (!widget.serverLaunch) {
              setState(() {
                widget.onStop?.call();
                started = !started;
              });
              return;
            }

            widget.proxyServer.stop().then((value) {
              widget.onStop?.call();
              setState(() {
                started = !started;
              });
            });
          } else {
            start();
          }
        });
  }

  ///启动代理服务器
  Future<void> start() async {
    if (_exiting) return;
    try {
      if (!widget.serverLaunch) {
        await widget.onStart?.call();
        setState(() {
          started = true;
        });
        return;
      }

      try {
        await widget.proxyServer.start();
        if (!mounted || _exiting) return;
        setState(() {
          started = true;
        });
        await widget.onStart?.call();
      } catch (e) {
        logger.e("启动代理服务器失败", error: e);
        if (mounted) {
          final message = localizations.proxyPortRepeat(widget.proxyServer.port);
          FlutterToastr.show(message, context, duration: 3);
        }
      }
    } finally {
      Future.delayed(const Duration(seconds: 5)).then((value) {
        if (!mounted) {
          return;
        }
        if (Platforms.isDesktop()) {
          PCCertChecker.check(context);
        } else if (Platform.isIOS) {
          IOSCertChecker.check(context);
        }
      });
    }
  }
}
