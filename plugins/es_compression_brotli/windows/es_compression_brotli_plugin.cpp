// Stub plugin - es_compression handles all the brotli work
// This plugin exists only to bundle native brotli DLLs

#include <flutter/plugin_registrar.h>

namespace {

class EsCompressionBrotliPlugin : public flutter::Plugin {
public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {}
};

}  // namespace

void EsCompressionBrotliPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  // No-op
}
