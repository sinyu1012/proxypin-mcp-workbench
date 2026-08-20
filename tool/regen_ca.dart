// 本地开发脚本: 生成仅供当前机器测试的 ProxyPin 根 CA.
// 输出到被 Git 忽略的 build/local-ca，绝不写入应用资源目录.
//
// 运行: dart run tool/regen_ca.dart           # 默认 10 年 (内置默认根 CA)
//       dart run tool/regen_ca.dart --user    # 825 天 (UI "重新生成根证书" 场景)
//
// 与 lib/network/util/crts.dart#generateNewRootCA 等价的实现, 但不依赖
// path_provider / Flutter assets 加载。输出只用于本地验证，禁止提交私钥.
import 'dart:io';

import 'package:pointycastle/asymmetric/api.dart';
import 'package:proxypin/network/util/cert/basic_constraints.dart';
import 'package:proxypin/network/util/cert/cert_data.dart';
import 'package:proxypin/network/util/cert/extension.dart';
import 'package:proxypin/network/util/cert/key_usage.dart';
import 'package:proxypin/network/util/cert/x509.dart';
import 'package:proxypin/network/util/crypto.dart';
import 'package:proxypin/network/util/random.dart';

const int _defaultRootCaDays = 3650; // 10 年 — 本地测试 CA
const int _userRegenCaDays = 825; // 2.26 年 — UI "重新生成根证书" 场景
// 与 crts.dart::generateNewRootCA 保持一致

Future<void> main(List<String> args) async {
  // 解析 --user 标志: 默认 10 年, --user 切到 825 天
  final isUserMode = args.contains('--user');
  final days = isUserMode ? _userRegenCaDays : _defaultRootCaDays;

  final keyPair = CryptoUtils.generateRSAKeyPair();
  final pubKey = keyPair.publicKey as RSAPublicKey;
  final priKey = keyPair.privateKey as RSAPrivateKey;

  final dateSuffix = DateTime.now().toIso8601String().substring(0, 10);
  final cn = 'ProxyPin CA ($dateSuffix,${RandomUtil.randomString(6).toUpperCase()})';

  final subject = <String, String>{
    'C': 'CN',
    'ST': 'BJ',
    'L': 'Beijing',
    'O': 'Proxy',
    'OU': 'ProxyPin',
    'CN': cn,
  };

  final caPem = X509Utils.generateSelfSignedCertificate(
    // 这里传一个 dummy caRoot, 但因为 issuer + subject 同时被覆盖, 实际签发自签名 CA.
    // generateSelfSignedCertificate 内部需要 caRoot.signatureAlgorithm, 用一个临时占位.
    // 我们直接复用现有 ca.crt 的算法 oid.
    _dummyCaRoot(),
    pubKey,
    priKey,
    days,
    sans: [cn],
    serialNumber: DateTime.now().millisecondsSinceEpoch.toString(),
    issuer: subject,
    subject: subject,
    keyUsage: ExtensionKeyUsage(ExtensionKeyUsage.keyCertSign | ExtensionKeyUsage.cRLSign),
    extKeyUsage: const [ExtendedKeyUsage.SERVER_AUTH, ExtendedKeyUsage.CLIENT_AUTH],
    basicConstraints: BasicConstraints(isCA: true),
  );

  const outputDirectory = 'build/local-ca';
  await Directory(outputDirectory).create(recursive: true);
  const caPath = '$outputDirectory/ca.crt';
  const keyPath = '$outputDirectory/ca_key.pem';
  await File(caPath).writeAsString(caPem);
  await File(keyPath).writeAsString(CryptoUtils.encodeRSAPrivateKeyToPem(priKey));
  if (!Platform.isWindows) {
    await Process.run('chmod', ['600', keyPath]);
  }

  // Print CN 与有效期以便人眼确认.
  print('Regenerated CA: CN=$cn  (days=$days, mode=${isUserMode ? "user" : "default"})');
  print('Wrote local-only files: $caPath and $keyPath');
}

// 临时占位 caRoot: 复用仓库里现有 ca.crt 解析出的元数据 (只为拿到 signatureAlgorithm OID).
// 最终签发使用 issuer/subject 覆盖, 因此这是纯算法复用, 不参与证书内容.
X509CertificateData _dummyCaRoot() {
  final pem = File('assets/certs/ca.crt').readAsStringSync();
  return X509Utils.x509CertificateFromPem(pem);
}
