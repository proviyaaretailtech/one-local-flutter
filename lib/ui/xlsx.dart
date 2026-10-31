import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// A one-sheet Excel workbook (.xlsx) from rows (0628: the closing stock export): the first [headerRows] rows bold, numbers as numbers
/// (so Excel can add them up), everything else as text. [widths] sets column widths in characters.
Uint8List buildXlsx(String sheetName, List<List<Object?>> rows, {int headerRows = 1, List<double> widths = const []}) {
  String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
  String col(int i) {
    var n = i + 1, s = '';
    while (n > 0) {
      final r = (n - 1) % 26;
      s = String.fromCharCode(65 + r) + s;
      n = (n - 1) ~/ 26;
    }
    return s;
  }

  final sheet = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">');
  if (headerRows > 0) sheet.write('<sheetViews><sheetView workbookViewId="0"><pane ySplit="$headerRows" topLeftCell="A${headerRows + 1}" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>');
  if (widths.isNotEmpty) {
    sheet.write('<cols>');
    for (var i = 0; i < widths.length; i++) {
      sheet.write('<col min="${i + 1}" max="${i + 1}" width="${widths[i]}" customWidth="1"/>');
    }
    sheet.write('</cols>');
  }
  sheet.write('<sheetData>');
  for (var r = 0; r < rows.length; r++) {
    final style = r < headerRows ? ' s="1"' : '';
    sheet.write('<row r="${r + 1}">');
    for (var c = 0; c < rows[r].length; c++) {
      final v = rows[r][c];
      final ref = '${col(c)}${r + 1}';
      if (v == null) continue;
      if (v is num && r >= headerRows) {
        sheet.write('<c r="$ref"$style><v>$v</v></c>');
      } else {
        sheet.write('<c r="$ref" t="inlineStr"$style><is><t xml:space="preserve">${esc('$v')}</t></is></c>');
      }
    }
    sheet.write('</row>');
  }
  sheet.write('</sheetData></worksheet>');

  final name = esc(sheetName.length > 31 ? sheetName.substring(0, 31) : sheetName);
  final files = {
    '[Content_Types].xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '</Types>',
    '_rels/.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>',
    'xl/workbook.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="$name" sheetId="1" r:id="rId1"/></sheets></workbook>',
    'xl/_rels/workbook.xml.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '</Relationships>',
    'xl/styles.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
        '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>'
        '</styleSheet>',
    'xl/worksheets/sheet1.xml': sheet.toString(),
  };
  final archive = Archive();
  for (final e in files.entries) {
    archive.addFile(ArchiveFile.bytes(e.key, utf8.encode(e.value)));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// The first sheet of an Excel workbook (.xlsx) as rows of text (31 Oct 2026: the catalogue import). Shared strings, inline strings and
/// numbers are read; a whole number comes back without ".0"; empty cells are ''. Throws [FormatException] when it is not a workbook.
List<List<String>> readXlsx(Uint8List bytes) {
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw const FormatException('This is not an Excel (.xlsx) file.');
  }
  String? text(String name) {
    final f = zip.findFile(name);
    return f == null ? null : utf8.decode(f.content as List<int>, allowMalformed: true);
  }

  String unesc(String s) => s
      .replaceAllMapped(RegExp(r'&#(x?)([0-9a-fA-F]+);'), (m) => String.fromCharCode(int.parse(m[2]!, radix: m[1] == 'x' ? 16 : 10)))
      .replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&apos;', "'").replaceAll('&amp;', '&');
  String joinT(String xml) => RegExp(r'<t[^>]*>([\s\S]*?)</t>').allMatches(xml).map((m) => unesc(m[1]!)).join();

  final shared = [for (final m in RegExp(r'<si>([\s\S]*?)</si>').allMatches(text('xl/sharedStrings.xml') ?? '')) joinT(m[1]!)];
  // the first sheet the workbook lists (sheet1.xml when there is no workbook map)
  var sheetPath = 'xl/worksheets/sheet1.xml';
  final wb = text('xl/workbook.xml'), rels = text('xl/_rels/workbook.xml.rels');
  final rid = wb == null ? null : RegExp(r'<sheet\b[^>]*\br:id="([^"]+)"').firstMatch(wb)?[1];
  if (rid != null && rels != null) {
    final target = RegExp('<Relationship\b[^>]*Id="$rid"[^>]*Target="([^"]+)"').firstMatch(rels)?[1] ??
        RegExp('<Relationship\b[^>]*Target="([^"]+)"[^>]*Id="$rid"').firstMatch(rels)?[1];
    if (target != null) sheetPath = target.startsWith('/') ? target.substring(1) : 'xl/$target';
  }
  final sheet = text(sheetPath);
  if (sheet == null) throw const FormatException('This workbook has no sheet to read.');

  int colIndex(String ref) {
    var n = 0;
    for (final c in ref.replaceAll(RegExp(r'[0-9]'), '').codeUnits) {
      n = n * 26 + (c - 64);
    }
    return n - 1;
  }

  final rows = <List<String>>[];
  for (final r in RegExp(r'<row\b[^>]*>([\s\S]*?)</row>').allMatches(sheet)) {
    final row = <String>[];
    for (final c in RegExp(r'<c\b([^>]*?)(?:/>|>([\s\S]*?)</c>)').allMatches(r[1]!)) {
      final attrs = c[1]!, body = c[2] ?? '';
      final ref = RegExp(r'\br="([A-Z]+)[0-9]+"').firstMatch(attrs)?[1];
      final type = RegExp(r'\bt="([^"]+)"').firstMatch(attrs)?[1];
      final v = RegExp(r'<v>([\s\S]*?)</v>').firstMatch(body)?[1];
      var value = switch (type) {
        's' => v == null ? '' : (int.tryParse(v) != null && int.parse(v) < shared.length ? shared[int.parse(v)] : ''),
        'inlineStr' => joinT(body),
        _ => v == null ? '' : unesc(v),
      };
      if (type == null || type == 'n') {
        final d = double.tryParse(value);
        if (d != null && d == d.roundToDouble() && d.abs() < 1e15) value = d.toInt().toString();
      }
      final at = ref == null ? row.length : colIndex(ref);
      while (row.length < at) {
        row.add('');
      }
      if (at < row.length) {
        row[at] = value;
      } else {
        row.add(value);
      }
    }
    rows.add(row);
  }
  return rows;
}

/// A CSV file as rows (quotes, commas and line breaks inside quotes, a UTF-8 byte-order mark).
List<List<String>> readCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[], cell = StringBuffer(), quoted = false;
  final s = text.startsWith('﻿') ? text.substring(1) : text;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (quoted) {
      if (ch == '"' && i + 1 < s.length && s[i + 1] == '"') {
        cell.write('"');
        i++;
      } else if (ch == '"') {
        quoted = false;
      } else {
        cell.write(ch);
      }
    } else if (ch == '"') {
      quoted = true;
    } else if (ch == ',') {
      row.add(cell.toString());
      cell = StringBuffer();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < s.length && s[i + 1] == '\n') i++;
      row.add(cell.toString());
      rows.add(row);
      row = <String>[];
      cell = StringBuffer();
    } else {
      cell.write(ch);
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    rows.add(row);
  }
  return rows;
}
