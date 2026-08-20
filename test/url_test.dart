import 'package:proxypin/network/util/uri.dart';

void main() {
  String url =
      "https://api.example.com/v1/feed?client_volume=0.25&known_signal=%7B%22network_level%22%3A6%2C%22device_level%22%3A1%2C%22device_model%22%3A%22Example%20Phone%22%7D&num=20&refresh_type=1";
  print(url);
  var uri = Uri.parse(url);
  print(uri.queryParameters);

  print(uri);
  String query = '{"network_level":6,"device_level":1,"device_model":"Example Phone"}';

  print(Uri.encodeComponent(query));
  // var splitQueryString = Uri.splitQueryString(uri.query);
  print(UriUtils.mapToQuery(uri.queryParameters));
  // print(uri.replace(queryParameters: splitQueryString));
  print(uri.replace(query: UriUtils.mapToQuery(uri.queryParameters)));
}
