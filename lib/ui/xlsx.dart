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
