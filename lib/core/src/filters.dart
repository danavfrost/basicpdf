// Stream filters (decoding) and Flate encoding.

import 'dart:io' show ZLibDecoder, ZLibEncoder;
import 'dart:typed_data';

import 'objects.dart';

class UnsupportedFilterException implements Exception {
  final String filter;
  UnsupportedFilterException(this.filter);
  @override
  String toString() => 'Unsupported filter $filter';
}

class _Collect implements Sink<List<int>> {
  final BytesBuilder b = BytesBuilder(copy: true);
  @override
  void add(List<int> data) => b.add(data);
  @override
  void close() {}
}

Uint8List flateDecode(Uint8List data) {
  try {
    final r = ZLibDecoder().convert(data);
    return r is Uint8List ? r : Uint8List.fromList(r);
  } catch (_) {
    // fall through to lenient decoding
  }
  // Lenient: decode as much as possible (truncated / trailing garbage).
  for (final raw in [false, true]) {
    final col = _Collect();
    try {
      final input = raw && data.length > 2
          ? Uint8List.sublistView(data, 2)
          : data;
      final sink = ZLibDecoder(raw: raw).startChunkedConversion(col);
      const chunk = 512;
      for (var i = 0; i < input.length; i += chunk) {
        sink.add(
          Uint8List.sublistView(
            input,
            i,
            i + chunk > input.length ? input.length : i + chunk,
          ),
        );
      }
      sink.close();
    } catch (_) {
      // keep what we have
    }
    if (col.b.length > 0) return col.b.takeBytes();
  }
  throw const FormatException('bad Flate data');
}

Uint8List flateEncode(List<int> data) {
  final r = ZLibEncoder(level: 6).convert(data);
  return r is Uint8List ? r : Uint8List.fromList(r);
}

Uint8List asciiHexDecode(Uint8List data) {
  final out = <int>[];
  var hi = -1;
  for (final c in data) {
    if (c == 0x3e) break;
    int v;
    if (c >= 0x30 && c <= 0x39) {
      v = c - 0x30;
    } else if (c >= 0x41 && c <= 0x46) {
      v = c - 0x37;
    } else if (c >= 0x61 && c <= 0x66) {
      v = c - 0x57;
    } else {
      continue;
    }
    if (hi < 0) {
      hi = v;
    } else {
      out.add(hi * 16 + v);
      hi = -1;
    }
  }
  if (hi >= 0) out.add(hi * 16);
  return Uint8List.fromList(out);
}

Uint8List ascii85Decode(Uint8List data) {
  final out = <int>[];
  var i = 0;
  // optional "<~" prefix
  while (i < data.length && (data[i] <= 0x20)) {
    i++;
  }
  if (i + 1 < data.length && data[i] == 0x3c && data[i + 1] == 0x7e) i += 2;
  final group = <int>[];
  for (; i < data.length; i++) {
    final c = data[i];
    if (c == 0x7e) break; // "~>"
    if (c <= 0x20) continue;
    if (c == 0x7a && group.isEmpty) {
      out.addAll(const [0, 0, 0, 0]);
      continue;
    }
    if (c < 0x21 || c > 0x75) continue;
    group.add(c - 0x21);
    if (group.length == 5) {
      var v = 0;
      for (final g in group) {
        v = v * 85 + g;
      }
      out
        ..add((v >> 24) & 0xff)
        ..add((v >> 16) & 0xff)
        ..add((v >> 8) & 0xff)
        ..add(v & 0xff);
      group.clear();
    }
  }
  if (group.isNotEmpty) {
    final n = group.length;
    while (group.length < 5) {
      group.add(84);
    }
    var v = 0;
    for (final g in group) {
      v = v * 85 + g;
    }
    final bytes = [
      (v >> 24) & 0xff,
      (v >> 16) & 0xff,
      (v >> 8) & 0xff,
      v & 0xff,
    ];
    out.addAll(bytes.take(n - 1));
  }
  return Uint8List.fromList(out);
}

Uint8List runLengthDecode(Uint8List data) {
  final out = <int>[];
  var i = 0;
  while (i < data.length) {
    final len = data[i++];
    if (len == 128) break;
    if (len < 128) {
      final n = len + 1;
      for (var j = 0; j < n && i < data.length; j++) {
        out.add(data[i++]);
      }
    } else {
      if (i >= data.length) break;
      final b = data[i++];
      for (var j = 0; j < 257 - len; j++) {
        out.add(b);
      }
    }
  }
  return Uint8List.fromList(out);
}

Uint8List lzwDecode(Uint8List data, {int earlyChange = 1}) {
  final out = BytesBuilder(copy: false);
  final table = <List<int>>[];
  void reset() {
    table
      ..clear()
      ..addAll([
        for (var i = 0; i < 256; i++) [i],
      ])
      ..add(const [])
      ..add(const []);
  }

  reset();
  var codeLen = 9;
  var bitBuf = 0, bitCount = 0;
  List<int>? prev;
  var i = 0;
  while (true) {
    while (bitCount < codeLen) {
      if (i >= data.length) return out.takeBytes();
      bitBuf = ((bitBuf << 8) | data[i++]) & 0xffffffff;
      bitCount += 8;
    }
    final code = (bitBuf >> (bitCount - codeLen)) & ((1 << codeLen) - 1);
    bitCount -= codeLen;
    if (code == 256) {
      reset();
      codeLen = 9;
      prev = null;
      continue;
    }
    if (code == 257) break;
    List<int> entry;
    if (code < table.length) {
      entry = table[code];
      if (prev != null) table.add([...prev, entry[0]]);
    } else if (prev != null) {
      entry = [...prev, prev[0]];
      table.add(entry);
    } else {
      break;
    }
    out.add(Uint8List.fromList(entry));
    prev = entry;
    final size = table.length + earlyChange;
    if (size >= 4096) {
      codeLen = 12;
    } else if (size >= 2048) {
      codeLen = 12;
    } else if (size >= 1024) {
      codeLen = 11;
    } else if (size >= 512) {
      codeLen = 10;
    }
  }
  return out.takeBytes();
}

