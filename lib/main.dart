// ignore_for_file: deprecated_member_use, use_build_context_synchronously, unused_field, unused_element, unused_import, unnecessary_import, unnecessary_string_escapes, unnecessary_brace_in_string_interps, prefer_interpolation_to_compose_strings, prefer_const_constructors, prefer_const_literals_to_create_immutables

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DocSnapArchiveApp());
}

class DocSnapArchiveApp extends StatelessWidget {
  const DocSnapArchiveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '증빙서류 스냅',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E3A8A),
          brightness: Brightness.light,
        ),
        fontFamily: 'Roboto',
      ),
      home: const HomeScreen(),
    );
  }
}

class DocCategory {
  static const String all = '전체';
  static const String officialIn = '공문(수신)';
  static const String officialOut = '공문(발신)';
  static const String invoice = '자재송장';
  static const String travel = '출장비';
  static const String medical = '병원비';
  static const String businessCard = '명함관리';
  static const String pdfConvert = 'PDF변환';

  static const List<String> list = [
    officialIn,
    officialOut,
    invoice,
    travel,
    medical,
    businessCard,
    pdfConvert,
  ];

  static const List<String> filterList = [
    officialIn,
    officialOut,
    invoice,
    travel,
    medical,
    businessCard,
    pdfConvert,
  ];

  static bool isOfficial(String cat) =>
      cat == officialIn || cat == officialOut || cat == '대외공문';
}

class TravelDivision {
  static const String car = '자차';
  static const String taxi = '택시';
  static const String train = '기차';
  static const String meal = '식대';
  static const String toll = '통행료';

  static const List<String> list = [car, taxi, train, meal, toll];
}

class InvoiceSpecRow {
  final TextEditingController productCtrl;
  final TextEditingController specCtrl;
  final TextEditingController unitCtrl;
  final TextEditingController qtyCtrl;

  InvoiceSpecRow({
    required String product,
    required String spec,
    required String unit,
    required String qty,
  })  : productCtrl = TextEditingController(text: product),
        specCtrl = TextEditingController(text: spec),
        unitCtrl = TextEditingController(text: unit),
        qtyCtrl = TextEditingController(text: qty);
}

class DocRecord {
  final String id;
  final String category;
  final String createdAt;
  final String imagePath;
  final String base64Image;
  final Map<String, String> fields;

  DocRecord({
    required this.id,
    required this.category,
    required this.createdAt,
    required this.imagePath,
    required this.base64Image,
    required this.fields,
  });

  String get subCategory => (fields['subCategory'] ?? '').trim();

  String get travelDivision {
    final div = (fields['travelDivision'] ?? '').trim();
    if (TravelDivision.list.contains(div)) return div;
    return TravelDivision.meal;
  }

  static String formatDotDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '-';
    final m = RegExp(r'(\d{4})\s*[-./년]\s*(\d{1,2})\s*[-./월]\s*(\d{1,2})')
        .firstMatch(raw);
    if (m != null) {
      int y = int.tryParse(m.group(1)!) ?? 2026;
      if (y >= 2100 && m.group(1)!.startsWith('26')) {
        y = int.tryParse('20${m.group(1)!.substring(2)}') ?? y;
      }
      final mo = m.group(2)!.padLeft(2, '0');
      final d = m.group(3)!.padLeft(2, '0');
      return '$y.$mo.$d';
    }
    return raw.trim();
  }

  static String stripDocNumSpaces(String? raw) {
    if (raw == null) return '';
    return raw.replaceAll(RegExp(r'\s+'), '').trim();
  }

  static String normalizeDocNumKey(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '';
    final String c = stripDocNumSpaces(raw);
    final m = RegExp(r'([가-힣A-Za-z0-9]+?)[-~—–_.:](\d+)').firstMatch(c);
    if (m != null) {
      final dept =
          m.group(1)!.replaceAll(RegExp(r'(?:과|팀|실|부|처|국|단|소|청)$'), '');
      final numPart = m.group(2)!.replaceFirst(RegExp(r'^0+'), '');
      return '$dept-${numPart.isEmpty ? "0" : numPart}';
    }
    final digits = RegExp(r'\d{3,7}').firstMatch(c);
    if (digits != null) return digits.group(0)!;
    return c;
  }

  String get officialCounterpartyValue {
    if (category == DocCategory.officialOut) {
      return (fields['recipient']?.trim().isNotEmpty == true)
          ? fields['recipient']!.trim()
          : (fields['sender']?.trim().isNotEmpty == true
              ? fields['sender']!.trim()
              : '-');
    } else {
      return (fields['sender']?.trim().isNotEmpty == true)
          ? fields['sender']!.trim()
          : '-';
    }
  }

  String get contentSignature {
    if (DocCategory.isOfficial(category)) {
      final d = formatDotDate(fields['sentDate']);
      final numKey = normalizeDocNumKey(fields['docNumber']);
      final t = (fields['title'] ?? '').replaceAll(RegExp(r'\s+'), '');
      return '$category|$d|$numKey|$t';
    } else if (category == DocCategory.invoice) {
      final d = formatDotDate(fields['arrivalDate']);
      final pName =
          (fields['productName'] ?? '').replaceAll(RegExp(r'\s+'), '');
      final s = (fields['specName'] ?? '')
          .toUpperCase()
          .replaceAll(RegExp(r'\s+'), '');
      final q = (fields['quantity'] ?? '').replaceAll(RegExp(r'\s+'), '');
      final ord = (fields['orderNumber'] ?? '').replaceAll(RegExp(r'\s+'), '');
      return 'INV|$d|$pName|$s|$q|$ord';
    } else if (category == DocCategory.travel) {
      final d = formatDotDate(fields['date']);
      final div = travelDivision;
      final m = (fields['merchantName'] ?? '').replaceAll(RegExp(r'\s+'), '');
      final a = numericAmount.toString();
      return 'TRV|$d|$div|$m|$a';
    } else if (category == DocCategory.medical) {
      final d = formatDotDate(fields['issueDate']);
      final pat = (fields['patientName'] ?? '').replaceAll(RegExp(r'\s+'), '');
      final c = (fields['clinicName'] ?? '').replaceAll(RegExp(r'\s+'), '');
      final a = numericAmount.toString();
      return 'MED|$d|$pat|$c|$a';
    } else if (category == DocCategory.businessCard) {
      final d = formatDotDate(fields['cardDate']);
      final comp = (fields['companyName'] ?? '').replaceAll(RegExp(r'\s+'), '');
      final site = (fields['siteName'] ?? '').replaceAll(RegExp(r'\s+'), '');
      final name = (fields['personName'] ?? '').replaceAll(RegExp(r'\s+'), '');
      final phone =
          (fields['mobilePhone'] ?? '').replaceAll(RegExp(r'[^0-9]'), '');
      return 'CARD|$d|$comp|$site|$name|$phone';
    } else if (category == DocCategory.pdfConvert) {
      final d = formatDotDate(fields['pdfDate']);
      final fn = (fields['pdfFileName'] ?? '').replaceAll(RegExp(r'\s+'), '');
      return 'PDF|$d|$fn|$id';
    }
    return id;
  }

  /// 병원비 및 PDF변환 탭에서 사용하는 추가 페이지(증빙첨부) 이미지 Base64 리스트
  List<String> get extraProofImages {
    final raw = (fields['proofImagesJson'] ?? '').trim();
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded
              .map((e) => e.toString())
              .where((s) => s.isNotEmpty)
              .toList();
        }
      } catch (_) {}
    }
    return const <String>[];
  }

  /// 병원비 및 PDF변환 탭에서 사용하는 추가 페이지 로컬 파일 경로 리스트
  List<String> get extraProofImagePaths {
    final raw = (fields['proofPathsJson'] ?? '').trim();
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded
              .map((e) => e.toString())
              .where((s) => s.isNotEmpty)
              .toList();
        }
      } catch (_) {}
    }
    return const <String>[];
  }

  int get proofAttachmentCount {
    final pathsLen = extraProofImagePaths.length;
    final b64Len = extraProofImages.length;
    if (pathsLen > 0 || b64Len > 0) {
      return math.max(pathsLen, b64Len);
    }
    final statusStr = (fields['proofStatus'] ?? '').trim();
    final m = RegExp(r'\((\d+)장\)').firstMatch(statusStr);
    if (m != null) {
      return int.tryParse(m.group(1)!) ?? 0;
    }
    return 0;
  }

  /// PDF변환 탭 총 페이지 장수 (기본 1장 + 추가 페이지 장수)
  int get totalPdfPageCount => 1 + proofAttachmentCount;

  Uint8List? resolveMainImageBytes() {
    if (imagePath.trim().isNotEmpty && !imagePath.startsWith('photos/')) {
      try {
        final f = File(imagePath);
        if (f.existsSync()) {
          return f.readAsBytesSync();
        }
      } catch (_) {}
    }
    if (base64Image.trim().isNotEmpty) {
      try {
        final clean = base64Image.contains(',')
            ? base64Image.split(',').last
            : base64Image;
        return base64Decode(clean.replaceAll(RegExp(r'\s+'), ''));
      } catch (_) {}
    }
    return null;
  }

  List<Uint8List> resolveAllProofImageBytes() {
    final List<Uint8List> out = <Uint8List>[];
    final paths = extraProofImagePaths;
    final b64s = extraProofImages;
    final cnt = math.max(paths.length, b64s.length);
    for (int i = 0; i < cnt; i++) {
      Uint8List? bytes;
      if (i < paths.length && paths[i].trim().isNotEmpty) {
        try {
          final pf = File(paths[i]);
          if (pf.existsSync()) {
            bytes = pf.readAsBytesSync();
          }
        } catch (_) {}
      }
      if (bytes == null && i < b64s.length && b64s[i].trim().isNotEmpty) {
        try {
          final raw = b64s[i].contains(',')
              ? b64s[i].split(',').last
              : b64s[i];
          bytes = base64Decode(raw.replaceAll(RegExp(r'\s+'), ''));
        } catch (_) {}
      }
      if (bytes != null && bytes.isNotEmpty) {
        out.add(bytes);
      }
    }
    return out;
  }

  bool get isMedicalClaimed {
    final raw = (fields['isClaimed'] ?? '').trim().toUpperCase();
    return raw == 'Y' || raw == 'TRUE' || raw == '1' || raw == '청구완료';
  }

  String get medicalClaimLabel => isMedicalClaimed ? '청구완료' : '미청구';

  static bool isDirectorName(String? name) {
    if (name == null) return false;
    return name.contains('소장');
  }

  List<Map<String, String>> get approvalEntries {
    final raw = (fields['approvalsJson'] ?? '').trim();
    if (raw.isEmpty) return const <Map<String, String>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final List<Map<String, String>> reviewers = <Map<String, String>>[];
        final List<Map<String, String>> directors = <Map<String, String>>[];
        for (final item in decoded) {
          if (item is Map) {
            final name = (item['name'] ?? '').toString().trim();
            final date = (item['date'] ?? '').toString().trim();
            if (name.isEmpty) continue;
            final entry = <String, String>{
              'name': name,
              'date': date.isEmpty ? '-' : date,
              'role': isDirectorName(name) ? '결재' : '검토',
            };
            if (isDirectorName(name)) {
              directors.add(entry);
            } else {
              reviewers.add(entry);
            }
          }
        }
        return <Map<String, String>>[...reviewers, ...directors];
      }
    } catch (_) {}
    return const <Map<String, String>>[];
  }

  bool get isDirectorApprovalCompleted {
    return approvalEntries
        .any((e) => isDirectorName(e['name']) || e['role'] == '결재');
  }

  String get approvalStatusLabel {
    final entries = approvalEntries;
    if (entries.isEmpty) return '결재';
    if (isDirectorApprovalCompleted) return '결재완료';
    return '검토';
  }

  static String mergeApprovalsJsonStrings(String? jsonA, String? jsonB) {
    final List<Map<String, String>> combined = <Map<String, String>>[];
    final Set<String> seenNames = <String>{};

    void addFromRaw(String? raw) {
      if (raw == null || raw.trim().isEmpty) return;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              final name = (item['name'] ?? '').toString().trim();
              final date = (item['date'] ?? '').toString().trim();
              if (name.isEmpty) continue;
              if (seenNames.add(name)) {
                combined.add({
                  'name': name,
                  'date': date.isEmpty ? '-' : date,
                  'role': isDirectorName(name) ? '결재' : '검토',
                });
              }
            }
          }
        }
      } catch (_) {}
    }

    addFromRaw(jsonA);
    addFromRaw(jsonB);
    if (combined.isEmpty) return '';

    final reviewers =
        combined.where((e) => !isDirectorName(e['name'])).toList();
    final directors =
        combined.where((e) => isDirectorName(e['name'])).toList();
    return jsonEncode(<Map<String, String>>[...reviewers, ...directors]);
  }

  static String removeApproverFromRawJson(String? raw, String targetName) {
    final cleanTarget = targetName.trim();
    if (raw == null || raw.trim().isEmpty || cleanTarget.isEmpty) {
      return raw ?? '';
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final List<Map<String, String>> remaining = <Map<String, String>>[];
        for (final item in decoded) {
          if (item is Map) {
            final name = (item['name'] ?? '').toString().trim();
            final date = (item['date'] ?? '').toString().trim();
            if (name.isEmpty || name == cleanTarget) continue;
            remaining.add({
              'name': name,
              'date': date.isEmpty ? '-' : date,
              'role': isDirectorName(name) ? '결재' : '검토',
            });
          }
        }
        if (remaining.isEmpty) return '';
        final reviewers =
            remaining.where((e) => !isDirectorName(e['name'])).toList();
        final directors =
            remaining.where((e) => isDirectorName(e['name'])).toList();
        return jsonEncode(<Map<String, String>>[...reviewers, ...directors]);
      }
    } catch (_) {}
    return raw;
  }

  String get pdfFileBaseName {
    String datePart = '';
    String titlePart = '';
    if (DocCategory.isOfficial(category)) {
      datePart = formatDotDate(fields['sentDate']);
      titlePart = fields['title'] ?? '대외공문';
    } else if (category == DocCategory.invoice) {
      datePart = formatDotDate(fields['arrivalDate']);
      final prod = fields['productName'] ?? '자재송장';
      final spec = fields['specName'] ?? '';
      titlePart = spec.isNotEmpty ? '${prod}_$spec' : prod;
    } else if (category == DocCategory.travel) {
      datePart = formatDotDate(fields['date']);
      titlePart =
          '${subCategory.isNotEmpty ? "${subCategory}_" : ""}${travelDivision}_${fields['merchantName'] ?? '출장비'}';
    } else if (category == DocCategory.medical) {
      datePart = formatDotDate(fields['issueDate']);
      final pat = (fields['patientName'] ?? '').trim();
      titlePart =
          '${subCategory.isNotEmpty ? "${subCategory}_" : ""}${pat.isNotEmpty ? "${pat}_" : ""}${fields['clinicName'] ?? '병원비'}';
    } else if (category == DocCategory.businessCard) {
      datePart = formatDotDate(fields['cardDate'] ?? createdAt.split(' ').first);
      final comp = (fields['companyName'] ?? '').trim();
      final person = (fields['personName'] ?? '').trim();
      titlePart =
          '명함_${comp.isNotEmpty ? "${comp}_" : ""}${person.isNotEmpty ? person : "담당자"}';
    } else if (category == DocCategory.pdfConvert) {
      datePart = formatDotDate(fields['pdfDate'] ?? createdAt.split(' ').first);
      titlePart = (fields['pdfFileName'] ?? '문서스캔').trim();
    }
    if (datePart == '-' || datePart.isEmpty) {
      datePart = formatDotDate(createdAt.split(' ').first);
    }
    final rawName = '$datePart-$titlePart';
    return rawName
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String get displayTitle {
    if (DocCategory.isOfficial(category)) {
      return fields['title']?.isNotEmpty == true
          ? fields['title']!
          : '(제목 없는 공문)';
    }
    switch (category) {
      case DocCategory.invoice:
        final prod = fields['productName'] ?? '품명 미상';
        final spec = fields['specName'] ?? '';
        return spec.isNotEmpty ? '$prod ($spec)' : prod;
      case DocCategory.travel:
        final m = fields['merchantName'] ?? '';
        if (travelDivision == TravelDivision.car) {
          final km = fields['distanceKm'] ?? '0';
          final mult = fields['carMultiplier'] ?? '2';
          final rate = fields['carUnitPrice'] ?? '300';
          return '${km}km × $mult × ${rate}원 = ${_formatCurrency(fields['totalAmount'])}원';
        }
        return m.isNotEmpty
            ? '$m (${_formatCurrency(fields['totalAmount'])}원)'
            : '$travelDivision (${_formatCurrency(fields['totalAmount'])}원)';
      case DocCategory.medical:
        final pat = (fields['patientName'] ?? '').trim();
        final clinic = fields['clinicName']?.isNotEmpty == true
            ? fields['clinicName']!
            : '(상호 미상)';
        return pat.isNotEmpty ? '$clinic [$pat]' : clinic;
      case DocCategory.businessCard:
        final comp = (fields['companyName'] ?? '').trim();
        final name = (fields['personName'] ?? '').trim();
        final site = (fields['siteName'] ?? '').trim();
        final mainLabel = [comp, name].where((s) => s.isNotEmpty).join(' · ');
        if (mainLabel.isEmpty) return '(이름 없는 명함)';
        return site.isNotEmpty ? '$mainLabel ($site)' : mainLabel;
      case DocCategory.pdfConvert:
        final fn = (fields['pdfFileName'] ?? '').trim();
        final cleanFn = fn.isNotEmpty ? fn : '이름없는_PDF';
        return cleanFn.toLowerCase().endsWith('.pdf')
            ? cleanFn
            : '$cleanFn.pdf';
      default:
        return '기타 문서';
    }
  }

  String get displaySubtitle {
    if (category == DocCategory.officialIn) {
      return '접수일: ${formatDotDate(fields['sentDate'])} | 보낸사람: $officialCounterpartyValue | 회신요청일: ${formatDotDate(fields['replyDeadline'])}';
    }
    if (category == DocCategory.officialOut) {
      return '발신일: ${formatDotDate(fields['sentDate'])} | 받는사람: $officialCounterpartyValue | 회신번호: ${fields['replyDocNumber'] ?? '-'}';
    }
    switch (category) {
      case DocCategory.invoice:
        return '날짜: ${formatDotDate(fields['arrivalDate'])} | 규격: ${fields['specName'] ?? '-'} | 수량: ${fields['quantity'] ?? '-'} ${fields['unit'] ?? 'ton'}';
      case DocCategory.travel:
        return '[구분: $travelDivision] 일자: ${formatDotDate(fields['date'])} | 금액: ${_formatCurrency(fields['totalAmount'])}원';
      case DocCategory.medical:
        final pat = (fields['patientName'] ?? '-').trim();
        return '환자: ${pat.isEmpty ? "-" : pat} | 발행일: ${formatDotDate(fields['issueDate'])} | 금액: ${_formatCurrency(fields['totalPaid'])}원 | 사업자: ${fields['bizRegNumber'] ?? '-'}';
      case DocCategory.businessCard:
        return '날짜: ${formatDotDate(fields['cardDate'] ?? createdAt.split(' ').first)} | 현장: ${fields['siteName'] ?? '-'} | 휴대폰: ${fields['mobilePhone'] ?? '-'} | 이메일: ${fields['email'] ?? '-'}';
      case DocCategory.pdfConvert:
        return '찍은날짜: ${formatDotDate(fields['pdfDate'] ?? createdAt.split(' ').first)} | 총 ${totalPdfPageCount}장';
      default:
        return createdAt;
    }
  }

  int get numericAmount {
    String raw = '0';
    if (category == DocCategory.medical) {
      raw = fields['totalPaid'] ?? '0';
    } else if (category == DocCategory.travel) {
      raw = fields['totalAmount'] ?? '0';
    } else {
      raw = fields['amount'] ?? '0';
    }
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    return int.tryParse(digits) ?? 0;
  }

  double get numericInvoiceQuantity {
    final raw = (fields['quantity'] ?? '')
        .replaceAll(',', '')
        .replaceAll(RegExp(r'[^0-9.]'), '');
    return double.tryParse(raw) ?? 0.0;
  }

  static String _formatCurrency(String? val) {
    if (val == null || val.trim().isEmpty) return '0';
    final numVal =
        int.tryParse(val.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
    return NumberFormat('#,###').format(numVal);
  }

  Map<String, dynamic> toJson({bool includeBase64 = true}) => {
        'id': id,
        'category':
            category == '대외공문' ? DocCategory.officialIn : category,
        'createdAt': createdAt,
        'imagePath': imagePath,
        'base64Image': includeBase64 ? base64Image : '',
        'fields': fields,
      };

  factory DocRecord.fromJson(Map<String, dynamic> json) {
    final rawFields = json['fields'] as Map<String, dynamic>? ?? {};
    final cleanFields =
        rawFields.map((k, v) => MapEntry(k, v?.toString() ?? ''));
    if (cleanFields.containsKey('docNumber')) {
      cleanFields['docNumber'] = stripDocNumSpaces(cleanFields['docNumber']);
    }
    if (cleanFields.containsKey('replyDocNumber')) {
      cleanFields['replyDocNumber'] =
          stripDocNumSpaces(cleanFields['replyDocNumber']);
    }
    String cat = json['category']?.toString() ?? DocCategory.officialIn;
    if (cat == '대외공문') {
      final dir = cleanFields['docDirection'] ?? '수신';
      cat = dir == '발신' ? DocCategory.officialOut : DocCategory.officialIn;
    }
    return DocRecord(
      id: json['id']?.toString() ?? '',
      category: cat,
      createdAt: json['createdAt']?.toString() ?? '',
      imagePath: json['imagePath']?.toString() ?? '',
      base64Image: json['base64Image']?.toString() ?? '',
      fields: cleanFields,
    );
  }
}

// =============================================================================
// 4점 모서리 스캔 & 평평하게 펴기 (Perspective Crop + Local Adaptive Whitening)
// =============================================================================
class PerspectiveCropResult {
  final Uint8List bytes;
  final int rotationDegrees;

  const PerspectiveCropResult({
    required this.bytes,
    required this.rotationDegrees,
  });
}

Map<String, dynamic> _decodeAndAutoDetectCornersIsolate(Uint8List rawBytes) {
  final decoded = img.decodeImage(rawBytes);
  if (decoded == null) {
    return {
      'w': 1000,
      'h': 1400,
      'corners': [0.06, 0.06, 0.94, 0.06, 0.94, 0.94, 0.06, 0.94],
    };
  }
  final baked = img.bakeOrientation(decoded);
  final w = baked.width;
  final h = baked.height;

  // vFlat 스타일 밝은 문서 영역 자동 탐지 (초록색 테두리 초기 위치 추정)
  const int gridW = 48;
  const int gridH = 64;
  double sumLum = 0;
  final List<double> lums = List<double>.filled(gridW * gridH, 0);
  for (int gy = 0; gy < gridH; gy++) {
    final py = (gy * h ~/ gridH).clamp(0, h - 1);
    for (int gx = 0; gx < gridW; gx++) {
      final px = (gx * w ~/ gridW).clamp(0, w - 1);
      final p = baked.getPixel(px, py);
      final lum = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      lums[gy * gridW + gx] = lum;
      sumLum += lum;
    }
  }
  final double avgLum = sumLum / (gridW * gridH);
  final double thresh = (avgLum * 1.06).clamp(115.0, 215.0);

  int minGx = gridW, maxGx = 0, minGy = gridH, maxGy = 0;
  int brightCount = 0;
  for (int gy = 2; gy < gridH - 2; gy++) {
    for (int gx = 2; gx < gridW - 2; gx++) {
      if (lums[gy * gridW + gx] >= thresh) {
        brightCount++;
        if (gx < minGx) minGx = gx;
        if (gx > maxGx) maxGx = gx;
        if (gy < minGy) minGy = gy;
        if (gy > maxGy) maxGy = gy;
      }
    }
  }

  List<double> corners;
  if (brightCount > (gridW * gridH * 0.12) &&
      maxGx > minGx + 10 &&
      maxGy > minGy + 10) {
    final left = (minGx / gridW).clamp(0.03, 0.22);
    final right = (maxGx / gridW).clamp(0.78, 0.97);
    final top = (minGy / gridH).clamp(0.03, 0.22);
    final bottom = (maxGy / gridH).clamp(0.78, 0.97);
    corners = [left, top, right, top, right, bottom, left, bottom];
  } else {
    corners = [0.05, 0.05, 0.95, 0.05, 0.95, 0.95, 0.05, 0.95];
  }

  return {
    'w': w,
    'h': h,
    'corners': corners,
  };
}

Uint8List? _rotateImageIsolate(Map<String, dynamic> args) {
  final Uint8List bytes = args['bytes'] as Uint8List;
  final int angle = args['angle'] as int;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final rotated = img.copyRotate(decoded, angle: angle);
  return Uint8List.fromList(img.encodeJpg(rotated, quality: 95));
}

Uint8List _perspectiveWarpIsolate(Map<String, dynamic> params) {
  final Uint8List srcBytes = params['bytes'] as Uint8List;
  final List<double> normPts =
      (params['points'] as List<dynamic>).map((e) => (e as num).toDouble()).toList();
  final bool enhanceScan = params['enhance'] as bool? ?? true;
  final int rotationDegrees = params['rotation'] as int? ?? 0;

  final decoded0 = img.decodeImage(srcBytes);
  if (decoded0 == null) return srcBytes;
  img.Image src = img.bakeOrientation(decoded0);
  if (rotationDegrees != 0) {
    src = img.copyRotate(src, angle: rotationDegrees);
  }

  final double sw = src.width.toDouble();
  final double sh = src.height.toDouble();

  final double x0 = normPts[0] * sw, y0 = normPts[1] * sh;
  final double x1 = normPts[2] * sw, y1 = normPts[3] * sh;
  final double x2 = normPts[4] * sw, y2 = normPts[5] * sh;
  final double x3 = normPts[6] * sw, y3 = normPts[7] * sh;

  final bool isFullFrame = (normPts[0] < 0.02 &&
      normPts[1] < 0.02 &&
      normPts[2] > 0.98 &&
      normPts[3] < 0.02 &&
      normPts[4] > 0.98 &&
      normPts[5] > 0.98 &&
      normPts[6] < 0.02 &&
      normPts[7] > 0.98);

  if (isFullFrame && !enhanceScan && rotationDegrees == 0) {
    return srcBytes;
  }

  final double topW = math.sqrt(math.pow(x1 - x0, 2) + math.pow(y1 - y0, 2));
  final double botW = math.sqrt(math.pow(x2 - x3, 2) + math.pow(y2 - y3, 2));
  final double leftH = math.sqrt(math.pow(x3 - x0, 2) + math.pow(y3 - y0, 2));
  final double rightH = math.sqrt(math.pow(x2 - x1, 2) + math.pow(y2 - y1, 2));

  double avgW = (topW + botW) * 0.5;
  double avgH = (leftH + rightH) * 0.5;
  if (avgW < 64) avgW = sw;
  if (avgH < 64) avgH = sh;

  const double maxSide = 2200.0;
  double scale = 1.0;
  if (math.max(avgW, avgH) > maxSide) {
    scale = maxSide / math.max(avgW, avgH);
  }
  final int outW = (avgW * scale).round().clamp(160, 2400);
  final int outH = (avgH * scale).round().clamp(160, 2400);

  final dst = img.Image(width: outW, height: outH);

  for (int dy = 0; dy < outH; dy++) {
    final double v = outH > 1 ? dy / (outH - 1) : 0.0;
    final double tx0 = x0 + (x3 - x0) * v;
    final double ty0 = y0 + (y3 - y0) * v;
    final double tx1 = x1 + (x2 - x1) * v;
    final double ty1 = y1 + (y2 - y1) * v;

    for (int dx = 0; dx < outW; dx++) {
      final double u = outW > 1 ? dx / (outW - 1) : 0.0;
      final double sx = (tx0 + (tx1 - tx0) * u).clamp(0.0, sw - 1.001);
      final double sy = (ty0 + (ty1 - ty0) * u).clamp(0.0, sh - 1.001);

      final px = src.getPixelLinear(sx, sy);
      dst.setPixelRgba(
        dx,
        dy,
        px.r.round(),
        px.g.round(),
        px.b.round(),
        255,
      );
    }
  }

  // 구역별 그림자 자동 제거(Local Adaptive Background Whitening)
  if (enhanceScan) {
    const int gxCount = 24;
    const int gyCount = 32;
    final List<double> bgGrid = List<double>.filled(gxCount * gyCount, 225.0);

    for (int gy = 0; gy < gyCount; gy++) {
      final int yStart = (gy * outH) ~/ gyCount;
      final int yEnd = math.min(outH, ((gy + 1) * outH) ~/ gyCount);
      for (int gx = 0; gx < gxCount; gx++) {
        final int xStart = (gx * outW) ~/ gxCount;
        final int xEnd = math.min(outW, ((gx + 1) * outW) ~/ gxCount);
        final List<int> samples = <int>[];
        final int stepY = math.max(1, (yEnd - yStart) ~/ 6);
        final int stepX = math.max(1, (xEnd - xStart) ~/ 6);
        for (int yy = yStart; yy < yEnd; yy += stepY) {
          for (int xx = xStart; xx < xEnd; xx += stepX) {
            final p = dst.getPixel(xx, yy);
            final int lum = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round();
            samples.add(lum);
          }
        }
        if (samples.isNotEmpty) {
          samples.sort();
          final int idx80 = ((samples.length - 1) * 0.80).round();
          bgGrid[gy * gxCount + gx] =
              samples[idx80].toDouble().clamp(115.0, 250.0);
        }
      }
    }

    // 3x3 스무딩으로 격자 경계선 제거
    final List<double> smoothGrid = List<double>.filled(gxCount * gyCount, 225.0);
    for (int gy = 0; gy < gyCount; gy++) {
      for (int gx = 0; gx < gxCount; gx++) {
        double sum = 0.0;
        int cnt = 0;
        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            final int ngy = (gy + dy).clamp(0, gyCount - 1);
            final int ngx = (gx + dx).clamp(0, gxCount - 1);
            sum += bgGrid[ngy * gxCount + ngx];
            cnt++;
          }
        }
        smoothGrid[gy * gxCount + gx] = sum / cnt;
      }
    }

    for (int y = 0; y < outH; y++) {
      final double fy = (y / outH) * (gyCount - 1);
      final int gy0 = fy.floor().clamp(0, gyCount - 1);
      final int gy1 = (gy0 + 1).clamp(0, gyCount - 1);
      final double wy = fy - gy0;

      for (int x = 0; x < outW; x++) {
        final double fx = (x / outW) * (gxCount - 1);
        final int gx0 = fx.floor().clamp(0, gxCount - 1);
        final int gx1 = (gx0 + 1).clamp(0, gxCount - 1);
        final double wx = fx - gx0;

        final double topBg = smoothGrid[gy0 * gxCount + gx0] * (1 - wx) +
            smoothGrid[gy0 * gxCount + gx1] * wx;
        final double botBg = smoothGrid[gy1 * gxCount + gx0] * (1 - wx) +
            smoothGrid[gy1 * gxCount + gx1] * wx;
        final double localBg = (topBg * (1 - wy) + botBg * wy).clamp(110.0, 252.0);

        final p = dst.getPixel(x, y);
        final double lum = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        final double ratio = lum / localBg;

        if (ratio >= 0.87) {
          dst.setPixelRgba(x, y, 255, 255, 255, 255);
        } else {
          final double gain = 255.0 / localBg;
          int nr = (p.r * gain).round();
          int ng = (p.g * gain).round();
          int nb = (p.b * gain).round();
          if (ratio < 0.68) {
            nr = (nr * 0.88).round();
            ng = (ng * 0.88).round();
            nb = (nb * 0.88).round();
          }
          dst.setPixelRgba(
            x,
            y,
            nr.clamp(0, 255),
            ng.clamp(0, 255),
            nb.clamp(0, 255),
            255,
          );
        }
      }
    }
  }

  return Uint8List.fromList(img.encodeJpg(dst, quality: 92));
}

class PerspectiveCropDialog extends StatefulWidget {
  final Uint8List originalBytes;
  final String titleText;

  const PerspectiveCropDialog({
    super.key,
    required this.originalBytes,
    this.titleText = '문서 모서리 자동 스캔 (vFlat 스타일)',
  });

  @override
  State<PerspectiveCropDialog> createState() => _PerspectiveCropDialogState();
}

class _PerspectiveCropDialogState extends State<PerspectiveCropDialog> {
  List<Offset> _corners = const [
    Offset(0.06, 0.06),
    Offset(0.94, 0.06),
    Offset(0.94, 0.94),
    Offset(0.06, 0.94),
  ];
  int _imgW = 1000;
  int _imgH = 1400;
  bool _ready = false;
  bool _processing = false;
  bool _enhanceScan = true;
  int _rotationDegrees = 0;

  @override
  void initState() {
    super.initState();
    _initCorners();
  }

  Future<void> _initCorners() async {
    try {
      final info = await compute(
        _decodeAndAutoDetectCornersIsolate,
        widget.originalBytes,
      );
      if (!mounted) return;
      final c = (info['corners'] as List<dynamic>)
          .map((e) => (e as num).toDouble())
          .toList();
      setState(() {
        _imgW = info['w'] as int;
        _imgH = info['h'] as int;
        _corners = [
          Offset(c[0], c[1]),
          Offset(c[2], c[3]),
          Offset(c[4], c[5]),
          Offset(c[6], c[7]),
        ];
        _ready = true;
      });
    } catch (_) {
      if (mounted) setState(() => _ready = true);
    }
  }

  void _rotate90() {
    setState(() {
      _rotationDegrees = (_rotationDegrees + 90) % 360;
      final tmp = _imgW;
      _imgW = _imgH;
      _imgH = tmp;
      _corners = _corners
          .map((pt) => Offset(1.0 - pt.dy, pt.dx))
          .toList();
    });
  }

