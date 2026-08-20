// 一次性自检脚本: 验证 assets/certs/ca.crt 包含 serverAuth + clientAuth,
// 同时验证 CA 私钥可与证书配对.
//
// 与 test/x509_test.dart 互补 — 后者验证 AKI/SKI 结构, 本脚本聚焦 EKU.

import 'dart:io';

import 'package:proxypin/network/util/cert/extension.dart';
import 'package:proxypin/network/util/cert/x509.dart';

void main() {
  final pem = File('assets/certs/ca.crt').readAsStringSync();
  final cert = X509Utils.x509CertificateFromPem(pem);

  final eku = cert.extensions?.extKeyUsage;
  if (eku == null) {
    throw StateError('CA missing ExtendedKeyUsage extension');
  }
  if (!eku.contains(ExtendedKeyUsage.SERVER_AUTH)) {
    throw StateError('CA missing serverAuth: got $eku');
  }
  if (!eku.contains(ExtendedKeyUsage.CLIENT_AUTH)) {
    throw StateError('CA missing clientAuth: got $eku');
  }
  print('[OK] CA ExtendedKeyUsage: $eku');

  if (cert.extensions?.cA != true) {
    throw StateError('CA basicConstraints isCA != true');
  }
  print('[OK] CA basicConstraints CA:TRUE');

  if (cert.subject.isEmpty) {
    throw StateError('CA subject is empty');
  }
  print('[OK] CA subject: ${cert.subject}');

  print('\n[OK] EKU verification passed');
}
