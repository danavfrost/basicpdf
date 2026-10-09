// Creates a fresh text PDF (SPEC §1.4).

import 'dart:typed_data';

import 'appearance.dart';
import 'edit_session.dart' show helveticaFontDict;
import 'filters.dart';
import 'model.dart';
import 'objects.dart';
import 'security.dart' show randomBytes;
import 'text.dart';

const double pageWidth = 612;
const double pageHeight = 792;
const double pageMargin = 72;
const double bodyFontSize = 12;
const String bodyDA = '/Helv 12 Tf 0 g';

/// Splits [text] into per-page chunks (substrings of [text]) the way
/// [createTextDocumentBytes] does.
List<String> paginateText(String text) {
  const boxW = pageWidth - 2 * pageMargin;
  const boxH = pageHeight - 2 * pageMargin;
  final perPage = linesThatFit(boxH, 0, bodyFontSize);
  final lines = wrapText(
    text,
    textWidthFor(boxW, 0),
    bodyFontSize,
    FontMetrics.helvetica,
  );
  final pages = <String>[];
  for (var i = 0; i < lines.length; i += perPage) {
    final end = i + perPage < lines.length ? i + perPage : lines.length;
    pages.add(text.substring(lines[i].start, lines[end - 1].end));
  }
  if (pages.isEmpty) pages.add('');
  return pages;
}

Uint8List createTextDocumentBytes(String text) {
  final chunks = paginateText(text);
  final objects = <Object?>[]; // index i → object number i+1
  PdfRef add(Object? o) {
    objects.add(o);
    return PdfRef(objects.length, 0);
  }

  PdfRef reserve() => add(null);
  void set(PdfRef r, Object? o) => objects[r.num - 1] = o;

  final catalogRef = reserve();
  final pagesRef = reserve();
  final acroRef = reserve();
  final fontRef = add(helveticaFontDict());
  final infoRef = add(
    PdfDict({
      'Producer': PdfString.latin1('PDFEdit'),
      'CreationDate': PdfString.latin1(_pdfDate(DateTime.now())),
    }),
  );
  final pageRefs = <PdfRef>[];
  final fieldRefs = <PdfRef>[];
  const rect = [
    pageMargin,
    pageMargin,
    pageWidth - pageMargin,
    pageHeight - pageMargin,
  ];
  final look = WidgetLook(width: rect[2] - rect[0], height: rect[3] - rect[1]);
  const spec = TextLayoutSpec(
    fontName: 'Helv',
    metrics: FontMetrics.helvetica,
    fontSize: bodyFontSize,
    multiline: true,
  );
  for (var i = 0; i < chunks.length; i++) {
    final pageRef = reserve();
    final ap = compressStream(
      look.formXObject(
        textAppearanceContent(look, spec, chunks[i]),
        PdfDict({
          'Font': PdfDict({'Helv': fontRef}),
        }),
      ),
    );
    final apRef = add(ap);
    final field = add(
      PdfDict({
        'Type': const PdfName('Annot'),
        'Subtype': const PdfName('Widget'),
        'FT': const PdfName('Tx'),
        'Ff': ffMultiline | ffDoNotScroll,
        'T': PdfString.latin1('Body${i + 1}'),
        'V': encodeTextString(chunks[i]),
        'DA': PdfString.latin1(bodyDA),
        'Rect': [for (final x in rect) x.round()],
        'F': 4,
        'P': pageRef,
        'MK': PdfDict(),
        'AP': PdfDict({'N': apRef}),
      }),
    );
    set(
      pageRef,
      PdfDict({
        'Type': const PdfName('Page'),
        'Parent': pagesRef,
        'MediaBox': [0, 0, pageWidth.round(), pageHeight.round()],
        'Resources': PdfDict(),
        'Annots': [field],
      }),
    );
    pageRefs.add(pageRef);
    fieldRefs.add(field);
  }
  set(
    pagesRef,
    PdfDict({
      'Type': const PdfName('Pages'),
      'Kids': pageRefs,
      'Count': pageRefs.length,
    }),
  );
  set(
    acroRef,
    PdfDict({
      'Fields': fieldRefs,
      'DR': PdfDict({
        'Font': PdfDict({'Helv': fontRef}),
      }),
      'DA': PdfString.latin1(bodyDA),
    }),
  );
  set(
    catalogRef,
    PdfDict({
      'Type': const PdfName('Catalog'),
      'Pages': pagesRef,
      'AcroForm': acroRef,
    }),
  );

  final out = PdfWriterBuffer();
  out.ascii('%PDF-1.7\n');
  out.bytes(const [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    final o = objects[i];
    out.ascii('${i + 1} 0 obj\n');
    if (o is PdfStream) {
      o.dict['Length'] = o.data.length;
      out.writeObject(o.dict);
      out.ascii('\nstream\n');
      out.bytes(o.data);
      out.ascii('\nendstream\nendobj\n');
    } else {
      out.writeObject(o);
      out.ascii('\nendobj\n');
    }
  }
  final xref = out.length;
  final sb = StringBuffer(
    'xref\n0 ${objects.length + 1}\n0000000000 65535 f \n',
  );
  for (final off in offsets) {
    sb.write('${off.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.ascii(sb.toString());
  final id = PdfString(randomBytes(16), hex: true);
  out.ascii('trailer\n');
  out.writeObject(
    PdfDict({
      'Size': objects.length + 1,
      'Root': catalogRef,
      'Info': infoRef,
      'ID': [id, id],
    }),
  );
  out.ascii('\nstartxref\n$xref\n%%EOF\n');
  return out.takeBytes();
}

String _pdfDate(DateTime t) {
  final u = t.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return "D:${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}"
      "${two(u.minute)}${two(u.second)}Z";
}
