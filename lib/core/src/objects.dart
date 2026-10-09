// PDF object model.
//
// Direct values are represented as:
//   null            → PDF null
//   bool            → boolean
//   int / double    → numbers
//   PdfName         → /Name
//   PdfString       → (literal) or <hex> string (raw bytes)
//   List<Object?>   → array
//   PdfDict         → dictionary
//   PdfStream       → stream (dictionary + raw, still-filtered data)
//   PdfRef          → indirect reference "n g R"

import 'dart:convert';
import 'dart:typed_data';

class PdfName {
  final String name;
  const PdfName(this.name);
  @override
  bool operator ==(Object other) => other is PdfName && other.name == name;
  @override
  int get hashCode => name.hashCode ^ 0x5a5a;
  @override
  String toString() => '/$name';
}

class PdfString {
  /// Raw bytes (decrypted).
  final Uint8List bytes;
  final bool hex;
  PdfString(this.bytes, {this.hex = false});
  factory PdfString.latin1(String s) =>
      PdfString(Uint8List.fromList(latin1.encode(s)));
  String get latin1Value => latin1.decode(bytes, allowInvalid: true);
  @override
  bool operator ==(Object other) {
    if (other is! PdfString || other.bytes.length != bytes.length) {
      return false;
    }
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != other.bytes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(bytes);
  @override
  String toString() => '($latin1Value)';
}

class PdfRef {
  final int num;
  final int gen;
  const PdfRef(this.num, this.gen);
  @override
  bool operator ==(Object other) =>
      other is PdfRef && other.num == num && other.gen == gen;
  @override
  int get hashCode => num * 31 + gen;
  @override
  String toString() => '$num $gen R';
  String get id => '$num $gen';
}

/// Keyword token produced by the lexer (obj, endobj, stream, R, ...).
class PdfKeyword {
  final String word;
  const PdfKeyword(this.word);
  @override
  bool operator ==(Object other) => other is PdfKeyword && other.word == word;
  @override
  int get hashCode => word.hashCode;
  @override
  String toString() => word;
}

class PdfDict {
  final Map<String, Object?> map;
  PdfDict([Map<String, Object?>? m]) : map = m ?? <String, Object?>{};

  Object? operator [](String key) => map[key];
  void operator []=(String key, Object? value) {
    if (value == null) {
      map.remove(key);
    } else {
      map[key] = value;
    }
  }

  bool containsKey(String key) => map.containsKey(key);
  Object? remove(String key) => map.remove(key);
  Iterable<String> get keys => map.keys;
  Iterable<MapEntry<String, Object?>> get entries => map.entries;

  /// Name value of [key] (or null).
  String? name(String key) {
    final v = map[key];
    return v is PdfName ? v.name : null;
  }

  @override
  String toString() =>
      '<<${map.entries.map((e) => ' /${e.key} ${e.value}').join()} >>';
}

class PdfStream {
  final PdfDict dict;

  /// Raw stream bytes, still encoded with the stream's /Filter but already
  /// decrypted.
  Uint8List data;
  PdfStream(this.dict, this.data);
  @override
  String toString() => 'stream$dict[${data.length}]';
}

/// Deep-copies direct structure; references are kept as references.
Object? deepCopy(Object? o) {
  if (o is PdfDict) {
    final m = <String, Object?>{};
    o.map.forEach((k, v) => m[k] = deepCopy(v));
    return PdfDict(m);
  }
  if (o is List) return [for (final e in o) deepCopy(e)];
  if (o is PdfStream) {
    return PdfStream(deepCopy(o.dict) as PdfDict, o.data);
  }
  return o;
}

double? numValue(Object? o) {
  if (o is int) return o.toDouble();
  if (o is double) return o;
  return null;
}

int? intValue(Object? o) {
  if (o is int) return o;
  if (o is double) return o.round();
  return null;
}

// ---------------------------------------------------------------------------
// Serialisation

/// Transforms a string's bytes when serialising (encryption hook).
typedef StringEncoder = Uint8List Function(Uint8List bytes);

const _hexDigits = '0123456789ABCDEF';

bool _isRegularNameChar(int c) {
  if (c < 0x21 || c > 0x7e) return false;
  switch (c) {
    case 0x23: // #
    case 0x28: // (
    case 0x29: // )
    case 0x3c: // <
    case 0x3e: // >
    case 0x5b: // [
    case 0x5d: // ]
    case 0x7b: // {
    case 0x7d: // }
    case 0x2f: // /
    case 0x25: // %
      return false;
  }
  return true;
}

String formatNumber(num n) {
  if (n is int) return n.toString();
  final d = n.toDouble();
  if (d.isNaN || d.isInfinite) return '0';
  if (d == d.roundToDouble() && d.abs() < 1e15) return d.round().toString();
  var s = d.toStringAsFixed(4);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  }
  if (s == '-0') s = '0';
  return s;
}

