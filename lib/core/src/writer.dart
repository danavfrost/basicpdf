// Working set of changed objects + incremental update writer.

import 'dart:typed_data';

import 'filters.dart';
import 'model.dart';
import 'objects.dart';
import 'pdf_file.dart';
import 'security.dart';

class Editor implements ObjectSource {
  final PdfFile file;
  final Map<int, Object?> changed = {};
  final Map<int, int> gens = {};
  late int nextNum = file.size;

  Editor(this.file);

  @override
  Object? resolve(Object? o) {
    var d = 0;
    while (o is PdfRef) {
      if (d++ > 32) return null;
      o = changed.containsKey(o.num) ? changed[o.num] : file.getObject(o.num);
    }
    return o;
  }

  /// A mutable copy of the object behind [ref], tracked for writing.
  Object? mutable(PdfRef ref) {
    if (!changed.containsKey(ref.num)) {
      changed[ref.num] = deepCopy(file.getObject(ref.num));
      gens[ref.num] = file.genOf(ref.num);
    }
    return changed[ref.num];
  }

  PdfRef add(Object? o) {
    final n = nextNum++;
    changed[n] = o;
    gens[n] = 0;
    return PdfRef(n, 0);
  }

  /// Mutable dictionary stored under [key] of mutable [parent] (following
  /// an indirect reference). Creates a direct dict if [create] and absent.
  PdfDict? subDict(PdfDict parent, String key, {bool create = false}) {
    final v = parent[key];
    if (v is PdfRef) {
      final r = resolve(v);
      if (r is PdfDict) return mutable(v) as PdfDict;
      if (r is PdfStream) return (mutable(v) as PdfStream).dict;
    } else if (v is PdfDict) {
      return v;
    }
    if (!create) return null;
    final d = PdfDict();
    parent[key] = d;
    return d;
  }

  /// Mutable array stored under [key] of mutable [parent].
  List<Object?>? subList(PdfDict parent, String key, {bool create = false}) {
    final v = parent[key];
    if (v is PdfRef) {
      final r = resolve(v);
      if (r is List) return mutable(v) as List<Object?>;
    } else if (v is List) {
      return v as List<Object?>;
    }
    if (!create) return null;
    final l = <Object?>[];
    parent[key] = l;
    return l;
  }

  // -------------------------------------------------------------------------

  /// Appends an update section with all changed objects to the original
  /// bytes. [trailerExtra] overrides trailer entries (e.g. a new /Root).
  Uint8List write({PdfDict? trailerOverride}) {
    final sec = file.security;
    final base = file.data;
    final out = PdfWriterBuffer();
    final needNl = base.isNotEmpty && base.last != 0x0a && base.last != 0x0d;
    if (needNl) out.ascii('\n');
    final offsets = <int, int>{};
    final nums = changed.keys.toList()..sort();
    for (final n in nums) {
      final gen = gens[n] ?? 0;
      offsets[n] = base.length + out.length;
      _writeIndirect(out, n, gen, changed[n], sec);
    }
    final t = PdfDict();
    final ft = file.trailer;
    for (final k in const ['Root', 'Info', 'ID', 'Encrypt']) {
      if (ft[k] != null) t[k] = ft[k];
    }
    if (trailerOverride != null) {
      for (final e in trailerOverride.entries) {
        t[e.key] = e.value;
      }
    }
    // ID must be direct.
    final id = file.resolve(t['ID']);
    if (id is List && id.length >= 2) {
      t['ID'] = [file.resolve(id[0]), file.resolve(id[1])];
    } else if (sec == null) {
      final a = PdfString(randomBytes(16), hex: true);
      t['ID'] = [a, a];
    }
    final xrefOffset = base.length + out.length;
    final full = file.repaired;
    final entries = <int, XrefEntry>{};
    if (full) {
      file.xref.forEach((k, v) {
        if (v.type != 0) entries[k] = v;
      });
    }
    offsets.forEach((k, v) => entries[k] = XrefEntry(1, v, gens[k] ?? 0));
    final useStream = full
        ? entries.values.any((e) => e.type == 2)
        : file.lastSectionIsStream;
    if (!full && file.startXref >= 0) t['Prev'] = file.startXref;
    if (useStream) {
      final xn = nextNum++;
      entries[xn] = XrefEntry(1, xrefOffset, 0);
      t['Size'] = _size(entries);
      _writeXrefStream(out, xn, entries, t, full);
    } else {
      t['Size'] = _size(entries);
      _writeXrefTable(out, entries, full);
      out.ascii('trailer\n');
      out.writeObject(t);
      out.ascii('\n');
    }
    out.ascii('startxref\n$xrefOffset\n%%EOF\n');
    final tail = out.takeBytes();
    final result = Uint8List(base.length + tail.length)
      ..setRange(0, base.length, base)
      ..setRange(base.length, base.length + tail.length, tail);
    return result;
  }

