enum ConnectionCheckLevel { success, warning, error, info }

class ConnectionCheck {
  final String id;
  final String title;
  final String detail;
  final ConnectionCheckLevel level;
  final String? action;

  const ConnectionCheck(
      {required this.id, required this.title, required this.detail, required this.level, this.action});
}
