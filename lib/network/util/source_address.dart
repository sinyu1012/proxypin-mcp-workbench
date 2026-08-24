String? normalizeSourceAddress(String? address) {
  final value = address?.trim();
  if (value == null || value.isEmpty) return null;

  const ipv4MappedPrefix = '::ffff:';
  if (value.toLowerCase().startsWith(ipv4MappedPrefix)) {
    return value.substring(ipv4MappedPrefix.length);
  }
  if (value == '::1') return '127.0.0.1';
  return value;
}

bool matchesSourceAddress(String? selectedSourceKey, String? requestSourceAddress) {
  return selectedSourceKey == null || selectedSourceKey == (normalizeSourceAddress(requestSourceAddress) ?? '');
}

/// Whether the accepted proxy connection originated from this machine's
/// loopback interface. macOS first-hop capture connects to ProxyPin through
/// 127.0.0.1, while phones and other LAN devices use their LAN address.
bool isLoopbackSourceAddress(String? address) {
  final value = normalizeSourceAddress(address);
  if (value == null) return false;

  final ipv4Parts = value.split('.');
  if (ipv4Parts.length == 4) {
    final octets = ipv4Parts.map(int.tryParse).toList(growable: false);
    return octets.every((octet) => octet != null && octet >= 0 && octet <= 255) && octets.first == 127;
  }

  return false;
}

enum CaptureSourceScope { all, external, localMachine }

bool matchesCaptureSourceScope(CaptureSourceScope scope, String? sourceAddress) {
  final isLocal = isLoopbackSourceAddress(sourceAddress);
  return switch (scope) {
    CaptureSourceScope.all => true,
    CaptureSourceScope.external => !isLocal,
    CaptureSourceScope.localMachine => isLocal,
  };
}