  Future<void> _confirmCrop({bool useOriginalFull = false}) async {
    if (_processing) return;
    setState(() => _processing = true);
    try {
      final pts = useOriginalFull
          ? <double>[0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0]
          : <double>[
              _corners[0].dx,
              _corners[0].dy,
              _corners[1].dx,
              _corners[1].dy,
              _corners[2].dx,
              _corners[2].dy,
              _corners[3].dx,
              _corners[3].dy,
            ];
      final warped = await compute(_perspectiveWarpIsolate, {
        'bytes': widget.originalBytes,
        'points': pts,
        'enhance': useOriginalFull ? false : _enhanceScan,
        'rotation': _rotationDegrees,
      });
      if (!mounted) return;
      Navigator.pop(
        context,
        PerspectiveCropResult(
          bytes: warped,
          rotationDegrees: _rotationDegrees,
        ),
      );
    } catch (_) {
      if (mounted) {
        Navigator.pop(
          context,
          PerspectiveCropResult(
            bytes: widget.originalBytes,
            rotationDegrees: _rotationDegrees,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final double aspect = (_imgW > 0 && _imgH > 0) ? (_imgW / _imgH) : 0.72;

    return Dialog.fullscreen(
      backgroundColor: const Color(0xFF0F172A),
      child: Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1E293B),
          foregroundColor: Colors.white,
          title: Text(
            widget.titleText,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
          actions: [
            TextButton.icon(
              onPressed: _processing ? null : _rotate90,
              icon: const Icon(Icons.rotate_right, color: Colors.amberAccent, size: 19),
              label: const Text(
                '90° 회전',
                style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold),
              ),
            ),
            TextButton(
              onPressed: _processing
                  ? null
                  : () => _confirmCrop(useOriginalFull: true),
              child: const Text(
                '원본 그대로',
                style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        body: !_ready
            ? const Center(
                child: CircularProgressIndicator(color: Colors.greenAccent),
              )
            : Column(
                children: [
                  Container(
                    width: double.infinity,
                    color: const Color(0xFF1E293B),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '🟢 초록색 모서리 점 4개를 문서 귀퉁이에 맞추면 평평하고 하얗게 보정됩니다.',
                            style: TextStyle(color: Colors.white70, fontSize: 11.5),
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              '하얗게 스캔보정',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 11.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Switch(
                              value: _enhanceScan,
                              activeColor: const Color(0xFF00E676),
                              onChanged: (v) => setState(() => _enhanceScan = v),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: AspectRatio(
                          aspectRatio: aspect,
                          child: LayoutBuilder(
                            builder: (ctx, box) {
                              final cw = box.maxWidth;
                              final ch = box.maxHeight;
                              return Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Positioned.fill(
                                    child: RotatedBox(
                                      quarterTurns: _rotationDegrees ~/ 90,
                                      child: Image.memory(
                                        widget.originalBytes,
                                        fit: BoxFit.fill,
                                      ),
                                    ),
                                  ),
                                  Positioned.fill(
                                    child: CustomPaint(
                                      painter: _GreenQuadPainter(_corners),
                                    ),
                                  ),
                                  for (int i = 0; i < 4; i++)
                                    Positioned(
                                      left: _corners[i].dx * cw - 20,
                                      top: _corners[i].dy * ch - 20,
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onPanUpdate: (d) {
                                          setState(() {
                                            final nx = (_corners[i].dx + d.delta.dx / cw)
                                                .clamp(0.0, 1.0);
                                            final ny = (_corners[i].dy + d.delta.dy / ch)
                                                .clamp(0.0, 1.0);
                                            final next = List<Offset>.from(_corners);
                                            next[i] = Offset(nx, ny);
                                            _corners = next;
                                          });
                                        },
                                        child: Container(
                                          width: 40,
                                          height: 40,
                                          alignment: Alignment.center,
                                          child: Container(
                                            width: 24,
                                            height: 24,
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF00E676),
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: Colors.white,
                                                width: 2.5,
                                              ),
                                              boxShadow: const [
                                                BoxShadow(
                                                  color: Colors.black54,
                                                  blurRadius: 4,
                                                ),
                                              ],
                                            ),
                                            alignment: Alignment.center,
                                            child: Text(
                                              '${i + 1}',
                                              style: const TextStyle(
                                                color: Color(0xFF0F172A),
                                                fontSize: 11,
                                                fontWeight: FontWeight.w900,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
                      child: SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF00E676),
                            foregroundColor: const Color(0xFF0F172A),
                          ),
                          onPressed: _processing ? null : () => _confirmCrop(),
                          icon: _processing
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2.4),
                                )
                              : const Icon(Icons.document_scanner),
                          label: Text(
                            _processing
                                ? '반듯하게 스캔 보정 중...'
                                : '모서리 맞춰 평평하게 펴기 & 확인',
                            style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _GreenQuadPainter extends CustomPainter {
  final List<Offset> corners;
  const _GreenQuadPainter(this.corners);

  @override
  void paint(Canvas canvas, Size size) {
    if (corners.length != 4) return;
    final pts = corners
        .map((c) => Offset(c.dx * size.width, c.dy * size.height))
        .toList();

    final path = Path()
      ..moveTo(pts[0].dx, pts[0].dy)
      ..lineTo(pts[1].dx, pts[1].dy)
      ..lineTo(pts[2].dx, pts[2].dy)
      ..lineTo(pts[3].dx, pts[3].dy)
      ..close();

    final fillPaint = Paint()
      ..color = const Color(0x2600E676)
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fillPaint);

    final borderPaint = Paint()
      ..color = const Color(0xFF00E676)
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _GreenQuadPainter oldDelegate) =>
      oldDelegate.corners != corners;
}

// =============================================================================
// 메인 화면 (HomeScreen)
// =============================================================================
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const String _prefsRecordsKey = 'doc_snap_records_v3';
  static const String _prefsGeminiKey = 'doc_snap_gemini_api_key';
  static const String _prefsGeminiVerifiedKey = 'doc_snap_gemini_verified';
  static const String _prefsSplitRatioKey = 'doc_snap_split_ratio_v14';
  static const String _prefsHorizSplitRatioKey =
      'doc_snap_horiz_split_ratio_v18';
  static const String _prefsUserSubCatsKey = 'doc_snap_user_sub_cats_v10';
  static const String _prefsPeriodStartDayKey =
      'doc_snap_period_start_day_v30';
  static const String _prefsUserNameKey = 'doc_snap_exporter_user_name_v35';
  static const String _prefsConflictFreeKey = 'doc_snap_conflict_free_v35';
  static const String _prefsGithubRepoKey = 'doc_snap_github_repo_v39';
  static const String _prefsGithubTokenKey = 'doc_snap_github_token_v39';
  static const String _prefsGithubFolderKey = 'doc_snap_github_folder_v39';
  static const String _prefsShareRoomModeKey = 'doc_snap_share_room_mode_v39';
  static const String _prefsOneDriveShareUrlKey = 'doc_snap_onedrive_url_v39';

  final ImagePicker _picker = ImagePicker();
  List<DocRecord> _records = [];
  String _selectedCategoryFilter = DocCategory.officialIn;
  String _selectedSubCategoryFilter = '전체';
  String _selectedTravelDivisionFilter = '전체';
  String _selectedInvoiceProductFilter = '전체';
  String _selectedMedicalClaimFilter = '전체';
  DocRecord? _selectedRecord;
  int _selectedPhotoIndex = 0;
  final PageController _photoPageCtrl = PageController();

  void _resetPhotoPageToZero() {
    _selectedPhotoIndex = 0;
    if (_photoPageCtrl.hasClients) {
      _photoPageCtrl.jumpToPage(0);
    }
  }

  bool _invSumByProduct = true;
  bool _invSumBySpec = false;

  bool _medSumByCat = true;
  bool _medSumByPatient = false;
  bool _medSumByClaim = false;

  String _businessCardSearchQuery = '';
  final TextEditingController _businessCardSearchCtrl = TextEditingController();

  bool _isBusy = false;
  String _geminiApiKey = '';
  bool _geminiKeyVerified = false;
  String _lastGeminiStatusMsg = '';
  String _exporterUserName = '';
  bool _useConflictFreeFileName = true;

  String _shareRoomMode = 'github';
  String _githubRepo = '';
  String _githubToken = '';
  String _githubFolder = '';
  String _oneDriveShareUrl = '';

  double _listSplitRatio = 0.44;
  double _detailHorizSplitRatio = 0.44;

  String _sortColumn = 'date';
  bool _sortAscending = false;

  int _periodStartDay = 1;
  final Map<String, bool> _periodFilterAllMap = {
    DocCategory.invoice: true,
    DocCategory.medical: true,
  };
  final Map<String, DateTime> _periodAnchorMonthMap = {
    DocCategory.invoice: DateTime(DateTime.now().year, DateTime.now().month, 1),
    DocCategory.medical: DateTime(DateTime.now().year, DateTime.now().month, 1),
  };
  DateTime? _medicalCustomStartDate;
  DateTime? _medicalCustomEndDate;

  final Map<String, List<String>> _userSubCategoriesMap = {
    DocCategory.officialIn: [],
    DocCategory.officialOut: [],
    DocCategory.invoice: [],
    DocCategory.travel: [],
    DocCategory.medical: [],
    DocCategory.businessCard: [],
    DocCategory.pdfConvert: [],
  };

  @override
  void initState() {
    super.initState();
    _loadInitialState();
  }

  @override
  void dispose() {
    _photoPageCtrl.dispose();
    _businessCardSearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadInitialState() async {
    final prefs = await SharedPreferences.getInstance();
    final rawList = prefs.getStringList(_prefsRecordsKey) ?? [];
    final loaded = <DocRecord>[];
    for (final s in rawList) {
      try {
        final rec = DocRecord.fromJson(jsonDecode(s) as Map<String, dynamic>);
        loaded.add(rec);
      } catch (_) {}
    }

    final savedSubCatsJson = prefs.getString(_prefsUserSubCatsKey);
    if (savedSubCatsJson != null && savedSubCatsJson.isNotEmpty) {
      try {
        final Map<String, dynamic> decoded =
            jsonDecode(savedSubCatsJson) as Map<String, dynamic>;
        decoded.forEach((key, val) {
          if (val is List) {
            final cleanList = val
                .map((e) => e.toString().trim())
                .where((s) => s.isNotEmpty)
                .toSet()
                .toList();
            if (key == '대외공문') {
              _userSubCategoriesMap[DocCategory.officialIn] = cleanList;
            } else {
              _userSubCategoriesMap[key] = cleanList;
            }
          }
        });
      } catch (_) {}
    } else {
      for (final r in loaded) {
        if (r.subCategory.isNotEmpty) {
          final list = _userSubCategoriesMap[r.category] ?? [];
          if (!list.contains(r.subCategory)) {
            list.add(r.subCategory);
            _userSubCategoriesMap[r.category] = list;
          }
        }
      }
    }

    setState(() {
      _records = loaded;
      _geminiApiKey = prefs.getString(_prefsGeminiKey) ?? '';
      _geminiKeyVerified = prefs.getBool(_prefsGeminiVerifiedKey) ?? false;
      _exporterUserName = prefs.getString(_prefsUserNameKey) ?? '';
      _useConflictFreeFileName = prefs.getBool(_prefsConflictFreeKey) ?? true;
      _shareRoomMode = prefs.getString(_prefsShareRoomModeKey) ?? 'github';
      _githubRepo = prefs.getString(_prefsGithubRepoKey) ?? '';
      _githubToken = prefs.getString(_prefsGithubTokenKey) ?? '';
      final savedFolder = prefs.getString(_prefsGithubFolderKey) ?? '';
      _githubFolder = savedFolder == '현장공유방' ? '' : savedFolder;
      _oneDriveShareUrl = prefs.getString(_prefsOneDriveShareUrlKey) ?? '';
      _listSplitRatio =
          (prefs.getDouble(_prefsSplitRatioKey) ?? 0.44).clamp(0.18, 0.82);
      _detailHorizSplitRatio =
          (prefs.getDouble(_prefsHorizSplitRatioKey) ?? 0.44)
              .clamp(0.22, 0.78);
      _periodStartDay =
          (prefs.getInt(_prefsPeriodStartDayKey) ?? 1).clamp(1, 28);
      final initialFiltered = _filteredRecords;
      if (initialFiltered.isNotEmpty) {
        _selectedRecord = initialFiltered.first;
      }
    });

    if (_geminiApiKey.trim().isNotEmpty) {
      _verifyGeminiApiKey(_geminiApiKey).then((res) {
        final ok = res['ok'] == true;
        prefs.setBool(_prefsGeminiVerifiedKey, ok);
        if (mounted) {
          setState(() => _geminiKeyVerified = ok);
        }
      });
    }
  }

  Future<void> _saveUserSubCategories() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsUserSubCatsKey,
      jsonEncode(_userSubCategoriesMap),
    );
  }

  Future<void> _addUserSubCategory(String majorCat, String newSubCat) async {
    final clean = newSubCat.trim();
    if (clean.isEmpty || clean == '전체' || clean == '미지정') return;
    final list = List<String>.from(_userSubCategoriesMap[majorCat] ?? []);
    if (!list.contains(clean)) {
      list.add(clean);
      setState(() {
        _userSubCategoriesMap[majorCat] = list;
      });
      await _saveUserSubCategories();
    }
  }

  Future<void> _deleteUserSubCategory(
      String majorCat, String targetSubCat) async {
    final list = List<String>.from(_userSubCategoriesMap[majorCat] ?? []);
    list.remove(targetSubCat);
    setState(() {
      _userSubCategoriesMap[majorCat] = list;
      if (_selectedSubCategoryFilter == targetSubCat) {
        _selectedSubCategoryFilter = '전체';
      }
      for (int i = 0; i < _records.length; i++) {
        if (_records[i].category == majorCat &&
            _records[i].subCategory == targetSubCat) {
          final updatedFields = Map<String, String>.from(_records[i].fields);
          updatedFields['subCategory'] = '';
          _records[i] = DocRecord(
            id: _records[i].id,
            category: _records[i].category,
            createdAt: _records[i].createdAt,
            imagePath: _records[i].imagePath,
            base64Image: _records[i].base64Image,
            fields: updatedFields,
          );
        }
      }
    });
    await _saveUserSubCategories();
    await _saveLocalRecords();
  }

  Future<void> _saveLocalRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final appDir = await getApplicationDocumentsDirectory();
    final List<String> serialized = <String>[];

    for (int i = 0; i < _records.length; i++) {
      DocRecord r = _records[i];
      String imgPath = r.imagePath;
      if ((imgPath.isEmpty || !File(imgPath).existsSync()) &&
          r.base64Image.trim().isNotEmpty) {
        try {
          final bytes = base64Decode(r.base64Image);
          final restoredFile = File(p.join(appDir.path, 'doc_${r.id}.jpg'));
          await restoredFile.writeAsBytes(bytes, flush: true);
          imgPath = restoredFile.path;
        } catch (_) {}
      }

      Map<String, String> cleanFields = Map<String, String>.from(r.fields);
      if (cleanFields.containsKey('proofImagesJson')) {
        final rawB64s = r.extraProofImages;
        final existingPaths = r.extraProofImagePaths;
        if (rawB64s.isNotEmpty && existingPaths.length < rawB64s.length) {
          final List<String> newPaths = <String>[];
          for (int pIdx = 0; pIdx < rawB64s.length; pIdx++) {
            try {
              final pBytes = base64Decode(rawB64s[pIdx]);
              final pf =
                  File(p.join(appDir.path, 'proof_${r.id}_$pIdx.jpg'));
              await pf.writeAsBytes(pBytes, flush: true);
              newPaths.add(pf.path);
            } catch (_) {}
          }
          if (newPaths.isNotEmpty) {
            cleanFields['proofPathsJson'] = jsonEncode(newPaths);
            cleanFields['proofStatus'] = '첨부(${newPaths.length}장)';
          }
        }
        cleanFields.remove('proofImagesJson');
      }

      final lightRec = DocRecord(
        id: r.id,
        category: r.category,
        createdAt: r.createdAt,
        imagePath: imgPath,
        base64Image: '',
        fields: cleanFields,
      );
      _records[i] = lightRec;
      if (_selectedRecord?.id == lightRec.id) {
        _selectedRecord = lightRec;
      }
      serialized.add(jsonEncode(lightRec.toJson(includeBase64: false)));
    }

    await prefs.setStringList(_prefsRecordsKey, serialized);
  }

  // ---------------------------------------------------------------------------
  // 날짜/기간 필터 & 합산 칩 계산
  // ---------------------------------------------------------------------------
  DateTime? _parseRecordDate(DocRecord r) {
    String raw = '';
    if (DocCategory.isOfficial(r.category)) {
      raw = r.fields['sentDate'] ?? '';
    } else if (r.category == DocCategory.invoice) {
      raw = r.fields['arrivalDate'] ?? '';
    } else if (r.category == DocCategory.travel) {
      raw = r.fields['date'] ?? '';
    } else if (r.category == DocCategory.medical) {
      raw = r.fields['issueDate'] ?? '';
    } else if (r.category == DocCategory.businessCard) {
      raw = r.fields['cardDate'] ?? '';
    } else if (r.category == DocCategory.pdfConvert) {
      raw = r.fields['pdfDate'] ?? '';
    }
    if (raw.trim().isEmpty) {
      raw = r.createdAt.split(' ').first;
    }
    final m = RegExp(r'(\d{4})\s*[-./년]\s*(\d{1,2})\s*[-./월]\s*(\d{1,2})')
        .firstMatch(raw);
    if (m != null) {
      final y = int.tryParse(m.group(1)!) ?? DateTime.now().year;
      final mo = int.tryParse(m.group(2)!) ?? 1;
      final d = int.tryParse(m.group(3)!) ?? 1;
      return DateTime(y, mo, d);
    }
    return null;
  }

  DateTimeRange _computePeriodRangeForAnchor(DateTime anchorMonth) {
    final int y = anchorMonth.year;
    final int m = anchorMonth.month;
    if (_periodStartDay <= 1) {
      final start = DateTime(y, m, 1);
      final end = DateTime(y, m + 1, 0, 23, 59, 59);
      return DateTimeRange(start: start, end: end);
    } else {
      final prevMonthStart = DateTime(y, m - 1, _periodStartDay);
      final currMonthEnd =
          DateTime(y, m, _periodStartDay - 1, 23, 59, 59);
      return DateTimeRange(start: prevMonthStart, end: currMonthEnd);
    }
  }

  bool _usesPeriodFilter(String cat) {
    return cat == DocCategory.invoice || cat == DocCategory.medical;
  }

  bool _usesSubCategory(String cat) {
    return cat == DocCategory.travel || cat == DocCategory.medical;
  }

  bool _matchesCurrentPeriodFilter(DocRecord r) {
    if (!_usesPeriodFilter(r.category)) return true;
    final isAll = _periodFilterAllMap[r.category] ?? true;
    if (isAll) return true;
    final dt = _parseRecordDate(r);
    if (dt == null) return true;
    final dayOnly = DateTime(dt.year, dt.month, dt.day);

    if (r.category == DocCategory.medical) {
      if (_medicalCustomStartDate != null) {
        final s = DateTime(
          _medicalCustomStartDate!.year,
          _medicalCustomStartDate!.month,
          _medicalCustomStartDate!.day,
        );
        if (dayOnly.isBefore(s)) return false;
      }
      if (_medicalCustomEndDate != null) {
        final e = DateTime(
          _medicalCustomEndDate!.year,
          _medicalCustomEndDate!.month,
          _medicalCustomEndDate!.day,
        );
        if (dayOnly.isAfter(e)) return false;
      }
      return true;
    }

    final anchor = _periodAnchorMonthMap[r.category] ??
        DateTime(DateTime.now().year, DateTime.now().month, 1);
    final range = _computePeriodRangeForAnchor(anchor);
    final startDay =
        DateTime(range.start.year, range.start.month, range.start.day);
    final endDay = DateTime(range.end.year, range.end.month, range.end.day);
    return !dayOnly.isBefore(startDay) && !dayOnly.isAfter(endDay);
  }

  String _currentPeriodButtonLabel(String cat) {
    final isAll = _periodFilterAllMap[cat] ?? true;
    if (isAll) return '전체';
    if (cat == DocCategory.medical) return '기간지정';
    final anchor = _periodAnchorMonthMap[cat] ?? DateTime.now();
    return '${anchor.month}월';
  }

  String _currentPeriodRangeDescription(String cat) {
    final isAll = _periodFilterAllMap[cat] ?? true;
    if (isAll) return '전체 기간';
    if (cat == DocCategory.medical) {
      final sStr = _medicalCustomStartDate != null
          ? DateFormat('yyyy.MM.dd').format(_medicalCustomStartDate!)
          : '처음';
      final eStr = _medicalCustomEndDate != null
          ? DateFormat('yyyy.MM.dd').format(_medicalCustomEndDate!)
          : '현재';
      return '$sStr ~ $eStr';
    }
    final anchor = _periodAnchorMonthMap[cat] ?? DateTime.now();
    final range = _computePeriodRangeForAnchor(anchor);
    return '${DateFormat('yyyy.MM.dd').format(range.start)} ~ ${DateFormat('yyyy.MM.dd').format(range.end)}';
  }

  void _shiftPeriodMonth(String cat, int deltaMonths) {
    setState(() {
      _periodFilterAllMap[cat] = false;
      final cur = _periodAnchorMonthMap[cat] ??
          DateTime(DateTime.now().year, DateTime.now().month, 1);
      _periodAnchorMonthMap[cat] =
          DateTime(cur.year, cur.month + deltaMonths, 1);
      final currentList = _filteredRecords;
      if (!currentList.any((r) => r.id == _selectedRecord?.id)) {
        _selectedRecord =
            currentList.isNotEmpty ? currentList.first : null;
      }
    });
  }

  Future<void> _openPeriodFilterDialog(String cat) async {
    final anchor = _periodAnchorMonthMap[cat] ?? DateTime.now();
    int selectedYear = anchor.year;
    int tempStartDay = _periodStartDay;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return AlertDialog(
            title: Text(
              '$cat 기간별 필터 설정',
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            content: SizedBox(
              width: 340,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: (_periodFilterAllMap[cat] ?? true)
                          ? const Color(0xFF1E3A8A)
                          : Colors.blueGrey,
                    ),
                    onPressed: () {
                      setState(() {
                        _periodFilterAllMap[cat] = true;
                      });
                      Navigator.pop(ctx);
                    },
                    icon: const Icon(Icons.all_inclusive, size: 18),
                    label: const Text('전체 기간 보기'),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        onPressed: () =>
                            setModalState(() => selectedYear -= 1),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Text(
                        '$selectedYear년',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      IconButton(
                        onPressed: () =>
                            setModalState(() => selectedYear += 1),
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    alignment: WrapAlignment.center,
                    children: List.generate(12, (idx) {
                      final m = idx + 1;
                      final isSelected = !(_periodFilterAllMap[cat] ?? true) &&
                          anchor.year == selectedYear &&
                          anchor.month == m;
                      return ChoiceChip(
                        label: Text('$m월'),
                        selected: isSelected,
                        onSelected: (_) {
                          setState(() {
                            _periodFilterAllMap[cat] = false;
                            _periodAnchorMonthMap[cat] =
                                DateTime(selectedYear, m, 1);
                          });
                          Navigator.pop(ctx);
                        },
                      );
                    }),
                  ),
                  const Divider(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '한 달 시작 기준일:',
                        style: TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.bold),
                      ),
                      DropdownButton<int>(
                        value: tempStartDay,
                        items: List.generate(28, (i) => i + 1)
                            .map((d) => DropdownMenuItem(
                                  value: d,
                                  child: Text(
                                      d == 1 ? '매월 1일 ~ 말일' : '전월 $d일 ~ 당월 ${d - 1}일'),
                                ))
                            .toList(),
                        onChanged: (v) async {
                          if (v == null) return;
                          setModalState(() => tempStartDay = v);
                          setState(() => _periodStartDay = v);
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setInt(_prefsPeriodStartDayKey, v);
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('닫기'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openMedicalDateFilterDialog() async {
    DateTime tempStart = _medicalCustomStartDate ??
        DateTime.now().subtract(const Duration(days: 30));
    DateTime tempEnd = _medicalCustomEndDate ?? DateTime.now();

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return AlertDialog(
            title: const Text(
              '병원비 날짜 지정 필터',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  onPressed: () {
                    setState(() {
                      _periodFilterAllMap[DocCategory.medical] = true;
                      _medicalCustomStartDate = null;
                      _medicalCustomEndDate = null;
                    });
                    Navigator.pop(ctx);
                  },
                  icon: const Icon(Icons.all_inclusive, size: 18),
                  label: const Text('전체 날짜 보기'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: tempStart,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) {
                      setModalState(() => tempStart = picked);
                    }
                  },
                  icon: const Icon(Icons.calendar_today, size: 16),
                  label: Text(
                      '시작일: ${DateFormat('yyyy.MM.dd').format(tempStart)}'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: tempEnd,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) {
                      setModalState(() => tempEnd = picked);
                    }
                  },
                  icon: const Icon(Icons.event, size: 16),
                  label:
                      Text('종료일: ${DateFormat('yyyy.MM.dd').format(tempEnd)}'),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () {
                  setState(() {
                    _periodFilterAllMap[DocCategory.medical] = false;
                    _medicalCustomStartDate = tempStart;
                    _medicalCustomEndDate = tempEnd;
                  });
                  Navigator.pop(ctx);
                },
                child: const Text('적용'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 그룹 키 & 합산 도우미
  // ---------------------------------------------------------------------------
  String get _invoiceSummaryModeLabel {
    if (_invSumByProduct && _invSumBySpec) return '제품명-규격별';
    if (_invSumBySpec) return '규격명별';
    return '제품명별';
  }

  String _invoiceGroupKeyOf(DocRecord r) {
    final prod = (r.fields['productName'] ?? '').trim().isEmpty
        ? '미지정'
        : r.fields['productName']!.trim();
    final spec = (r.fields['specName'] ?? '').trim().isEmpty
        ? '규격미상'
        : r.fields['specName']!.trim();
    if (_invSumByProduct && _invSumBySpec) return '$prod-$spec';
    if (_invSumBySpec) return spec;
    return prod;
  }

  void _toggleInvoiceGroupHeader(String fieldType) {
    setState(() {
      if (fieldType == 'product') {
        if (_invSumByProduct && _invSumBySpec) {
          _invSumByProduct = false;
        } else if (_invSumByProduct && !_invSumBySpec) {
          _invSumByProduct = true;
        } else {
          _invSumByProduct = true;
        }
      } else if (fieldType == 'spec') {
        if (_invSumByProduct && _invSumBySpec) {
          _invSumBySpec = false;
        } else if (!_invSumByProduct && _invSumBySpec) {
          _invSumByProduct = true;
          _invSumBySpec = false;
        } else {
          _invSumByProduct = false;
          _invSumBySpec = true;
        }
      }
      if (!_invSumByProduct && !_invSumBySpec) {
        _invSumByProduct = true;
      }
      _selectedInvoiceProductFilter = '전체';
    });
  }

  String get _medicalSummaryModeLabel {
    final parts = <String>[];
    if (_medSumByCat) parts.add('카테고리');
    if (_medSumByPatient) parts.add('환자');
    if (_medSumByClaim) parts.add('청구여부');
    if (parts.isEmpty) return '카테고리별';
    return '${parts.join('-')}별';
  }

  String _medicalGroupKeyOf(DocRecord r) {
    final cat = r.subCategory.isEmpty ? '미지정' : r.subCategory;
    final pat = (r.fields['patientName'] ?? '').trim().isEmpty
        ? '환자미상'
        : r.fields['patientName']!.trim();
    final clm = r.medicalClaimLabel;
    final parts = <String>[];
    if (_medSumByCat) parts.add(cat);
    if (_medSumByPatient) parts.add(pat);
    if (_medSumByClaim) parts.add(clm);
    if (parts.isEmpty) return cat;
    return parts.join('-');
  }

  void _toggleMedicalGroupHeader(String fieldType) {
    setState(() {
      if (fieldType == 'cat') {
        _medSumByCat = true;
        _medSumByPatient = false;
        _medSumByClaim = false;
      } else if (fieldType == 'patient') {
        if (!_medSumByPatient && !_medSumByClaim) {
          _medSumByCat = false;
          _medSumByPatient = true;
          _medSumByClaim = false;
        } else if (_medSumByPatient && !_medSumByCat && !_medSumByClaim) {
          _medSumByCat = true;
          _medSumByPatient = true;
        } else {
          _medSumByCat = false;
          _medSumByPatient = true;
          _medSumByClaim = false;
        }
      } else if (fieldType == 'claim') {
        if (!_medSumByClaim) {
          _medSumByCat = false;
          _medSumByPatient = false;
          _medSumByClaim = true;
        } else {
          _medSumByCat = true;
          _medSumByPatient = false;
          _medSumByClaim = false;
        }
      }
      _selectedSubCategoryFilter = '전체';
    });
  }

  String _formatQtyClean(double v) {
    if ((v - v.roundToDouble()).abs() < 0.0001) {
      return v.round().toString();
    }
    return v
        .toStringAsFixed(3)
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');
  }

  int _sumByMajorCategory(String majorCat) {
    final list = majorCat == DocCategory.all
        ? _records
        : _records.where(
            (r) => r.category == majorCat && _matchesCurrentPeriodFilter(r));
    int sum = 0;
    for (final r in list) {
      sum += r.numericAmount;
    }
    return sum;
  }

  int _sumBySubCategory(String subCat) {
    final majorList = _recordsInSelectedMajorCategory;
    int sum = 0;
    for (final r in majorList) {
      if (subCat == '전체') {
        sum += r.numericAmount;
      } else if (_selectedCategoryFilter == DocCategory.medical) {
        if (_medicalGroupKeyOf(r) == subCat) sum += r.numericAmount;
      } else if (subCat == '미지정') {
        if (r.subCategory.isEmpty) sum += r.numericAmount;
      } else if (r.subCategory == subCat) {
        sum += r.numericAmount;
      }
    }
    return sum;
  }

  int _countBySubCategory(String subCat) {
    final majorList = _recordsInSelectedMajorCategory;
    if (subCat == '전체') return majorList.length;
    if (_selectedCategoryFilter == DocCategory.medical) {
      return majorList.where((r) => _medicalGroupKeyOf(r) == subCat).length;
    }
    if (subCat == '미지정') {
      return majorList.where((r) => r.subCategory.isEmpty).length;
    }
    return majorList.where((r) => r.subCategory == subCat).length;
  }

  int _sumByTravelDivision(String division) {
    final subFiltered = _subCategoryFilteredRecords
        .where((r) => r.category == DocCategory.travel);
    int sum = 0;
    for (final r in subFiltered) {
      if (division == '전체' || r.travelDivision == division) {
        sum += r.numericAmount;
      }
    }
    return sum;
  }

  int _countByTravelDivision(String division) {
    final subFiltered = _subCategoryFilteredRecords
        .where((r) => r.category == DocCategory.travel);
    if (division == '전체') return subFiltered.length;
    return subFiltered.where((r) => r.travelDivision == division).length;
  }

  int _sumByMedicalClaimStatus(String statusFilter) {
    final baseList = _subCategoryFilteredRecords
        .where((r) => r.category == DocCategory.medical);
    int sum = 0;
    for (final r in baseList) {
      if (statusFilter == '전체') {
        sum += r.numericAmount;
      } else if (statusFilter == '청구완료' && r.isMedicalClaimed) {
        sum += r.numericAmount;
      } else if (statusFilter == '미청구' && !r.isMedicalClaimed) {
        sum += r.numericAmount;
      }
    }
    return sum;
  }

  int _countByMedicalClaimStatus(String statusFilter) {
    final baseList = _subCategoryFilteredRecords
        .where((r) => r.category == DocCategory.medical);
    if (statusFilter == '전체') return baseList.length;
    final bool wantClaimed = statusFilter == '청구완료';
    return baseList.where((r) => r.isMedicalClaimed == wantClaimed).length;
  }

  List<String> get _invoiceProductNamesInCurrentPeriod {
    final periodInvoices = _records
        .where((r) =>
            r.category == DocCategory.invoice && _matchesCurrentPeriodFilter(r))
        .toList();
    final Set<String> groups = {};
    for (final r in periodInvoices) {
      final g = _invoiceGroupKeyOf(r);
      if (g.isNotEmpty) groups.add(g);
    }
    return ['전체', ...groups];
  }

  String _invoiceProductChipLabel(String groupKey) {
    final periodInvoices = _records
        .where((r) =>
            r.category == DocCategory.invoice && _matchesCurrentPeriodFilter(r))
        .toList();
    if (groupKey == '전체') {
      final Map<String, double> sumByUnit = {};
      for (final r in periodInvoices) {
        final prod = (r.fields['productName'] ?? '').trim();
        final rawU = (r.fields['unit'] ?? '').trim();
        final u = rawU.isNotEmpty
            ? rawU
            : (prod.contains('철근') ? 'ton' : '매');
        sumByUnit[u] = (sumByUnit[u] ?? 0.0) + r.numericInvoiceQuantity;
      }
      if (sumByUnit.isEmpty) {
        return '전체 (0건)';
      }
      final unitParts = sumByUnit.entries
          .map((e) => '${_formatQtyClean(e.value)}${e.key}')
          .join(' / ');
      return '전체 (${periodInvoices.length}건 · $unitParts)';
    }
    final matching = periodInvoices
        .where((r) => _invoiceGroupKeyOf(r) == groupKey)
        .toList();
    double sumQty = 0.0;
    String unit = 'ton';
    for (final r in matching) {
      sumQty += r.numericInvoiceQuantity;
      final u = (r.fields['unit'] ?? '').trim();
      if (u.isNotEmpty) unit = u;
    }
    return '$groupKey(${_formatQtyClean(sumQty)}$unit)';
  }

  List<DocRecord> get _recordsInSelectedMajorCategory {
    if (_selectedCategoryFilter == DocCategory.all) return _records;
    return _records
        .where((r) =>
            r.category == _selectedCategoryFilter &&
            _matchesCurrentPeriodFilter(r))
        .toList();
  }

  List<DocRecord> get _subCategoryFilteredRecords {
    final majorList = _recordsInSelectedMajorCategory;
    if (!_usesSubCategory(_selectedCategoryFilter)) return majorList;
    if (_selectedSubCategoryFilter == '전체') return majorList;
    if (_selectedCategoryFilter == DocCategory.medical) {
      return majorList
          .where((r) => _medicalGroupKeyOf(r) == _selectedSubCategoryFilter)
          .toList();
    }
    if (_selectedSubCategoryFilter == '미지정') {
      return majorList.where((r) => r.subCategory.isEmpty).toList();
    }
    return majorList
        .where((r) => r.subCategory == _selectedSubCategoryFilter)
        .toList();
  }

  String _extractSortableDateKey(DocRecord r) {
    final f = r.fields;
    String raw = '';
    if (DocCategory.isOfficial(r.category)) {
      raw = f['sentDate'] ?? '';
    } else if (r.category == DocCategory.invoice) {
      raw = f['arrivalDate'] ?? '';
    } else if (r.category == DocCategory.travel) {
      raw = f['date'] ?? '';
    } else if (r.category == DocCategory.medical) {
      raw = f['issueDate'] ?? '';
    } else if (r.category == DocCategory.businessCard) {
      raw = f['cardDate'] ?? '';
    } else if (r.category == DocCategory.pdfConvert) {
      raw = f['pdfDate'] ?? '';
    }
    final dot = DocRecord.formatDotDate(raw);
    if (RegExp(r'^\d{4}\.\d{2}\.\d{2}$').hasMatch(dot)) return dot;
    return r.createdAt;
  }

  void _toggleSortColumn(String colKey) {
    setState(() {
      if (_sortColumn == colKey) {
        _sortAscending = !_sortAscending;
      } else {
        _sortColumn = colKey;
        _sortAscending = (colKey == 'date' ||
                colKey == 'replied' ||
                colKey == 'amount' ||
                colKey == 'claimed' ||
                colKey == 'pageCount')
            ? false
            : true;
      }
    });
  }

  void _sortRecordList(
    List<DocRecord> list,
    Set<String> repliedKeys, {
    String? colOverride,
    bool? ascOverride,
  }) {
    final col = colOverride ?? _sortColumn;
    final asc = ascOverride ?? _sortAscending;
    list.sort((a, b) {
      int cmp = 0;
      if (col == 'docNumber') {
        final da = (a.fields['docNumber'] ?? '').trim();
        final db = (b.fields['docNumber'] ?? '').trim();
        cmp = da.compareTo(db);
      } else if (col == 'replied') {
        final ra = _isIncomingDocReplied(a, repliedKeys) ? 1 : 0;
        final rb = _isIncomingDocReplied(b, repliedKeys) ? 1 : 0;
        cmp = ra.compareTo(rb);
      } else if (col == 'uploader') {
        final ua = _resolveUploaderName(a);
        final ub = _resolveUploaderName(b);
        cmp = ua.compareTo(ub);
      } else if (col == 'product') {
        final pa = (a.fields['productName'] ?? '').trim();
        final pb = (b.fields['productName'] ?? '').trim();
        cmp = pa.compareTo(pb);
      } else if (col == 'spec') {
        final sa = (a.fields['specName'] ?? '').trim();
        final sb = (b.fields['specName'] ?? '').trim();
        cmp = sa.compareTo(sb);
      } else if (col == 'supplier') {
        final sa = (a.fields['supplierName'] ?? '').trim();
        final sb = (b.fields['supplierName'] ?? '').trim();
        cmp = sa.compareTo(sb);
      } else if (col == 'subCategory') {
        final ca = a.subCategory.isEmpty ? '미지정' : a.subCategory;
        final cb = b.subCategory.isEmpty ? '미지정' : b.subCategory;
        cmp = ca.compareTo(cb);
      } else if (col == 'patient') {
        final pa = (a.fields['patientName'] ?? '').trim();
        final pb = (b.fields['patientName'] ?? '').trim();
        cmp = pa.compareTo(pb);
      } else if (col == 'clinic') {
        final ma = (a.fields['clinicName'] ??
                a.fields['merchantName'] ??
                a.fields['title'] ??
                '')
            .trim();
        final mb = (b.fields['clinicName'] ??
                b.fields['merchantName'] ??
                b.fields['title'] ??
                '')
            .trim();
        cmp = ma.compareTo(mb);
      } else if (col == 'amount') {
        cmp = a.numericAmount.compareTo(b.numericAmount);
      } else if (col == 'claimed') {
        final ca = a.isMedicalClaimed ? 1 : 0;
        final cb = b.isMedicalClaimed ? 1 : 0;
        cmp = ca.compareTo(cb);
      } else if (col == 'companyName') {
        final ca = (a.fields['companyName'] ?? '').trim();
        final cb = (b.fields['companyName'] ?? '').trim();
        cmp = ca.compareTo(cb);
      } else if (col == 'siteName') {
        final sa = (a.fields['siteName'] ?? '').trim();
        final sb = (b.fields['siteName'] ?? '').trim();
        cmp = sa.compareTo(sb);
      } else if (col == 'personName') {
        final pa = (a.fields['personName'] ?? '').trim();
        final pb = (b.fields['personName'] ?? '').trim();
        cmp = pa.compareTo(pb);
      } else if (col == 'pdfFileName') {
        final fa = (a.fields['pdfFileName'] ?? '').trim();
        final fb = (b.fields['pdfFileName'] ?? '').trim();
        cmp = fa.compareTo(fb);
      } else if (col == 'pageCount') {
        cmp = a.totalPdfPageCount.compareTo(b.totalPdfPageCount);
      } else {
        final da = _extractSortableDateKey(a);
        final db = _extractSortableDateKey(b);
        cmp = da.compareTo(db);
      }
      if (cmp == 0) {
        cmp = a.createdAt.compareTo(b.createdAt);
      }
      return asc ? cmp : -cmp;
    });
  }

  List<DocRecord> get _filteredRecords {
    final subList = _subCategoryFilteredRecords;
    List<DocRecord> result;
    if (_selectedCategoryFilter == DocCategory.travel &&
        _selectedTravelDivisionFilter != '전체') {
      result = subList
          .where((r) => r.travelDivision == _selectedTravelDivisionFilter)
          .toList();
    } else if (_selectedCategoryFilter == DocCategory.invoice &&
        _selectedInvoiceProductFilter != '전체') {
      result = subList
          .where((r) => _invoiceGroupKeyOf(r) == _selectedInvoiceProductFilter)
          .toList();
    } else if (_selectedCategoryFilter == DocCategory.medical &&
        _selectedMedicalClaimFilter != '전체') {
      final wantClaimed = _selectedMedicalClaimFilter == '청구완료';
      result =
          subList.where((r) => r.isMedicalClaimed == wantClaimed).toList();
    } else if (_selectedCategoryFilter == DocCategory.businessCard &&
        _businessCardSearchQuery.trim().isNotEmpty) {
      final q = _businessCardSearchQuery.trim().toLowerCase();
      final qCompact = q.replaceAll(RegExp(r'\s+'), '');
      result = subList.where((r) {
        final comp = (r.fields['companyName'] ?? '').toLowerCase();
        final site = (r.fields['siteName'] ?? '').toLowerCase();
        final name = (r.fields['personName'] ?? '').toLowerCase();
        final combined = '$comp $site $name';
        final combinedCompact = combined.replaceAll(RegExp(r'\s+'), '');
        return combined.contains(q) || combinedCompact.contains(qCompact);
      }).toList();
    } else {
      result = List<DocRecord>.from(subList);
    }

    final repliedKeys = _computeRepliedDocNumKeys(_records);
    _sortRecordList(result, repliedKeys);
    return result;
  }

  Set<String> _computeRepliedDocNumKeys(List<DocRecord> records) {
    final Set<String> keys = {};
    for (final r in records) {
      if (r.category == DocCategory.officialOut) {
        final k = DocRecord.normalizeDocNumKey(r.fields['replyDocNumber']);
        if (k.isNotEmpty) keys.add(k);
      }
    }
    return keys;
  }

  bool _isIncomingDocReplied(DocRecord rec, Set<String> repliedKeys) {
    if (rec.category != DocCategory.officialIn) return false;
    final myKey = DocRecord.normalizeDocNumKey(rec.fields['docNumber']);
    if (myKey.isEmpty) return false;
    return repliedKeys.contains(myKey);
  }

  Map<String, String> _computeInvoiceCumulativeMap(List<DocRecord> records) {
    final invoiceList =
        records.where((r) => r.category == DocCategory.invoice).toList();

    invoiceList.sort((a, b) {
      final da = DocRecord.formatDotDate(a.fields['arrivalDate']);
      final db = DocRecord.formatDotDate(b.fields['arrivalDate']);
      final cmpDate = da.compareTo(db);
      if (cmpDate != 0) return cmpDate;
      return a.createdAt.compareTo(b.createdAt);
    });

    final Map<String, double> runningSums = {};
    final Map<String, String> result = {};

    for (final rec in invoiceList) {
      final prod =
          (rec.fields['productName'] ?? '').trim().replaceAll(' ', '');
      final spec = (rec.fields['specName'] ?? '')
          .trim()
          .toUpperCase()
          .replaceAll(' ', '');
      final key = '$prod|$spec';
      final qty = rec.numericInvoiceQuantity;
      final newSum = (runningSums[key] ?? 0.0) + qty;
      runningSums[key] = newSum;

      if (newSum == 0) {
        result[rec.id] = '-';
      } else if ((newSum - newSum.roundToDouble()).abs() < 0.0001) {
        result[rec.id] = newSum.round().toString();
      } else {
        result[rec.id] = newSum
            .toStringAsFixed(3)
            .replaceAll(RegExp(r'0+$'), '')
            .replaceAll(RegExp(r'\.$'), '');
      }
    }
    return result;
  }

  List<String> get _userRegisteredSubCategoriesForCurrentTab {
    if (!_usesSubCategory(_selectedCategoryFilter)) return ['전체'];
    if (_selectedCategoryFilter == DocCategory.medical) {
      if (_medSumByCat && !_medSumByPatient && !_medSumByClaim) {
        final Set<String> subs = {};
        subs.addAll(_userSubCategoriesMap[DocCategory.medical] ?? []);
        for (final r in _recordsInSelectedMajorCategory) {
          final k = _medicalGroupKeyOf(r);
          if (k.isNotEmpty && k != '미지정') subs.add(k);
        }
        final result = ['전체', ...subs];
        if (_recordsInSelectedMajorCategory
            .any((r) => r.subCategory.isEmpty)) {
          result.add('미지정');
        }
        return result;
      } else {
        final Set<String> groups = {};
        for (final r in _recordsInSelectedMajorCategory) {
          groups.add(_medicalGroupKeyOf(r));
        }
        return ['전체', ...groups];
      }
    }
    final registered = _userSubCategoriesMap[_selectedCategoryFilter] ?? [];
    final Set<String> subs = {...registered};
    for (final r in _recordsInSelectedMajorCategory) {
      if (r.subCategory.isNotEmpty) subs.add(r.subCategory);
    }
    final result = ['전체', ...subs];
    if (_recordsInSelectedMajorCategory.any((r) => r.subCategory.isEmpty)) {
      result.add('미지정');
    }
    return result;
  }

  Future<void> _promptAddNewSubCategory(String majorCat) async {
    final ctrl = TextEditingController();
    final added = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$majorCat 새 카테고리 등록'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '카테고리 이름',
            hintText: '예: 갑상선, 치과, 여의도출장 등',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('등록'),
          ),
        ],
      ),
    );
    if (added != null && added.isNotEmpty) {
      await _addUserSubCategory(majorCat, added);
    }
  }

  // ===========================================================================
  // 1단계: 오프라인 한국어 OCR (Google ML Kit) & 2단계: Gemini AI 정밀 분석
  // (※ PDF변환 탭은 OCR/AI를 전혀 호출하지 않고 즉시 파일명만 입력받습니다!)
  // ===========================================================================
  static Uint8List? _cropFooterForFineOcrIsolate(Uint8List srcBytes) {
    final decoded = img.decodeImage(srcBytes);
    if (decoded == null) return null;
    final int yStart = (decoded.height * 0.68).round();
    final int cropH = decoded.height - yStart;
    if (cropH < 40) return null;
    final cropped = img.copyCrop(
      decoded,
      x: 0,
      y: yStart,
      width: decoded.width,
      height: cropH,
    );
    final upscaled = img.copyResize(
      cropped,
      width: math.min(2400, cropped.width * 2),
    );
    return Uint8List.fromList(img.encodeJpg(upscaled, quality: 92));
  }

  Future<RecognizedText> _runMlKitOnBytes(
    TextRecognizer recognizer,
    Uint8List bytes,
    String tempName,
  ) async {
    final tempDir = await getTemporaryDirectory();
    final f = File(p.join(tempDir.path, tempName));
    await f.writeAsBytes(bytes, flush: true);
    final inputImage = InputImage.fromFilePath(f.path);
    return recognizer.processImage(inputImage);
  }

  List<String> _mergeRecognizedRows(RecognizedText recognized) {
    final allLines = <TextLine>[];
    for (final b in recognized.blocks) {
      allLines.addAll(b.lines);
    }
    if (allLines.isEmpty) return [];

    allLines.sort(
      (a, b) => a.boundingBox.center.dy.compareTo(b.boundingBox.center.dy),
    );

    final List<List<TextLine>> rowGroups = [];
    for (final line in allLines) {
      bool placed = false;
      for (final group in rowGroups) {
        final ref = group.first;
        final double dy =
            (line.boundingBox.center.dy - ref.boundingBox.center.dy).abs();
        final double tol =
            math.max(line.boundingBox.height, ref.boundingBox.height) * 0.62;
        if (dy <= tol) {
          group.add(line);
          placed = true;
          break;
        }
      }
      if (!placed) {
        rowGroups.add([line]);
      }
    }

    final List<String> merged = [];
    for (final g in rowGroups) {
      g.sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));
      merged.add(g.map((e) => e.text.trim()).join('   '));
    }
    return merged;
  }

  Future<Map<String, String>> _extractFieldsOfflineOcr({
    required String imagePath,
    required Uint8List imageBytes,
    required String category,
  }) async {
    if (category == DocCategory.pdfConvert) {
      return {};
    }
    TextRecognizer? textRecognizer;
    try {
      textRecognizer = TextRecognizer(script: TextRecognitionScript.korean);
      final inputImage = InputImage.fromFilePath(imagePath);
      final recognized = await textRecognizer.processImage(inputImage);
      final mergedRows = _mergeRecognizedRows(recognized);
      final fullText = mergedRows.join('\n');

      if (DocCategory.isOfficial(category)) {
        final bool isOutgoing = category == DocCategory.officialOut;
        final parsed = _parseOfficialDocText(
          fullText,
          mergedRows,
          recognized,
          isOutgoing: isOutgoing,
        );
        if ((parsed['docNumber'] ?? '').trim().isEmpty) {
          final footerBytes =
              await compute(_cropFooterForFineOcrIsolate, imageBytes);
          if (footerBytes != null) {
            final footerRec = await _runMlKitOnBytes(
              textRecognizer,
              footerBytes,
              'official_footer_crop.jpg',
            );
            final footerRows = _mergeRecognizedRows(footerRec);
            final footerParsed = _parseOfficialDocText(
              footerRows.join('\n'),
              footerRows,
              footerRec,
              isOutgoing: isOutgoing,
            );
            if ((footerParsed['docNumber'] ?? '').isNotEmpty) {
              parsed['docNumber'] = footerParsed['docNumber']!;
            }
            if ((parsed['sentDate'] ?? '').isEmpty &&
                (footerParsed['sentDate'] ?? '').isNotEmpty) {
              parsed['sentDate'] = footerParsed['sentDate']!;
            }
            if ((parsed['sender'] ?? '').isEmpty &&
                (footerParsed['sender'] ?? '').isNotEmpty) {
              parsed['sender'] = footerParsed['sender']!;
            }
          }
        }
        return parsed;
      }

      if (category == DocCategory.invoice) {
        final parsed0 = _parseInvoiceText(fullText, mergedRows, recognized);
        bool isRotatedOrIncomplete = parsed0['_isRotated90'] == 'true';
        if (!isRotatedOrIncomplete && (parsed0['itemsJson'] ?? '').isNotEmpty) {
          try {
            final list = jsonDecode(parsed0['itemsJson']!) as List<dynamic>;
            if (list.any((e) =>
                ((e as Map)['quantity']?.toString() ?? '').trim().isEmpty)) {
              isRotatedOrIncomplete = true;
            }
          } catch (_) {}
        }

        if (isRotatedOrIncomplete) {
          final uprightBytes = await compute(
            _rotateImageIsolate,
            {'bytes': imageBytes, 'angle': 270},
          );
          if (uprightBytes != null) {
            final uprightRec = await _runMlKitOnBytes(
              textRecognizer,
              uprightBytes,
              'invoice_upright_270.jpg',
            );
            final uprightRows = _mergeRecognizedRows(uprightRec);
            final uprightText = uprightRows.join('\n');
            final parsed270 =
                _parseInvoiceText(uprightText, uprightRows, uprightRec);
            if ((parsed270['itemsJson'] ?? '').isNotEmpty) {
              final list270 =
                  jsonDecode(parsed270['itemsJson']!) as List<dynamic>;
              if (list270.isNotEmpty &&
                  list270.every((e) =>
                      ((e as Map)['quantity']?.toString() ?? '')
                          .trim()
                          .isNotEmpty)) {
                return parsed270;
              }
            }
          }
        }
        return parsed0;
      }

      if (category == DocCategory.medical) {
        return _parseMedicalReceiptText(fullText, mergedRows, recognized);
      } else if (category == DocCategory.businessCard) {
        return _parseBusinessCardText(fullText, mergedRows, recognized);
      } else {
        return _parseTravelReceiptText(fullText, mergedRows, recognized.blocks);
      }
    } catch (_) {
      return {};
    } finally {
      try {
        await textRecognizer?.close();
      } catch (_) {}
    }
  }

  Map<String, String> _parseOfficialDocText(
    String fullText,
    List<String> rows,
    RecognizedText recognized, {
    required bool isOutgoing,
  }) {
    final result = <String, String>{};
    result['docDirection'] = isOutgoing ? '발신' : '수신';

    final sihaengDateMatch = RegExp(
      r'시\s*행[^\n()]*\(\s*(\d{4})\s*[-./년\s]\s*(\d{1,2})\s*[-./월\s]\s*(\d{1,2})',
    ).firstMatch(fullText);
    if (sihaengDateMatch != null) {
      result['sentDate'] = DocRecord.formatDotDate(
        '${sihaengDateMatch.group(1)}.${sihaengDateMatch.group(2)}.${sihaengDateMatch.group(3)}',
      );
    } else {
      for (final r in rows.reversed) {
        if (RegExp(r'일\s*시|기\s*간|까지|부터|회\s*신|참\s*석').hasMatch(r)) {
          continue;
        }
        final dm = RegExp(
                r'(\d{4})\s*[-./년]\s*(\d{1,2})\s*[-./월]\s*(\d{1,2})')
            .firstMatch(r);
        if (dm != null) {
          result['sentDate'] = DocRecord.formatDotDate(
            '${dm.group(1)}.${dm.group(2)}.${dm.group(3)}',
          );
          break;
        }
      }
    }

    final topDocNoMatch = RegExp(
      r'제\s*(\d{2,4}\s*[-~—]\s*\d{2,6})\s*호',
    ).firstMatch(fullText);
    if (topDocNoMatch != null) {
      result['docNumber'] =
          '${DocRecord.stripDocNumSpaces(topDocNoMatch.group(1))}호';
    } else {
      final sihaengNoMatch = RegExp(
        r'시\s*행\s*([가-힣A-Za-z0-9]+?\s*(?:제\s*)?\d{2,4}\s*[-~—]\s*\d{1,6}(?:\s*호)?)',
      ).firstMatch(fullText);
      if (sihaengNoMatch != null) {
        String rawNo = DocRecord.stripDocNumSpaces(sihaengNoMatch.group(1));
        final innerJe = RegExp(r'제(\d{2,4}-\d{1,6}호?)$').firstMatch(rawNo);
        if (innerJe != null) {
          rawNo = innerJe.group(1)!;
        }
        result['docNumber'] = rawNo;
      } else {
        final deptNoMatch = RegExp(
          r'([가-힣]{2,10}(?:과|팀|실|부|처|청|국|단|소|본부))\s*[-~—]\s*(\d{2,7})',
        ).firstMatch(fullText);
        if (deptNoMatch != null) {
          result['docNumber'] =
              '${deptNoMatch.group(1)}-${deptNoMatch.group(2)}';
        }
      }
    }

    final replyBracketMatch = RegExp(
      r'\[\s*([가-힣A-Za-z0-9\s]+?[-~—]\s*\d{2,7})\s*\]',
    ).firstMatch(fullText);
    if (replyBracketMatch != null) {
      result['replyDocNumber'] =
          DocRecord.stripDocNumSpaces(replyBracketMatch.group(1));
    }

    for (final line in rows) {
      final tm = RegExp(r'제\s*목\s*[:：]?\s*(.+)$').firstMatch(line);
      if (tm != null) {
        String t = tm.group(1)!.trim();
        t = t.replaceFirst(RegExp(r'^\[[^\]]+\]\s*'), '').trim();
        if (t.isNotEmpty) {
          result['title'] = t;
          break;
        }
      }
    }

    for (final line in rows) {
      final recMatch = RegExp(r'수\s*신\s*[:：]?\s*(.+)$').firstMatch(line);
      if (recMatch != null) {
        String rName = recMatch
            .group(1)!
            .replaceAll(RegExp(r'\(경유\)|귀하'), '')
            .trim();
        if (rName.isNotEmpty) {
          result['recipient'] = rName;
          break;
        }
      }
    }

    for (final line in rows.reversed) {
      final compact = line.replaceAll(RegExp(r'\s+'), '');
      if (compact.contains('수신') || compact.contains('제목')) continue;
      final sm = RegExp(
        r'([가-힣0-9A-Za-z()]{2,20}(?:시장|구청장|군수|도지사|청장|장관|본부장|위원장|지부장|조합장|대표이사|소장|단장|원장|총장|사장))',
      ).firstMatch(compact);
      if (sm != null && !sm.group(1)!.contains('행복도시')) {
        result['sender'] = sm.group(1)!;
        break;
      }
    }

    final deadlineMatch = RegExp(
      r'(\d{4})\s*[.년-]\s*(\d{1,2})\s*[.월-]\s*(\d{1,2})[^\n]{0,12}(?:까지|한|기한|회신)',
    ).firstMatch(fullText);
    if (deadlineMatch != null) {
      result['replyDeadline'] = DocRecord.formatDotDate(
        '${deadlineMatch.group(1)}.${deadlineMatch.group(2)}.${deadlineMatch.group(3)}',
      );
    }

    if ((result['title'] ?? '').isNotEmpty) {
      result['aiSummary'] = '${result['title']} 관련 안내 및 협조 요청';
    }
    return result;
  }

  Map<String, String> _parseTravelReceiptText(
    String fullText,
    List<String> lines,
    List<TextBlock> blocks,
  ) {
    final result = <String, String>{};

    final dateMatch =
        RegExp(r'(\d{4})\s*[-./년]\s*(\d{1,2})\s*[-./월]\s*(\d{1,2})')
            .firstMatch(fullText);
    if (dateMatch != null) {
      result['date'] =
          '${dateMatch.group(1)}.${dateMatch.group(2)!.padLeft(2, '0')}.${dateMatch.group(3)!.padLeft(2, '0')}';
    }

    final bool isMapRoute = RegExp(
      r'(?:실\s*시\s*간\s*추\s*천|안\s*내\s*시\s*작|전\s*체\s*경\s*로|큰\s*길\s*우\s*선|거\s*리\s*우\s*선|최\s*적\s*경\s*로|추천경로)',
    ).hasMatch(fullText);

    if (isMapRoute) {
      result['travelDivision'] = TravelDivision.car;
      double? detectedKm;
      final kmMatch =
          RegExp(r'(\d+(?:\.\d+)?)\s*km', caseSensitive: false)
              .firstMatch(fullText);
      if (kmMatch != null) {
        detectedKm = double.tryParse(kmMatch.group(1)!);
      }
      if (detectedKm != null && detectedKm > 0) {
        final kmStr = detectedKm == detectedKm.roundToDouble()
            ? detectedKm.round().toString()
            : detectedKm.toString();
        final fare = (detectedKm * 2 * 300).round();
        result['distanceKm'] = kmStr;
        result['totalAmount'] = fare.toString();
        result['merchantName'] = '실시간추천 ${kmStr}km 왕복 자차';
      }
      return result;
    }

    if (RegExp(r'(?:코레일|KORAIL|SRT|KTX|한국철도|승차권|열차|무궁화|새마을|ITX)',
            caseSensitive: false)
        .hasMatch(fullText)) {
      result['travelDivision'] = TravelDivision.train;
      result['merchantName'] =
          fullText.toUpperCase().contains('SRT') ? 'SRT 승차권' : '코레일(기차)';
    } else if (RegExp(r'(?:카카오\s*T|카카오택시|택시|개인택시|법인택시|미터기|호출료)',
            caseSensitive: false)
        .hasMatch(fullText)) {
      result['travelDivision'] = TravelDivision.taxi;
      result['merchantName'] =
          fullText.contains('카카오') ? '카카오택시' : '택시요금';
    } else if (RegExp(r'(?:하이패스|도로공사|통행료|톨게이트|영업소|고속도로|hi-pass|KEC)',
            caseSensitive: false)
        .hasMatch(fullText)) {
      result['travelDivision'] = TravelDivision.toll;
      result['merchantName'] = '하이패스 통행료';

      final cardTollMatches = RegExp(
        r'(?:[1-6]\s*종|경\s*차)[^\d\n]*([1-9]\d{0,2}(?:,\d{3})*|\d{2,6})\s*원?\s*\(\s*카\s*드\s*\)',
      ).allMatches(fullText).toList();

      if (cardTollMatches.isNotEmpty) {
        int sumToll = 0;
        for (final m in cardTollMatches) {
          sumToll += int.tryParse(m.group(1)!.replaceAll(',', '')) ?? 0;
        }
        if (sumToll > 0) {
          result['totalAmount'] = sumToll.toString();
          return result;
        }
      }
    } else {
      result['travelDivision'] = TravelDivision.meal;
      for (final line in lines) {
        if (line.contains('상세 이용내역') || line.contains('가맹점정보')) continue;
        final m = RegExp(
                r'([가-힣A-Za-z0-9\s]{2,16}(?:점|식당|카페|커피|분식|마트|버거|리아|김밥|국밥|회관|베이커리))')
            .firstMatch(line);
        if (m != null) {
          result['merchantName'] = m.group(1)!.trim();
          break;
        }
      }
    }

    final amtMatches = RegExp(r'([1-9]\d{0,2}(?:,\d{3})+)\s*원?')
        .allMatches(fullText)
        .toList();
    if (amtMatches.isNotEmpty) {
      result['totalAmount'] =
          amtMatches.last.group(1)!.replaceAll(',', '');
    }
    return result;
  }

  Map<String, String> _parseInvoiceText(
    String fullText,
    List<String> lines,
    RecognizedText recognized,
  ) {
    final result = <String, String>{};

    final dateMatch = RegExp(
      r'(\d{4})\s*(?:[-./]|년)\s*(\d{1,2})\s*(?:[-./]|월)\s*(\d{1,2})',
    ).firstMatch(fullText);
    if (dateMatch != null) {
      final y = dateMatch.group(1)!;
      final m = dateMatch.group(2)!.padLeft(2, '0');
      final d = dateMatch.group(3)!.padLeft(2, '0');
      result['arrivalDate'] = '$y.$m.$d';
    }

    final orderMatch = RegExp(
      r'([A-Z]-\d-\d{8}-\d{4,6}|\b[A-Z]-\d{2,4}-\d{3,6}\b|\b\d{10,14}\b|\b\d{2}-\d{3}-\d{4}\b)',
    ).firstMatch(fullText);
    if (orderMatch != null) {
      result['orderNumber'] = orderMatch.group(1)!;
    } else {
      for (final line in lines) {
        final noFullMatch = RegExp(
          r'No\.?\s*[:：]?\s*([0-9]{1,4}(?:\s+[A-Z0-9]{1,5}[-][A-Z0-9-]{3,12})?|[A-Z0-9]+[-][A-Z0-9-]+|[0-9]{4,14})',
          caseSensitive: false,
        ).firstMatch(line);
        if (noFullMatch != null) {
          final cand =
              noFullMatch.group(1)!.trim().replaceAll(RegExp(r'\s+'), ' ');
          if (RegExp(r'^\d{1,3}$').hasMatch(cand)) {
            final codeInLine =
                RegExp(r'([A-Z0-9]{1,4}-\d{2,5}-\d{2,6})').firstMatch(line);
            if (codeInLine != null) {
              result['orderNumber'] = '$cand ${codeInLine.group(1)!}';
            } else {
              result['orderNumber'] = cand;
            }
          } else {
            result['orderNumber'] = cand;
          }
          break;
        }
      }
      final carNoMatch = RegExp(
        r'운\s*반\s*차\s*번\s*호[^0-9]*(\d{2,4}\s*\(\s*\d{4}\s*\)|\d{2,4}[가-힣]\s*\d{4})',
      ).firstMatch(fullText);
      if (carNoMatch != null) {
        final carNo = carNoMatch.group(1)!.replaceAll(RegExp(r'\s+'), '');
        final curOrd = (result['orderNumber'] ?? '').trim();
        if (curOrd.isEmpty) {
          result['orderNumber'] = carNo;
        } else if (RegExp(r'^\d{1,3}$').hasMatch(curOrd)) {
          result['orderNumber'] = 'No.$curOrd (차량 $carNo)';
        }
      }
    }

    if (fullText.toUpperCase().contains('HYUNDAI STEEL') ||
        fullText.contains('현대제철')) {
      result['supplierName'] = '현대제철';
    } else {
      final supplierMatch = RegExp(
        r'((?:\(주\)|주식회사|㈜)\s*[가-힣A-Za-z0-9]{2,12}|[가-힣A-Za-z0-9]{2,12}(?:제철|철강|자재|산업|건업|물산|상사|테크|금속|시멘트|레미콘|피씨|PC|콘크리트|기업|개발|이엔지|ENG)\s*(?:\(주\)|주식회사|㈜)?)',
      ).firstMatch(fullText);
      if (supplierMatch != null) {
        result['supplierName'] =
            supplierMatch.group(1)!.replaceAll(RegExp(r'\s+'), '');
      }
    }

    final bool isRemiconDoc = fullText.contains('레미콘') ||
        RegExp(r'호\s*칭\s*강\s*도|슬\s*럼프|시\s*방\s*배\s*합|납\s*품\s*용\s*적')
            .hasMatch(fullText);

    String detectedProduct = '';
    final pcMatch = RegExp(
      r'(PC\s*(?:기둥|보|슬래브|거더|벽체|패널|계단|암거|부재)|피씨\s*(?:기둥|보|슬래브|부재))',
      caseSensitive: false,
    ).firstMatch(fullText);

    if (isRemiconDoc) {
      detectedProduct = '레미콘';
    } else if (pcMatch != null) {
      detectedProduct = pcMatch
          .group(1)!
          .replaceAll(RegExp(r'\s+'), '')
          .toUpperCase()
          .replaceFirst('피씨', 'PC');
    } else if (RegExp(r'고\s*장\s*력\s*철\s*근').hasMatch(fullText) ||
        fullText.toUpperCase().contains('HYUNDAI STEEL') ||
        RegExp(r'\bD\d{2}\s*MM\b', caseSensitive: false).hasMatch(fullText) ||
        RegExp(r'\b(?:SD\s*[3456]00|SHD|UHD)\b', caseSensitive: false)
            .hasMatch(fullText)) {
      detectedProduct = '고장력철근';
    } else if (fullText.contains('철근') || fullText.contains('이형봉강')) {
      detectedProduct = '고장력철근';
    } else if (RegExp(r'매\s*수').hasMatch(fullText) &&
        RegExp(r'가\s*로').hasMatch(fullText) &&
        RegExp(r'세\s*로').hasMatch(fullText)) {
      detectedProduct = 'PC기둥';
    } else {
      for (final line in lines) {
        if (RegExp(r'착지|운송|주소|Page|공장|주문번호|청구번호|규격명').hasMatch(line)) {
          continue;
        }
        final prodMatch = RegExp(
                r'([가-힣A-Za-z0-9]+(?:기둥|시멘트|레미콘|몰탈|파이프|강관|합판|목재|벽돌|타일|석고보드|단열재|철근|형강))')
            .firstMatch(line);
        if (prodMatch != null) {
          detectedProduct = prodMatch.group(1)!;
          break;
        }
      }
    }
    if (detectedProduct.isEmpty) detectedProduct = '고장력철근';
    result['productName'] = detectedProduct;

    final bool isRebar = detectedProduct.contains('철근');

    if (isRemiconDoc) {
      String remiconSpec = '';
      final specTripleMatch = RegExp(
        r'\b(13|19|20|25|40)\s*(?:mm)?[^0-9\n]{1,20}(18|21|24|27|30|35|40|45|50)\s*(?:MPa)?[^0-9\n]{1,20}(80|100|120|150|180|210|500|550|600)\b',
        caseSensitive: false,
      ).firstMatch(fullText);
      if (specTripleMatch != null) {
        remiconSpec =
            '${specTripleMatch.group(1)}-${specTripleMatch.group(2)}-${specTripleMatch.group(3)}';
      } else {
        final hyochingMatch =
            RegExp(r'\b(20|25)\s*[-*]\s*(\d{2})\s*[-*]\s*(\d{2,3})\b')
                .firstMatch(fullText);
        if (hyochingMatch != null) {
          remiconSpec =
              '${hyochingMatch.group(1)}-${hyochingMatch.group(2)}-${hyochingMatch.group(3)}';
        }
      }

      String remiconQty = '6';
      final volMatch = RegExp(
        r'납\s*품\s*용\s*적[^0-9]*(\d{1,2}(?:\.\d{1,2})?)',
      ).firstMatch(fullText);
      if (volMatch != null) {
        final qNum = double.tryParse(volMatch.group(1)!) ?? 6.0;
        remiconQty = (qNum == qNum.roundToDouble())
            ? qNum.round().toString()
            : qNum.toString();
      }

      final remRows = [
        {
          'productName': '레미콘',
          'specName': remiconSpec,
          'unit': 'm3',
          'quantity': remiconQty,
        }
      ];
      result['itemsJson'] = jsonEncode(remRows);
      result['specName'] = remiconSpec;
      result['unit'] = 'm3';
      result['quantity'] = remiconQty;
      return result;
    }

    final bool isPcOrDimensionTable = !isRebar &&
        (detectedProduct.toUpperCase().contains('PC') ||
            detectedProduct.contains('기둥') ||
            (RegExp(r'가\s*로').hasMatch(fullText) &&
                RegExp(r'세\s*로').hasMatch(fullText)));

    if (isPcOrDimensionTable) {
      final List<Map<String, String>> pcRows = [];
      for (final line in lines) {
        if (RegExp(r'제\s*품\s*번\s*호|출\s*하\s*일\s*자|하\s*차\s*시\s*간|합\s*계')
            .hasMatch(line)) {
          continue;
        }
        final rowMatch = RegExp(
          r'(?:\b(\d{2,3}-\d{2,4}-\d{3,5})\b\s+)?(\d{1,3})\s+\d{1,3}[.,]\d{3}\s+(\d{2,4})\s+(\d{2,4})\s+(\d{1,2},?\d{3}|\d{3,5})',
        ).firstMatch(line);
        if (rowMatch != null) {
          final prodCode = (rowMatch.group(1) ?? '').trim();
          if (prodCode.isNotEmpty && (result['orderNumber'] ?? '').isEmpty) {
            result['orderNumber'] = prodCode;
          }
          final qtyStr = rowMatch.group(2)!.trim();
          final w = rowMatch.group(3)!.replaceAll(',', '').trim();
          final d = rowMatch.group(4)!.replaceAll(',', '').trim();
          final len = rowMatch.group(5)!.replaceAll(',', '').trim();
          pcRows.add({
            'productName': detectedProduct,
            'specName': '$w×$d×$len',
            'unit': '매',
            'quantity': qtyStr,
          });
        }
      }

      if (pcRows.isEmpty) {
        final fullRowMatch = RegExp(
          r'(\d{1,3})\s+\d{1,3}[.,]\d{3}\s+(\d{2,4})\s+(\d{2,4})\s+(\d{1,2},?\d{3}|\d{3,5})',
        ).firstMatch(fullText);
        if (fullRowMatch != null) {
          final qtyStr = fullRowMatch.group(1)!.trim();
          final w = fullRowMatch.group(2)!.replaceAll(',', '').trim();
          final d = fullRowMatch.group(3)!.replaceAll(',', '').trim();
          final len = fullRowMatch.group(4)!.replaceAll(',', '').trim();
          pcRows.add({
            'productName': detectedProduct,
            'specName': '$w×$d×$len',
            'unit': '매',
            'quantity': qtyStr,
          });
        } else {
          final dimMatch = RegExp(
            r'(\d{2,4})\s*[xX×*]\s*(\d{2,4})\s*[xX×*]\s*(\d{1,2},?\d{3}|\d{3,5})',
          ).firstMatch(fullText);
          final maesuMatch = RegExp(r'(\d{1,3})\s*매').firstMatch(fullText);
          if (dimMatch != null) {
            final w = dimMatch.group(1)!.replaceAll(',', '');
            final d = dimMatch.group(2)!.replaceAll(',', '');
            final len = dimMatch.group(3)!.replaceAll(',', '');
            pcRows.add({
              'productName': detectedProduct,
              'specName': '$w×$d×$len',
              'unit': '매',
              'quantity': maesuMatch?.group(1) ?? '1',
            });
          }
        }
      }

      if (pcRows.isNotEmpty) {
        result['itemsJson'] = jsonEncode(pcRows);
        result['specName'] = pcRows.first['specName'] ?? '';
        result['unit'] = pcRows.first['unit'] ?? '매';
        result['quantity'] = pcRows.first['quantity'] ?? '';
        return result;
      }
    }

    final allLinesElements = <TextLine>[];
    for (final b in recognized.blocks) {
      allLinesElements.addAll(b.lines);
    }

    final List<Map<String, dynamic>> specNodes = [];
    final bool hasExplicitMmSpec =
        RegExp(r'\bD\s*\d{2}\s*M\s*M\b', caseSensitive: false)
            .hasMatch(fullText);

    for (final tl in allLinesElements) {
      if (RegExp(r'운송|발행일|출하일|합\s*계').hasMatch(tl.text)) continue;
      final matches = RegExp(
        hasExplicitMmSpec
            ? r'\b(D\s*(?:10|13|16|19|22|25|29|32|35)\s*M\s*M)\b'
            : r'\b((?:U?SHD|HD|D)\s*(?:10|13|16|19|22|25|29|32|35)(?:\s*M\s*M)?)\b',
        caseSensitive: false,
      ).allMatches(tl.text);

      for (final m in matches) {
        String s = m.group(1)!.toUpperCase().replaceAll(RegExp(r'\s+'), '');
        if (RegExp(r'^D\d{2}$').hasMatch(s)) s = '${s}MM';
        if (!specNodes.any((e) => e['spec'] == s)) {
          specNodes.add({
            'spec': s,
            'box': tl.boundingBox,
          });
        }
      }
    }

    final List<Map<String, dynamic>> weightNodes = [];
    for (final tl in allLinesElements) {
      if (RegExp(r'010|202\d[./-]').hasMatch(tl.text)) continue;
      final matches =
          RegExp(r'(?<![0-9.])(\d{1,2})\s*[.,]\s*(\d{3})(?![0-9])')
              .allMatches(tl.text);
      for (final m in matches) {
        final valStr = '${m.group(1)}.${m.group(2)}';
        final valNum = double.tryParse(valStr) ?? 0.0;
        if (valNum > 0.1 && valNum < 100.0) {
          weightNodes.add({
            'valStr': valStr,
            'valNum': valNum,
            'box': tl.boundingBox,
            'lineText': tl.text,
          });
        }
      }
    }

    final List<Map<String, String>> parsedRows = [];
    if (specNodes.isNotEmpty) {
      double dxSpan = 0;
      double dySpan = 0;
      if (specNodes.length >= 2) {
        final firstBox = specNodes.first['box'] as Rect;
        final lastBox = specNodes.last['box'] as Rect;
        dxSpan = (firstBox.center.dx - lastBox.center.dx).abs();
        dySpan = (firstBox.center.dy - lastBox.center.dy).abs();
      }
      final bool isRotated90 = dxSpan > dySpan;
      result['_isRotated90'] = isRotated90 ? 'true' : 'false';

      if (isRotated90) {
        specNodes.sort((a, b) => (b['box'] as Rect)
            .center
            .dx
            .compareTo((a['box'] as Rect).center.dx));
      } else {
        specNodes.sort((a, b) => (a['box'] as Rect)
            .center
            .dy
            .compareTo((b['box'] as Rect).center.dy));
      }

      double? totalWeightVal;
      if (weightNodes.length >= 2) {
        int maxIdx = 0;
        for (int i = 1; i < weightNodes.length; i++) {
          if ((weightNodes[i]['valNum'] as double) >
              (weightNodes[maxIdx]['valNum'] as double)) {
            maxIdx = i;
          }
        }
        final maxNode = weightNodes[maxIdx];
        final maxVal = maxNode['valNum'] as double;
        final maxBox = maxNode['box'] as Rect;
        final lastSpecBox = specNodes.last['box'] as Rect;

        final sumOthers = weightNodes
            .asMap()
            .entries
            .where((e) => e.key != maxIdx)
            .fold(0.0, (acc, e) => acc + (e.value['valNum'] as double));

        double rowGap = 35.0;
        if (specNodes.length >= 2) {
          final b0 = specNodes[0]['box'] as Rect;
          final b1 = specNodes[1]['box'] as Rect;
          rowGap = isRotated90
              ? (b0.center.dx - b1.center.dx).abs()
              : (b1.center.dy - b0.center.dy).abs();
        }

        final bool isBeyondLastSpecRow = isRotated90
            ? (maxBox.center.dx < lastSpecBox.center.dx - rowGap * 0.45)
            : (maxBox.center.dy > lastSpecBox.center.dy + rowGap * 0.45);

        if (weightNodes.length > specNodes.length ||
            (maxVal - sumOthers).abs() < 0.1 ||
            isBeyondLastSpecRow) {
          totalWeightVal = maxVal;
          weightNodes.removeAt(maxIdx);
        }
      }

      double rowTolerance = 45.0;
      if (specNodes.length >= 2) {
        final b0 = specNodes[0]['box'] as Rect;
        final b1 = specNodes[1]['box'] as Rect;
        final gap = isRotated90
            ? (b0.center.dx - b1.center.dx).abs()
            : (b1.center.dy - b0.center.dy).abs();
        if (gap > 10) rowTolerance = gap * 0.65;
      }

      final List<Map<String, dynamic>?> matchedWeights =
          List<Map<String, dynamic>?>.filled(specNodes.length, null);

      for (int wi = 0; wi < weightNodes.length; wi++) {
        final wBox = weightNodes[wi]['box'] as Rect;
        int bestSpecIdx = -1;
        double bestDiff = double.infinity;
        for (int si = 0; si < specNodes.length; si++) {
          final sBox = specNodes[si]['box'] as Rect;
          final diff = isRotated90
              ? (sBox.center.dx - wBox.center.dx).abs()
              : (sBox.center.dy - wBox.center.dy).abs();
          if (diff < bestDiff) {
            bestDiff = diff;
            bestSpecIdx = si;
          }
        }
        if (bestSpecIdx != -1 &&
            matchedWeights[bestSpecIdx] == null &&
            (bestDiff <= rowTolerance ||
                weightNodes.length == specNodes.length)) {
          matchedWeights[bestSpecIdx] = weightNodes[wi];
        }
      }

      final missingSpecIndices = <int>[];
      double knownSum = 0.0;
      for (int si = 0; si < specNodes.length; si++) {
        if (matchedWeights[si] == null) {
          missingSpecIndices.add(si);
        } else {
          knownSum += (matchedWeights[si]!['valNum'] as double);
        }
      }

      if (missingSpecIndices.length == 1 && totalWeightVal != null) {
        final double recoveredVal = totalWeightVal - knownSum;
        if (recoveredVal > 0.05) {
          final String recoveredStr = recoveredVal
              .toStringAsFixed(3)
              .replaceAll(RegExp(r'0+$'), '')
              .replaceAll(RegExp(r'\.$'), '');
          matchedWeights[missingSpecIndices.first] = {
            'valStr': recoveredStr,
            'valNum': recoveredVal,
          };
        }
      }

      for (int si = 0; si < specNodes.length; si++) {
        final mw = matchedWeights[si];
        parsedRows.add({
          'productName': detectedProduct,
          'specName': specNodes[si]['spec'] as String,
          'unit': isRebar ? 'ton' : 'EA',
          'quantity': mw != null ? (mw['valStr'] as String) : '',
        });
      }
    }

    if (parsedRows.isNotEmpty) {
      result['itemsJson'] = jsonEncode(parsedRows);
      result['specName'] = parsedRows.first['specName'] ?? '';
      result['unit'] = parsedRows.first['unit'] ?? (isRebar ? 'ton' : 'EA');
      result['quantity'] = parsedRows.first['quantity'] ?? '';
    } else {
      result['unit'] = isRebar ? 'ton' : 'EA';
      if (weightNodes.isNotEmpty) {
        result['quantity'] = weightNodes.first['valStr'] as String;
      }
    }

    return result;
  }

  Map<String, String> _parseMedicalReceiptText(
    String fullText,
    List<String> lines,
    RecognizedText recognized,
  ) {
    final result = <String, String>{};

    final bizMatch = RegExp(r'\b(\d{3})\s*-\s*(\d{2})\s*-\s*(\d{5})\b')
        .firstMatch(fullText);
    if (bizMatch != null) {
      result['bizRegNumber'] =
          '${bizMatch.group(1)}-${bizMatch.group(2)}-${bizMatch.group(3)}';
    }

    final dateLabelMatch = RegExp(
      r'(?:발\s*행\s*일|조\s*제\s*일\s*자|진\s*료\s*일\s*자)[^\d]*(\d{4})\s*[-./년]\s*(\d{1,2})\s*[-./월]\s*(\d{1,2})',
    ).firstMatch(fullText);
    if (dateLabelMatch != null) {
      final y = dateLabelMatch.group(1)!;
      final m = dateLabelMatch.group(2)!.padLeft(2, '0');
      final d = dateLabelMatch.group(3)!.padLeft(2, '0');
      result['issueDate'] = '$y.$m.$d';
    } else {
      final anyDate = RegExp(r'(\d{4})\s*[-./]\s*(\d{2})\s*[-./]\s*(\d{2})')
          .firstMatch(fullText);
      if (anyDate != null) {
        result['issueDate'] =
            '${anyDate.group(1)}.${anyDate.group(2)}.${anyDate.group(3)}';
      }
    }

    final nameMatch = RegExp(
      r'([가-힣0-9]{2,15}(?:약국|병원|의원|치과|한의원|클리닉|메디컬|센터))',
    ).firstMatch(fullText);
    if (nameMatch != null) {
      result['clinicName'] = nameMatch.group(1)!;
    }

    const Set<String> patientStopWords = {
      '조제일자', '투약일수', '영수증번호', '진료일자', '발행일', '납부자', '약제비총액',
      '본인부담금', '보험자부담금', '사업자등록번호', '상호', '성명', '야간', '공휴',
      '외래', '입원', '합계', '진료과', '병실', '주민등록번호', '환자구분', '급여', '비급여'
    };

    String? extractedPatient;
    for (final line in lines) {
      final pm = RegExp(
        r'(?:환\s*자\s*성\s*명|환\s*자\s*명|수\s*진\s*자\s*성?\s*명|진\s*료\s*환\s*자)\s*[:：|]?\s*([가-힣]{2,5})',
      ).firstMatch(line);
      if (pm != null) {
        final cand = pm.group(1)!.trim();
        if (!patientStopWords.contains(cand)) {
          extractedPatient = cand;
          break;
        }
      }
    }
    if (extractedPatient != null && extractedPatient.isNotEmpty) {
      result['patientName'] = extractedPatient;
    }

    final allLines = <TextLine>[];
    for (final b in recognized.blocks) {
      allLines.addAll(b.lines);
    }

    final List<Map<String, dynamic>> amountNodes = [];
    for (final tl in allLines) {
      if (RegExp(r'\d{3}-\d{2}-\d{5}|202\d[-./]|02-|031-').hasMatch(tl.text)) {
        continue;
      }
      final matches =
          RegExp(r'(?<![0-9,])([1-9]\d{0,2}(?:,\d{3})+)(?![0-9])')
              .allMatches(tl.text);
      for (final m in matches) {
        final v = int.tryParse(m.group(1)!.replaceAll(',', '')) ?? 0;
        if (v >= 100 && v < 100000000) {
          amountNodes.add({
            'val': v,
            'y': tl.boundingBox.center.dy,
          });
        }
      }
    }
    amountNodes.sort((a, b) => (a['y'] as double).compareTo(b['y'] as double));
    if (amountNodes.isNotEmpty) {
      result['totalPaid'] = (amountNodes.last['val'] as int).toString();
    }

    return result;
  }

  Map<String, String> _parseBusinessCardText(
    String fullText,
    List<String> rows,
    RecognizedText recognized,
  ) {
    final result = <String, String>{};
    final lines =
        rows.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

    final emailMatch = RegExp(
      r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
    ).firstMatch(fullText.replaceAll(' ', ''));
    if (emailMatch != null) {
      result['email'] = emailMatch.group(0)!;
    }

    final mobileMatch = RegExp(
      r'(?:(?:\+?82[\s.-]*)?0?1[016789])[\s.-]*(\d{3,4})[\s.-]*(\d{4})',
    ).firstMatch(fullText);
    if (mobileMatch != null) {
      result['mobilePhone'] =
          '010-${mobileMatch.group(1)}-${mobileMatch.group(2)}';
    } else {
      final telMatch =
          RegExp(r'(0\d{1,2})[\s.-]*(\d{3,4})[\s.-]*(\d{4})')
              .firstMatch(fullText);
      if (telMatch != null) {
        result['mobilePhone'] =
            '${telMatch.group(1)}-${telMatch.group(2)}-${telMatch.group(3)}';
      }
    }

    final companySuffixRegex = RegExp(
      r'(?:주식회사|\(주\)|㈜|\(유\)|유한회사|건설|엔지니어링|산업|개발|건축|종합건설|토건|전기|통신|설비|소방|기계|테크|코퍼레이션|그룹|파트너스|공사|공단|시청|구청|군청)',
      caseSensitive: false,
    );
    for (final line in lines) {
      if (line.contains('@') || RegExp(r'\d{3,4}[-\s.]\d{4}').hasMatch(line)) {
        continue;
      }
      if (companySuffixRegex.hasMatch(line)) {
        String comp = line.replaceAll(RegExp(r'\s{2,}.*$'), '').trim();
        if (comp.length >= 2 && comp.length <= 28) {
          result['companyName'] = comp;
          break;
        }
      }
    }

    for (final line in lines) {
      if (line == result['companyName']) continue;
      if (line.contains('@') || RegExp(r'\d{3,4}[-\s.]\d{4}').hasMatch(line)) {
        continue;
      }
      if (RegExp(
              r'(?:현장|사업소|신축|증축|재개발|재건축|아파트|공동주택|공사|공구|사업단|지사|본부|부|팀|과|실|소)')
          .hasMatch(line)) {
        result['siteName'] = line.trim();
        break;
      }
    }

    for (final line in lines) {
      if (line.contains('@') || RegExp(r'\d{3}').hasMatch(line)) continue;
      final nameMatches =
          RegExp(r'(?<![가-힣])[가-힣]{2,4}(?![가-힣])').allMatches(line);
      for (final m in nameMatches) {
        final cand = m.group(0)!;
        if (!companySuffixRegex.hasMatch(cand) &&
            !cand.endsWith('현장') &&
            !cand.endsWith('팀') &&
            !cand.endsWith('부') &&
            !cand.endsWith('과')) {
          result['personName'] = cand;
          break;
        }
      }
      if ((result['personName'] ?? '').isNotEmpty) break;
    }

    return result;
  }

  static Uint8List _compressForAiPayloadIsolate(Uint8List srcBytes) {
    if (srcBytes.lengthInBytes <= 600 * 1024) return srcBytes;
    final decoded = img.decodeImage(srcBytes);
    if (decoded == null) return srcBytes;
    img.Image resized = decoded;
    if (math.max(decoded.width, decoded.height) > 1600) {
      resized = decoded.width >= decoded.height
          ? img.copyResize(decoded, width: 1600)
          : img.copyResize(decoded, height: 1600);
    }
    return Uint8List.fromList(img.encodeJpg(resized, quality: 88));
  }

  Future<List<String>> _resolveCandidateGeminiModels(String key) async {
    final List<String> candidates = [
      'gemini-3.0-flash',
      'gemini-3.1-pro-preview',
      'gemini-3.5-flash-lite',
      'gemini-2.5-pro',
      'gemini-2.5-flash',
      'gemini-2.0-flash',
    ];
    try {
      final listUri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models',
      );
      final resp = await http
          .get(
            listUri,
            headers: {'x-goog-api-key': key},
          )
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final decoded =
            jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
        final modelsList = decoded['models'] as List<dynamic>? ?? [];
        final List<String> discovered = [];
        for (final item in modelsList) {
          if (item is Map) {
            final rawName = item['name']?.toString() ?? '';
            final methods =
                (item['supportedGenerationMethods'] as List<dynamic>? ?? [])
                    .map((e) => e.toString())
                    .toList();
            if (!methods.contains('generateContent')) continue;
            final shortName = rawName.replaceFirst('models/', '');
            if (!shortName.startsWith('gemini-')) continue;
            if (shortName.contains('embedding') ||
                shortName.contains('imagen') ||
                shortName.contains('veo') ||
                shortName.contains('tts') ||
                shortName.contains('audio')) {
              continue;
            }
            discovered.add(shortName);
          }
        }
        final all = <String>[...discovered, ...candidates];
        final seen = <String>{};
        return all.where((m) => seen.add(m)).toList();
      }
    } catch (_) {}
    return candidates;
  }

  String? _extractSuggestedModelFromError(String errorMsg) {
    final m = RegExp(r'models/(gemini-[a-zA-Z0-9._-]+)').firstMatch(errorMsg);
    return m?.group(1);
  }

  Future<Map<String, dynamic>> _verifyGeminiApiKey(String rawKey) async {
    final key = rawKey.trim();
    if (key.isEmpty) {
      return {
        'ok': false,
        'msg': 'API 키가 비어 있습니다. (비워두시면 내장 오프라인 한국어 OCR로 작동합니다)',
      };
    }
    if (key.length < 16 || RegExp(r'[가-힣\s]').hasMatch(key)) {
      return {
        'ok': false,
        'msg':
            '❌ 올바른 Gemini API 키 형식이 아닙니다. (Google AI Studio에서 발급받은 AQ... 또는 AIza... 키 전체를 복사해 넣어주세요)',
      };
    }

    final models = await _resolveCandidateGeminiModels(key);
    final tried = <String>{};
    String lastErr = '연결 실패';

    for (int i = 0; i < models.length; i++) {
      final modelName = models[i];
      if (!tried.add(modelName)) continue;
      try {
        final uri = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$modelName:generateContent',
        );
        final resp = await http
            .post(
              uri,
              headers: {
                'Content-Type': 'application/json',
                'x-goog-api-key': key,
              },
              body: jsonEncode({
                'contents': [
                  {
                    'role': 'user',
                    'parts': [
                      {'text': 'Reply with OK'}
                    ]
                  }
                ],
                'generationConfig': {'maxOutputTokens': 8},
              }),
            )
            .timeout(const Duration(seconds: 8));
        if (resp.statusCode == 200) {
          return {
            'ok': true,
            'model': modelName,
            'msg': '✅ Gemini API 정밀 연동 성공! (작동 모델: $modelName)',
          };
        } else {
          try {
            final errJson =
                jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
            final errMsg = errJson['error']?['message']?.toString() ??
                'HTTP ${resp.statusCode}';
            lastErr = '[$modelName] $errMsg';
            final suggested = _extractSuggestedModelFromError(errMsg);
            if (suggested != null && !tried.contains(suggested)) {
              models.insert(i + 1, suggested);
            }
          } catch (_) {
            lastErr = 'HTTP 오류 코드 ${resp.statusCode}';
          }
        }
      } catch (e) {
        lastErr = '네트워크/시간초과: $e';
      }
    }
    return {
      'ok': false,
      'msg': '❌ Gemini 호출 실패: $lastErr',
    };
  }

  Future<Map<String, String>?> _analyzeDocumentWithAi({
    required String category,
    required Uint8List imageBytes,
  }) async {
    if (category == DocCategory.pdfConvert) return null;
    final key = _geminiApiKey.trim();
    if (key.isEmpty) return null;

    if (key.length < 16 || RegExp(r'[가-힣\s]').hasMatch(key)) {
      _lastGeminiStatusMsg = '❌ 잘못된 API 키 형식 (내장 OCR 결과만 적용됨)';
      if (mounted) setState(() => _geminiKeyVerified = false);
      return null;
    }

    final aiBytes = await compute(_compressForAiPayloadIsolate, imageBytes);
    final base64Image = base64Encode(aiBytes);

    String prompt;
    if (DocCategory.isOfficial(category)) {
      prompt = '''
이 대한민국 공문서 이미지를 분석해서 순수 JSON 객체로 응답해줘:
- title (제목): 앞쪽 [공동주택과-16092] 같은 대괄호는 빼고 순수 제목만
- aiSummary (내용): 공문의 핵심 요지를 한 문장으로 명확히 요약!
- docNumber (공문번호): 띄어쓰기 없이 붙여 쓸 것!
- replyDocNumber (회신번호): 띄어쓰기 없이 붙여 쓸 것!
- sender (보낸사람): 발신명의 (예: "김해시장")
- recipient (받는사람): '수신' 옆에 적힌 받는사람 (예: "김해시장")
- replyDeadline (회신요청일): YYYY.MM.DD
- sentDate (접수일/발신일): 반드시 문서 하단 '시행' 옆 괄호 안에 적힌 실제 공문 발행일(YYYY.MM.DD)을 넣을 것!
''';
    } else if (category == DocCategory.invoice) {
      prompt = '''
이 자재송장/거래명세서/출하전표/레미콘납품서 이미지를 읽고 실제 적힌 값만 순수 JSON으로 정확히 응답해줘.
핵심 규칙 (절대 예시 숫자를 그대로 베끼지 말고 이미지의 실제 값만 추출할 것!):
1) [철근류(고장력철근 등)인 경우]:
   - unit(단위)은 반드시 "ton"으로 하고, quantity(수량)에는 각 규격(예: D16MM, D32MM)별 중량(톤)을 넣을 것 (하단 합계 중량은 제외).
2) [PC기둥, PC보, PC슬래브 등 PC부재인 경우]:
   - productName: 문서 상단 현장명 옆이나 품목란에 적힌 실제 품목명 (예: "PC기둥")
   - specName(규격명): 절대 제품번호(예: 13-211-0100)를 규격에 넣지 말고, 부재의 실제 치수/사이즈인 가로×세로×길이(쉼표 제거, 예: 가로 800, 세로 300, 길이 6,750이면 "800×300×6750")를 넣을 것! (제품번호 13-211-0100 등은 orderNumber에 넣을 것)
   - unit(단위): "매"
   - quantity(수량): 중량(24.000)이 아니라 실제 매수(예: "5")를 넣을 것!
3) [레미콘 납품서인 경우]:
   - productName: "레미콘"
   - specName(규격명): 호칭방법의 [굵은골재 최대치수]-[호칭강도]-[슬럼프/슬럼프플로] 조합 (예: "25-24-500")
   - unit(단위): "m3"
   - quantity(수량): '납품용적' 칸의 1회 납품량만 소수점 뒷자리 .00을 빼고 깔끔하게 넣을 것(예: "6")
   - orderNumber(주문송장번호): 상단 'No.' 옆에 적힌 번호를 읽을 때 앞의 짧은 숫자(예: "82")만 잘라서 읽지 말고, 그 옆에 이어진 하이픈 전표번호(예: "B-028-0202" 또는 "82 B-028-0202")나 '운반차번호'(예: "206(9976)")까지 빠짐없이 읽어서 넣을 것!
{
  "arrivalDate": "YYYY.MM.DD",
  "supplierName": "공급자 상호명",
  "orderNumber": "전체 송장번호/전표번호 또는 제품번호",
  "items": [
    {"productName": "실제품목명", "specName": "실제규격", "unit": "매 또는 m3 또는 ton", "quantity": "실제수량"}
  ]
}''';
    } else if (category == DocCategory.travel) {
      prompt = '''
이 출장비 증빙 이미지를 보고 5가지 구분('자차', '택시', '기차', '식대', '통행료') 중 하나로 분류해 순수 JSON으로 응답해줘:
{
  "travelDivision": "자차 또는 택시 또는 기차 또는 식대 또는 통행료",
  "distanceKm": "자차일 때 실시간 추천 km 숫자만",
  "totalAmount": "결제금액 숫자만 (영수증이 여러 장이면 합산한 금액)",
  "merchantName": "실제 상호명/지점명",
  "date": "YYYY.MM.DD"
}''';
    } else if (category == DocCategory.businessCard) {
      prompt = '''
이 명함(Business Card) 이미지를 읽고 다음 5가지 항목을 순수 JSON 객체로 정확히 추출해줘:
{
  "companyName": "회사명",
  "siteName": "현장명 또는 부서명",
  "personName": "이름",
  "mobilePhone": "010-0000-0000",
  "email": "example@company.com"
}''';
    } else {
      prompt = '''
이 병원비/약국 영수증 이미지를 읽고 순수 JSON 객체로 응답해줘:
{
  "patientName": "환자성명",
  "clinicName": "상호명",
  "bizRegNumber": "사업자등록번호",
  "issueDate": "YYYY.MM.DD",
  "totalPaid": "실제 계산한 합계(본인부담 수납액) 숫자만"
}''';
    }

    final body = jsonEncode({
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': prompt},
            {
              'inline_data': {
                'mime_type': 'image/jpeg',
                'data': base64Image,
              }
            }
          ]
        }
      ],
      'generationConfig': {
        'response_mime_type': 'application/json',
      }
    });

    final models = await _resolveCandidateGeminiModels(key);
    final tried = <String>{};

    for (int i = 0; i < models.length; i++) {
      final modelName = models[i];
      if (!tried.add(modelName)) continue;
      try {
        final uri = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$modelName:generateContent',
        );
        final resp = await http
            .post(
              uri,
              headers: {
                'Content-Type': 'application/json',
                'x-goog-api-key': key,
              },
              body: body,
            )
            .timeout(const Duration(seconds: 14));
        if (resp.statusCode == 200) {
          final decoded =
              jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
          final parts =
              decoded['candidates']?[0]?['content']?['parts'] as List<dynamic>?;
          String text = '{}';
          if (parts != null) {
            for (final p in parts) {
              if (p is Map && p['text'] != null && p['thought'] != true) {
                text = p['text'].toString();
              }
            }
          }
          final cleanJson =
              text.replaceAll('```json', '').replaceAll('```', '').trim();
          final Map<String, dynamic> parsed =
              jsonDecode(cleanJson) as Map<String, dynamic>;
          final result = <String, String>{};
          parsed.forEach((k, v) {
            if (k == 'items' && v is List) {
              result['itemsJson'] = jsonEncode(v);
            } else if (v != null && v.toString().trim().isNotEmpty) {
              result[k] = v.toString().trim();
            }
          });
          if (result.isNotEmpty) {
            _lastGeminiStatusMsg = '✅ Gemini AI($modelName) 정밀 교정 완료!';
            if (mounted && !_geminiKeyVerified) {
              setState(() => _geminiKeyVerified = true);
            }
            return result;
          }
        }
      } catch (_) {}
    }
    return null;
  }

  // ===========================================================================
  // 3단계: 촬영 날짜(EXIF) 추출 및 신규 등록 / 수정 / 다중 페이지(증빙/PDF변환) 관리
  // ===========================================================================
  Future<String> _extractPhotoTakenDateOrToday(
    Uint8List rawBytes,
    XFile picked,
  ) async {
    final todayDot = DateFormat('yyyy.MM.dd').format(DateTime.now());
    try {
      final decoded = img.decodeImage(rawBytes);
      if (decoded != null && !decoded.exif.isEmpty) {
        final exifStr = decoded.exif.toString();
        final m = RegExp(r'(\d{4})[:\-/](\d{2})[:\-/](\d{2})')
            .firstMatch(exifStr);
        if (m != null) {
          final y = int.tryParse(m.group(1)!) ?? 0;
          if (y >= 2000 && y <= 2100) {
            return '${m.group(1)}.${m.group(2)}.${m.group(3)}';
          }
        }
      }
    } catch (_) {}

    try {
      final nameMatch = RegExp(r'(20\d{2})[-_.]?(0[1-9]|1[0-2])[-_.]?(0[1-9]|[12]\d|3[01])')
          .firstMatch(picked.name);
      if (nameMatch != null) {
        return '${nameMatch.group(1)}.${nameMatch.group(2)}.${nameMatch.group(3)}';
      }
    } catch (_) {}

    try {
      final lm = await picked.lastModified();
      return DateFormat('yyyy.MM.dd').format(lm);
    } catch (_) {}

    return todayDot;
  }

  Widget _buildField(
    TextEditingController ctrl,
    String label,
    String hint, {
    int maxLines = 1,
    TextInputType keyboardType = TextInputType.text,
    ValueChanged<String>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: TextField(
        controller: ctrl,
        maxLines: maxLines,
        keyboardType: keyboardType,
        onChanged: onChanged,
        style: const TextStyle(fontSize: 13.5),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          filled: true,
          fillColor: Colors.grey.shade50,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
        ),
      ),
    );
  }

  /// 다중 페이지/증빙첨부(병원비 & PDF변환 공통) 사진 추가 촬영/갤러리 선택
  Future<void> _pickAndAppendExtraPage({
    required ImageSource source,
    required List<String> pathList,
    required List<String> base64List,
    required VoidCallback onUpdated,
    String dialogTitle = '추가 페이지 모서리 스캔',
  }) async {
    try {
      if (source == ImageSource.gallery) {
        final List<XFile> pickedFiles = await _picker.pickMultiImage(
          maxWidth: 2600,
          maxHeight: 2600,
          imageQuality: 95,
        );
        if (pickedFiles.isEmpty) return;
        final appDir = await getApplicationDocumentsDirectory();
        for (final xf in pickedFiles) {
          final rawBytes = await xf.readAsBytes();
          if (!mounted) return;
          final cropRes = await showDialog<PerspectiveCropResult>(
            context: context,
            barrierDismissible: false,
            builder: (_) => PerspectiveCropDialog(
              originalBytes: rawBytes,
              titleText: dialogTitle,
            ),
          );
          if (cropRes == null) continue;
          final fileName =
              'extra_${DateTime.now().microsecondsSinceEpoch}.jpg';
          final saved = File(p.join(appDir.path, fileName));
          await saved.writeAsBytes(cropRes.bytes, flush: true);
          pathList.add(saved.path);
          base64List.add(base64Encode(cropRes.bytes));
          onUpdated();
        }
      } else {
        final XFile? picked = await _picker.pickImage(
          source: ImageSource.camera,
          maxWidth: 2600,
          maxHeight: 2600,
          imageQuality: 95,
        );
        if (picked == null) return;
        final rawBytes = await picked.readAsBytes();
        if (!mounted) return;
        final cropRes = await showDialog<PerspectiveCropResult>(
          context: context,
          barrierDismissible: false,
          builder: (_) => PerspectiveCropDialog(
            originalBytes: rawBytes,
            titleText: dialogTitle,
          ),
        );
        if (cropRes == null) return;
        final appDir = await getApplicationDocumentsDirectory();
        final fileName =
            'extra_${DateTime.now().microsecondsSinceEpoch}.jpg';
        final saved = File(p.join(appDir.path, fileName));
        await saved.writeAsBytes(cropRes.bytes, flush: true);
        pathList.add(saved.path);
        base64List.add(base64Encode(cropRes.bytes));
        onUpdated();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('사진 추가 중 오류: $e')),
        );
      }
    }
  }

  /// 병원비 및 PDF변환 탭에서 기존 항목의 추가 페이지(증빙첨부/PDF페이지)를 관리하는 팝업
  Future<void> _manageRecordExtraPagesDialog(DocRecord rec) async {
    final bool isPdfTab = rec.category == DocCategory.pdfConvert;
    final List<String> paths = List<String>.from(rec.extraProofImagePaths);
    final List<Uint8List> previewBytesList = rec.resolveAllProofImageBytes();
    final List<String> b64List = previewBytesList
        .map((b) => base64Encode(b))
        .toList();
    while (paths.length < b64List.length) {
      paths.add('');
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final int totalPages = 1 + math.max(paths.length, b64List.length);
          return AlertDialog(
            title: Text(
              isPdfTab
                  ? '📄 PDF 페이지 추가·관리 (총 ${totalPages}장)'
                  : '📎 병원비 추가 증빙첨부 관리 (${math.max(paths.length, b64List.length)}장)',
              style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.bold),
            ),
            content: SizedBox(
              width: 380,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      isPdfTab
                          ? '1페이지(대표 사진) 외에 같은 PDF로 묶을 추가 페이지들을 카메라로 찍거나 갤러리에서 여러 장 추가하세요.'
                          : '기본 영수증 외에 진료비 세부내역서·처방전 등을 여러 장 추가하면 PDF 내보내기 시 한 묶음으로 함께 출력됩니다.',
                      style: const TextStyle(fontSize: 12, color: Colors.black87),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF1E3A8A),
                            ),
                            onPressed: () async {
                              await _pickAndAppendExtraPage(
                                source: ImageSource.camera,
                                pathList: paths,
                                base64List: b64List,
                                dialogTitle: isPdfTab
                                    ? '추가 PDF 페이지 스캔'
                                    : '추가 증빙서류 스캔',
                                onUpdated: () => setModalState(() {}),
                              );
                            },
                            icon: const Icon(Icons.camera_alt, size: 16),
                            label: Text(
                              isPdfTab ? '+ 페이지 촬영' : '+ 카메라 촬영',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              await _pickAndAppendExtraPage(
                                source: ImageSource.gallery,
                                pathList: paths,
                                base64List: b64List,
                                dialogTitle: isPdfTab
                                    ? '추가 PDF 페이지 스캔'
                                    : '추가 증빙서류 스캔',
                                onUpdated: () => setModalState(() {}),
                              );
                            },
                            icon: const Icon(Icons.photo_library, size: 16),
                            label: Text(
                              isPdfTab ? '+ 갤러리 다중추가' : '+ 갤러리 추가',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (b64List.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          isPdfTab
                              ? '현재 1장짜리 PDF입니다. 위 버튼으로 2페이지, 3페이지... 사진을 계속 추가할 수 있습니다.'
                              : '추가된 증빙첨부 사진이 없습니다.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: List.generate(b64List.length, (idx) {
                          Uint8List? thumb;
                          try {
                            thumb = base64Decode(b64List[idx]);
                          } catch (_) {}
                          return Stack(
                            children: [
                              Container(
                                width: 88,
                                height: 112,
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.indigo.shade200),
                                  borderRadius: BorderRadius.circular(8),
                                  color: Colors.black12,
                                ),
                                child: Column(
                                  children: [
                                    Expanded(
                                      child: thumb != null
                                          ? ClipRRect(
                                              borderRadius:
                                                  const BorderRadius.vertical(
                                                      top: Radius.circular(7)),
                                              child: Image.memory(
                                                thumb,
                                                fit: BoxFit.cover,
                                                width: double.infinity,
                                              ),
                                            )
                                          : const Icon(Icons.image),
                                    ),
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(vertical: 2),
                                      color: Colors.indigo.shade900,
                                      child: Text(
                                        isPdfTab
                                            ? '${idx + 2}페이지'
                                            : '증빙 ${idx + 1}',
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Positioned(
                                right: 2,
                                top: 2,
                                child: GestureDetector(
                                  onTap: () {
                                    setModalState(() {
                                      if (idx < paths.length) paths.removeAt(idx);
                                      if (idx < b64List.length) b64List.removeAt(idx);
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(2),
                                    decoration: const BoxDecoration(
                                      color: Colors.red,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.close,
                                      size: 14,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        }),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () async {
                  final updatedFields = Map<String, String>.from(rec.fields);
                  final cleanPaths =
                      paths.where((s) => s.trim().isNotEmpty).toList();
                  if (cleanPaths.isNotEmpty) {
                    updatedFields['proofPathsJson'] = jsonEncode(cleanPaths);
                    updatedFields['proofStatus'] =
                        '첨부(${cleanPaths.length}장)';
                  } else {
                    updatedFields.remove('proofPathsJson');
                    updatedFields.remove('proofImagesJson');
                    updatedFields.remove('proofStatus');
                  }
                  if (isPdfTab) {
                    updatedFields['pageCount'] =
                        (1 + cleanPaths.length).toString();
                  }
                  final newRec = DocRecord(
                    id: rec.id,
                    category: rec.category,
                    createdAt: rec.createdAt,
                    imagePath: rec.imagePath,
                    base64Image: rec.base64Image,
                    fields: updatedFields,
                  );
                  setState(() {
                    final rIdx = _records.indexWhere((r) => r.id == rec.id);
                    if (rIdx != -1) _records[rIdx] = newRec;
                    if (_selectedRecord?.id == rec.id) {
                      _selectedRecord = newRec;
                      if (_selectedPhotoIndex >= newRec.totalPdfPageCount) {
                        _selectedPhotoIndex = 0;
                      }
                    }
                  });
                  await _saveLocalRecords();
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('저장'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 단일 PDF변환 항목(또는 선택 항목)을 즉시 파일명.pdf로 생성해 공유/저장
  Future<void> _exportSinglePdfConvertRecord(DocRecord rec) async {
    setState(() => _isBusy = true);
    try {
      final doc = pw.Document();
      final List<Uint8List> allPages = <Uint8List>[];
      final mainBytes = rec.resolveMainImageBytes();
      if (mainBytes != null && mainBytes.isNotEmpty) {
        allPages.add(mainBytes);
      }
      allPages.addAll(rec.resolveAllProofImageBytes());

      if (allPages.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('변환할 사진 이미지를 찾을 수 없습니다.')),
        );
        return;
      }

      for (int i = 0; i < allPages.length; i++) {
        final memImg = pw.MemoryImage(allPages[i]);
        doc.addPage(
          pw.Page(
            pageFormat: PdfPageFormat.a4,
            margin: const pw.EdgeInsets.all(14),
            build: (pw.Context ctx) {
              return pw.Center(
                child: pw.Image(memImg, fit: pw.BoxFit.contain),
              );
            },
          ),
        );
      }

      final pdfBytes = await doc.save();
      final tempDir = await getTemporaryDirectory();
      String rawFileName = (rec.fields['pdfFileName'] ?? '').trim();
      if (rawFileName.isEmpty) {
        rawFileName =
            '문서스캔_${DocRecord.formatDotDate(rec.fields['pdfDate'])}';
      }
      rawFileName = rawFileName
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
          .trim();
      if (!rawFileName.toLowerCase().endsWith('.pdf')) {
        rawFileName = '$rawFileName.pdf';
      }

      final outFile = File(p.join(tempDir.path, rawFileName));
      await outFile.writeAsBytes(pdfBytes, flush: true);

      await Share.shareXFiles([XFile(outFile.path)]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF 생성 오류: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  /// 사진 촬영 또는 갤러리 선택 후 신규 등록 다이얼로그
  /// (★ PDF변환 탭에서 갤러리 선택 시 처음부터 여러 장을 한꺼번에 멀티선택 가능!)
  Future<void> _captureAndAddRecord(ImageSource source) async {
    try {
      final bool isPdfMultiGallery =
          source == ImageSource.gallery &&
          _selectedCategoryFilter == DocCategory.pdfConvert;

      XFile? picked;
      Uint8List? rawBytes;
      Uint8List? flattenedBytes;
      final List<String> initialMultiExtraPaths = <String>[];
      final List<String> initialMultiExtraBase64 = <String>[];

      final appDir = await getApplicationDocumentsDirectory();
      final String newId = DateTime.now().microsecondsSinceEpoch.toString();
      final File savedFile = File(p.join(appDir.path, 'doc_$newId.jpg'));

      if (isPdfMultiGallery) {
        final List<XFile> pickedFiles = await _picker.pickMultiImage(
          maxWidth: 2600,
          maxHeight: 2600,
          imageQuality: 96,
        );
        if (pickedFiles.isEmpty) return;

        for (int i = 0; i < pickedFiles.length; i++) {
          final xf = pickedFiles[i];
          final b = await xf.readAsBytes();
          if (!mounted) return;
          final cropRes = await showDialog<PerspectiveCropResult>(
            context: context,
            barrierDismissible: false,
            builder: (_) => PerspectiveCropDialog(
              originalBytes: b,
              titleText: pickedFiles.length > 1
                  ? 'PDF 스캔 (${i + 1} / ${pickedFiles.length}장)'
                  : '문서 영역 스캔',
            ),
          );
          if (cropRes == null) continue;
          if (picked == null) {
            picked = xf;
            rawBytes = b;
            flattenedBytes = cropRes.bytes;
            await savedFile.writeAsBytes(flattenedBytes, flush: true);
          } else {
            final extraFileName =
                'extra_${DateTime.now().microsecondsSinceEpoch}_$i.jpg';
            final extraSaved = File(p.join(appDir.path, extraFileName));
            await extraSaved.writeAsBytes(cropRes.bytes, flush: true);
            initialMultiExtraPaths.add(extraSaved.path);
            initialMultiExtraBase64.add(base64Encode(cropRes.bytes));
          }
        }
        if (picked == null || rawBytes == null || flattenedBytes == null) {
          return;
        }
      } else {
        picked = await _picker.pickImage(
          source: source,
          maxWidth: 2600,
          maxHeight: 2600,
          imageQuality: 96,
        );
        if (picked == null) return;

        rawBytes = await picked.readAsBytes();
        if (!mounted) return;

        final cropRes = await showDialog<PerspectiveCropResult>(
          context: context,
          barrierDismissible: false,
          builder: (_) => PerspectiveCropDialog(originalBytes: rawBytes!),
        );
        if (cropRes == null) return;

        flattenedBytes = cropRes.bytes;
        await savedFile.writeAsBytes(flattenedBytes, flush: true);
      }

      final XFile validPicked = picked;
      final Uint8List validRawBytes = rawBytes;
      final Uint8List validFlattenedBytes = flattenedBytes;

      String chosenCategory = _selectedCategoryFilter == DocCategory.all
          ? DocCategory.officialIn
          : _selectedCategoryFilter;

      List<String> registeredSubList =
          List<String>.from(_userSubCategoriesMap[chosenCategory] ?? []);
      String initialSubCat = (_selectedSubCategoryFilter != '전체' &&
              _selectedSubCategoryFilter != '미지정' &&
              registeredSubList.contains(_selectedSubCategoryFilter))
          ? _selectedSubCategoryFilter
          : (registeredSubList.isNotEmpty ? registeredSubList.first : '');

      final subCategoryCtrl = TextEditingController(text: initialSubCat);
      final todayDotStr = DateFormat('yyyy.MM.dd').format(DateTime.now());
      final photoTakenDateDot =
          await _extractPhotoTakenDateOrToday(validRawBytes, validPicked);

      // 1. 공문(수신) / 공문(발신) 컨트롤러
      final docTitleCtrl = TextEditingController();
      final aiSummaryCtrl = TextEditingController();
      final docNumberCtrl = TextEditingController();
      final replyDocNumberCtrl = TextEditingController();
      final senderCtrl = TextEditingController();
      final recipientCtrl = TextEditingController();
      final replyDeadlineCtrl = TextEditingController();
      final sentDateCtrl = TextEditingController(text: todayDotStr);

      // 2. 자재송장 컨트롤러
      final arrivalDateCtrl = TextEditingController(text: todayDotStr);
      final orderNumberCtrl = TextEditingController();
      final supplierNameCtrl = TextEditingController();
      List<InvoiceSpecRow> invoiceRows = [
        InvoiceSpecRow(product: '고장력철근', spec: '', unit: 'ton', qty: ''),
      ];

      void enforceRebarRuleOnRows() {
        for (final row in invoiceRows) {
          final pText = row.productCtrl.text.trim();
          if (pText.contains('철근')) {
            row.unitCtrl.text = 'ton';
          } else if (pText.toUpperCase().contains('PC') ||
              pText.contains('기둥') ||
              pText.contains('슬래브') ||
              pText.contains('패널')) {
            if (row.unitCtrl.text.trim().isEmpty ||
                row.unitCtrl.text.trim().toLowerCase() == 'ton') {
              row.unitCtrl.text = '매';
            }
          }
        }
      }

      // 3. 출장비 컨트롤러
      String chosenTravelDivision = _selectedTravelDivisionFilter != '전체'
          ? _selectedTravelDivisionFilter
          : TravelDivision.car;
      final travelDistanceKmCtrl = TextEditingController(text: '0');
      final travelCarMultiplierCtrl = TextEditingController(text: '2');
      final travelCarUnitPriceCtrl = TextEditingController(text: '300');
      final travelAmountCtrl = TextEditingController(text: '0');
      final travelMerchantCtrl = TextEditingController();
      final travelDateCtrl = TextEditingController(text: todayDotStr);

      void recalcCarDistanceCost() {
        if (chosenTravelDivision != TravelDivision.car) return;
        final double km = double.tryParse(
              travelDistanceKmCtrl.text.replaceAll(RegExp(r'[^0-9.]'), ''),
            ) ??
            0;
        final double mult = double.tryParse(
              travelCarMultiplierCtrl.text.replaceAll(RegExp(r'[^0-9.]'), ''),
            ) ??
            2;
        final double unitPrice = double.tryParse(
              travelCarUnitPriceCtrl.text.replaceAll(RegExp(r'[^0-9.]'), ''),
            ) ??
            300;
        final int fare = (km * mult * unitPrice).round();
        travelAmountCtrl.text = fare.toString();
      }

      // 4. 병원비 컨트롤러 & 추가 증빙첨부 리스트
      final patientNameCtrl = TextEditingController();
      final clinicNameCtrl = TextEditingController();
      final bizRegNumberCtrl = TextEditingController();
      final issueDateCtrl = TextEditingController(text: todayDotStr);
      final totalPaidCtrl = TextEditingController();
      final List<String> medicalProofBase64List = <String>[];
      final List<String> medicalProofPathList = <String>[];

      // 5. 명함관리 컨트롤러
      final cardDateCtrl = TextEditingController(text: photoTakenDateDot);
      final companyNameCtrl = TextEditingController();
      final siteNameCtrl = TextEditingController();
      final personNameCtrl = TextEditingController();
      final mobilePhoneCtrl = TextEditingController();
      final emailCtrl = TextEditingController();

      // 6. PDF변환 컨트롤러 (OCR 없음! 찍은날짜 + 파일명 + 다중 페이지 추가)
      final pdfDateCtrl = TextEditingController(text: photoTakenDateDot);
      final pdfFileNameCtrl = TextEditingController();
      final List<String> pdfExtraBase64List =
          List<String>.from(initialMultiExtraBase64);
      final List<String> pdfExtraPathList =
          List<String>.from(initialMultiExtraPaths);

      void applyExtractedMap(Map<String, String> extracted) {
        if (DocCategory.isOfficial(chosenCategory)) {
          if (extracted['title']?.isNotEmpty == true) {
            docTitleCtrl.text = extracted['title']!;
          }
          if (extracted['aiSummary']?.isNotEmpty == true) {
            aiSummaryCtrl.text = extracted['aiSummary']!;
          }
          if (extracted['docNumber']?.isNotEmpty == true) {
            docNumberCtrl.text =
                DocRecord.stripDocNumSpaces(extracted['docNumber']);
          }
          if (extracted['replyDocNumber']?.isNotEmpty == true) {
            replyDocNumberCtrl.text =
                DocRecord.stripDocNumSpaces(extracted['replyDocNumber']);
          }
          if (extracted['sender']?.isNotEmpty == true) {
            senderCtrl.text = extracted['sender']!;
          }
          if (extracted['recipient']?.isNotEmpty == true) {
            recipientCtrl.text = extracted['recipient']!;
          }
          if (extracted['replyDeadline']?.isNotEmpty == true) {
            replyDeadlineCtrl.text =
                DocRecord.formatDotDate(extracted['replyDeadline']);
          }
          if (extracted['sentDate']?.isNotEmpty == true) {
            sentDateCtrl.text = DocRecord.formatDotDate(extracted['sentDate']);
          }
        } else if (chosenCategory == DocCategory.invoice) {
          if (extracted['arrivalDate']?.isNotEmpty == true) {
            arrivalDateCtrl.text =
                DocRecord.formatDotDate(extracted['arrivalDate']);
          }
          if (extracted['orderNumber']?.isNotEmpty == true) {
            orderNumberCtrl.text = extracted['orderNumber']!;
          }
          if (extracted['supplierName']?.isNotEmpty == true) {
            supplierNameCtrl.text = extracted['supplierName']!;
          }
          if (extracted['itemsJson']?.isNotEmpty == true) {
            try {
              final List<dynamic> list =
                  jsonDecode(extracted['itemsJson']!) as List<dynamic>;
              if (list.isNotEmpty) {
                invoiceRows = list.map((item) {
                  final m = item as Map<String, dynamic>;
                  final prod = (m['productName']?.toString() ?? '고장력철근').trim();
                  final isRebar = prod.contains('철근');
                  final isPc = prod.toUpperCase().contains('PC') ||
                      prod.contains('기둥') ||
                      prod.contains('슬래브');
                  final rawUnit = (m['unit']?.toString() ?? '').trim();
                  final resolvedUnit = isRebar
                      ? 'ton'
                      : (isPc &&
                              (rawUnit.isEmpty ||
                                  rawUnit.toLowerCase() == 'ton')
                          ? '매'
                          : (rawUnit.isNotEmpty ? rawUnit : '매'));
                  String rawSpec = (m['specName']?.toString() ?? '').trim();
                  if (!isRebar &&
                      RegExp(r'^\d+\s*[xX×*]\s*\d+').hasMatch(rawSpec)) {
                    rawSpec = rawSpec
                        .replaceAll(',', '')
                        .replaceAll(RegExp(r'\s*[xX×*]\s*'), '×');
                  }
                  String rawQty = (m['quantity']?.toString() ?? '').trim();
                  if (!isRebar) {
                    rawQty = rawQty
                        .replaceAll(
                            RegExp(r'(?:매|EA|개|본)$', caseSensitive: false), '')
                        .trim();
                  }
                  return InvoiceSpecRow(
                    product: prod,
                    spec: rawSpec,
                    unit: resolvedUnit,
                    qty: rawQty,
                  );
                }).toList();
              }
            } catch (_) {}
          } else {
            final prod = extracted['productName'] ?? '고장력철근';
            final isRebar = prod.contains('철근');
            final isPc = prod.toUpperCase().contains('PC') ||
                prod.contains('기둥') ||
                prod.contains('슬래브');
            final rawUnit = (extracted['unit'] ?? '').trim();
            final resolvedUnit = isRebar
                ? 'ton'
                : (isPc && (rawUnit.isEmpty || rawUnit.toLowerCase() == 'ton')
                    ? '매'
                    : (rawUnit.isNotEmpty ? rawUnit : '매'));
            String rawSpec = (extracted['specName'] ?? '').trim();
            if (!isRebar && RegExp(r'^\d+\s*[xX×*]\s*\d+').hasMatch(rawSpec)) {
              rawSpec = rawSpec
                  .replaceAll(',', '')
                  .replaceAll(RegExp(r'\s*[xX×*]\s*'), '×');
            }
            String rawQty =
                (extracted['quantity'] ?? extracted['weight'] ?? '').trim();
            if (!isRebar) {
              rawQty = rawQty
                  .replaceAll(
                      RegExp(r'(?:매|EA|개|본)$', caseSensitive: false), '')
                  .trim();
            }
            invoiceRows = [
              InvoiceSpecRow(
                product: prod,
                spec: rawSpec,
                unit: resolvedUnit,
                qty: rawQty,
              ),
            ];
          }
          enforceRebarRuleOnRows();
        } else if (chosenCategory == DocCategory.travel) {
          final div = extracted['travelDivision']?.trim() ?? '';
          if (TravelDivision.list.contains(div)) {
            chosenTravelDivision = div;
          }
          if (extracted['distanceKm']?.isNotEmpty == true) {
            travelDistanceKmCtrl.text = extracted['distanceKm']!;
          }
          if (chosenTravelDivision == TravelDivision.car) {
            recalcCarDistanceCost();
          } else if (extracted['totalAmount']?.isNotEmpty == true) {
            travelAmountCtrl.text =
                extracted['totalAmount']!.replaceAll(RegExp(r'[^0-9]'), '');
          }
          if (extracted['merchantName']?.isNotEmpty == true) {
            travelMerchantCtrl.text = extracted['merchantName']!;
          }
          if (extracted['date']?.isNotEmpty == true) {
            travelDateCtrl.text = DocRecord.formatDotDate(extracted['date']);
          }
        } else if (chosenCategory == DocCategory.medical) {
          if (extracted['patientName']?.isNotEmpty == true) {
            patientNameCtrl.text = extracted['patientName']!;
          }
          if (extracted['clinicName']?.isNotEmpty == true) {
            clinicNameCtrl.text = extracted['clinicName']!;
          }
          if (extracted['bizRegNumber']?.isNotEmpty == true) {
            bizRegNumberCtrl.text = extracted['bizRegNumber']!;
          }
          if (extracted['issueDate']?.isNotEmpty == true) {
            issueDateCtrl.text =
                DocRecord.formatDotDate(extracted['issueDate']);
          }
          if (extracted['totalPaid']?.isNotEmpty == true) {
            totalPaidCtrl.text = extracted['totalPaid']!;
          }
        } else if (chosenCategory == DocCategory.businessCard) {
          if (extracted['companyName']?.isNotEmpty == true) {
            companyNameCtrl.text = extracted['companyName']!;
          }
          if (extracted['siteName']?.isNotEmpty == true) {
            siteNameCtrl.text = extracted['siteName']!;
          }
          if (extracted['personName']?.isNotEmpty == true) {
            personNameCtrl.text = extracted['personName']!;
          }
          if (extracted['mobilePhone']?.isNotEmpty == true) {
            mobilePhoneCtrl.text = extracted['mobilePhone']!;
          }
          if (extracted['email']?.isNotEmpty == true) {
            emailCtrl.text = extracted['email']!;
          }
        }
      }

      bool isAiAnalyzing = chosenCategory != DocCategory.pdfConvert;
      bool initialAutoRunTriggered = false;

      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, setDialogState) {
              Future<void> triggerOcrAndAiExtract() async {
                if (!ctx.mounted) return;
                if (chosenCategory == DocCategory.pdfConvert) {
                  setDialogState(() {
                    isAiAnalyzing = false;
                    _lastGeminiStatusMsg = '';
                  });
                  return;
                }
                setDialogState(() => isAiAnalyzing = true);
                try {
                  final ocrMap = await _extractFieldsOfflineOcr(
                    imagePath: savedFile.path,
                    imageBytes: validFlattenedBytes,
                    category: chosenCategory,
                  );
                  if (ctx.mounted) {
                    setDialogState(() {
                      applyExtractedMap(ocrMap);
                      isAiAnalyzing = false;
                    });
                  }

                  if (_geminiApiKey.trim().isNotEmpty) {
                    if (ctx.mounted) {
                      setDialogState(() {
                        isAiAnalyzing = true;
                        _lastGeminiStatusMsg = '⏳ Gemini AI 정밀 분석 중...';
                      });
                    }
                    final aiMap = await _analyzeDocumentWithAi(
                      category: chosenCategory,
                      imageBytes: validFlattenedBytes,
                    );
                    if (ctx.mounted) {
                      setDialogState(() {
                        if (aiMap != null) applyExtractedMap(aiMap);
                        isAiAnalyzing = false;
                      });
                    }
                  } else {
                    _lastGeminiStatusMsg = 'ℹ️ 내장 한국어 OCR 분석 완료';
                  }
                } catch (_) {
                  if (ctx.mounted) {
                    setDialogState(() => isAiAnalyzing = false);
                  }
                }
              }

              if (!initialAutoRunTriggered) {
                initialAutoRunTriggered = true;
                Future.microtask(triggerOcrAndAiExtract);
              }

              final mySavedCats =
                  _userSubCategoriesMap[chosenCategory] ?? <String>[];

              return AlertDialog(
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          chosenCategory == DocCategory.pdfConvert
                              ? '📄 PDF변환 파일명 입력 & 페이지 추가'
                              : '증빙서류 입력',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (isAiAnalyzing)
                          const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 13,
                                height: 13,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                              SizedBox(width: 5),
                              Text(
                                '분석 중...',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: Colors.blueAccent,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                    if (_lastGeminiStatusMsg.isNotEmpty &&
                        chosenCategory != DocCategory.pdfConvert) ...[
                      const SizedBox(height: 5),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _lastGeminiStatusMsg.startsWith('✅')
                              ? Colors.green.shade50
                              : Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _lastGeminiStatusMsg,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                content: SizedBox(
                  width: 420,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 대분류 선택 칩
                        Wrap(
                          spacing: 5,
                          runSpacing: 5,
                          children: DocCategory.list.map((cat) {
                            final selected = chosenCategory == cat;
                            return ChoiceChip(
                              visualDensity: VisualDensity.compact,
                              label: Text(
                                cat,
                                style: const TextStyle(fontSize: 11.5),
                              ),
                              selected: selected,
                              onSelected: (_) {
                                setDialogState(() {
                                  chosenCategory = cat;
                                });
                                triggerOcrAndAiExtract();
                              },
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 10),

                        // 출장비/병원비 전용 내 카테고리
                        if (_usesSubCategory(chosenCategory)) ...[
                          _buildField(
                            subCategoryCtrl,
                            '내 카테고리 (직접 입력 또는 아래 칩 선택)',
                            '예: 갑상선, 치과, 현장출장 등',
                          ),
                          if (mySavedCats.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Wrap(
                                spacing: 5,
                                runSpacing: 5,
                                children: mySavedCats.map((sc) {
                                  final isSel =
                                      subCategoryCtrl.text.trim() == sc;
                                  return InputChip(
                                    visualDensity: VisualDensity.compact,
                                    label: Text(sc,
                                        style: const TextStyle(fontSize: 11)),
                                    selected: isSel,
                                    onSelected: (_) => setDialogState(
                                        () => subCategoryCtrl.text = sc),
                                    onDeleted: () async {
                                      await _deleteUserSubCategory(
                                          chosenCategory, sc);
                                      setDialogState(() {});
                                    },
                                  );
                                }).toList(),
                              ),
                            ),
                        ],

                        // 1. 공문 입력 폼
                        if (DocCategory.isOfficial(chosenCategory)) ...[
                          _buildField(docTitleCtrl, '제목', '공문 제목'),
                          _buildField(
                            aiSummaryCtrl,
                            '내용 (한 줄 요약)',
                            '핵심 내용 요약',
                            maxLines: 2,
                          ),
                          _buildField(
                            docNumberCtrl,
                            '공문번호 (띄어쓰기 자동제거)',
                            '예: 공동주택과-16092',
                          ),
                          if (chosenCategory == DocCategory.officialOut)
                            _buildField(
                              replyDocNumberCtrl,
                              '회신번호 (수신공문 번호)',
                              '예: 공동주택과-16092',
                            ),
                          if (chosenCategory == DocCategory.officialIn)
                            _buildField(senderCtrl, '보낸사람', '예: 김해시장')
                          else
                            _buildField(recipientCtrl, '받는사람', '예: 김해시장'),
                          if (chosenCategory == DocCategory.officialIn)
                            _buildField(
                              replyDeadlineCtrl,
                              '회신요청일',
                              '예: 2025.05.21',
                            ),
                          _buildField(
                            sentDateCtrl,
                            chosenCategory == DocCategory.officialIn
                                ? '접수일(시행일)'
                                : '발신일(시행일)',
                            '예: 2025.05.19',
                          ),
                        ],

                        // 2. 자재송장 입력 폼
                        if (chosenCategory == DocCategory.invoice) ...[
                          _buildField(
                              arrivalDateCtrl, '날짜 (도착/발행일)', '예: 2026.06.25'),
                          Container(
                            padding: const EdgeInsets.all(8),
                            margin: const EdgeInsets.only(bottom: 10),
                            decoration: BoxDecoration(
                              color: Colors.indigo.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.indigo.shade200),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Expanded(
                                      child: Text(
                                        '품목/규격별 목록 (철근=ton/중량, PC기둥=매/가로×세로×길이, 레미콘=m3)',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFF1E3A8A),
                                        ),
                                      ),
                                    ),
                                    TextButton.icon(
                                      onPressed: () {
                                        setDialogState(() {
                                          invoiceRows.add(
                                            InvoiceSpecRow(
                                              product: invoiceRows.isNotEmpty
                                                  ? invoiceRows
                                                      .first.productCtrl.text
                                                  : '고장력철근',
                                              spec: '',
                                              unit: 'ton',
                                              qty: '',
                                            ),
                                          );
                                        });
                                      },
                                      icon: const Icon(Icons.add, size: 16),
                                      label: const Text('규격 추가',
                                          style: TextStyle(fontSize: 11.5)),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                for (int idx = 0;
                                    idx < invoiceRows.length;
                                    idx++)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          flex: 3,
                                          child: TextField(
                                            controller:
                                                invoiceRows[idx].productCtrl,
                                            onChanged: (val) {
                                              if (val.contains('철근')) {
                                                setDialogState(() {
                                                  invoiceRows[idx]
                                                      .unitCtrl
                                                      .text = 'ton';
                                                });
                                              } else if (val
                                                      .toUpperCase()
                                                      .contains('PC') ||
                                                  val.contains('기둥')) {
                                                setDialogState(() {
                                                  invoiceRows[idx]
                                                      .unitCtrl
                                                      .text = '매';
                                                });
                                              } else if (val.contains('레미콘')) {
                                                setDialogState(() {
                                                  invoiceRows[idx]
                                                      .unitCtrl
                                                      .text = 'm3';
                                                });
                                              }
                                            },
                                            decoration: const InputDecoration(
                                              labelText: '제품명',
                                              filled: true,
                                              fillColor: Colors.white,
                                              border: OutlineInputBorder(),
                                              isDense: true,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          flex: 3,
                                          child: TextField(
                                            controller:
                                                invoiceRows[idx].specCtrl,
                                            decoration: const InputDecoration(
                                              labelText: '규격명',
                                              hintText: '800×300×6750',
                                              filled: true,
                                              fillColor: Colors.white,
                                              border: OutlineInputBorder(),
                                              isDense: true,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          flex: 2,
                                          child: TextField(
                                            controller:
                                                invoiceRows[idx].unitCtrl,
                                            decoration: const InputDecoration(
                                              labelText: '단위',
                                              hintText: 'ton/매/m3',
                                              filled: true,
                                              fillColor: Colors.white,
                                              border: OutlineInputBorder(),
                                              isDense: true,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          flex: 3,
                                          child: TextField(
                                            controller:
                                                invoiceRows[idx].qtyCtrl,
                                            keyboardType: const TextInputType
                                                .numberWithOptions(
                                                decimal: true),
                                            decoration: const InputDecoration(
                                              labelText: '수량',
                                              hintText: '5',
                                              filled: true,
                                              fillColor: Colors.white,
                                              border: OutlineInputBorder(),
                                              isDense: true,
                                            ),
                                          ),
                                        ),
                                        if (invoiceRows.length > 1)
                                          IconButton(
                                            visualDensity:
                                                VisualDensity.compact,
                                            icon: const Icon(
                                                Icons.remove_circle_outline,
                                                color: Colors.red,
                                                size: 18),
                                            onPressed: () {
                                              setDialogState(() {
                                                invoiceRows.removeAt(idx);
                                              });
                                            },
                                          ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          _buildField(supplierNameCtrl, '공급자 상호', '예: 선일레미콘(주)'),
                          _buildField(
                              orderNumberCtrl, '주문송장번호', '예: B-028-0202'),
                        ],

                        // 3. 출장비 입력 폼
                        if (chosenCategory == DocCategory.travel) ...[
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: TravelDivision.list.map((div) {
                              final isSel = chosenTravelDivision == div;
                              return ChoiceChip(
                                visualDensity: VisualDensity.compact,
                                label: Text(div),
                                selected: isSel,
                                selectedColor: Colors.amber.shade300,
                                onSelected: (_) {
                                  setDialogState(() {
                                    chosenTravelDivision = div;
                                    if (div == TravelDivision.car) {
                                      recalcCarDistanceCost();
                                    }
                                  });
                                },
                              );
                            }).toList(),
                          ),
                          const SizedBox(height: 10),
                          _buildField(travelDateCtrl, '날짜', '예: 2026.10.30'),
                          if (chosenTravelDivision == TravelDivision.car) ...[
                            _buildField(
                              travelDistanceKmCtrl,
                              '실시간 추천 거리 (편도 km)',
                              '예: 25',
                              keyboardType: TextInputType.number,
                              onChanged: (_) =>
                                  setDialogState(recalcCarDistanceCost),
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: _buildField(
                                    travelCarMultiplierCtrl,
                                    '왕복 배수 (기본 2)',
                                    '2',
                                    keyboardType: TextInputType.number,
                                    onChanged: (_) =>
                                        setDialogState(recalcCarDistanceCost),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: _buildField(
                                    travelCarUnitPriceCtrl,
                                    'km당 단가 (원)',
                                    '300',
                                    keyboardType: TextInputType.number,
                                    onChanged: (_) =>
                                        setDialogState(recalcCarDistanceCost),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          _buildField(
                              travelMerchantCtrl, '상호 / 내역', '예: 롯데리아 창동역점'),
                          _buildField(
                            travelAmountCtrl,
                            '금액 (원)',
                            '예: 15000',
                            keyboardType: TextInputType.number,
                          ),
                        ],

                        // 4. 병원비 입력 폼
                        if (chosenCategory == DocCategory.medical) ...[
                          _buildField(patientNameCtrl, '환자성명', '예: 이경훈'),
                          _buildField(issueDateCtrl, '날짜 (발행/조제일)', '예: 2026.04.02'),
                          _buildField(clinicNameCtrl, '상호 (병원/약국명)', '예: 타워약국'),
                          _buildField(
                            totalPaidCtrl,
                            '수납 금액 (본인부담 합계)',
                            '예: 3000',
                            keyboardType: TextInputType.number,
                          ),
                          _buildField(
                              bizRegNumberCtrl, '사업자등록번호', '예: 840-78-00407'),
                          Container(
                            padding: const EdgeInsets.all(10),
                            margin: const EdgeInsets.only(top: 4),
                            decoration: BoxDecoration(
                              color: Colors.indigo.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.indigo.shade200),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '📎 추가 증빙첨부 (${medicalProofBase64List.length}장)',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF1E3A8A),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        onPressed: () async {
                                          await _pickAndAppendExtraPage(
                                            source: ImageSource.camera,
                                            pathList: medicalProofPathList,
                                            base64List: medicalProofBase64List,
                                            onUpdated: () =>
                                                setDialogState(() {}),
                                          );
                                        },
                                        icon: const Icon(Icons.camera_alt,
                                            size: 15),
                                        label: const Text('+ 카메라 촬영',
                                            style: TextStyle(fontSize: 11.5)),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        onPressed: () async {
                                          await _pickAndAppendExtraPage(
                                            source: ImageSource.gallery,
                                            pathList: medicalProofPathList,
                                            base64List: medicalProofBase64List,
                                            onUpdated: () =>
                                                setDialogState(() {}),
                                          );
                                        },
                                        icon: const Icon(Icons.photo_library,
                                            size: 15),
                                        label: const Text('+ 갤러리 추가',
                                            style: TextStyle(fontSize: 11.5)),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],

                        // 5. 명함관리 입력 폼
                        if (chosenCategory == DocCategory.businessCard) ...[
                          _buildField(
                              cardDateCtrl, '날짜 (찍은날짜 / 등록일)', '예: 2026.11.07'),
                          _buildField(companyNameCtrl, '회사명', '예: 현대건설(주)'),
                          _buildField(siteNameCtrl, '현장명 (또는 부서명)', '예: 공무팀'),
                          _buildField(personNameCtrl, '이름', '예: 홍길동'),
                          _buildField(
                              mobilePhoneCtrl, '휴대폰번호', '예: 010-1234-5678'),
                          _buildField(
                              emailCtrl, '이메일주소', '예: gildong@company.com'),
                        ],

                        // 6. ★ PDF변환 전용 입력 폼 (OCR 없이 파일명만 입력 + 다중 페이지 추가)
                        if (chosenCategory == DocCategory.pdfConvert) ...[
                          Container(
                            padding: const EdgeInsets.all(10),
                            margin: const EdgeInsets.only(bottom: 10),
                            decoration: BoxDecoration(
                              color: Colors.teal.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.teal.shade300),
                            ),
                            child: const Text(
                              '✅ OCR 문자 인식 없이 빠르게 사진을 스캔하여 PDF로 묶어줍니다.\n파일명만 입력하시고, 여러 장을 한 PDF로 묶으려면 아래 [+ 페이지 추가]를 눌러주세요.',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: Color(0xFF0F766E),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          _buildField(
                            pdfFileNameCtrl,
                            '파일명 (필수 입력)',
                            '예: 현장점검보고서, 계약서스캔 등',
                          ),
                          _buildField(
                            pdfDateCtrl,
                            '찍은날짜 (자동 입력)',
                            '예: 2026.11.07',
                          ),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.indigo.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.indigo.shade200),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '📄 현재 PDF 총 장수: ${1 + pdfExtraBase64List.length}장 (기본 1장 + 추가 ${pdfExtraBase64List.length}장)',
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFF1E3A8A),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: FilledButton.icon(
                                        style: FilledButton.styleFrom(
                                          backgroundColor:
                                              const Color(0xFF1E3A8A),
                                        ),
                                        onPressed: () async {
                                          await _pickAndAppendExtraPage(
                                            source: ImageSource.camera,
                                            pathList: pdfExtraPathList,
                                            base64List: pdfExtraBase64List,
                                            dialogTitle: '추가 PDF 페이지 스캔',
                                            onUpdated: () =>
                                                setDialogState(() {}),
                                          );
                                        },
                                        icon: const Icon(Icons.add_a_photo,
                                            size: 15),
                                        label: const Text('+ 카메라로 장수 추가',
                                            style: TextStyle(fontSize: 11.5)),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        onPressed: () async {
                                          await _pickAndAppendExtraPage(
                                            source: ImageSource.gallery,
                                            pathList: pdfExtraPathList,
                                            base64List: pdfExtraBase64List,
                                            dialogTitle: '추가 PDF 페이지 스캔',
                                            onUpdated: () =>
                                                setDialogState(() {}),
                                          );
                                        },
                                        icon: const Icon(Icons.photo_library,
                                            size: 15),
                                        label: const Text('+ 갤러리 다중추가',
                                            style: TextStyle(fontSize: 11.5)),
                                      ),
                                    ),
                                  ],
                                ),
                                if (pdfExtraBase64List.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: List.generate(
                                        pdfExtraBase64List.length, (pIdx) {
                                      return Chip(
                                        visualDensity: VisualDensity.compact,
                                        label: Text(
                                          '${pIdx + 2}페이지',
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                        onDeleted: () {
                                          setDialogState(() {
                                            if (pIdx < pdfExtraPathList.length) {
                                              pdfExtraPathList.removeAt(pIdx);
                                            }
                                            pdfExtraBase64List.removeAt(pIdx);
                                          });
                                        },
                                      );
                                    }),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('취소'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('저장'),
                  ),
                ],
              );
            },
          );
        },
      );

      if (confirmed != true) return;

      final String nowStr =
          DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
      final String typedSubCat = subCategoryCtrl.text.trim();
      if (_usesSubCategory(chosenCategory) && typedSubCat.isNotEmpty) {
        await _addUserSubCategory(chosenCategory, typedSubCat);
      }

      final List<DocRecord> createdRecords = <DocRecord>[];

      if (chosenCategory == DocCategory.invoice) {
        for (int i = 0; i < invoiceRows.length; i++) {
          final r = invoiceRows[i];
          final prod = r.productCtrl.text.trim().isEmpty
              ? '고장력철근'
              : r.productCtrl.text.trim();
          final spec = r.specCtrl.text.trim();
          final unit = r.unitCtrl.text.trim().isEmpty
              ? (prod.contains('철근') ? 'ton' : '매')
              : r.unitCtrl.text.trim();
          final qty = r.qtyCtrl.text.trim();
          final recId = i == 0 ? newId : '${newId}_$i';
          createdRecords.add(
            DocRecord(
              id: recId,
              category: DocCategory.invoice,
              createdAt: nowStr,
              imagePath: savedFile.path,
              base64Image: '',
              fields: {
                'arrivalDate': DocRecord.formatDotDate(arrivalDateCtrl.text),
                'productName': prod,
                'specName': spec,
                'unit': unit,
                'quantity': qty,
                'supplierName': supplierNameCtrl.text.trim(),
                'orderNumber': orderNumberCtrl.text.trim(),
                'uploader': _exporterUserName.trim(),
              },
            ),
          );
        }
      } else if (DocCategory.isOfficial(chosenCategory)) {
        createdRecords.add(
          DocRecord(
            id: newId,
            category: chosenCategory,
            createdAt: nowStr,
            imagePath: savedFile.path,
            base64Image: '',
            fields: {
              'title': docTitleCtrl.text.trim(),
              'aiSummary': aiSummaryCtrl.text.trim(),
              'docNumber': DocRecord.stripDocNumSpaces(docNumberCtrl.text),
              'replyDocNumber':
                  DocRecord.stripDocNumSpaces(replyDocNumberCtrl.text),
              'sender': senderCtrl.text.trim(),
              'recipient': recipientCtrl.text.trim(),
              'replyDeadline': DocRecord.formatDotDate(replyDeadlineCtrl.text),
              'sentDate': DocRecord.formatDotDate(sentDateCtrl.text),
              'uploader': _exporterUserName.trim(),
            },
          ),
        );
      } else if (chosenCategory == DocCategory.travel) {
        createdRecords.add(
          DocRecord(
            id: newId,
            category: DocCategory.travel,
            createdAt: nowStr,
            imagePath: savedFile.path,
            base64Image: '',
            fields: {
              'subCategory': typedSubCat,
              'travelDivision': chosenTravelDivision,
              'date': DocRecord.formatDotDate(travelDateCtrl.text),
              'distanceKm': travelDistanceKmCtrl.text.trim(),
              'carMultiplier': travelCarMultiplierCtrl.text.trim(),
              'carUnitPrice': travelCarUnitPriceCtrl.text.trim(),
              'merchantName': travelMerchantCtrl.text.trim(),
              'totalAmount':
                  travelAmountCtrl.text.replaceAll(RegExp(r'[^0-9]'), ''),
            },
          ),
        );
      } else if (chosenCategory == DocCategory.medical) {
        final Map<String, String> medFields = {
          'subCategory': typedSubCat,
          'patientName': patientNameCtrl.text.trim(),
          'issueDate': DocRecord.formatDotDate(issueDateCtrl.text),
          'clinicName': clinicNameCtrl.text.trim(),
          'totalPaid': totalPaidCtrl.text.replaceAll(RegExp(r'[^0-9]'), ''),
          'bizRegNumber': bizRegNumberCtrl.text.trim(),
          'isClaimed': 'N',
        };
        if (medicalProofPathList.isNotEmpty) {
          medFields['proofPathsJson'] = jsonEncode(medicalProofPathList);
          medFields['proofStatus'] = '첨부(${medicalProofPathList.length}장)';
        }
        createdRecords.add(
          DocRecord(
            id: newId,
            category: DocCategory.medical,
            createdAt: nowStr,
            imagePath: savedFile.path,
            base64Image: '',
            fields: medFields,
          ),
        );
      } else if (chosenCategory == DocCategory.businessCard) {
        createdRecords.add(
          DocRecord(
            id: newId,
            category: DocCategory.businessCard,
            createdAt: nowStr,
            imagePath: savedFile.path,
            base64Image: '',
            fields: {
              'cardDate': DocRecord.formatDotDate(cardDateCtrl.text),
              'companyName': companyNameCtrl.text.trim(),
              'siteName': siteNameCtrl.text.trim(),
              'personName': personNameCtrl.text.trim(),
              'mobilePhone': mobilePhoneCtrl.text.trim(),
              'email': emailCtrl.text.trim(),
            },
          ),
        );
      } else if (chosenCategory == DocCategory.pdfConvert) {
        final String rawName = pdfFileNameCtrl.text.trim().isEmpty
            ? '문서스캔_${DocRecord.formatDotDate(pdfDateCtrl.text)}'
            : pdfFileNameCtrl.text.trim();
        final Map<String, String> pdfFields = {
          'pdfDate': DocRecord.formatDotDate(pdfDateCtrl.text),
          'pdfFileName': rawName,
          'pageCount': (1 + pdfExtraPathList.length).toString(),
        };
        if (pdfExtraPathList.isNotEmpty) {
          pdfFields['proofPathsJson'] = jsonEncode(pdfExtraPathList);
          pdfFields['proofStatus'] = '첨부(${pdfExtraPathList.length}장)';
        }
        createdRecords.add(
          DocRecord(
            id: newId,
            category: DocCategory.pdfConvert,
            createdAt: nowStr,
            imagePath: savedFile.path,
            base64Image: '',
            fields: pdfFields,
          ),
        );
      }

      setState(() {
        _selectedCategoryFilter = chosenCategory;
        for (final nr in createdRecords) {
          _records.insert(0, nr);
        }
        if (createdRecords.isNotEmpty) {
          _selectedRecord = createdRecords.first;
          _selectedPhotoIndex = 0;
        }
      });
      await _saveLocalRecords();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('서류 등록 오류: $e')),
        );
      }
    }
  }

  // ===========================================================================
  // 4단계: 항목 수정(_editRecordDialog), 삭제, 전화/메일 연결, 결재(검토/소장결재/본인취소)
  // ===========================================================================
  Future<void> _editRecordDialog(DocRecord rec) async {
    String chosenCategory = rec.category;
    final subCategoryCtrl = TextEditingController(text: rec.subCategory);
    final uploaderNameCtrl =
        TextEditingController(text: _resolveUploaderName(rec));

    // 1. 공문
    final docTitleCtrl = TextEditingController(text: rec.fields['title'] ?? '');
    final aiSummaryCtrl =
        TextEditingController(text: rec.fields['aiSummary'] ?? '');
    final docNumberCtrl =
        TextEditingController(text: rec.fields['docNumber'] ?? '');
    final replyDocNumberCtrl =
        TextEditingController(text: rec.fields['replyDocNumber'] ?? '');
    final senderCtrl = TextEditingController(text: rec.fields['sender'] ?? '');
    final recipientCtrl =
        TextEditingController(text: rec.fields['recipient'] ?? '');
    final replyDeadlineCtrl =
        TextEditingController(text: rec.fields['replyDeadline'] ?? '');
    final sentDateCtrl =
        TextEditingController(text: rec.fields['sentDate'] ?? '');

    // 2. 자재송장
    final arrivalDateCtrl =
        TextEditingController(text: rec.fields['arrivalDate'] ?? '');
    final productNameCtrl =
        TextEditingController(text: rec.fields['productName'] ?? '');
    final specNameCtrl =
        TextEditingController(text: rec.fields['specName'] ?? '');
    final unitCtrl = TextEditingController(text: rec.fields['unit'] ?? 'ton');
    final quantityCtrl =
        TextEditingController(text: rec.fields['quantity'] ?? '');
    final supplierNameCtrl =
        TextEditingController(text: rec.fields['supplierName'] ?? '');
    final orderNumberCtrl =
        TextEditingController(text: rec.fields['orderNumber'] ?? '');

    // 3. 출장비
    String chosenTravelDivision = rec.travelDivision;
    final travelDateCtrl =
        TextEditingController(text: rec.fields['date'] ?? '');
    final travelDistanceKmCtrl =
        TextEditingController(text: rec.fields['distanceKm'] ?? '0');
    final travelCarMultiplierCtrl =
        TextEditingController(text: rec.fields['carMultiplier'] ?? '2');
    final travelCarUnitPriceCtrl =
        TextEditingController(text: rec.fields['carUnitPrice'] ?? '300');
    final travelMerchantCtrl =
        TextEditingController(text: rec.fields['merchantName'] ?? '');
    final travelAmountCtrl =
        TextEditingController(text: rec.fields['totalAmount'] ?? '0');

    void recalcCarDistanceCost() {
      if (chosenTravelDivision != TravelDivision.car) return;
      final km = double.tryParse(
            travelDistanceKmCtrl.text.replaceAll(RegExp(r'[^0-9.]'), ''),
          ) ??
          0;
      final mult = double.tryParse(
            travelCarMultiplierCtrl.text.replaceAll(RegExp(r'[^0-9.]'), ''),
          ) ??
          2;
      final unitPrice = double.tryParse(
            travelCarUnitPriceCtrl.text.replaceAll(RegExp(r'[^0-9.]'), ''),
          ) ??
          300;
      travelAmountCtrl.text = (km * mult * unitPrice).round().toString();
    }

    // 4. 병원비
    final patientNameCtrl =
        TextEditingController(text: rec.fields['patientName'] ?? '');
    final issueDateCtrl =
        TextEditingController(text: rec.fields['issueDate'] ?? '');
    final clinicNameCtrl =
        TextEditingController(text: rec.fields['clinicName'] ?? '');
    final totalPaidCtrl =
        TextEditingController(text: rec.fields['totalPaid'] ?? '');
    final bizRegNumberCtrl =
        TextEditingController(text: rec.fields['bizRegNumber'] ?? '');
    bool isClaimedFlag = rec.isMedicalClaimed;

    // 5. 명함관리
    final cardDateCtrl = TextEditingController(
      text: rec.fields['cardDate'] ??
          DocRecord.formatDotDate(rec.createdAt.split(' ').first),
    );
    final companyNameCtrl =
        TextEditingController(text: rec.fields['companyName'] ?? '');
    final siteNameCtrl =
        TextEditingController(text: rec.fields['siteName'] ?? '');
    final personNameCtrl =
        TextEditingController(text: rec.fields['personName'] ?? '');
    final mobilePhoneCtrl =
        TextEditingController(text: rec.fields['mobilePhone'] ?? '');
    final emailCtrl = TextEditingController(text: rec.fields['email'] ?? '');

    // 6. PDF변환
    final pdfDateCtrl = TextEditingController(
      text: rec.fields['pdfDate'] ??
          DocRecord.formatDotDate(rec.createdAt.split(' ').first),
    );
    final pdfFileNameCtrl =
        TextEditingController(text: rec.fields['pdfFileName'] ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final mySavedCats =
              _userSubCategoriesMap[chosenCategory] ?? <String>[];
          return AlertDialog(
            title: const Text(
              '✏️ 항목 정보 수정',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            content: SizedBox(
              width: 400,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_usesSubCategory(chosenCategory)) ...[
                      _buildField(
                          subCategoryCtrl, '내 카테고리', '예: 갑상선, 치과, 현장출장'),
                      if (mySavedCats.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Wrap(
                            spacing: 5,
                            runSpacing: 5,
                            children: mySavedCats.map((sc) {
                              return InputChip(
                                visualDensity: VisualDensity.compact,
                                label: Text(sc,
                                    style: const TextStyle(fontSize: 11)),
                                selected: subCategoryCtrl.text.trim() == sc,
                                onSelected: (_) => setDialogState(
                                    () => subCategoryCtrl.text = sc),
                              );
                            }).toList(),
                          ),
                        ),
                    ],
                    if (DocCategory.isOfficial(chosenCategory)) ...[
                      _buildField(sentDateCtrl, '날짜(시행일)', '예: 2025.05.19'),
                      _buildField(docNumberCtrl, '공문번호', '예: 공동주택과-16092'),
                      if (chosenCategory == DocCategory.officialOut)
                        _buildField(
                            replyDocNumberCtrl, '회신번호', '예: 공동주택과-16092'),
                      if (chosenCategory == DocCategory.officialIn)
                        _buildField(senderCtrl, '보낸사람', '예: 김해시장')
                      else
                        _buildField(recipientCtrl, '받는사람', '예: 김해시장'),
                      _buildField(docTitleCtrl, '제목', '공문 제목'),
                      _buildField(aiSummaryCtrl, '내용 (요약)', '핵심 내용',
                          maxLines: 2),
                      if (chosenCategory == DocCategory.officialIn)
                        _buildField(replyDeadlineCtrl, '회신요청일', '예: 2025.05.21'),
                      _buildField(uploaderNameCtrl, '올린사람 (담당자)', '예: 이경훈'),
                    ],
                    if (chosenCategory == DocCategory.invoice) ...[
                      _buildField(arrivalDateCtrl, '날짜', '예: 2026.06.25'),
                      _buildField(
                        productNameCtrl,
                        '제품명',
                        '예: 고장력철근, PC기둥, 레미콘',
                        onChanged: (v) {
                          if (v.contains('철근')) {
                            setDialogState(() => unitCtrl.text = 'ton');
                          } else if (v.toUpperCase().contains('PC') ||
                              v.contains('기둥')) {
                            setDialogState(() => unitCtrl.text = '매');
                          } else if (v.contains('레미콘')) {
                            setDialogState(() => unitCtrl.text = 'm3');
                          }
                        },
                      ),
                      _buildField(specNameCtrl, '규격명', '예: 800×300×6750'),
                      _buildField(unitCtrl, '단위', '예: ton / 매 / m3'),
                      _buildField(
                        quantityCtrl,
                        '수량',
                        '예: 5',
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                      ),
                      _buildField(supplierNameCtrl, '공급자', '예: 선일레미콘(주)'),
                      _buildField(orderNumberCtrl, '주문송장번호', '예: B-028-0202'),
                      _buildField(uploaderNameCtrl, '올린사람 (담당자)', '예: 이경훈'),
                    ],
                    if (chosenCategory == DocCategory.travel) ...[
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: TravelDivision.list.map((div) {
                          return ChoiceChip(
                            visualDensity: VisualDensity.compact,
                            label: Text(div),
                            selected: chosenTravelDivision == div,
                            onSelected: (_) {
                              setDialogState(() {
                                chosenTravelDivision = div;
                                if (div == TravelDivision.car) {
                                  recalcCarDistanceCost();
                                }
                              });
                            },
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 8),
                      _buildField(travelDateCtrl, '날짜', '예: 2026.10.30'),
                      if (chosenTravelDivision == TravelDivision.car) ...[
                        _buildField(
                          travelDistanceKmCtrl,
                          '거리 (편도 km)',
                          '예: 25',
                          keyboardType: TextInputType.number,
                          onChanged: (_) =>
                              setDialogState(recalcCarDistanceCost),
                        ),
                      ],
                      _buildField(travelMerchantCtrl, '상호', '예: 롯데리아 창동역점'),
                      _buildField(
                        travelAmountCtrl,
                        '금액 (원)',
                        '예: 15000',
                        keyboardType: TextInputType.number,
                      ),
                    ],
                    if (chosenCategory == DocCategory.medical) ...[
                      _buildField(patientNameCtrl, '환자성명', '예: 이경훈'),
                      _buildField(issueDateCtrl, '날짜', '예: 2026.04.02'),
                      _buildField(clinicNameCtrl, '상호', '예: 타워약국'),
                      _buildField(
                        totalPaidCtrl,
                        '금액 (원)',
                        '예: 3000',
                        keyboardType: TextInputType.number,
                      ),
                      _buildField(bizRegNumberCtrl, '사업자등록번호', '예: 840-78-00407'),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('실손보험 청구완료 여부',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.bold)),
                        value: isClaimedFlag,
                        onChanged: (v) =>
                            setDialogState(() => isClaimedFlag = v ?? false),
                      ),
                    ],
                    if (chosenCategory == DocCategory.businessCard) ...[
                      _buildField(cardDateCtrl, '날짜 (찍은날짜)', '예: 2026.11.07'),
                      _buildField(companyNameCtrl, '회사명', '예: 현대건설(주)'),
                      _buildField(siteNameCtrl, '현장명', '예: 공무팀'),
                      _buildField(personNameCtrl, '이름', '예: 홍길동'),
                      _buildField(mobilePhoneCtrl, '휴대폰번호', '예: 010-1234-5678'),
                      _buildField(emailCtrl, '이메일주소', '예: gildong@company.com'),
                    ],
                    if (chosenCategory == DocCategory.pdfConvert) ...[
                      _buildField(pdfDateCtrl, '찍은날짜', '예: 2026.11.07'),
                      _buildField(pdfFileNameCtrl, '파일명', '예: 현장점검보고서'),
                      const SizedBox(height: 6),
                      OutlinedButton.icon(
                        onPressed: () async {
                          Navigator.pop(ctx, false);
                          await _manageRecordExtraPagesDialog(rec);
                        },
                        icon: const Icon(Icons.note_add_outlined, size: 17),
                        label: Text(
                            '📄 PDF 페이지 사진 추가/삭제 관리 (현재 ${rec.totalPdfPageCount}장)'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('저장'),
              ),
            ],
          );
        },
      ),
    );

    if (saved != true) return;

    final updatedFields = Map<String, String>.from(rec.fields);
    if (_usesSubCategory(chosenCategory)) {
      updatedFields['subCategory'] = subCategoryCtrl.text.trim();
      if (subCategoryCtrl.text.trim().isNotEmpty) {
        await _addUserSubCategory(chosenCategory, subCategoryCtrl.text.trim());
      }
    }

    if (DocCategory.isOfficial(chosenCategory)) {
      updatedFields['sentDate'] = DocRecord.formatDotDate(sentDateCtrl.text);
      updatedFields['docNumber'] =
          DocRecord.stripDocNumSpaces(docNumberCtrl.text);
      updatedFields['replyDocNumber'] =
          DocRecord.stripDocNumSpaces(replyDocNumberCtrl.text);
      updatedFields['sender'] = senderCtrl.text.trim();
      updatedFields['recipient'] = recipientCtrl.text.trim();
      updatedFields['title'] = docTitleCtrl.text.trim();
      updatedFields['aiSummary'] = aiSummaryCtrl.text.trim();
      updatedFields['replyDeadline'] =
          DocRecord.formatDotDate(replyDeadlineCtrl.text);
      updatedFields['uploader'] = uploaderNameCtrl.text.trim();
    } else if (chosenCategory == DocCategory.invoice) {
      updatedFields['arrivalDate'] =
          DocRecord.formatDotDate(arrivalDateCtrl.text);
      updatedFields['productName'] = productNameCtrl.text.trim();
      updatedFields['specName'] = specNameCtrl.text.trim();
      updatedFields['unit'] = unitCtrl.text.trim();
      updatedFields['quantity'] = quantityCtrl.text.trim();
      updatedFields['supplierName'] = supplierNameCtrl.text.trim();
      updatedFields['orderNumber'] = orderNumberCtrl.text.trim();
      updatedFields['uploader'] = uploaderNameCtrl.text.trim();
    } else if (chosenCategory == DocCategory.travel) {
      updatedFields['travelDivision'] = chosenTravelDivision;
      updatedFields['date'] = DocRecord.formatDotDate(travelDateCtrl.text);
      updatedFields['distanceKm'] = travelDistanceKmCtrl.text.trim();
      updatedFields['carMultiplier'] = travelCarMultiplierCtrl.text.trim();
      updatedFields['carUnitPrice'] = travelCarUnitPriceCtrl.text.trim();
      updatedFields['merchantName'] = travelMerchantCtrl.text.trim();
      updatedFields['totalAmount'] =
          travelAmountCtrl.text.replaceAll(RegExp(r'[^0-9]'), '');
    } else if (chosenCategory == DocCategory.medical) {
      updatedFields['patientName'] = patientNameCtrl.text.trim();
      updatedFields['issueDate'] = DocRecord.formatDotDate(issueDateCtrl.text);
      updatedFields['clinicName'] = clinicNameCtrl.text.trim();
      updatedFields['totalPaid'] =
          totalPaidCtrl.text.replaceAll(RegExp(r'[^0-9]'), '');
      updatedFields['bizRegNumber'] = bizRegNumberCtrl.text.trim();
      updatedFields['isClaimed'] = isClaimedFlag ? 'Y' : 'N';
    } else if (chosenCategory == DocCategory.businessCard) {
      updatedFields['cardDate'] = DocRecord.formatDotDate(cardDateCtrl.text);
      updatedFields['companyName'] = companyNameCtrl.text.trim();
      updatedFields['siteName'] = siteNameCtrl.text.trim();
      updatedFields['personName'] = personNameCtrl.text.trim();
      updatedFields['mobilePhone'] = mobilePhoneCtrl.text.trim();
      updatedFields['email'] = emailCtrl.text.trim();
    } else if (chosenCategory == DocCategory.pdfConvert) {
      updatedFields['pdfDate'] = DocRecord.formatDotDate(pdfDateCtrl.text);
      updatedFields['pdfFileName'] = pdfFileNameCtrl.text.trim().isEmpty
          ? '문서스캔'
          : pdfFileNameCtrl.text.trim();
    }

    final updatedRec = DocRecord(
      id: rec.id,
      category: chosenCategory,
      createdAt: rec.createdAt,
      imagePath: rec.imagePath,
      base64Image: rec.base64Image,
      fields: updatedFields,
    );

    setState(() {
      final idx = _records.indexWhere((r) => r.id == rec.id);
      if (idx != -1) _records[idx] = updatedRec;
      if (_selectedRecord?.id == rec.id) _selectedRecord = updatedRec;
    });
    await _saveLocalRecords();
  }

  Future<void> _deleteRecord(DocRecord rec) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('항목 영구 삭제'),
        content: Text('"${rec.displayTitle}" 항목을 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() {
      _records.removeWhere((r) => r.id == rec.id);
      if (_selectedRecord?.id == rec.id) {
        final cur = _filteredRecords;
        _selectedRecord = cur.isNotEmpty ? cur.first : null;
        _selectedPhotoIndex = 0;
      }
    });
    await _saveLocalRecords();
  }

  Future<void> _toggleMedicalRecordClaimed(DocRecord rec) async {
    final updatedFields = Map<String, String>.from(rec.fields);
    updatedFields['isClaimed'] = rec.isMedicalClaimed ? 'N' : 'Y';
    final updatedRec = DocRecord(
      id: rec.id,
      category: rec.category,
      createdAt: rec.createdAt,
      imagePath: rec.imagePath,
      base64Image: rec.base64Image,
      fields: updatedFields,
    );
    setState(() {
      final idx = _records.indexWhere((r) => r.id == rec.id);
      if (idx != -1) _records[idx] = updatedRec;
      if (_selectedRecord?.id == rec.id) _selectedRecord = updatedRec;
    });
    await _saveLocalRecords();
  }

  Future<void> _bulkToggleMedicalClaimed(List<DocRecord> targetList) async {
    final medList =
        targetList.where((r) => r.category == DocCategory.medical).toList();
    if (medList.isEmpty) return;
    final bool allClaimed = medList.every((r) => r.isMedicalClaimed);
    final String nextVal = allClaimed ? 'N' : 'Y';
    final Set<String> targetIds = medList.map((r) => r.id).toSet();

    setState(() {
      for (int i = 0; i < _records.length; i++) {
        if (targetIds.contains(_records[i].id)) {
          final nf = Map<String, String>.from(_records[i].fields);
          nf['isClaimed'] = nextVal;
          _records[i] = DocRecord(
            id: _records[i].id,
            category: _records[i].category,
            createdAt: _records[i].createdAt,
            imagePath: _records[i].imagePath,
            base64Image: _records[i].base64Image,
            fields: nf,
          );
          if (_selectedRecord?.id == _records[i].id) {
            _selectedRecord = _records[i];
          }
        }
      }
    });
    await _saveLocalRecords();
  }

  String _resolveUploaderName(DocRecord r) {
    final u = (r.fields['uploader'] ?? '').trim();
    if (u.isNotEmpty) return u;
    if (_exporterUserName.trim().isNotEmpty) return _exporterUserName.trim();
    return '-';
  }

  Future<void> _openPhoneDialer(String rawPhone) async {
    final clean = rawPhone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (clean.isEmpty) return;
    try {
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      await channel.invokeMethod('launch', <String, dynamic>{
        'url': 'tel:$clean',
        'useSafariVC': false,
        'useWebView': false,
        'enableJavaScript': false,
        'enableDomStorage': false,
        'universalLinksOnly': false,
        'headers': <String, String>{},
      });
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: rawPhone));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('전화번호($rawPhone)가 복사되었습니다. 전화 앱에 붙여넣어 통화하세요.'),
          ),
        );
      }
    }
  }

  Future<void> _openEmailComposer(String rawEmail) async {
    final clean = rawEmail.trim();
    if (clean.isEmpty) return;
    try {
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      await channel.invokeMethod('launch', <String, dynamic>{
        'url': 'mailto:$clean',
        'useSafariVC': false,
        'useWebView': false,
        'enableJavaScript': false,
        'enableDomStorage': false,
        'universalLinksOnly': false,
        'headers': <String, String>{},
      });
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: clean));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('이메일 주소($clean)가 복사되었습니다.'),
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 결재 / 검토 / 본인 결재취소 모달
  // ---------------------------------------------------------------------------
  Future<String?> _ensureApproverUserName() async {
    if (_exporterUserName.trim().isNotEmpty) {
      return _exporterUserName.trim();
    }
    final ctrl = TextEditingController();
    final entered = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '결재/검토자 이름 입력',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '내 이름 (소장님은 이름에 "소장" 포함)',
            hintText: '예: 이경훈, 김철수 소장',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('확인'),
          ),
        ],
      ),
    );
    if (entered != null && entered.isNotEmpty) {
      setState(() => _exporterUserName = entered);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsUserNameKey, entered);
      return entered;
    }
    return null;
  }

  Future<DocRecord> _appendApprovalToRecord(
      DocRecord rec, String userName) async {
    final todayDot = DateFormat('yyyy.MM.dd').format(DateTime.now());
    final newEntryJson = jsonEncode([
      {
        'name': userName.trim(),
        'date': todayDot,
        'role': DocRecord.isDirectorName(userName) ? '결재' : '검토',
      }
    ]);
    final mergedJson = DocRecord.mergeApprovalsJsonStrings(
      rec.fields['approvalsJson'],
      newEntryJson,
    );
    final updatedFields = Map<String, String>.from(rec.fields);
    updatedFields['approvalsJson'] = mergedJson;

    final updatedRec = DocRecord(
      id: rec.id,
      category: rec.category,
      createdAt: rec.createdAt,
      imagePath: rec.imagePath,
      base64Image: rec.base64Image,
      fields: updatedFields,
    );

    setState(() {
      final idx = _records.indexWhere((r) => r.id == rec.id);
      if (idx != -1) _records[idx] = updatedRec;
      if (_selectedRecord?.id == rec.id) _selectedRecord = updatedRec;
    });
    await _saveLocalRecords();
    return updatedRec;
  }

  Future<DocRecord> _removeApprovalFromRecord(
      DocRecord rec, String targetName) async {
    final nextJson = DocRecord.removeApproverFromRawJson(
      rec.fields['approvalsJson'],
      targetName,
    );
    final updatedFields = Map<String, String>.from(rec.fields);
    if (nextJson.isEmpty) {
      updatedFields.remove('approvalsJson');
    } else {
      updatedFields['approvalsJson'] = nextJson;
    }

    final updatedRec = DocRecord(
      id: rec.id,
      category: rec.category,
      createdAt: rec.createdAt,
      imagePath: rec.imagePath,
      base64Image: rec.base64Image,
      fields: updatedFields,
    );

    setState(() {
      final idx = _records.indexWhere((r) => r.id == rec.id);
      if (idx != -1) _records[idx] = updatedRec;
      if (_selectedRecord?.id == rec.id) _selectedRecord = updatedRec;
    });
    await _saveLocalRecords();
    return updatedRec;
  }

  Future<DocRecord?> _handleApprovalCellTap(
    DocRecord rec, {
    Future<void> Function(DocRecord updated)? onChangedCallback,
  }) async {
    final entries = rec.approvalEntries;
    if (entries.isEmpty) {
      final userName = await _ensureApproverUserName();
      if (userName == null || userName.isEmpty) return null;
      final updated = await _appendApprovalToRecord(rec, userName);
      if (onChangedCallback != null) await onChangedCallback(updated);
      return updated;
    }

    DocRecord currentRec = rec;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final list = currentRec.approvalEntries;
          final myName = _exporterUserName.trim();
          final bool alreadyApprovedByMe =
              myName.isNotEmpty && list.any((e) => e['name'] == myName);

          return AlertDialog(
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  currentRec.isDirectorApprovalCompleted
                      ? '✅ 결재완료 이력'
                      : '📝 검토·결재 이력 (${list.length}명)',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (int i = 0; i < list.length; i++)
                    Container(
                      margin: const EdgeInsets.only(bottom: 7),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: DocRecord.isDirectorName(list[i]['name'])
                            ? Colors.green.shade50
                            : Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: DocRecord.isDirectorName(list[i]['name'])
                              ? Colors.green.shade300
                              : Colors.blue.shade200,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color:
                                      DocRecord.isDirectorName(list[i]['name'])
                                          ? Colors.green.shade700
                                          : const Color(0xFF1E3A8A),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  DocRecord.isDirectorName(list[i]['name'])
                                      ? '최종결재'
                                      : '검토 ${i + 1}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                list[i]['name'] ?? '-',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              Text(
                                list[i]['date'] ?? '-',
                                style: const TextStyle(
                                    fontSize: 11.5, color: Colors.black54),
                              ),
                              // ★ 본인만 결재취소 가능!
                              if (myName.isNotEmpty &&
                                  list[i]['name'] == myName) ...[
                                const SizedBox(width: 6),
                                InkWell(
                                  onTap: () async {
                                    currentRec =
                                        await _removeApprovalFromRecord(
                                      currentRec,
                                      myName,
                                    );
                                    if (onChangedCallback != null) {
                                      await onChangedCallback(currentRec);
                                    }
                                    setModalState(() {});
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 5, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.red.shade50,
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(
                                          color: Colors.red.shade300),
                                    ),
                                    child: const Text(
                                      '결재취소',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: Colors.red,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('닫기'),
              ),
              if (alreadyApprovedByMe)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                  onPressed: () async {
                    currentRec = await _removeApprovalFromRecord(
                      currentRec,
                      myName,
                    );
                    if (onChangedCallback != null) {
                      await onChangedCallback(currentRec);
                    }
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  icon: const Icon(Icons.undo, size: 16),
                  label: Text('$myName 결재취소'),
                )
              else
                FilledButton.icon(
                  onPressed: () async {
                    final uName = await _ensureApproverUserName();
                    if (uName == null || uName.isEmpty) return;
                    currentRec =
                        await _appendApprovalToRecord(currentRec, uName);
                    if (onChangedCallback != null) {
                      await onChangedCallback(currentRec);
                    }
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  icon: const Icon(Icons.check_circle_outline, size: 16),
                  label: const Text('+ 내 검토/결재 추가'),
                ),
            ],
          );
        },
      ),
    );
    return currentRec;
  }

  // ===========================================================================
  // 5단계: 설정(⚙️), 현장공유(☁️ GitHub/OneDrive), HTML내보내기/업로드, PDF내보내기
  // ===========================================================================
  String _buildEffectiveGithubFolder(String rawSiteName) {
    final clean = rawSiteName
        .trim()
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    if (clean.isEmpty || clean == '현장공유방') {
      return '현장공유방';
    }
    if (clean.startsWith('현장공유방/')) {
      return clean;
    }
    return '현장공유방/$clean';
  }

  Future<void> _openSettingsDialog() async {
    final userNameCtrl = TextEditingController(text: _exporterUserName);
    final repoCtrl = TextEditingController(text: _githubRepo);
    final tokenCtrl = TextEditingController(text: _githubToken);
    final folderCtrl = TextEditingController(text: _githubFolder);
    final oneDriveUrlCtrl = TextEditingController(text: _oneDriveShareUrl);
    final geminiCtrl = TextEditingController(text: _geminiApiKey);
    String tempMode = _shareRoomMode;
    bool testingGemini = false;
    String testResultMsg = _lastGeminiStatusMsg;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return AlertDialog(
            title: const Text(
              '⚙️ 현장공유 및 AI 설정',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            content: SizedBox(
              width: 400,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildField(
                      userNameCtrl,
                      '내 이름 / 담당자명 (소장님은 이름에 "소장" 포함)',
                      '예: 이경훈, 김철수 소장',
                    ),
                    const Divider(height: 18),
                    const Text(
                      '☁️ 현장공유방 연동 방식 선택',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1E3A8A),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: ChoiceChip(
                            label: const Text('🐙 GitHub 자동동기화',
                                style: TextStyle(fontSize: 11.5)),
                            selected: tempMode == 'github',
                            onSelected: (_) =>
                                setModalState(() => tempMode = 'github'),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: ChoiceChip(
                            label: const Text('☁️ OneDrive 간편공유',
                                style: TextStyle(fontSize: 11.5)),
                            selected: tempMode == 'onedrive',
                            onSelected: (_) =>
                                setModalState(() => tempMode = 'onedrive'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (tempMode == 'github') ...[
                      _buildField(
                        repoCtrl,
                        'GitHub 저장소 (아이디/저장소명)',
                        '예: tectura77/field-share',
                      ),
                      _buildField(
                        tokenCtrl,
                        'GitHub 토큰 (ghp_...)',
                        '예: ghp_xxxxxxxxxxxx',
                      ),
                      _buildField(
                        folderCtrl,
                        '현장명 (현장공유방 하위 폴더 이름)',
                        '○○현장',
                      ),
                    ] else ...[
                      _buildField(
                        oneDriveUrlCtrl,
                        'OneDrive 공유폴더 링크 (선택사항)',
                        '비워두면 스마트폰 OneDrive 앱 공유로 작동합니다',
                      ),
                    ],
                    const Divider(height: 18),
                    const Text(
                      '✨ Google Gemini AI 키 (선택사항 - 미입력 시 무료 내장 OCR 작동)',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1E3A8A),
                      ),
                    ),
                    const SizedBox(height: 6),
                    _buildField(
                      geminiCtrl,
                      'Gemini API Key (AQ... 또는 AIza...)',
                      '비워두면 내장 오프라인 한국어 OCR로 작동',
                    ),
                    OutlinedButton.icon(
                      onPressed: testingGemini
                          ? null
                          : () async {
                              setModalState(() {
                                testingGemini = true;
                                testResultMsg = '⏳ Google Gemini 서버 연결 확인 중...';
                              });
                              final res =
                                  await _verifyGeminiApiKey(geminiCtrl.text);
                              final ok = res['ok'] == true;
                              final msg = res['msg']?.toString() ?? '';
                              setState(() {
                                _geminiKeyVerified = ok;
                                _lastGeminiStatusMsg = msg;
                              });
                              setModalState(() {
                                testingGemini = false;
                                testResultMsg = msg;
                              });
                            },
                      icon: testingGemini
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.verified_outlined, size: 16),
                      label: const Text('Gemini API 키 실제 연결 테스트',
                          style: TextStyle(fontSize: 12)),
                    ),
                    if (testResultMsg.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        testResultMsg,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                          color: testResultMsg.startsWith('✅')
                              ? Colors.green.shade800
                              : Colors.red.shade700,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () async {
                  final prefs = await SharedPreferences.getInstance();
                  final uName = userNameCtrl.text.trim();
                  final gRepo = repoCtrl.text.trim();
                  final gToken = tokenCtrl.text.trim();
                  final gFolder = folderCtrl.text.trim();
                  final odUrl = oneDriveUrlCtrl.text.trim();
                  final gKey = geminiCtrl.text.trim();

                  await prefs.setString(_prefsUserNameKey, uName);
                  await prefs.setString(_prefsShareRoomModeKey, tempMode);
                  await prefs.setString(_prefsGithubRepoKey, gRepo);
                  await prefs.setString(_prefsGithubTokenKey, gToken);
                  await prefs.setString(_prefsGithubFolderKey, gFolder);
                  await prefs.setString(_prefsOneDriveShareUrlKey, odUrl);
                  await prefs.setString(_prefsGeminiKey, gKey);

                  setState(() {
                    _exporterUserName = uName;
                    _shareRoomMode = tempMode;
                    _githubRepo = gRepo;
                    _githubToken = gToken;
                    _githubFolder = gFolder;
                    _oneDriveShareUrl = odUrl;
                    _geminiApiKey = gKey;
                  });
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('저장'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // PDF 내보내기 (현재 탭/필터의 항목들을 한 묶음 PDF 파일로 생성 및 공유)
  // ※ PDF변환 탭에서 선택한 항목이 있으면 그 항목의 파일명.pdf로 내보내고,
  //   전체 묶음 내보내기 시에도 각 항목의 추가 페이지들을 모두 순서대로 포함합니다!
  // ---------------------------------------------------------------------------
  Future<void> _exportCurrentTabBundledPdf() async {
    final targetRecords = _filteredRecords;
    if (targetRecords.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('현재 탭에 PDF로 내보낼 항목이 없습니다.')),
      );
      return;
    }

    // 만약 PDF변환 탭이고 선택된 항목이 있으면 해당 항목 단독 내보내기 또는 전체 묶음 선택 가능
    if (_selectedCategoryFilter == DocCategory.pdfConvert &&
        _selectedRecord != null &&
        _selectedRecord!.category == DocCategory.pdfConvert) {
      await _exportSinglePdfConvertRecord(_selectedRecord!);
      return;
    }

    setState(() => _isBusy = true);
    try {
      final doc = pw.Document();
      int addedPages = 0;

      for (final rec in targetRecords) {
        final mainBytes = rec.resolveMainImageBytes();
        if (mainBytes != null && mainBytes.isNotEmpty) {
          final memImg = pw.MemoryImage(mainBytes);
          doc.addPage(
            pw.Page(
              pageFormat: PdfPageFormat.a4,
              margin: const pw.EdgeInsets.all(14),
              build: (pw.Context ctx) => pw.Center(
                child: pw.Image(memImg, fit: pw.BoxFit.contain),
              ),
            ),
          );
          addedPages++;
        }

        // 병원비 추가 증빙첨부 또는 PDF변환 추가 페이지들도 빠짐없이 순서대로 출력
        final extraBytesList = rec.resolveAllProofImageBytes();
        for (final pBytes in extraBytesList) {
          final pImg = pw.MemoryImage(pBytes);
          doc.addPage(
            pw.Page(
              pageFormat: PdfPageFormat.a4,
              margin: const pw.EdgeInsets.all(14),
              build: (pw.Context ctx) => pw.Center(
                child: pw.Image(pImg, fit: pw.BoxFit.contain),
              ),
            ),
          );
          addedPages++;
        }
      }

      if (addedPages == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PDF에 포함할 사진 파일이 없습니다.')),
        );
        return;
      }

      final pdfBytes = await doc.save();
      final tempDir = await getTemporaryDirectory();
      final cleanCat = _selectedCategoryFilter
          .replaceAll('(', '_')
          .replaceAll(')', '')
          .trim();
      final fileName =
          '증빙서류_${cleanCat}_묶음(${targetRecords.length}건_${addedPages}장).pdf';
      final outFile = File(p.join(tempDir.path, fileName));
      await outFile.writeAsBytes(pdfBytes, flush: true);

      await Share.shareXFiles([XFile(outFile.path)]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF 내보내기 오류: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  // ---------------------------------------------------------------------------
  // HTML 내보내기 & HTML 업로드(병합)
  // ---------------------------------------------------------------------------
  List<DocRecord> _parseRecordsFromHtmlContent(String htmlContent) {
    final startIdx = htmlContent.indexOf('/*ARCHIVE_DATA_START*/');
    final endIdx = htmlContent.indexOf('/*ARCHIVE_DATA_END*/');
    if (startIdx == -1 || endIdx == -1 || endIdx <= startIdx) return [];
    final jsonPart =
        htmlContent.substring(startIdx + '/*ARCHIVE_DATA_START*/'.length, endIdx).trim();
    try {
      final decoded = jsonDecode(jsonPart);
      if (decoded is List) {
        return decoded
            .map((e) => DocRecord.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {}
    return [];
  }

  List<DocRecord> _mergeRecordListsSmart(
    List<DocRecord> existingList,
    List<DocRecord> incomingList,
  ) {
    final Map<String, DocRecord> byId = {};
    final Map<String, String> sigToId = {};

    for (final r in existingList) {
      byId[r.id] = r;
      sigToId[r.contentSignature] = r.id;
    }

    for (final inc in incomingList) {
      final matchedId = byId.containsKey(inc.id)
          ? inc.id
          : sigToId[inc.contentSignature];
      if (matchedId != null && byId.containsKey(matchedId)) {
        final old = byId[matchedId]!;
        final mergedFields = Map<String, String>.from(old.fields)
          ..addAll(inc.fields);
        final mergedApprovals = DocRecord.mergeApprovalsJsonStrings(
          old.fields['approvalsJson'],
          inc.fields['approvalsJson'],
        );
        if (mergedApprovals.isNotEmpty) {
          mergedFields['approvalsJson'] = mergedApprovals;
        }
        byId[matchedId] = DocRecord(
          id: old.id,
          category: inc.category,
          createdAt: old.createdAt,
          imagePath: inc.imagePath.isNotEmpty ? inc.imagePath : old.imagePath,
          base64Image:
              inc.base64Image.isNotEmpty ? inc.base64Image : old.base64Image,
          fields: mergedFields,
        );
      } else {
        byId[inc.id] = inc;
        sigToId[inc.contentSignature] = inc.id;
      }
    }

    return byId.values.toList();
  }

  Future<void> _importAndMergeHtmlFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['html', 'htm'],
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;

      setState(() => _isBusy = true);
      int importedCount = 0;
      List<DocRecord> current = List<DocRecord>.from(_records);

      for (final pf in result.files) {
        if (pf.path == null) continue;
        final content = await File(pf.path!).readAsString();
        final parsed = _parseRecordsFromHtmlContent(content);
        if (parsed.isNotEmpty) {
          importedCount += parsed.length;
          current = _mergeRecordListsSmart(current, parsed);
        }
      }

      setState(() {
        _records = current;
        final curFiltered = _filteredRecords;
        if (_selectedRecord == null && curFiltered.isNotEmpty) {
          _selectedRecord = curFiltered.first;
        }
      });
      await _saveLocalRecords();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('HTML 파일에서 총 ${importedCount}건의 데이터를 성공적으로 병합했습니다!'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('HTML 업로드 오류: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _exportCurrentTabHtml() async {
    final targetRecords = _filteredRecords;
    if (targetRecords.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('내보낼 항목이 없습니다.')),
      );
      return;
    }

    setState(() => _isBusy = true);
    try {
      final htmlStr = _buildInteractiveHtmlDocument(
        records: targetRecords,
        scopeTitle: _selectedCategoryFilter,
        majorCat: _selectedCategoryFilter,
        embedBase64Images: true,
      );
      final tempDir = await getTemporaryDirectory();
      final cleanCat = _selectedCategoryFilter
          .replaceAll('(', '_')
          .replaceAll(')', '')
          .trim();
      final fileName = '증빙서류_$cleanCat.html';
      final f = File(p.join(tempDir.path, fileName));
      await f.writeAsString(htmlStr, flush: true);

      await Share.shareXFiles([XFile(f.path)]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('HTML 내보내기 오류: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  String _buildInteractiveHtmlDocument({
    required List<DocRecord> records,
    required String scopeTitle,
    required String majorCat,
    bool embedBase64Images = true,
  }) {
    final List<Map<String, dynamic>> serialized = [];
    for (final r in records) {
      String b64 = '';
      if (embedBase64Images) {
        final bytes = r.resolveMainImageBytes();
        if (bytes != null && bytes.isNotEmpty) {
          b64 = base64Encode(bytes);
        }
      }
      final fieldsCopy = Map<String, String>.from(r.fields);
      if (embedBase64Images &&
          (r.category == DocCategory.medical ||
              r.category == DocCategory.pdfConvert)) {
        final extraBytes = r.resolveAllProofImageBytes();
        if (extraBytes.isNotEmpty) {
          fieldsCopy['proofImagesJson'] =
              jsonEncode(extraBytes.map((b) => base64Encode(b)).toList());
        }
      }
      serialized.add({
        'id': r.id,
        'category': r.category,
        'createdAt': r.createdAt,
        'imagePath': embedBase64Images ? '' : 'photos/doc_${r.id}.jpg',
        'base64Image': b64,
        'fields': fieldsCopy,
      });
    }

    final recordsJson = jsonEncode(serialized);
    final bool isOfficialGroup = DocCategory.isOfficial(majorCat) ||
        records.every((r) => DocCategory.isOfficial(r.category));
    final List<String> allowedTabs = isOfficialGroup
        ? [DocCategory.officialIn, DocCategory.officialOut]
        : [majorCat];
    final allowedTabsJson = jsonEncode(allowedTabs);
    final exporterUserJson = jsonEncode(_exporterUserName);

    return '''<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0" />
  <title>증빙서류 - $scopeTitle</title>
  <style>
    * { box-sizing: border-box; }
    body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Malgun Gothic", sans-serif; background: #f1f5f9; color: #0f172a; height: 100vh; display: flex; flex-direction: column; overflow: hidden; }
    header { background: #1e3a8a; color: #fff; padding: 8px 12px; display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-shrink: 0; }
    .chip-bar { background: #fff; padding: 6px 10px; border-bottom: 1px solid #cbd5e1; display: flex; gap: 6px; overflow-x: auto; flex-shrink: 0; }
    .chip-btn { border: 1px solid #cbd5e1; background: #f8fafc; color: #334155; padding: 5px 11px; border-radius: 999px; font-size: 12px; font-weight: 700; cursor: pointer; white-space: nowrap; }
    .chip-btn.active { background: #1e3a8a; color: #fff; border-color: #1e3a8a; }
    #workspace { flex: 1; display: flex; flex-direction: column; overflow: hidden; }
    @media (orientation: landscape) { #workspace { flex-direction: row; } }
    #list-pane { flex: 0 0 46%; overflow: auto; background: #fff; }
    #resizer-bar { background: #cbd5e1; display: flex; align-items: center; justify-content: center; font-size: 11px; font-weight: 700; color: #1e3a8a; user-select: none; touch-action: none; flex-shrink: 0; }
    @media (orientation: portrait) { #resizer-bar { height: 24px; cursor: row-resize; } }
    @media (orientation: landscape) { #resizer-bar { width: 22px; writing-mode: vertical-rl; cursor: col-resize; } }
    #photo-pane { flex: 1; background: #0f172a; position: relative; overflow: hidden; display: flex; flex-direction: column; }
    #photo-viewport { flex: 1; display: flex; align-items: center; justify-content: center; overflow: hidden; touch-action: none; }
    #preview-img { max-width: 100%; max-height: 100%; object-fit: contain; transform-origin: center center; }
    table { width: max-content; min-width: 100%; border-collapse: collapse; table-layout: fixed; }
    th { position: sticky; top: 0; background: #e2e8f0; color: #1e293b; font-size: 11px; font-weight: 800; border: 1px solid #cbd5e1; padding: 6px 4px; text-align: center; cursor: pointer; z-index: 2; }
    td { border: 1px solid #e2e8f0; padding: 6px 5px; font-size: 11px; text-align: center; word-break: break-word; }
    tr.selected { background: #dbeafe !important; }
  </style>
</head>
<body>
  <header>
    <div style="font-size:14px; font-weight:800;">📂 $scopeTitle</div>
    <div id="major-tabs-bar" style="display:flex; gap:5px;"></div>
  </header>
  <div id="workspace">
    <div id="list-pane"><table id="doc-table"><thead id="doc-thead"></thead><tbody id="doc-tbody"></tbody></table></div>
    <div id="resizer-bar">═ 화면 크기 조절</div>
    <div id="photo-pane">
      <div id="photo-page-bar" style="background:#1e293b; padding:4px 8px; display:none; gap:5px; overflow-x:auto;"></div>
      <div id="photo-viewport"><img id="preview-img" alt="미리보기" /></div>
    </div>
  </div>
  <script>
    const archiveRecords = /*ARCHIVE_DATA_START*/ $recordsJson /*ARCHIVE_DATA_END*/;
    const ALL_TABS = $allowedTabsJson;
    const EXPORTER_USER = $exporterUserJson;
    let selectedCategoryFilter = ALL_TABS[0] || '$majorCat';
    let selectedId = archiveRecords.length > 0 ? archiveRecords[0].id : null;
    let selectedPageIdx = 0;

    function escapeHtml(s) {
      return String(s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }

    function getFiltered() {
      return archiveRecords.filter(function(r) { return r.category === selectedCategoryFilter; });
    }

    function selectRow(id) {
      selectedId = id;
      selectedPageIdx = 0;
      render();
    }

    function render() {
      const tabBar = document.getElementById('major-tabs-bar');
      tabBar.innerHTML = ALL_TABS.map(function(t) {
        const cnt = archiveRecords.filter(function(r) { return r.category === t; }).length;
        const cls = t === selectedCategoryFilter ? 'chip-btn active' : 'chip-btn';
        return '<button class="' + cls + '" onclick="selectedCategoryFilter=\\'' + t + '\\'; render();">' + escapeHtml(t) + ' (' + cnt + ')</button>';
      }).join('');

      const list = getFiltered();
      if (!list.some(function(r) { return r.id === selectedId; })) {
        selectedId = list.length > 0 ? list[0].id : null;
      }

      const thead = document.getElementById('doc-thead');
      const tbody = document.getElementById('doc-tbody');
      if (selectedCategoryFilter === 'PDF변환') {
        thead.innerHTML = '<tr><th style="width:90px;">찍은날짜</th><th style="width:190px;">파일명</th><th style="width:70px;">장수</th></tr>';
        tbody.innerHTML = list.map(function(r) {
          const f = r.fields || {};
          const extra = [];
          try { if (f.proofImagesJson) extra.push.apply(extra, JSON.parse(f.proofImagesJson)); } catch(_) {}
          const pages = 1 + extra.length;
          const sel = r.id === selectedId ? 'selected' : '';
          return '<tr class="' + sel + '" onclick="selectRow(\\'' + r.id + '\\')">' +
            '<td>' + escapeHtml(f.pdfDate || '-') + '</td>' +
            '<td style="font-weight:700; color:#1e3a8a;">' + escapeHtml(f.pdfFileName || '문서스캔') + '.pdf</td>' +
            '<td style="font-weight:700;">' + pages + '장</td></tr>';
        }).join('');
      } else if (selectedCategoryFilter === '자재송장') {
        thead.innerHTML = '<tr><th style="width:82px;">날짜</th><th style="width:92px;">제품명</th><th style="width:105px;">규격명</th><th style="width:50px;">단위</th><th style="width:64px;">수량</th><th style="width:90px;">공급자</th><th style="width:110px;">주문송장번호</th><th style="width:68px;">올린사람</th></tr>';
        tbody.innerHTML = list.map(function(r) {
          const f = r.fields || {};
          const sel = r.id === selectedId ? 'selected' : '';
          return '<tr class="' + sel + '" onclick="selectRow(\\'' + r.id + '\\')">' +
            '<td>' + escapeHtml(f.arrivalDate || '-') + '</td>' +
            '<td>' + escapeHtml(f.productName || '-') + '</td>' +
            '<td>' + escapeHtml(f.specName || '-') + '</td>' +
            '<td>' + escapeHtml(f.unit || '-') + '</td>' +
            '<td style="font-weight:700;">' + escapeHtml(f.quantity || '-') + '</td>' +
            '<td>' + escapeHtml(f.supplierName || '-') + '</td>' +
            '<td>' + escapeHtml(f.orderNumber || '-') + '</td>' +
            '<td>' + escapeHtml(f.uploader || '-') + '</td></tr>';
        }).join('');
      } else {
        thead.innerHTML = '<tr><th style="width:82px;">날짜</th><th style="width:95px;">공문번호</th><th style="width:95px;">보낸/받는사람</th><th style="width:140px;">제목</th><th style="width:170px;">내용</th><th style="width:68px;">올린사람</th></tr>';
        tbody.innerHTML = list.map(function(r) {
          const f = r.fields || {};
          const sel = r.id === selectedId ? 'selected' : '';
          return '<tr class="' + sel + '" onclick="selectRow(\\'' + r.id + '\\')">' +
            '<td>' + escapeHtml(f.sentDate || f.date || f.issueDate || f.cardDate || '-') + '</td>' +
            '<td>' + escapeHtml(f.docNumber || '-') + '</td>' +
            '<td>' + escapeHtml(f.sender || f.recipient || f.clinicName || f.merchantName || f.companyName || '-') + '</td>' +
            '<td>' + escapeHtml(f.title || f.personName || '-') + '</td>' +
            '<td>' + escapeHtml(f.aiSummary || f.totalPaid || f.totalAmount || f.mobilePhone || '-') + '</td>' +
            '<td>' + escapeHtml(f.uploader || '-') + '</td></tr>';
        }).join('');
      }

      const cur = list.find(function(r) { return r.id === selectedId; });
      const imgEl = document.getElementById('preview-img');
      const pageBar = document.getElementById('photo-page-bar');
      if (!cur) {
        imgEl.removeAttribute('src');
        pageBar.style.display = 'none';
        return;
      }
      const pages = [cur.base64Image ? ('data:image/jpeg;base64,' + cur.base64Image) : (cur.imagePath || '')];
      try {
        if (cur.fields && cur.fields.proofImagesJson) {
          const arr = JSON.parse(cur.fields.proofImagesJson);
          arr.forEach(function(b) { pages.push('data:image/jpeg;base64,' + b); });
        }
      } catch(_) {}
      if (pages.length > 1) {
        pageBar.style.display = 'flex';
        pageBar.innerHTML = pages.map(function(_, idx) {
          const cls = idx === selectedPageIdx ? 'chip-btn active' : 'chip-btn';
          return '<button class="' + cls + '" onclick="selectedPageIdx=' + idx + '; render();">' + (idx + 1) + '페이지</button>';
        }).join('');
      } else {
        pageBar.style.display = 'none';
      }
      imgEl.src = pages[selectedPageIdx] || pages[0] || '';
    }

    render();
  </script>
</body>
</html>''';
  }

  // ---------------------------------------------------------------------------
  // GitHub / OneDrive 현장공유방 연동 (사진 파일 photos/ 분리 업로드 & PC 바로가기)
  // ---------------------------------------------------------------------------
  Map<String, String> _githubHeaders(String token) => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  Future<void> _cancelRunningGithubWorkflowsIfAny(
      String repo, String token) async {
    try {
      final uri = Uri.parse(
          'https://api.github.com/repos/$repo/actions/runs?status=in_progress');
      final resp = await http
          .get(uri, headers: _githubHeaders(token))
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        final decoded =
            jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
        final runs = decoded['workflow_runs'] as List<dynamic>? ?? [];
        for (final r in runs) {
          if (r is Map && r['id'] != null) {
            final cancelUri = Uri.parse(
                'https://api.github.com/repos/$repo/actions/runs/${r['id']}/cancel');
            await http.post(cancelUri, headers: _githubHeaders(token));
          }
        }
      }
    } catch (_) {}
  }

  Future<Map<String, String>?> _fetchGithubFileContentAndSha({
    required String repo,
    required String token,
    required String pathInRepo,
  }) async {
    final encodedPath =
        pathInRepo.split('/').map(Uri.encodeComponent).join('/');
    final uri =
        Uri.parse('https://api.github.com/repos/$repo/contents/$encodedPath');
    final resp = await http
        .get(uri, headers: _githubHeaders(token))
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) return null;
    final decoded =
        jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final sha = decoded['sha']?.toString() ?? '';
    final downloadUrl = decoded['download_url']?.toString() ?? '';
    String contentStr = '';
    final rawContent =
        (decoded['content']?.toString() ?? '').replaceAll(RegExp(r'\s+'), '');
    if (rawContent.isNotEmpty) {
      contentStr = utf8.decode(base64Decode(rawContent), allowMalformed: true);
    } else if (downloadUrl.isNotEmpty) {
      final rawResp = await http
          .get(Uri.parse(downloadUrl))
          .timeout(const Duration(seconds: 15));
      if (rawResp.statusCode == 200) {
        contentStr = utf8.decode(rawResp.bodyBytes, allowMalformed: true);
      }
    }
    return {'sha': sha, 'content': contentStr};
  }

  Future<bool> _putGithubFileBytes({
    required String repo,
    required String token,
    required String pathInRepo,
    required List<int> bytes,
    required String message,
    String? sha,
  }) async {
    final encodedPath =
        pathInRepo.split('/').map(Uri.encodeComponent).join('/');
    final uri =
        Uri.parse('https://api.github.com/repos/$repo/contents/$encodedPath');
    final Map<String, dynamic> body = {
      'message': '$message [skip ci]',
      'content': base64Encode(bytes),
    };
    if (sha != null && sha.isNotEmpty) {
      body['sha'] = sha;
    }
    final resp = await http
        .put(
          uri,
          headers: {
            ..._githubHeaders(token),
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    _cancelRunningGithubWorkflowsIfAny(repo, token);
    return resp.statusCode == 200 || resp.statusCode == 201;
  }

  Future<Set<String>> _listExistingPhotoFileNamesInGithub({
    required String repo,
    required String token,
    required String folderPath,
  }) async {
    final Set<String> names = {};
    try {
      final photosDir = '$folderPath/photos';
      final encodedPath =
          photosDir.split('/').map(Uri.encodeComponent).join('/');
      final uri =
          Uri.parse('https://api.github.com/repos/$repo/contents/$encodedPath');
      final resp = await http
          .get(uri, headers: _githubHeaders(token))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map && item['name'] != null) {
              names.add(item['name'].toString());
            }
          }
        }
      }
    } catch (_) {}
    return names;
  }

  Future<void> _syncAndMergeCategoryWithGithubRoom({
    required bool isOfficialRoom,
    required bool openViewerAfterSync,
  }) async {
    final repo = _githubRepo.trim();
    final token = _githubToken.trim();
    final effFolder = _buildEffectiveGithubFolder(_githubFolder);
    final fileName = isOfficialRoom ? '공문_통합.html' : '자재송장_통합.html';
    final pathInRepo = '$effFolder/$fileName';

    if (repo.isEmpty || token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('먼저 ⚙️ 설정에서 GitHub 저장소와 토큰을 입력해주세요.')),
      );
      return;
    }

    setState(() => _isBusy = true);
    try {
      final remoteData = await _fetchGithubFileContentAndSha(
        repo: repo,
        token: token,
        pathInRepo: pathInRepo,
      );

      final List<DocRecord> remoteRecords = remoteData != null
          ? _parseRecordsFromHtmlContent(remoteData['content'] ?? '')
          : <DocRecord>[];

      final List<DocRecord> myRoomRecords = _records.where((r) {
        return isOfficialRoom
            ? DocCategory.isOfficial(r.category)
            : r.category == DocCategory.invoice;
      }).toList();

      final List<DocRecord> mergedRoomRecords =
          _mergeRecordListsSmart(remoteRecords, myRoomRecords);

      final existingPhotos = await _listExistingPhotoFileNamesInGithub(
        repo: repo,
        token: token,
        folderPath: effFolder,
      );

      for (final rec in mergedRoomRecords) {
        final photoName = 'doc_${rec.id}.jpg';
        if (!existingPhotos.contains(photoName)) {
          final imgBytes = rec.resolveMainImageBytes();
          if (imgBytes != null && imgBytes.isNotEmpty) {
            await _putGithubFileBytes(
              repo: repo,
              token: token,
              pathInRepo: '$effFolder/photos/$photoName',
              bytes: imgBytes,
              message: 'Upload photo $photoName',
            );
          }
        }
      }

      final htmlStr = _buildInteractiveHtmlDocument(
        records: mergedRoomRecords,
        scopeTitle: isOfficialRoom ? '공문_통합' : '자재송장_통합',
        majorCat:
            isOfficialRoom ? DocCategory.officialIn : DocCategory.invoice,
        embedBase64Images: false,
      );

      await _putGithubFileBytes(
        repo: repo,
        token: token,
        pathInRepo: pathInRepo,
        bytes: utf8.encode(htmlStr),
        message: 'Sync $fileName',
        sha: remoteData?['sha'],
      );

      final otherRecords = _records.where((r) {
        return isOfficialRoom
            ? !DocCategory.isOfficial(r.category)
            : r.category != DocCategory.invoice;
      }).toList();

      setState(() {
        _records = [...mergedRoomRecords, ...otherRecords];
      });
      await _saveLocalRecords();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                '✅ $effFolder/$fileName 동기화 완료! (총 ${mergedRoomRecords.length}건)'),
          ),
        );
      }

      if (openViewerAfterSync && mounted) {
        setState(() {
          _selectedCategoryFilter =
              isOfficialRoom ? DocCategory.officialIn : DocCategory.invoice;
          final cur = _filteredRecords;
          if (cur.isNotEmpty) _selectedRecord = cur.first;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('현장공유방 연동 오류: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _exportPcShortcutLauncherHtml() async {
    final repo = _githubRepo.trim();
    final token = _githubToken.trim();
    final effFolder = _buildEffectiveGithubFolder(_githubFolder);
    if (repo.isEmpty || token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('먼저 ⚙️ 설정에서 GitHub 저장소와 토큰을 입력해주세요.')),
      );
      return;
    }

    final encodedCfg = base64Encode(utf8.encode(jsonEncode({
      'r': repo,
      't': token,
      'f': effFolder,
    })));

    final html = '''<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="UTF-8" />
  <title>현장공유방 PC 바로가기</title>
  <style>
    body { margin:0; font-family: "Malgun Gothic", sans-serif; background:#0f172a; color:#fff; display:flex; flex-direction:column; height:100vh; }
    header { background:#1e3a8a; padding:10px 16px; display:flex; justify-content:space-between; align-items:center; }
    button { background:#f59e0b; color:#0f172a; border:none; padding:7px 14px; border-radius:6px; font-weight:800; cursor:pointer; margin-left:6px; }
    #main { flex:1; display:flex; overflow:hidden; background:#fff; color:#0f172a; }
    #left { flex:0 0 54%; overflow:auto; border-right:2px solid #cbd5e1; }
    #right { flex:1; background:#0f172a; display:flex; align-items:center; justify-content:center; }
    #right img { max-width:100%; max-height:100%; object-fit:contain; }
    table { width:100%; border-collapse:collapse; font-size:12px; }
    th { background:#e2e8f0; padding:8px 5px; border:1px solid #cbd5e1; position:sticky; top:0; }
    td { padding:7px 5px; border:1px solid #e2e8f0; text-align:center; }
    tr:hover { background:#f1f5f9; cursor:pointer; }
  </style>
</head>
<body>
  <header>
    <div style="font-weight:900; font-size:15px;">☁️ 현장공유방 실시간 뷰어 ($effFolder)</div>
    <div>
      <button onclick="loadRoom('공문_통합.html')">📄 공문 통합</button>
      <button onclick="loadRoom('자재송장_통합.html')">📦 자재송장 통합</button>
    </div>
  </header>
  <div id="main">
    <div id="left"><table id="tbl"><thead id="th"></thead><tbody id="tb"></tbody></table></div>
    <div id="right"><img id="viewer" alt="문서 사진을 선택하세요" /></div>
  </div>
  <script>
    const cfg = JSON.parse(decodeURIComponent(escape(atob('$encodedCfg'))));
    let currentRecords = [];
    async function loadRoom(fileName) {
      const path = (cfg.f + '/' + fileName).split('/').map(encodeURIComponent).join('/');
      const resp = await fetch('https://api.github.com/repos/' + cfg.r + '/contents/' + path, {
        headers: { 'Authorization': 'Bearer ' + cfg.t, 'Accept': 'application/vnd.github+json' }
      });
      if (!resp.ok) { alert('데이터가 아직 없거나 접근할 수 없습니다.'); return; }
      const meta = await resp.json();
      let html = '';
      if (meta.content) {
        html = decodeURIComponent(escape(atob(meta.content.replace(/\\s+/g, ''))));
      } else if (meta.download_url) {
        const r2 = await fetch(meta.download_url);
        html = await r2.text();
      }
      const s = html.indexOf('/*ARCHIVE_DATA_START*/');
      const e = html.indexOf('/*ARCHIVE_DATA_END*/');
      if (s === -1 || e === -1) return;
      currentRecords = JSON.parse(html.substring(s + 22, e));
      renderTable(fileName.indexOf('자재') !== -1);
    }
    function renderTable(isInv) {
      const th = document.getElementById('th');
      const tb = document.getElementById('tb');
      if (isInv) {
        th.innerHTML = '<tr><th>날짜</th><th>제품명</th><th>규격명</th><th>단위</th><th>수량</th><th>공급자</th><th>주문송장번호</th><th>올린사람</th></tr>';
        tb.innerHTML = currentRecords.map(function(r, i) {
          const f = r.fields || {};
          return '<tr onclick="showPhoto(' + i + ')"><td>' + (f.arrivalDate||'-') + '</td><td>' + (f.productName||'-') + '</td><td>' + (f.specName||'-') + '</td><td>' + (f.unit||'-') + '</td><td>' + (f.quantity||'-') + '</td><td>' + (f.supplierName||'-') + '</td><td>' + (f.orderNumber||'-') + '</td><td>' + (f.uploader||'-') + '</td></tr>';
        }).join('');
      } else {
        th.innerHTML = '<tr><th>구분</th><th>날짜</th><th>공문번호</th><th>보낸/받는사람</th><th>제목</th><th>내용</th><th>올린사람</th></tr>';
        tb.innerHTML = currentRecords.map(function(r, i) {
          const f = r.fields || {};
          return '<tr onclick="showPhoto(' + i + ')"><td>' + r.category + '</td><td>' + (f.sentDate||'-') + '</td><td>' + (f.docNumber||'-') + '</td><td>' + (f.sender||f.recipient||'-') + '</td><td>' + (f.title||'-') + '</td><td>' + (f.aiSummary||'-') + '</td><td>' + (f.uploader||'-') + '</td></tr>';
        }).join('');
      }
      if (currentRecords.length > 0) showPhoto(0);
    }
    async function showPhoto(idx) {
      const r = currentRecords[idx];
      if (!r) return;
      const img = document.getElementById('viewer');
      if (r.base64Image) { img.src = 'data:image/jpeg;base64,' + r.base64Image; return; }
      const pPath = (cfg.f + '/photos/doc_' + r.id + '.jpg').split('/').map(encodeURIComponent).join('/');
      const resp = await fetch('https://api.github.com/repos/' + cfg.r + '/contents/' + pPath, {
        headers: { 'Authorization': 'Bearer ' + cfg.t, 'Accept': 'application/vnd.github+json' }
      });
      if (resp.ok) {
        const m = await resp.json();
        if (m.content) img.src = 'data:image/jpeg;base64,' + m.content.replace(/\\s+/g, '');
        else if (m.download_url) img.src = m.download_url;
      }
    }
    loadRoom('공문_통합.html');
  </script>
</body>
</html>''';

    final tempDir = await getTemporaryDirectory();
    final f = File(p.join(tempDir.path, '현장공유방_PC바로가기.html'));
    await f.writeAsString(html, flush: true);
    await Share.shareXFiles([XFile(f.path)]);
  }

  Future<void> _openFieldShareRoomDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final effFolder = _buildEffectiveGithubFolder(_githubFolder);
          return AlertDialog(
            title: const Text(
              '☁️ 현장 공유방 (공문 · 자재송장 통합)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            content: SizedBox(
              width: 390,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: ChoiceChip(
                            label: const Text('🐙 GitHub 방식',
                                style: TextStyle(fontSize: 12)),
                            selected: _shareRoomMode == 'github',
                            onSelected: (_) async {
                              setState(() => _shareRoomMode = 'github');
                              setModalState(() {});
                              final prefs =
                                  await SharedPreferences.getInstance();
                              await prefs.setString(
                                  _prefsShareRoomModeKey, 'github');
                            },
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: ChoiceChip(
                            label: const Text('☁️ OneDrive 방식',
                                style: TextStyle(fontSize: 12)),
                            selected: _shareRoomMode == 'onedrive',
                            onSelected: (_) async {
                              setState(() => _shareRoomMode = 'onedrive');
                              setModalState(() {});
                              final prefs =
                                  await SharedPreferences.getInstance();
                              await prefs.setString(
                                  _prefsShareRoomModeKey, 'onedrive');
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.indigo.shade50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.indigo.shade200),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '📄 1. 공문 HTML ($effFolder/공문_통합.html)',
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF1E3A8A),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    _syncAndMergeCategoryWithGithubRoom(
                                      isOfficialRoom: true,
                                      openViewerAfterSync: false,
                                    );
                                  },
                                  icon:
                                      const Icon(Icons.cloud_upload, size: 16),
                                  label: const Text('올려서 합치기',
                                      style: TextStyle(fontSize: 12)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    _syncAndMergeCategoryWithGithubRoom(
                                      isOfficialRoom: true,
                                      openViewerAfterSync: true,
                                    );
                                  },
                                  icon: const Icon(Icons.visibility, size: 16),
                                  label: const Text('들어가서 보기',
                                      style: TextStyle(fontSize: 12)),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.amber.shade300),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '📦 2. 자재송장 HTML ($effFolder/자재송장_통합.html)',
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF92400E),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xFFB45309),
                                  ),
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    _syncAndMergeCategoryWithGithubRoom(
                                      isOfficialRoom: false,
                                      openViewerAfterSync: false,
                                    );
                                  },
                                  icon:
                                      const Icon(Icons.cloud_upload, size: 16),
                                  label: const Text('올려서 합치기',
                                      style: TextStyle(fontSize: 12)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    _syncAndMergeCategoryWithGithubRoom(
                                      isOfficialRoom: false,
                                      openViewerAfterSync: true,
                                    );
                                  },
                                  icon: const Icon(Icons.visibility, size: 16),
                                  label: const Text('들어가서 보기',
                                      style: TextStyle(fontSize: 12)),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _exportPcShortcutLauncherHtml();
                      },
                      icon: const Icon(Icons.desktop_windows, size: 16),
                      label: const Text(
                        '💻 PC용 현장공유방 바로가기(1회 설치용) 보내기',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('닫기'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ===========================================================================
  // 6단계: 상단 액션 바, 7개 탭 바(PDF변환 포함), 테이블 리스트, 하단/우측 사진 뷰어
  // ===========================================================================
  static const double _kTableHeaderHeight = 40.0;
  static const double _kTableDataRowHeight = 48.0;

  Widget _buildTopActionBtn({
    required IconData icon,
    required String label,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Material(
        color: Colors.white.withOpacity(0.14),
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: _isBusy ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 12.5, color: iconColor),
                const SizedBox(width: 3),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFixedHeaderCell(
    String text,
    double width, {
    String? sortKey,
    VoidCallback? onHeaderTap,
    bool isHighlightedGroup = false,
  }) {
    final bool isSorted = sortKey != null && _sortColumn == sortKey;
    String displayLabel = text;
    if (sortKey != null) {
      if (isSorted) {
        final String arrow = _sortAscending ? '▲' : '▼';
        displayLabel = '$text\n$arrow';
      } else {
        displayLabel = '$text ↕';
      }
    }
    return InkWell(
      onTap: onHeaderTap ??
          (sortKey != null ? () => _toggleSortColumn(sortKey) : null),
      child: Container(
        width: width,
        height: _kTableHeaderHeight,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        decoration: BoxDecoration(
          color: isHighlightedGroup
              ? Colors.amber.shade100
              : (isSorted ? const Color(0xFFDBEAFE) : const Color(0xFFE2E8F0)),
          border: const Border(
            right: BorderSide(color: Color(0xFFCBD5E1), width: 1),
            bottom: BorderSide(color: Color(0xFFCBD5E1), width: 1.2),
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          displayLabel,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11.5,
            height: 1.15,
            fontWeight: FontWeight.w900,
            color: isHighlightedGroup
                ? const Color(0xFF92400E)
                : (isSorted
                    ? const Color(0xFF1E3A8A)
                    : const Color(0xFF1E293B)),
          ),
        ),
      ),
    );
  }

  Widget _buildFixedDataCell(
    String text,
    double width, {
    bool bold = false,
    Color? textColor,
    VoidCallback? onTap,
  }) {
    final content = Container(
      width: width,
      height: _kTableDataRowHeight,
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      decoration: const BoxDecoration(
        border: Border(
          right: BorderSide(color: Color(0xFFE2E8F0), width: 1),
          bottom: BorderSide(color: Color(0xFFE2E8F0), width: 1),
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        text.trim().isEmpty ? '-' : text,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        softWrap: true,
        style: TextStyle(
          fontSize: 11.5,
          height: 1.2,
          fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
          color: textColor ?? const Color(0xFF0F172A),
        ),
      ),
    );
    if (onTap != null) {
      return InkWell(onTap: onTap, child: content);
    }
    return content;
  }

  Widget _buildEditDeleteActionCell(DocRecord rec, double width) {
    return Container(
      width: width,
      height: _kTableDataRowHeight,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      decoration: const BoxDecoration(
        border: Border(
          right: BorderSide(color: Color(0xFFE2E8F0), width: 1),
          bottom: BorderSide(color: Color(0xFFE2E8F0), width: 1),
        ),
      ),
      alignment: Alignment.center,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          InkWell(
            onTap: () => _editRecordDialog(rec),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.edit_outlined,
                  size: 16, color: Color(0xFF1E3A8A)),
            ),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: () => _deleteRecord(rec),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.delete_outline, size: 16, color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildApprovalCell(DocRecord rec, double width) {
    final label = rec.approvalStatusLabel;
    final entries = rec.approvalEntries;
    final bool isDone = rec.isDirectorApprovalCompleted;
    final bool hasReview = entries.isNotEmpty;

    Color bg = Colors.grey.shade100;
    Color fg = Colors.blueGrey.shade800;
    Color borderCol = Colors.grey.shade400;
    if (isDone) {
      bg = Colors.green.shade50;
      fg = Colors.green.shade800;
      borderCol = Colors.green.shade400;
    } else if (hasReview) {
      bg = Colors.blue.shade50;
      fg = const Color(0xFF1E3A8A);
      borderCol = Colors.blue.shade300;
    }

    return Container(
      width: width,
      height: _kTableDataRowHeight,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: const BoxDecoration(
        border: Border(
          right: BorderSide(color: Color(0xFFE2E8F0), width: 1),
          bottom: BorderSide(color: Color(0xFFE2E8F0), width: 1),
        ),
      ),
      alignment: Alignment.center,
      child: InkWell(
        onTap: () => _handleApprovalCellTap(rec),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: borderCol),
          ),
          child: Text(
            hasReview && !isDone ? '검토(${entries.length})' : label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryAndSubCategoryBar() {
    final cat = _selectedCategoryFilter;
    // ★ 공문(수신), 공문(발신), 그리고 PDF변환 탭은 3번째 줄 요약/PDF공유 바를 표시하지 않음! (맨 위 PDF내보내기 사용)
    if (DocCategory.isOfficial(cat) || cat == DocCategory.pdfConvert) {
      return const SizedBox.shrink();
    }

    if (cat == DocCategory.businessCard) {
      final allCards = _records
          .where((r) => r.category == DocCategory.businessCard)
          .length;
      final filteredCards = _filteredRecords.length;
      return Container(
        width: double.infinity,
        color: const Color(0xFFF8FAFC),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 34,
                child: TextField(
                  controller: _businessCardSearchCtrl,
                  onChanged: (v) =>
                      setState(() => _businessCardSearchQuery = v),
                  style: const TextStyle(fontSize: 12.5),
                  decoration: InputDecoration(
                    hintText: '🔍 회사명, 현장명, 이름으로 명함 검색...',
                    prefixIcon: const Icon(Icons.search, size: 17),
                    suffixIcon: _businessCardSearchQuery.isNotEmpty
                        ? IconButton(
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.clear, size: 16),
                            onPressed: () {
                              _businessCardSearchCtrl.clear();
                              setState(() => _businessCardSearchQuery = '');
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF1E3A8A),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _businessCardSearchQuery.isEmpty
                    ? '총 ${allCards}명'
                    : '${filteredCards} / ${allCards}명',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (cat == DocCategory.invoice) {
      final prods = _invoiceProductNamesInCurrentPeriod;
      return Container(
        width: double.infinity,
        color: const Color(0xFFF8FAFC),
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                InkWell(
                  onTap: () => _openPeriodFilterDialog(DocCategory.invoice),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E3A8A),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '📅 기간필터: ${_currentPeriodButtonLabel(DocCategory.invoice)} ▼',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 26),
                  onPressed: () => _shiftPeriodMonth(DocCategory.invoice, -1),
                  icon: const Icon(Icons.chevron_left, size: 18),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 26),
                  onPressed: () => _shiftPeriodMonth(DocCategory.invoice, 1),
                  icon: const Icon(Icons.chevron_right, size: 18),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _currentPeriodRangeDescription(DocCategory.invoice),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1E3A8A),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '📊 합산기준: $_invoiceSummaryModeLabel (표의 [제품명]·[규격명] 제목을 누르면 합산 기준 전환)',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Color(0xFF92400E),
              ),
            ),
            const SizedBox(height: 4),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: prods.map((pKey) {
                  final isSel = _selectedInvoiceProductFilter == pKey;
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      visualDensity: VisualDensity.compact,
                      selectedColor: Colors.amber.shade300,
                      label: Text(
                        _invoiceProductChipLabel(pKey),
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      selected: isSel,
                      onSelected: (_) {
                        setState(() => _selectedInvoiceProductFilter = pKey);
                      },
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      );
    }

    // 출장비 또는 병원비
    final majorSum = _sumByMajorCategory(cat);
    final majorCnt = _recordsInSelectedMajorCategory.length;
    final subCats = _userRegisteredSubCategoriesForCurrentTab;
    final subSelectedSum = _sumBySubCategory(_selectedSubCategoryFilter);

    return Container(
      width: double.infinity,
      color: const Color(0xFFF8FAFC),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (cat == DocCategory.medical)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                children: [
                  InkWell(
                    onTap: _openMedicalDateFilterDialog,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E3A8A),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '📅 날짜필터: ${_currentPeriodButtonLabel(DocCategory.medical)} ▼',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _currentPeriodRangeDescription(DocCategory.medical),
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1E3A8A),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '$cat 합계 (${majorCnt}건): ${NumberFormat('#,###').format(majorSum)}원',
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF1E3A8A),
                      ),
                    ),
                    if (_selectedSubCategoryFilter != '전체')
                      Text(
                        '[${_selectedSubCategoryFilter} 합계: ${NumberFormat('#,###').format(subSelectedSum)}원]',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1E3A8A),
                        ),
                      ),
                  ],
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                onPressed: () => _promptAddNewSubCategory(cat),
                icon: const Icon(Icons.add, size: 15),
                label: const Text('+ 카테고리',
                    style: TextStyle(fontSize: 11.5)),
              ),
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: subCats.map((sc) {
                final isSel = _selectedSubCategoryFilter == sc;
                final cnt = _countBySubCategory(sc);
                final sum = _sumBySubCategory(sc);
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: InputChip(
                    visualDensity: VisualDensity.compact,
                    selected: isSel,
                    label: Text(
                      '$sc (${cnt}건 · ${NumberFormat('#,###').format(sum)}원)',
                      style: const TextStyle(
                          fontSize: 11.5, fontWeight: FontWeight.bold),
                    ),
                    onSelected: (_) =>
                        setState(() => _selectedSubCategoryFilter = sc),
                    onDeleted: (sc != '전체' &&
                            sc != '미지정' &&
                            (_userSubCategoriesMap[cat] ?? []).contains(sc))
                        ? () => _deleteUserSubCategory(cat, sc)
                        : null,
                  ),
                );
              }).toList(),
            ),
          ),
          if (cat == DocCategory.travel) ...[
            const SizedBox(height: 4),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: ['전체', ...TravelDivision.list].map((div) {
                  final isSel = _selectedTravelDivisionFilter == div;
                  final cnt = _countByTravelDivision(div);
                  final sum = _sumByTravelDivision(div);
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      visualDensity: VisualDensity.compact,
                      selectedColor: Colors.amber.shade300,
                      selected: isSel,
                      label: Text(
                        div == '전체'
                            ? '구분전체 (${cnt}건)'
                            : '$div (${NumberFormat('#,###').format(sum)}원)',
                        style: const TextStyle(
                            fontSize: 11.5, fontWeight: FontWeight.bold),
                      ),
                      onSelected: (_) =>
                          setState(() => _selectedTravelDivisionFilter = div),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
          if (cat == DocCategory.medical) ...[
            const SizedBox(height: 4),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final st in ['전체', '미청구', '청구완료'])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        visualDensity: VisualDensity.compact,
                        selectedColor: Colors.teal.shade200,
                        selected: _selectedMedicalClaimFilter == st,
                        label: Text(
                          st == '전체'
                              ? '청구전체 (${_countByMedicalClaimStatus(st)}건)'
                              : '$st (${_countByMedicalClaimStatus(st)}건 · ${NumberFormat('#,###').format(_sumByMedicalClaimStatus(st))}원)',
                          style: const TextStyle(
                              fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                        onSelected: (_) =>
                            setState(() => _selectedMedicalClaimFilter = st),
                      ),
                    ),
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: Colors.indigo.shade50,
                    label: const Text(
                      '☑ 현재목록 일괄체크',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1E3A8A),
                      ),
                    ),
                    onPressed: () =>
                        _bulkToggleMedicalClaimed(_filteredRecords),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRecordTableSection(List<DocRecord> list) {
    if (list.isEmpty) {
      return Center(
        child: Text(
          '등록된 $_selectedCategoryFilter 항목이 없습니다.\n우측 하단 촬영 버튼으로 사진을 추가하세요.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.black54, fontSize: 13),
        ),
      );
    }

    final cat = _selectedCategoryFilter;
    final repliedKeys = _computeRepliedDocNumKeys(_records);
    final cumulativeMap = _computeInvoiceCumulativeMap(_records);

    Widget buildHeaderRow() {
      if (cat == DocCategory.officialIn) {
        return Row(
          children: [
            _buildFixedHeaderCell('날짜', 82, sortKey: 'date'),
            _buildFixedHeaderCell('공문번호', 96, sortKey: 'docNumber'),
            _buildFixedHeaderCell('보낸사람', 92, sortKey: 'clinic'),
            _buildFixedHeaderCell('제목', 142),
            _buildFixedHeaderCell('내용', 168),
            _buildFixedHeaderCell('회신요청일', 82),
            _buildFixedHeaderCell('회신완료', 64, sortKey: 'replied'),
            _buildFixedHeaderCell('올린사람', 68, sortKey: 'uploader'),
            _buildFixedHeaderCell('결재', 74),
            _buildFixedHeaderCell('수정/삭제', 68),
          ],
        );
      } else if (cat == DocCategory.officialOut) {
        return Row(
          children: [
            _buildFixedHeaderCell('날짜', 82, sortKey: 'date'),
            _buildFixedHeaderCell('공문번호', 96, sortKey: 'docNumber'),
            _buildFixedHeaderCell('받는사람', 92, sortKey: 'clinic'),
            _buildFixedHeaderCell('회신번호', 96),
            _buildFixedHeaderCell('제목', 142),
            _buildFixedHeaderCell('내용', 168),
            _buildFixedHeaderCell('올린사람', 68, sortKey: 'uploader'),
            _buildFixedHeaderCell('결재', 74),
            _buildFixedHeaderCell('수정/삭제', 68),
          ],
        );
      } else if (cat == DocCategory.invoice) {
        return Row(
          children: [
            _buildFixedHeaderCell('날짜', 82, sortKey: 'date'),
            _buildFixedHeaderCell(
              '제품명 ${_invSumByProduct ? "✓" : ""}',
              92,
              onHeaderTap: () {
                _toggleInvoiceGroupHeader('product');
                _toggleSortColumn('product');
              },
              isHighlightedGroup: _invSumByProduct,
            ),
            _buildFixedHeaderCell(
              '규격명 ${_invSumBySpec ? "✓" : ""}',
              110,
              onHeaderTap: () {
                _toggleInvoiceGroupHeader('spec');
                _toggleSortColumn('spec');
              },
              isHighlightedGroup: _invSumBySpec,
            ),
            _buildFixedHeaderCell('단위', 52),
            _buildFixedHeaderCell('수량', 66),
            _buildFixedHeaderCell('누적수량', 72),
            _buildFixedHeaderCell('공급자', 92, sortKey: 'supplier'),
            _buildFixedHeaderCell('주문송장번호', 112),
            _buildFixedHeaderCell('올린사람', 68, sortKey: 'uploader'),
            _buildFixedHeaderCell('결재', 74),
            _buildFixedHeaderCell('수정/삭제', 68),
          ],
        );
      } else if (cat == DocCategory.travel) {
        return Row(
          children: [
            _buildFixedHeaderCell('카테고리(날짜)', 106, sortKey: 'date'),
            _buildFixedHeaderCell('구분', 64),
            _buildFixedHeaderCell('상호', 140, sortKey: 'clinic'),
            _buildFixedHeaderCell('금액', 88, sortKey: 'amount'),
            _buildFixedHeaderCell('수정/삭제', 68),
          ],
        );
      } else if (cat == DocCategory.medical) {
        return Row(
          children: [
            _buildFixedHeaderCell(
              '카테고리 ${_medSumByCat ? "✓" : ""}',
              82,
              onHeaderTap: () {
                _toggleMedicalGroupHeader('cat');
                _toggleSortColumn('subCategory');
              },
              isHighlightedGroup: _medSumByCat,
            ),
            _buildFixedHeaderCell(
              '환자성명 ${_medSumByPatient ? "✓" : ""}',
              76,
              onHeaderTap: () {
                _toggleMedicalGroupHeader('patient');
                _toggleSortColumn('patient');
              },
              isHighlightedGroup: _medSumByPatient,
            ),
            _buildFixedHeaderCell('날짜', 82, sortKey: 'date'),
            _buildFixedHeaderCell('상호', 110, sortKey: 'clinic'),
            _buildFixedHeaderCell('금액', 82, sortKey: 'amount'),
            _buildFixedHeaderCell('사업자등록번호', 102),
            _buildFixedHeaderCell(
              '청구여부 ${_medSumByClaim ? "✓" : ""}',
              76,
              onHeaderTap: () {
                _toggleMedicalGroupHeader('claim');
                _toggleSortColumn('claimed');
              },
              isHighlightedGroup: _medSumByClaim,
            ),
            _buildFixedHeaderCell('증빙첨부', 80),
            _buildFixedHeaderCell('수정/삭제', 68),
          ],
        );
      } else if (cat == DocCategory.businessCard) {
        return Row(
          children: [
            _buildFixedHeaderCell('날짜', 82, sortKey: 'date'),
            _buildFixedHeaderCell('회사명', 108, sortKey: 'companyName'),
            _buildFixedHeaderCell('현장명', 112, sortKey: 'siteName'),
            _buildFixedHeaderCell('이름', 74, sortKey: 'personName'),
            _buildFixedHeaderCell('휴대폰번호 (📞전화)', 124),
            _buildFixedHeaderCell('이메일주소 (✉️메일)', 152),
            _buildFixedHeaderCell('수정/삭제', 68),
          ],
        );
      } else {
        // ★ PDF변환 탭: 찍은날짜 | 파일명 | 장수 | 페이지추가 | 수정/삭제
        return Row(
          children: [
            _buildFixedHeaderCell('찍은날짜', 90, sortKey: 'date'),
            _buildFixedHeaderCell('파일명', 175, sortKey: 'pdfFileName'),
            _buildFixedHeaderCell('장수', 66, sortKey: 'pageCount'),
            _buildFixedHeaderCell('페이지추가', 88),
            _buildFixedHeaderCell('수정/삭제', 68),
          ],
        );
      }
    }

    Widget buildDataRow(DocRecord r) {
      final f = r.fields;
      final bool isSelected = _selectedRecord?.id == r.id;

      Widget rowWidget;
      if (cat == DocCategory.officialIn) {
        final bool replied = _isIncomingDocReplied(r, repliedKeys);
        rowWidget = Row(
          children: [
            _buildFixedDataCell(DocRecord.formatDotDate(f['sentDate']), 82),
            _buildFixedDataCell(f['docNumber'] ?? '-', 96, bold: true),
            _buildFixedDataCell(r.officialCounterpartyValue, 92),
            _buildFixedDataCell(f['title'] ?? '-', 142, bold: true),
            _buildFixedDataCell(f['aiSummary'] ?? '-', 168),
            _buildFixedDataCell(
                DocRecord.formatDotDate(f['replyDeadline']), 82),
            _buildFixedDataCell(
              replied ? '○' : '-',
              64,
              bold: true,
              textColor: replied ? Colors.green.shade700 : Colors.black38,
            ),
            _buildFixedDataCell(_resolveUploaderName(r), 68),
            _buildApprovalCell(r, 74),
            _buildEditDeleteActionCell(r, 68),
          ],
        );
      } else if (cat == DocCategory.officialOut) {
        rowWidget = Row(
          children: [
            _buildFixedDataCell(DocRecord.formatDotDate(f['sentDate']), 82),
            _buildFixedDataCell(f['docNumber'] ?? '-', 96, bold: true),
            _buildFixedDataCell(r.officialCounterpartyValue, 92),
            _buildFixedDataCell(f['replyDocNumber'] ?? '-', 96),
            _buildFixedDataCell(f['title'] ?? '-', 142, bold: true),
            _buildFixedDataCell(f['aiSummary'] ?? '-', 168),
            _buildFixedDataCell(_resolveUploaderName(r), 68),
            _buildApprovalCell(r, 74),
            _buildEditDeleteActionCell(r, 68),
          ],
        );
      } else if (cat == DocCategory.invoice) {
        rowWidget = Row(
          children: [
            _buildFixedDataCell(DocRecord.formatDotDate(f['arrivalDate']), 82),
            _buildFixedDataCell(f['productName'] ?? '-', 92, bold: true),
            _buildFixedDataCell(f['specName'] ?? '-', 110, bold: true),
            _buildFixedDataCell(f['unit'] ?? '-', 52),
            _buildFixedDataCell(f['quantity'] ?? '-', 66, bold: true),
            _buildFixedDataCell(
              cumulativeMap[r.id] ?? '-',
              72,
              bold: true,
              textColor: const Color(0xFF1E3A8A),
            ),
            _buildFixedDataCell(f['supplierName'] ?? '-', 92),
            _buildFixedDataCell(f['orderNumber'] ?? '-', 112),
            _buildFixedDataCell(_resolveUploaderName(r), 68),
            _buildApprovalCell(r, 74),
            _buildEditDeleteActionCell(r, 68),
          ],
        );
      } else if (cat == DocCategory.travel) {
        final subLabel = r.subCategory.isEmpty ? '미지정' : r.subCategory;
        final dateStr = DocRecord.formatDotDate(f['date']);
        rowWidget = Row(
          children: [
            _buildFixedDataCell('$subLabel\n($dateStr)', 106, bold: true),
            _buildFixedDataCell(r.travelDivision, 64, bold: true),
            _buildFixedDataCell(f['merchantName'] ?? '-', 140, bold: true),
            _buildFixedDataCell(
              '${NumberFormat('#,###').format(r.numericAmount)}원',
              88,
              bold: true,
              textColor: const Color(0xFF1E3A8A),
            ),
            _buildEditDeleteActionCell(r, 68),
          ],
        );
      } else if (cat == DocCategory.medical) {
        final subLabel = r.subCategory.isEmpty ? '미지정' : r.subCategory;
        final cnt = r.proofAttachmentCount;
        rowWidget = Row(
          children: [
            _buildFixedDataCell(subLabel, 82, bold: true),
            _buildFixedDataCell(f['patientName'] ?? '-', 76, bold: true),
            _buildFixedDataCell(DocRecord.formatDotDate(f['issueDate']), 82),
            _buildFixedDataCell(f['clinicName'] ?? '-', 110, bold: true),
            _buildFixedDataCell(
              '${NumberFormat('#,###').format(r.numericAmount)}원',
              82,
              bold: true,
              textColor: const Color(0xFF1E3A8A),
            ),
            _buildFixedDataCell(f['bizRegNumber'] ?? '-', 102),
            _buildFixedDataCell(
              r.isMedicalClaimed ? '☑ 청구완료' : '☐ 미청구',
              76,
              bold: true,
              textColor: r.isMedicalClaimed
                  ? Colors.green.shade700
                  : Colors.orange.shade800,
              onTap: () => _toggleMedicalRecordClaimed(r),
            ),
            _buildFixedDataCell(
              cnt > 0 ? '📎 첨부($cnt)' : '+ 증빙추가',
              80,
              bold: true,
              textColor: const Color(0xFF1E3A8A),
              onTap: () => _manageRecordExtraPagesDialog(r),
            ),
            _buildEditDeleteActionCell(r, 68),
          ],
        );
      } else if (cat == DocCategory.businessCard) {
        final phone = (f['mobilePhone'] ?? '').trim();
        final email = (f['email'] ?? '').trim();
        rowWidget = Row(
          children: [
            _buildFixedDataCell(
              DocRecord.formatDotDate(
                  f['cardDate'] ?? r.createdAt.split(' ').first),
              82,
            ),
            _buildFixedDataCell(f['companyName'] ?? '-', 108, bold: true),
            _buildFixedDataCell(f['siteName'] ?? '-', 112),
            _buildFixedDataCell(f['personName'] ?? '-', 74, bold: true),
            _buildFixedDataCell(
              phone.isEmpty ? '-' : '📞 $phone',
              124,
              bold: true,
              textColor: Colors.green.shade800,
              onTap: phone.isEmpty ? null : () => _openPhoneDialer(phone),
            ),
            _buildFixedDataCell(
              email.isEmpty ? '-' : '✉️ $email',
              152,
              textColor: const Color(0xFF1E3A8A),
              onTap: email.isEmpty ? null : () => _openEmailComposer(email),
            ),
            _buildEditDeleteActionCell(r, 68),
          ],
        );
      } else {
        // ★ PDF변환 탭 데이터 행: 찍은날짜 | 파일명 | 장수 | 페이지추가 | 수정/삭제
        final rawFn = (f['pdfFileName'] ?? '').trim();
        final dispFn = rawFn.isEmpty
            ? '문서스캔.pdf'
            : (rawFn.toLowerCase().endsWith('.pdf') ? rawFn : '$rawFn.pdf');
        final totalPages = r.totalPdfPageCount;
        rowWidget = Row(
          children: [
            _buildFixedDataCell(
              DocRecord.formatDotDate(
                  f['pdfDate'] ?? r.createdAt.split(' ').first),
              90,
            ),
            _buildFixedDataCell(
              dispFn,
              175,
              bold: true,
              textColor: const Color(0xFF1E3A8A),
            ),
            _buildFixedDataCell(
              '${totalPages}장',
              66,
              bold: true,
              textColor: const Color(0xFF0F766E),
            ),
            _buildFixedDataCell(
              '+ 페이지추가',
              88,
              bold: true,
              textColor: const Color(0xFF1E3A8A),
              onTap: () => _manageRecordExtraPagesDialog(r),
            ),
            _buildEditDeleteActionCell(r, 68),
          ],
        );
      }

      return GestureDetector(
        onTap: () {
          setState(() {
            _selectedRecord = r;
          });
          _resetPhotoPageToZero();
        },
        onLongPress: () => _editRecordDialog(r),
        child: Container(
          height: _kTableDataRowHeight,
          color: isSelected ? const Color(0xFFDBEAFE) : Colors.white,
          child: rowWidget,
        ),
      );
    }

    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: cat == DocCategory.officialIn
              ? 936
              : (cat == DocCategory.officialOut
                  ? 886
                  : (cat == DocCategory.invoice
                      ? 888
                      : (cat == DocCategory.medical
                          ? 758
                          : (cat == DocCategory.businessCard
                              ? 720
                              : (cat == DocCategory.pdfConvert ? 487 : 466))))),
          child: Column(
            children: [
              buildHeaderRow(),
              Expanded(
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  itemExtent: _kTableDataRowHeight,
                  itemCount: list.length,
                  itemBuilder: (ctx, idx) => buildDataRow(list[idx]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// ★ 하단 사진 미리보기:
  /// - 여러 장(1페이지/2페이지/3페이지...) 칩 버튼 나열 대신,
  ///   [병원비]: "기본 영수증  |  첨부 2장 (1/3)" 표시 + 좌우 스와이프(PageView)로 한 장씩 넘겨보기
  ///   [PDF변환]: "총 4장 (현재 1/4장)" 표시 + 좌우 스와이프(PageView)로 한 장씩 넘겨보기
  Widget _buildPhotoPreviewSection() {
    final rec = _selectedRecord;
    if (rec == null) {
      return Container(
        color: const Color(0xFF0F172A),
        alignment: Alignment.center,
        child: const Text(
          '상단 목록에서 항목을 선택하면 아래에 사진이 표시됩니다.',
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
      );
    }

    final List<Uint8List> allPageBytes = <Uint8List>[];
    final mainBytes = rec.resolveMainImageBytes();
    if (mainBytes != null && mainBytes.isNotEmpty) {
      allPageBytes.add(mainBytes);
    }
    final bool supportsMultiPages =
        rec.category == DocCategory.medical ||
            rec.category == DocCategory.pdfConvert;
    if (supportsMultiPages) {
      allPageBytes.addAll(rec.resolveAllProofImageBytes());
    }

    final int totalCount = allPageBytes.length;
    final int safeIndex =
        totalCount == 0 ? 0 : _selectedPhotoIndex.clamp(0, totalCount - 1);
    final int extraCount = math.max(0, totalCount - 1);

    return Container(
      color: const Color(0xFF0F172A),
      child: Column(
        children: [
          if (supportsMultiPages)
            Container(
              width: double.infinity,
              color: const Color(0xFF1E293B),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 9, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.amber.shade300,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            rec.category == DocCategory.medical
                                ? (safeIndex == 0
                                    ? '기본 영수증 (첨부 ${extraCount}장)'
                                    : '첨부사진 $safeIndex / ${extraCount}장 (기본영수증 외 총 ${extraCount}장)')
                                : '총 ${totalCount}장 (${safeIndex + 1} / ${totalCount}장)',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                        ),
                        if (totalCount > 1) ...[
                          const SizedBox(width: 8),
                          const Flexible(
                            child: Text(
                              '👉 좌우로 밀어서 한 장씩 넘겨보기',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  InkWell(
                    onTap: () => _manageRecordExtraPagesDialog(rec),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00E676),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        rec.category == DocCategory.pdfConvert
                            ? '+ 페이지 추가'
                            : '+ 증빙첨부',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: allPageBytes.isEmpty
                ? const Center(
                    child: Text(
                      '저장된 이미지가 없습니다.',
                      style: TextStyle(color: Colors.white54),
                    ),
                  )
                : Stack(
                    children: [
                      PageView.builder(
                        controller: _photoPageCtrl,
                        itemCount: totalCount,
                        onPageChanged: (idx) {
                          setState(() => _selectedPhotoIndex = idx);
                        },
                        itemBuilder: (ctx, pageIdx) {
                          return InteractiveViewer(
                            minScale: 0.5,
                            maxScale: 8.0,
                            child: Center(
                              child: Image.memory(
                                allPageBytes[pageIdx],
                                fit: BoxFit.contain,
                              ),
                            ),
                          );
                        },
                      ),
                      if (totalCount > 1 && safeIndex > 0)
                        Positioned(
                          left: 6,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: IconButton(
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.black54,
                                foregroundColor: Colors.white,
                              ),
                              icon: const Icon(Icons.chevron_left, size: 24),
                              onPressed: () {
                                _photoPageCtrl.previousPage(
                                  duration: const Duration(milliseconds: 220),
                                  curve: Curves.easeOut,
                                );
                              },
                            ),
                          ),
                        ),
                      if (totalCount > 1 && safeIndex < totalCount - 1)
                        Positioned(
                          right: 6,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: IconButton(
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.black54,
                                foregroundColor: Colors.white,
                              ),
                              icon: const Icon(Icons.chevron_right, size: 24),
                              onPressed: () {
                                _photoPageCtrl.nextPage(
                                  duration: const Duration(milliseconds: 220),
                                  curve: Curves.easeOut,
                                );
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredRecords;
    if (_selectedRecord != null &&
        !filtered.any((r) => r.id == _selectedRecord!.id)) {
      _selectedRecord = filtered.isNotEmpty ? filtered.first : null;
      _selectedPhotoIndex = 0;
    }

    final bool isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        toolbarHeight: 44,
        titleSpacing: 4,
        title: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: _openSettingsDialog,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
                  child: Icon(
                    _geminiApiKey.trim().isEmpty
                        ? Icons.settings
                        : (_geminiKeyVerified
                            ? Icons.auto_awesome
                            : Icons.warning_amber_rounded),
                    color: _geminiApiKey.trim().isEmpty
                        ? Colors.white
                        : (_geminiKeyVerified
                            ? Colors.amberAccent
                            : Colors.redAccent),
                    size: 18,
                  ),
                ),
              ),
              _buildTopActionBtn(
                icon: Icons.cloud_sync_outlined,
                label: '현장공유',
                iconColor: const Color(0xFF67E8F9),
                onTap: _openFieldShareRoomDialog,
              ),
              _buildTopActionBtn(
                icon: Icons.upload_file,
                label: 'HTML내보내기',
                iconColor: const Color(0xFF93C5FD),
                onTap: _exportCurrentTabHtml,
              ),
              _buildTopActionBtn(
                icon: Icons.download_rounded,
                label: 'HTML업로드',
                iconColor: const Color(0xFF6EE7B7),
                onTap: _importAndMergeHtmlFiles,
              ),
              _buildTopActionBtn(
                icon: Icons.picture_as_pdf,
                label: 'PDF내보내기',
                iconColor: const Color(0xFFFDE047),
                onTap: _exportCurrentTabBundledPdf,
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          if (_isBusy) const LinearProgressIndicator(minHeight: 3),

          // 상단 대분류 탭 바 (맨 우측에 PDF변환 탭 배치)
          Container(
            width: double.infinity,
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: DocCategory.filterList.map((cat) {
                  final isSelected = _selectedCategoryFilter == cat;
                  final count =
                      _records.where((r) => r.category == cat).length;
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(
                        count > 0 ? '$cat ($count)' : cat,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight:
                              isSelected ? FontWeight.w900 : FontWeight.w600,
                        ),
                      ),
                      selected: isSelected,
                      onSelected: (_) {
                        setState(() {
                          _selectedCategoryFilter = cat;
                          _selectedSubCategoryFilter = '전체';
                          _selectedTravelDivisionFilter = '전체';
                          _selectedInvoiceProductFilter = '전체';
                          _selectedMedicalClaimFilter = '전체';
                          final nextList = _filteredRecords;
                          _selectedRecord =
                              nextList.isNotEmpty ? nextList.first : null;
                        });
                        _resetPhotoPageToZero();
                      },
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          const Divider(height: 1),

          // 요약 및 기간/검색 필터 바
          _buildSummaryAndSubCategoryBar(),
          const Divider(height: 1),

          // 본문: 세로모드(위 리스트 / 아래 사진), 가로모드(좌 리스트 / 우 사진)
          Expanded(
            child: LayoutBuilder(
              builder: (ctx, constraints) {
                if (!isLandscape) {
                  final totalH = constraints.maxHeight;
                  const barH = 26.0;
                  final listH =
                      ((totalH - barH) * _listSplitRatio).clamp(100.0, totalH - 120.0);
                  return Column(
                    children: [
                      SizedBox(
                        height: listH,
                        child: _buildRecordTableSection(filtered),
                      ),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onVerticalDragUpdate: (d) async {
                          setState(() {
                            _listSplitRatio =
                                ((_listSplitRatio * totalH + d.delta.dy) /
                                        totalH)
                                    .clamp(0.18, 0.82);
                          });
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setDouble(
                              _prefsSplitRatioKey, _listSplitRatio);
                        },
                        child: Container(
                          height: barH,
                          width: double.infinity,
                          color: const Color(0xFFCBD5E1),
                          alignment: Alignment.center,
                          child: const Text(
                            '═ 위아래로 끌어서 화면 크기 조절 (표는 좌우로 드래그 가능)',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1E3A8A),
                            ),
                          ),
                        ),
                      ),
                      Expanded(child: _buildPhotoPreviewSection()),
                    ],
                  );
                } else {
                  final totalW = constraints.maxWidth;
                  const barW = 24.0;
                  final listW = ((totalW - barW) * _detailHorizSplitRatio)
                      .clamp(180.0, totalW - 180.0);
                  return Row(
                    children: [
                      SizedBox(
                        width: listW,
                        child: _buildRecordTableSection(filtered),
                      ),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragUpdate: (d) async {
                          setState(() {
                            _detailHorizSplitRatio =
                                ((_detailHorizSplitRatio * totalW +
                                            d.delta.dx) /
                                        totalW)
                                    .clamp(0.22, 0.78);
                          });
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setDouble(_prefsHorizSplitRatioKey,
                              _detailHorizSplitRatio);
                        },
                        child: Container(
                          width: barW,
                          height: double.infinity,
                          color: const Color(0xFFCBD5E1),
                          alignment: Alignment.center,
                          child: const RotatedBox(
                            quarterTurns: 1,
                            child: Text(
                              '═ 좌우 크기 조절',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1E3A8A),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(child: _buildPhotoPreviewSection()),
                    ],
                  );
                }
              },
            ),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'gallery_btn',
            backgroundColor: Colors.white,
            foregroundColor: const Color(0xFF1E3A8A),
            tooltip: _selectedCategoryFilter == DocCategory.pdfConvert
                ? '갤러리에서 여러 장 멀티선택하여 PDF 만들기'
                : '갤러리에서 사진 불러오기',
            onPressed: _isBusy
                ? null
                : () => _captureAndAddRecord(ImageSource.gallery),
            child: const Icon(Icons.photo_library_outlined),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.extended(
            heroTag: 'camera_btn',
            backgroundColor: const Color(0xFF1E3A8A),
            foregroundColor: Colors.white,
            onPressed:
                _isBusy ? null : () => _captureAndAddRecord(ImageSource.camera),
            icon: Icon(
              _selectedCategoryFilter == DocCategory.businessCard
                  ? Icons.badge_outlined
                  : (_selectedCategoryFilter == DocCategory.pdfConvert
                      ? Icons.picture_as_pdf
                      : Icons.camera_alt),
            ),
            label: Text(
              _selectedCategoryFilter == DocCategory.businessCard
                  ? '명함 촬영'
                  : (_selectedCategoryFilter == DocCategory.pdfConvert
                      ? 'PDF 스캔 촬영'
                      : '서류 촬영'),
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }
}
