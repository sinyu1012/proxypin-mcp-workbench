import 'package:flutter/services.dart';
import 'package:proxypin/network/util/logger.dart';

abstract interface class LifecycleListener {
  void onUserLeaveHint() {}

  void onPictureInPictureModeChanged(bool isInPictureInPictureMode) {}

  Future<bool> onAppTerminateRequested(int requestId) async => true;

  void onAppTerminationCancelled(int requestId) {}
}

class AppLifecycleBinding {
  static const MethodChannel _methodChannel = MethodChannel('com.proxy/appLifecycle');

  //单例对象
  static AppLifecycleBinding get instance {
    _instance ??= AppLifecycleBinding._();
    return _instance!;
  }

  final List<LifecycleListener> _listeners = <LifecycleListener>[];

  static AppLifecycleBinding? _instance;

  AppLifecycleBinding._() {
    //注册方法
    _methodChannel.setMethodCallHandler(_methodCallHandler);
  }

  static AppLifecycleBinding ensureInitialized() {
    return AppLifecycleBinding.instance;
  }

  void addListener(LifecycleListener listener) {
    if (_listeners.contains(listener)) return;
    _listeners.add(listener);
  }

  void removeListener(LifecycleListener listener) {
    _listeners.remove(listener);
  }

  Future<Object?> _methodCallHandler(MethodCall call) async {
    logger.d("AppLifecycle methodCallHandler ${call.method}");
    switch (call.method) {
      case 'appDetached':
        final requestId = _terminationRequestId(call.arguments);
        if (requestId == null) {
          logger.w('缺少 macOS 退出请求 ID，已取消本次退出');
          return false;
        }
        if (_listeners.isEmpty) {
          logger.w('Flutter 安全退出处理器尚未就绪，已取消本次退出');
          return false;
        }
        for (final listener in List<LifecycleListener>.of(_listeners)) {
          if (!await listener.onAppTerminateRequested(requestId)) return false;
        }
        return true;
      case 'appTerminationCancelled':
        final requestId = _terminationRequestId(call.arguments);
        if (requestId == null) return false;
        for (final listener in List<LifecycleListener>.of(_listeners)) {
          listener.onAppTerminationCancelled(requestId);
        }
        return true;
      case 'onUserLeaveHint':
        for (var listener in _listeners) {
          listener.onUserLeaveHint();
        }
        break;
      case 'onPictureInPictureModeChanged':
        for (var listener in _listeners) {
          listener.onPictureInPictureModeChanged(call.arguments);
        }
        break;
    }
    return null;
  }

  int? _terminationRequestId(Object? arguments) {
    if (arguments is! Map) return null;
    final requestId = arguments['requestId'];
    return requestId is int ? requestId : null;
  }
}