  int _size(Map<int, XrefEntry> entries) {
    var m = file.size;
    for (final k in entries.keys) {
      if (k + 1 > m) m = k + 1;
    }
    if (nextNum > m) m = nextNum;
    return m;
  }

  static List<List<int>> _groups(List<int> nums) {
    final groups = <List<int>>[];
    for (final n in nums) {
      if (groups.isNotEmpty && groups.last.last + 1 == n) {
        groups.last.add(n);
      } else {
        groups.add([n]);
      }
    }
    return groups;
  }

  void _writeXrefTable(
    PdfWriterBuffer out,
    Map<int, XrefEntry> entries,
    bool full,
  ) {
    out.ascii('xref\n');
    final nums = entries.keys.where((n) => n != 0).toList()..sort();
    if (full) {
      out.ascii('0 1\n0000000000 65535 f \n');
    }
    for (final g in _groups(nums)) {
      out.ascii('${g.first} ${g.length}\n');
      final sb = StringBuffer();
      for (final n in g) {
        final e = entries[n]!;
        sb
          ..write(e.offset.toString().padLeft(10, '0'))
          ..write(' ')
          ..write(e.gen.toString().padLeft(5, '0'))
          ..write(' n \n');
      }
      out.ascii(sb.toString());
    }
  }

  void _writeXrefStream(
    PdfWriterBuffer out,
    int xn,
    Map<int, XrefEntry> entries,
    PdfDict trailer,
    bool full,
  ) {
    final nums = entries.keys.where((n) => n != 0).toList()..sort();
    final index = <int>[];
    final rows = BytesBuilder();
    if (full) {
      index.addAll([0, 1]);
      rows.add([0, 0, 0, 0, 0, 0xff, 0xff]);
    }
    for (final g in _groups(nums)) {
      index.addAll([g.first, g.length]);
      for (final n in g) {
        final e = entries[n]!;
        final a = e.offset;
        rows.add([
          e.type,
          (a >> 24) & 0xff,
          (a >> 16) & 0xff,
          (a >> 8) & 0xff,
          a & 0xff,
          (e.gen >> 8) & 0xff,
          e.gen & 0xff,
        ]);
      }
    }
    final data = flateEncode(rows.takeBytes());
    final d = PdfDict({
      'Type': const PdfName('XRef'),
      for (final e in trailer.entries) e.key: e.value,
      'W': [1, 4, 2],
      'Index': index,
      'Filter': const PdfName('FlateDecode'),
      'Length': data.length,
    });
    out.ascii('$xn 0 obj\n');
    out.writeObject(d);
    out.ascii('\nstream\n');
    out.bytes(data);
    out.ascii('\nendstream\nendobj\n');
  }

  void _writeIndirect(
    PdfWriterBuffer out,
    int num,
    int gen,
    Object? obj,
    SecurityHandler? sec,
  ) {
    StringEncoder? enc;
    if (sec != null) {
      enc = (b) => sec.encryptString(b, num, gen);
    }
    out.ascii('$num $gen obj\n');
    if (obj is PdfStream) {
      var data = obj.data;
      final d = PdfDict(Map.of(obj.dict.map));
      if (sec != null) {
        final type = d.name('Type');
        final skip =
            type == 'XRef' || (type == 'Metadata' && !sec.encryptMetadata);
        if (!skip) data = sec.encryptStream(data, num, gen);
      }
      d['Length'] = data.length;
      out.writeObject(d, enc: enc);
      out.ascii('\nstream\n');
      out.bytes(data);
      out.ascii('\nendstream\nendobj\n');
    } else {
      out.writeObject(obj, enc: enc);
      out.ascii('\nendobj\n');
    }
  }
}