class PdfWriterBuffer {
  final BytesBuilder _b = BytesBuilder(copy: false);
  int get length => _b.length;

  void ascii(String s) {
    final out = Uint8List(s.length);
    for (var i = 0; i < s.length; i++) {
      out[i] = s.codeUnitAt(i) & 0xff;
    }
    _b.add(out);
  }

  void bytes(List<int> b) => _b.add(b is Uint8List ? b : Uint8List.fromList(b));

  Uint8List takeBytes() => _b.takeBytes();

  void writeName(String name) {
    final sb = StringBuffer('/');
    // Names hold raw bytes as Latin-1 code units so they round-trip.
    for (final cu in name.codeUnits) {
      final c = cu & 0xff;
      if (_isRegularNameChar(c)) {
        sb.writeCharCode(c);
      } else {
        sb
          ..write('#')
          ..write(_hexDigits[c >> 4])
          ..write(_hexDigits[c & 15]);
      }
    }
    ascii(sb.toString());
  }

  void writeStringBytes(Uint8List b, {bool hex = false}) {
    if (hex) {
      final sb = StringBuffer('<');
      for (final c in b) {
        sb
          ..write(_hexDigits[c >> 4])
          ..write(_hexDigits[c & 15]);
      }
      sb.write('>');
      ascii(sb.toString());
      return;
    }
    final out = <int>[0x28];
    for (final c in b) {
      switch (c) {
        case 0x28:
        case 0x29:
        case 0x5c:
          out
            ..add(0x5c)
            ..add(c);
        case 0x0a:
          out.addAll(const [0x5c, 0x6e]);
        case 0x0d:
          out.addAll(const [0x5c, 0x72]);
        default:
          out.add(c);
      }
    }
    out.add(0x29);
    bytes(out);
  }

  /// Writes a direct object. [enc] (if given) transforms string bytes.
  void writeObject(Object? o, {StringEncoder? enc}) {
    if (o == null) {
      ascii('null');
    } else if (o is bool) {
      ascii(o ? 'true' : 'false');
    } else if (o is num) {
      ascii(formatNumber(o));
    } else if (o is PdfName) {
      writeName(o.name);
    } else if (o is PdfString) {
      if (enc != null) {
        writeStringBytes(enc(o.bytes), hex: true);
      } else {
        writeStringBytes(o.bytes, hex: o.hex);
      }
    } else if (o is PdfRef) {
      ascii('${o.num} ${o.gen} R');
    } else if (o is List) {
      ascii('[');
      var first = true;
      for (final e in o) {
        if (!first) ascii(' ');
        first = false;
        writeObject(e, enc: enc);
      }
      ascii(']');
    } else if (o is PdfDict) {
      ascii('<<');
      for (final e in o.map.entries) {
        writeName(e.key);
        ascii(' ');
        writeObject(e.value, enc: enc);
        ascii('\n');
      }
      ascii('>>');
    } else if (o is PdfStream) {
      throw ArgumentError('stream must be written as an indirect object');
    } else if (o is PdfKeyword) {
      ascii(o.word);
    } else {
      throw ArgumentError('cannot serialise $o');
    }
  }
}

/// Serialises a whole object to bytes (used for content and tests).
Uint8List serializeObject(Object? o) {
  final w = PdfWriterBuffer();
  w.writeObject(o);
  return w.takeBytes();
}
