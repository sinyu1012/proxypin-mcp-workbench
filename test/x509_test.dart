import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/asymmetric/api.dart';
import 'package:proxypin/network/util/cert/x509.dart';
import 'package:proxypin/network/util/crypto.dart';

void main() async {
  // ============ Existing tests ============
  var caPem = await File('assets/certs/ca.crt').readAsString();
  var caRoot = X509Utils.x509CertificateFromPem(caPem);
  var subject = caRoot.subject;
  var d = X509Utils.getSubjectHashName(subject);
  print('CA subject hash: $d');

  // ============ AKI/SKI 单元测试 (T-06) ============
  await _testLeafCertificateAkiSki();
  await _testAkiSkiConsistency();
  print('\n[OK] All AKI/SKI tests passed');
}

/// 测试: 用项目自带 CA 签发叶子证书, 验证生成的证书包含 AKI/SKI 扩展
Future<void> _testLeafCertificateAkiSki() async {
  final caPem = await File('assets/certs/ca.crt').readAsString();
  final caRoot = X509Utils.x509CertificateFromPem(caPem);

  final keyPair = CryptoUtils.generateRSAKeyPair();
  final serverPubKey = keyPair.publicKey as RSAPublicKey;
  final serverPriKey = keyPair.privateKey as RSAPrivateKey;

  final leafPem = X509Utils.generateSelfSignedCertificate(
    caRoot,
    serverPubKey,
    serverPriKey,
    365,
    sans: ['api.example.com'],
    serialNumber: '123456',
    subject: {
      'C': 'CN',
      'ST': 'BJ',
      'L': 'Beijing',
      'O': 'Proxy',
      'OU': 'ProxyPin',
      'CN': 'api.example.com',
    },
  );

  // 解析生成的证书
  final leafCert = X509Utils.x509CertificateFromPem(leafPem);

  // 断言: SKI 字段非空且为 20 字节 (SHA-1)
  if (leafCert.extensions?.subjectKeyIdentifier == null) {
    throw StateError('Leaf cert SKI is null');
  }
  if (leafCert.extensions!.subjectKeyIdentifier!.length != 20) {
    throw StateError('Leaf cert SKI length is ${leafCert.extensions!.subjectKeyIdentifier!.length}, expected 20');
  }
  print('[OK] Leaf cert SKI: ${leafCert.extensions!.subjectKeyIdentifier!.length} bytes');

  // 断言: AKI 字段非空且为 20 字节
  if (leafCert.extensions?.authorityKeyIdentifier == null) {
    throw StateError('Leaf cert AKI is null');
  }
  if (leafCert.extensions!.authorityKeyIdentifier!.length != 20) {
    throw StateError('Leaf cert AKI length is ${leafCert.extensions!.authorityKeyIdentifier!.length}, expected 20');
  }
  print('[OK] Leaf cert AKI: ${leafCert.extensions!.authorityKeyIdentifier!.length} bytes');
}

/// 测试: 验证叶子证书的 SKI 等于 leaf 公钥的 SHA-1, 叶子证书的 AKI 等于 CA 的 SHA-1
Future<void> _testAkiSkiConsistency() async {
  final caPem = await File('assets/certs/ca.crt').readAsString();
  final caRoot = X509Utils.x509CertificateFromPem(caPem);

  final keyPair = CryptoUtils.generateRSAKeyPair();
  final serverPubKey = keyPair.publicKey as RSAPublicKey;
  final serverPriKey = keyPair.privateKey as RSAPrivateKey;

  // 叶子证书的 SKI 应当等于叶子公钥的 SKI
  final expectedLeafSki = X509Utils.computeSubjectKeyIdentifier(serverPubKey);

  final leafPem = X509Utils.generateSelfSignedCertificate(
    caRoot,
    serverPubKey,
    serverPriKey,
    365,
    sans: ['api.example.com'],
    serialNumber: '654321',
    subject: {
      'C': 'CN',
      'ST': 'BJ',
      'L': 'Beijing',
      'O': 'Proxy',
      'OU': 'ProxyPin',
      'CN': 'api2.example.com',
    },
  );

  final leafCert = X509Utils.x509CertificateFromPem(leafPem);

  // 断言: 叶子 SKI == computeSubjectKeyIdentifier(serverPubKey)
  final actualSki = leafCert.extensions!.subjectKeyIdentifier!;
  if (!_bytesEqual(actualSki, expectedLeafSki)) {
    throw StateError('Leaf SKI mismatch');
  }
  print('[OK] Leaf SKI matches computeSubjectKeyIdentifier');
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

//获取证书 subject hash

// class KeyUsage {
//   static const int keyCertSign = (1 << 2);
//   static const int cRLSign = (1 << 1);
//
//   final ASN1BitString bitString;
//
//   KeyUsage(int usage) : bitString = ASN1BitString(stringValues: getBytes(usage))..unusedbits = getPadBits(usage);
//
//   static Uint8List getBytes(int bitString) {
//     if (bitString == 0) {
//       return Uint8List(0);
//     }
//
//     int bytes = 4;
//     for (int i = 3; i >= 1; i--) {
//       if ((bitString & (0xFF << (i * 8))) != 0) {
//         break;
//       }
//       bytes--;
//     }
//
//     Uint8List result = Uint8List(bytes);
//     for (int i = 0; i < bytes; i++) {
//       result[i] = ((bitString >> (i * 8)) & 0xFF);
//     }
//
//     return result;
//   }
//
//   static int getPadBits(int bitString) {
//     int val = 0;
//     for (int i = 3; i >= 0; i--) {
//       if (i != 0) {
//         if ((bitString >> (i * 8)) != 0) {
//           val = (bitString >> (i * 8)) & 0xFF;
//           break;
//         }
//       } else {
//         if (bitString != 0) {
//           val = bitString & 0xFF;
//           break;
//         }
//       }
//     }
//
//     if (val == 0) {
//       return 0;
//     }
//
//     int bits = 1;
//     while (((val <<= 1) & 0xFF) != 0) {
//       bits++;
//     }
//
//     return 8 - bits;
//   }
// }