Uint8List applyPredictor(Uint8List data, PdfDict? parms) {
  if (parms == null) return data;
  final predictor = intValue(parms['Predictor']) ?? 1;
  if (predictor <= 1) return data;
  final colors = intValue(parms['Colors']) ?? 1;
  final bpc = intValue(parms['BitsPerComponent']) ?? 8;
  final columns = intValue(parms['Columns']) ?? 1;
  final bpp = ((colors * bpc) + 7) ~/ 8;
  final rowLen = (colors * bpc * columns + 7) ~/ 8;
  if (predictor == 2) {
    if (bpc != 8) return data;
    final out = Uint8List.fromList(data);
    for (var r = 0; r + rowLen <= out.length; r += rowLen) {
      for (var x = bpp; x < rowLen; x++) {
        out[r + x] = (out[r + x] + out[r + x - bpp]) & 0xff;
      }
    }
    return out;
  }
  // PNG predictors: each row prefixed by a filter-type byte.
  final rows =
      data.length ~/ (rowLen + 1) + ((data.length % (rowLen + 1)) > 1 ? 1 : 0);
  final out = Uint8List(rows * rowLen);
  final prior = Uint8List(rowLen);
  var inPos = 0;
  var outPos = 0;
  for (var r = 0; r < rows; r++) {
    if (inPos >= data.length) break;
    final type = data[inPos++];
    final cur = Uint8List(rowLen);
    for (var x = 0; x < rowLen && inPos < data.length; x++) {
      cur[x] = data[inPos++];
    }
    for (var x = 0; x < rowLen; x++) {
      final left = x >= bpp ? cur[x - bpp] : 0;
      final up = prior[x];
      final upLeft = x >= bpp ? prior[x - bpp] : 0;
      int v;
      switch (type) {
        case 1:
          v = cur[x] + left;
        case 2:
          v = cur[x] + up;
        case 3:
          v = cur[x] + ((left + up) >> 1);
        case 4:
          final p = left + up - upLeft;
          final pa = (p - left).abs(),
              pb = (p - up).abs(),
              pc = (p - upLeft).abs();
          final pred = (pa <= pb && pa <= pc) ? left : (pb <= pc ? up : upLeft);
          v = cur[x] + pred;
        default:
          v = cur[x];
      }
      cur[x] = v & 0xff;
    }
    out.setRange(outPos, outPos + rowLen, cur);
    outPos += rowLen;
    prior.setAll(0, cur);
  }
  return outPos == out.length ? out : Uint8List.sublistView(out, 0, outPos);
}

/// Decodes stream [data] according to [dict]'s /Filter and /DecodeParms.
/// Image-only filters (DCT, JPX, CCITT, JBIG2) throw
/// [UnsupportedFilterException]; we never need image data.
Uint8List decodeStreamData(
  Uint8List data,
  PdfDict dict, {
  Object? Function(Object?)? resolve,
}) {
  Object? r(Object? o) => resolve == null ? o : resolve(o);
  var filters = r(dict['Filter'] ?? dict['F']);
  var parms = r(dict['DecodeParms'] ?? dict['DP']);
  final fl = <String>[];
  final pl = <PdfDict?>[];
  if (filters is PdfName) {
    fl.add(filters.name);
    final p = r(parms is List ? (parms.isEmpty ? null : parms[0]) : parms);
    pl.add(p is PdfDict ? p : null);
  } else if (filters is List) {
    for (var i = 0; i < filters.length; i++) {
      final f = r(filters[i]);
      if (f is! PdfName) continue;
      fl.add(f.name);
      Object? p;
      if (parms is List && i < parms.length) p = r(parms[i]);
      if (parms is PdfDict && filters.length == 1) p = parms;
      pl.add(p is PdfDict ? p : null);
    }
  }
  var out = data;
  for (var i = 0; i < fl.length; i++) {
    switch (fl[i]) {
      case 'FlateDecode':
      case 'Fl':
        out = applyPredictor(flateDecode(out), pl[i]);
      case 'LZWDecode':
      case 'LZW':
        out = applyPredictor(
          lzwDecode(out, earlyChange: intValue(pl[i]?['EarlyChange']) ?? 1),
          pl[i],
        );
      case 'ASCIIHexDecode':
      case 'AHx':
        out = asciiHexDecode(out);
      case 'ASCII85Decode':
      case 'A85':
        out = ascii85Decode(out);
      case 'RunLengthDecode':
      case 'RL':
        out = runLengthDecode(out);
      case 'Crypt':
        break; // handled by the security layer
      default:
        throw UnsupportedFilterException(fl[i]);
    }
  }
  return out;
}

/// Flate-compresses a stream's data in place when worthwhile.
PdfStream compressStream(PdfStream s) {
  if (s.data.length < 128 || s.dict['Filter'] != null) return s;
  s.data = flateEncode(s.data);
  s.dict['Filter'] = const PdfName('FlateDecode');
  return s;
}
