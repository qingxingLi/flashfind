// Pure Dart SHA-256 (FIPS 180-4). The prototype keeps zero pub/Flutter dependencies,
// so the digest is computed here instead of importing package:crypto.
// Cross-checked against /usr/bin/openssl dgst -sha256 by run_sourcepin.py evidence.
import 'dart:typed_data';

const List<int> _k = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _mask(int value) => value & 0xFFFFFFFF;
int _rotr(int x, int n) => _mask((x >>> n) | (x << (32 - n)));

Uint8List sha256Bytes(List<int> message) {
  final bitLength = message.length * 8;
  final padded = ((message.length + 9) + 63) ~/ 64 * 64;
  final buffer = Uint8List(padded);
  buffer.setRange(0, message.length, message);
  buffer[message.length] = 0x80;
  final lengthOffset = padded - 8;
  for (var i = 0; i < 8; i++) {
    buffer[lengthOffset + i] = (bitLength >>> (56 - 8 * i)) & 0xFF;
  }
  final h = Uint32List.fromList(<int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);
  final w = Uint32List(64);
  for (var block = 0; block < padded; block += 64) {
    for (var i = 0; i < 16; i++) {
      final b = block + i * 4;
      w[i] = _mask((buffer[b] << 24) | (buffer[b + 1] << 16) | (buffer[b + 2] << 8) | buffer[b + 3]);
    }
    for (var i = 16; i < 64; i++) {
      final x = w[i - 15], y = w[i - 2];
      final s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >>> 3);
      final s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >>> 10);
      w[i] = _mask(w[i - 16] + s0 + w[i - 7] + s1);
    }
    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], t = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = _mask((e & f) ^ (_mask(~e) & g));
      final temp1 = _mask(t + s1 + ch + _k[i] + w[i]);
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = _mask((a & b) ^ (a & c) ^ (b & c));
      final temp2 = _mask(s0 + maj);
      t = g; g = f; f = e; e = _mask(d + temp1); d = c; c = b; b = a; a = _mask(temp1 + temp2);
    }
    h[0] = _mask(h[0] + a); h[1] = _mask(h[1] + b); h[2] = _mask(h[2] + c); h[3] = _mask(h[3] + d);
    h[4] = _mask(h[4] + e); h[5] = _mask(h[5] + f); h[6] = _mask(h[6] + g); h[7] = _mask(h[7] + t);
  }
  final out = Uint8List(32);
  for (var i = 0; i < 8; i++) {
    out[i * 4] = (h[i] >>> 24) & 0xFF;
    out[i * 4 + 1] = (h[i] >>> 16) & 0xFF;
    out[i * 4 + 2] = (h[i] >>> 8) & 0xFF;
    out[i * 4 + 3] = h[i] & 0xFF;
  }
  return out;
}

String sha256Hex(List<int> message) =>
    sha256Bytes(message).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
