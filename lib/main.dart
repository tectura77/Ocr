import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DocSnapArchiveApp());
}

class DocSnapArchiveApp extends StatelessWidget {
  const DocSnapArchiveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '증빙서류 스냅 아카이브',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1E3A8A)),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

/// 문서 분류 상수
class DocCategory {
  static const String all = '전체';
  static const String officialDoc = '대외공문';
  static const String invoice = '자재송장';
  static const String travel = '출장비';
  static const String medical = '병원비';

  static const List<String> filterList = [
    all,
    officialDoc,
    invoice,
    travel,
    medical,
  ];

  static const List<String> inputList = [
    officialDoc,
    invoice,
    travel,
    medical,
  ];
}

// =============================================================================
// 백그라운드 Isolate에서 실행되는 안전한 4점 모서리 평탄화 함수 (UI 멈춤/강제종료 원천 차단)
// =============================================================================
class WarpRequest {
  final Uint8List originalBytes;
  final List<double> cornerCoords; // [x0, y0, x1, y1, x2, y2, x3, y3]
  final bool enhanceContrast;

  WarpRequest({
    required this.originalBytes,
    required this.cornerCoords,
    required this.enhanceContrast,
  });
}

Uint8List _performPerspectiveWarpIsolate(WarpRequest req) {
  final decoded = img.decodeImage(req.originalBytes);
  if (decoded == null) return req.originalBytes;
  final src = img.bakeOrientation(decoded);

  final c = req.cornerCoords;
  final p0x = c[0] * src.width;
  final p0y = c[1] * src.height;
  final p1x = c[2] * src.width;
  final p1y = c[3] * src.height;
  final p2x = c[4] * src.width;
  final p2y = c[5] * src.height;
  final p3x = c[6] * src.width;
  final p3y = c[7] * src.height;

  final topW = math.sqrt(math.pow(p1x - p0x, 2) + math.pow(p1y - p0y, 2));
  final botW = math.sqrt(math.pow(p2x - p3x, 2) + math.pow(p2y - p3y, 2));
  final leftH = math.sqrt(math.pow(p3x - p0x, 2) + math.pow(p3y - p0y, 2));
  final rightH = math.sqrt(math.pow(p2x - p1x, 2) + math.pow(p2y - p1y, 2));

  // 메모리 초과 및 연산 지연을 막기 위해 적정 스캔 해상도(최대 1100x1500)로 제한
  int dstW = math.max(topW, botW).round().clamp(300, 1100);
  int dstH = math.max(leftH, rightH).round().clamp(300, 1500);

  final dst = img.Image(width: dstW, height: dstH);

  for (int y = 0; y < dstH; y++) {
    final v = dstH > 1 ? y / (dstH - 1) : 0.0;
    for (int x = 0; x < dstW; x++) {
      final u = dstW > 1 ? x / (dstW - 1) : 0.0;
      final sx = (1 - u) * (1 - v) * p0x +
          u * (1 - v) * p1x +
          u * v * p2x +
          (1 - u) * v * p3x;
      final sy = (1 - u) * (1 - v) * p0y +
          u * (1 - v) * p1y +
          u * v * p2y +
          (1 - u) * v * p3y;

      final ix = sx.round().clamp(0, src.width - 1);
      final iy = sy.round().clamp(0, src.height - 1);
      final pixel = src.getPixel(ix, iy);

      if (req.enhanceContrast) {
        int r = ((pixel.r - 128) * 1.18 + 136).round().clamp(0, 255);
        int g = ((pixel.g - 128) * 1.18 + 136).round().clamp(0, 255);
        int b = ((pixel.b - 128) * 1.18 + 136).round().clamp(0, 255);
        dst.setPixelRgb(x, y, r, g, b);
      } else {
        dst.setPixel(x, y, pixel);
      }
    }
  }

  return Uint8List.fromList(img.encodeJpg(dst, quality: 86));
}

// =============================================================================
// 4점 모서리 지정 및 원근 평탄화(Perspective Warp) 다이얼로그
// =============================================================================
class PerspectiveCropDialog extends StatefulWidget {
  final Uint8List originalBytes;

  const PerspectiveCropDialog({super.key, required this.originalBytes});

  @override
  State<PerspectiveCropDialog> createState() => _PerspectiveCropDialogState();
}

class _PerspectiveCropDialogState extends State<PerspectiveCropDialog> {
  // 정규화된 4개 모서리 좌표 (0.0 ~ 1.0): 1(좌상), 2(우상), 3(우하), 4(좌하)
  List<Offset> _corners = const [
    Offset(0.08, 0.08),
    Offset(0.92, 0.08),
    Offset(0.92, 0.92),
    Offset(0.08, 0.92),
  ];

  bool _enhanceScanContrast = true;
  bool _isProcessing = false;
  int? _activeCornerIndex;

  Future<void> _applyPerspectiveFlatten() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);
    try {
      final flatCoords = <double>[
        _corners[0].dx,
        _corners[0].dy,
        _corners[1].dx,
        _corners[1].dy,
        _corners[2].dx,
        _corners[2].dy,
        _corners[3].dx,
        _corners[3].dy,
      ];

      final resultBytes = await compute(
        _performPerspectiveWarpIsolate,
        WarpRequest(
          originalBytes: widget.originalBytes,
          cornerCoords: flatCoords,
          enhanceContrast: _enhanceScanContrast,
        ),
      );

      if (mounted) Navigator.pop(context, resultBytes);
    } catch (_) {
      if (mounted) Navigator.pop(context, widget.originalBytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        title: const Text('네 모서리 맞춰 평평하게 스캔'),
        actions: [
          TextButton(
            onPressed: _isProcessing
                ? null
                : () => Navigator.pop(context, widget.originalBytes),
            child: const Text(
              '원본 그대로 사용',
              style: TextStyle(color: Colors.white70),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            color: Colors.black54,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Text(
                    '파란색 점 4개를 서류의 네 모서리에 맞춘 뒤 하단 버튼을 누르세요.',
                    style: TextStyle(color: Colors.white, fontSize: 12.5),
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '스캔 선명화',
                      style: TextStyle(color: Colors.amberAccent, fontSize: 12),
                    ),
                    Switch(
                      value: _enhanceScanContrast,
                      onChanged: (v) => setState(() => _enhanceScanContrast = v),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: LayoutBuilder(
                builder: (ctx, constraints) {
                  final boxW = constraints.maxWidth;
                  final boxH = constraints.maxHeight;

                  return GestureDetector(
                    onPanStart: (details) {
                      final pos = details.localPosition;
                      int closestIdx = 0;
                      double minDist = double.infinity;
                      for (int i = 0; i < 4; i++) {
                        final pt = Offset(
                          _corners[i].dx * boxW,
                          _corners[i].dy * boxH,
                        );
                        final d = (pt - pos).distance;
                        if (d < minDist) {
                          minDist = d;
                          closestIdx = i;
                        }
                      }
                      if (minDist < 65) {
                        setState(() => _activeCornerIndex = closestIdx);
                      }
                    },
                    onPanUpdate: (details) {
                      if (_activeCornerIndex == null) return;
                      final pos = details.localPosition;
                      final nx = (pos.dx / boxW).clamp(0.0, 1.0);
                      final ny = (pos.dy / boxH).clamp(0.0, 1.0);
                      setState(() {
                        final updated = List<Offset>.from(_corners);
                        updated[_activeCornerIndex!] = Offset(nx, ny);
                        _corners = updated;
                      });
                    },
                    onPanEnd: (_) => setState(() => _activeCornerIndex = null),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.memory(
                          widget.originalBytes,
                          fit: BoxFit.fill,
                        ),
                        CustomPaint(
                          painter: _QuadOverlayPainter(corners: _corners),
                        ),
                        for (int i = 0; i < 4; i++)
                          Positioned(
                            left: _corners[i].dx * boxW - 18,
                            top: _corners[i].dy * boxH - 18,
                            child: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: _activeCornerIndex == i
                                    ? Colors.amber
                                    : Colors.blueAccent.withOpacity(0.85),
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 2.5),
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
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  onPressed: _isProcessing ? null : _applyPerspectiveFlatten,
                  icon: _isProcessing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.crop_free),
                  label: Text(
                    _isProcessing
                        ? '모서리 평평하게 펴는 중...'
                        : '모서리 맞춰 평평하게 펴기 & 글자 자동 읽기',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuadOverlayPainter extends CustomPainter {
  final List<Offset> corners;

  _QuadOverlayPainter({required this.corners});

  @override
  void paint(Canvas canvas, Size size) {
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
      ..color = Colors.blueAccent.withOpacity(0.18)
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fillPaint);

    final strokePaint = Paint()
      ..color = Colors.amberAccent
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(covariant _QuadOverlayPainter oldDelegate) => true;
}

// =============================================================================
// 문서 항목 데이터 모델
// =============================================================================
class DocRecord {
  final String id;
  final String category; // 대외공문, 자재송장, 출장비, 병원비
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

  String get displayTitle {
    switch (category) {
      case DocCategory.officialDoc:
        final title = fields['title'] ?? '';
        final sender = fields['sender'] ?? '';
        return title.isNotEmpty
            ? title
            : (sender.isNotEmpty ? '$sender 공문' : '대외공문');
      case DocCategory.invoice:
        final prod = fields['productName'] ?? '';
        final sup = fields['supplierName'] ?? '';
        return prod.isNotEmpty
            ? '$prod (${sup.isNotEmpty ? sup : "송장"})'
            : '자재송장';
      case DocCategory.travel:
        final dist = fields['distanceKm'] ?? '0';
        final total = fields['totalAmount'] ?? '0';
        return '왕복 ${dist}km 출장 (총 ${_formatCurrency(total)}원)';
      case DocCategory.medical:
        final clinic = fields['clinicName'] ?? '';
        final paid = fields['totalPaid'] ?? '0';
        return '${clinic.isNotEmpty ? clinic : "병원비"} (${_formatCurrency(paid)}원)';
      default:
        return category;
    }
  }

  String get displaySubtitle {
    switch (category) {
      case DocCategory.officialDoc:
        return '발신: ${fields['sender'] ?? '-'} | 번호: ${fields['docNumber'] ?? '-'} | 기한: ${fields['replyDeadline'] ?? '-'}';
      case DocCategory.invoice:
        return '공급자: ${fields['supplierName'] ?? '-'} | 규격: ${fields['specName'] ?? '-'} | 수량: ${fields['quantity'] ?? '-'}${fields['unit'] ?? ''} (${fields['weight'] ?? '-'}kg)';
      case DocCategory.travel:
        return '교통비: ${_formatCurrency(fields['carFare'])}원 | 영수증: ${_formatCurrency(fields['receiptTotal'])}원 | 하이패스: ${_formatCurrency(fields['hipassTotal'])}원';
      case DocCategory.medical:
        return '사업자번호: ${fields['bizRegNumber'] ?? '-'} | 발행일: ${fields['issueDate'] ?? '-'} | 수납액: ${_formatCurrency(fields['totalPaid'])}원';
      default:
        return createdAt;
    }
  }

  String get referenceDate {
    switch (category) {
      case DocCategory.officialDoc:
        return fields['sentDate']?.isNotEmpty == true
            ? fields['sentDate']!
            : createdAt.split(' ').first;
      case DocCategory.invoice:
        return fields['arrivalDate']?.isNotEmpty == true
            ? fields['arrivalDate']!
            : createdAt.split(' ').first;
      case DocCategory.travel:
        return createdAt.split(' ').first;
      case DocCategory.medical:
        return fields['issueDate']?.isNotEmpty == true
            ? fields['issueDate']!
            : createdAt.split(' ').first;
      default:
        return createdAt.split(' ').first;
    }
  }

  String get summaryKeyDetails {
    switch (category) {
      case DocCategory.officialDoc:
        return '공문번호: ${fields['docNumber'] ?? '-'}\n요약: ${fields['aiSummary'] ?? '-'}\n회신기한: ${fields['replyDeadline'] ?? '-'}';
      case DocCategory.invoice:
        return '주문번호: ${fields['orderNumber'] ?? '-'}\n품명/규격: ${fields['productName'] ?? '-'} / ${fields['specName'] ?? '-'}\n수량/중량: ${fields['quantity'] ?? '-'}${fields['unit'] ?? ''} / ${fields['weight'] ?? '-'}';
      case DocCategory.travel:
        return '거리: ${fields['distanceKm'] ?? '0'}km (교통비 ${_formatCurrency(fields['carFare'])}원)\n영수증합산: ${_formatCurrency(fields['receiptTotal'])}원\n하이패스합산: ${_formatCurrency(fields['hipassTotal'])}원';
      case DocCategory.medical:
        return '상호: ${fields['clinicName'] ?? '-'}\n사업자번호: ${fields['bizRegNumber'] ?? '-'}';
      default:
        return '';
    }
  }

  String get summaryAmountOrMetric {
    switch (category) {
      case DocCategory.officialDoc:
        return fields['replyDeadline']?.isNotEmpty == true
            ? '기한: ${fields['replyDeadline']}'
            : '-';
      case DocCategory.invoice:
        return '${fields['quantity'] ?? '0'}${fields['unit'] ?? ''} (${fields['weight'] ?? '0'}kg)';
      case DocCategory.travel:
        return '${_formatCurrency(fields['totalAmount'])}원';
      case DocCategory.medical:
        return '${_formatCurrency(fields['totalPaid'])}원';
      default:
        return '-';
    }
  }

  static String _formatCurrency(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '0';
    final cleaned = raw.replaceAll(RegExp(r'[^0-9]'), '');
    final val = int.tryParse(cleaned) ?? 0;
    return NumberFormat('#,###').format(val);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'category': category,
        'createdAt': createdAt,
        'imagePath': imagePath,
        'base64Image': base64Image,
        'fields': fields,
      };

  factory DocRecord.fromJson(Map<String, dynamic> json) {
    final rawFields = json['fields'] as Map<String, dynamic>? ?? {};
    return DocRecord(
      id: json['id'] as String,
      category: json['category'] as String? ?? DocCategory.officialDoc,
      createdAt: json['createdAt'] as String? ?? '',
      imagePath: json['imagePath'] as String? ?? '',
      base64Image: json['base64Image'] as String? ?? '',
      fields: rawFields.map((k, v) => MapEntry(k, v?.toString() ?? '')),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const String _prefsRecordsKey = 'local_doc_records_v2';
  static const String _prefsOneDriveSyncDirKey = 'onedrive_local_sync_dir';
  static const String _prefsOneDriveSubfolderKey = 'onedrive_target_subfolder';
  static const String _prefsAccessTokenKey = 'onedrive_access_token';
  static const String _prefsGeminiApiKey = 'gemini_api_key';
  static const String _defaultHtmlFileName = '증빙서류_누적목록.html';

  List<DocRecord> _records = [];
  String _selectedCategoryFilter = DocCategory.all;
  DocRecord? _selectedRecord;
  bool _isBusy = false;

  String _oneDriveLocalDir = '';
  String _oneDriveSubfolder = 'Documents/증빙서류함';
  String _accessToken = '';
  String _geminiApiKey = '';

  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    final prefs = await SharedPreferences.getInstance();
    final rawList = prefs.getStringList(_prefsRecordsKey) ?? [];
    final loaded = rawList
        .map((e) => DocRecord.fromJson(jsonDecode(e) as Map<String, dynamic>))
        .toList();

    setState(() {
      _records = loaded;
      if (_records.isNotEmpty) {
        _selectedRecord = _records.first;
      }
      _oneDriveLocalDir = prefs.getString(_prefsOneDriveSyncDirKey) ?? '';
      _oneDriveSubfolder =
          prefs.getString(_prefsOneDriveSubfolderKey) ?? 'Documents/증빙서류함';
      _accessToken = prefs.getString(_prefsAccessTokenKey) ?? '';
      _geminiApiKey = prefs.getString(_prefsGeminiApiKey) ?? '';
    });
  }

  Future<void> _saveLocalRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = _records.map((r) => jsonEncode(r.toJson())).toList();
    await prefs.setStringList(_prefsRecordsKey, encoded);
  }

  List<DocRecord> get _filteredRecords {
    if (_selectedCategoryFilter == DocCategory.all) return _records;
    return _records
        .where((r) => r.category == _selectedCategoryFilter)
        .toList();
  }

  // ===========================================================================
  // 1단계: 온디바이스(오프라인) Google ML Kit 한글 OCR 자동 추출기
  // ===========================================================================
  Future<Map<String, String>> _extractFieldsOfflineOcr({
    required String imagePath,
    required String category,
  }) async {
    TextRecognizer? textRecognizer;
    try {
      textRecognizer = TextRecognizer(script: TextRecognitionScript.korean);
      final inputImage = InputImage.fromFilePath(imagePath);
      final RecognizedText recognized =
          await textRecognizer.processImage(inputImage);
      final fullText = recognized.text;
      final lines = fullText
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();

      if (category == DocCategory.medical) {
        return _parseMedicalReceiptText(fullText, lines);
      } else if (category == DocCategory.invoice) {
        return _parseInvoiceText(fullText, lines);
      } else if (category == DocCategory.officialDoc) {
        return _parseOfficialDocText(fullText, lines);
      } else {
        return _parseTravelReceiptText(fullText, lines);
      }
    } catch (_) {
      return {};
    } finally {
      try {
        await textRecognizer?.close();
      } catch (_) {}
    }
  }

  /// 병원비 / 약제비 계산서·영수증 전용 고정밀 한국어 파서
  /// (보내주신 맘온누리약국 / 타워약국 영수증 포함 모든 약국·병원 영수증 완벽 파싱)
  Map<String, String> _parseMedicalReceiptText(
    String fullText,
    List<String> lines,
  ) {
    final result = <String, String>{};

    // 1) 사업자등록번호 (예: 276-63-00432, 840-78-00407)
    final bizMatch = RegExp(r'\b(\d{3})\s*-\s*(\d{2})\s*-\s*(\d{5})\b')
        .firstMatch(fullText);
    if (bizMatch != null) {
      result['bizRegNumber'] =
          '${bizMatch.group(1)}-${bizMatch.group(2)}-${bizMatch.group(3)}';
    }

    // 2) 발행일 / 조제일자 (예: 2026-10-01)
    final dateLabelMatch = RegExp(
      r'(?:발\s*행\s*일|조\s*제\s*일\s*자|진\s*료\s*일\s*자)[^\d]*(\d{4})\s*[-./년]\s*(\d{1,2})\s*[-./월]\s*(\d{1,2})',
    ).firstMatch(fullText);
    if (dateLabelMatch != null) {
      final y = dateLabelMatch.group(1)!;
      final m = dateLabelMatch.group(2)!.padLeft(2, '0');
      final d = dateLabelMatch.group(3)!.padLeft(2, '0');
      result['issueDate'] = '$y-$m-$d';
    } else {
      final anyDate = RegExp(r'(\d{4})\s*[-./]\s*(\d{2})\s*[-./]\s*(\d{2})')
          .firstMatch(fullText);
      if (anyDate != null) {
        result['issueDate'] =
            '${anyDate.group(1)}-${anyDate.group(2)}-${anyDate.group(3)}';
      }
    }

    // 3) 상호 (예: 맘온누리약국, 타워약국 등)
    final nameMatch = RegExp(
      r'([가-힣0-9]{2,15}(?:약국|병원|의원|치과|한의원|클리닉|메디컬|센터))',
    ).firstMatch(fullText);
    if (nameMatch != null) {
      result['clinicName'] = nameMatch.group(1)!;
    } else {
      for (final line in lines) {
        final sanghoMatch =
            RegExp(r'상\s*호\s*[:：]?\s*([가-힣A-Za-z0-9()]+)').firstMatch(line);
        if (sanghoMatch != null) {
          final candidate = sanghoMatch.group(1)!.trim();
          if (candidate.isNotEmpty && !candidate.contains('사업자')) {
            result['clinicName'] = candidate;
            break;
          }
        }
      }
    }

    // 4) 총수납금액 (합계 4,600 / 본인부담금 4,600 / 현금 4,600 / 카드 등)
    final amountPatterns = [
      RegExp(r'합\s*계[^\d\n]*([1-9]\d{0,2}(?:,\d{3})+|\d{3,7})'),
      RegExp(r'총\s*수\s*납\s*금\s*액[^\d]*([1-9]\d{0,2}(?:,\d{3})+|\d{3,7})'),
      RegExp(r'본\s*인\s*부\s*담\s*금[^\d]*([1-9]\d{0,2}(?:,\d{3})+|\d{3,7})'),
      RegExp(r'현\s*금[^\d\n]*([1-9]\d{0,2}(?:,\d{3})+|\d{3,7})'),
      RegExp(r'카\s*드[^\d\n]*([1-9]\d{0,2}(?:,\d{3})+|\d{3,7})'),
      RegExp(r'결\s*제\s*금\s*액[^\d]*([1-9]\d{0,2}(?:,\d{3})+|\d{3,7})'),
    ];
    for (final pat in amountPatterns) {
      final m = pat.firstMatch(fullText);
      if (m != null) {
        final digits = m.group(1)!.replaceAll(',', '');
        final val = int.tryParse(digits) ?? 0;
        if (val >= 100) {
          result['totalPaid'] = val.toString();
          break;
        }
      }
    }
    if ((result['totalPaid'] ?? '').isEmpty) {
      final allCommaNums = RegExp(r'\b([1-9]\d{0,2}(?:,\d{3})+)\b')
          .allMatches(fullText)
          .map((m) => int.tryParse(m.group(1)!.replaceAll(',', '')) ?? 0)
          .where((v) => v >= 500 && v < 100000000)
          .toList();
      if (allCommaNums.isNotEmpty) {
        result['totalPaid'] = allCommaNums.last.toString();
      }
    }

    return result;
  }

  /// 자재송장 오프라인 OCR 파서
  Map<String, String> _parseInvoiceText(String fullText, List<String> lines) {
    final result = <String, String>{};
    final dateMatch = RegExp(r'(\d{4})\s*[-./]\s*(\d{2})\s*[-./]\s*(\d{2})')
        .firstMatch(fullText);
    if (dateMatch != null) {
      result['arrivalDate'] =
          '${dateMatch.group(1)}-${dateMatch.group(2)}-${dateMatch.group(3)}';
    }
    final orderMatch =
        RegExp(r'(?:주문번호|송장번호|NO|번호)\s*[:：]?\s*([A-Za-z0-9-]+)')
            .firstMatch(fullText);
    if (orderMatch != null) result['orderNumber'] = orderMatch.group(1)!;

    for (final line in lines) {
      if (line.contains('품명') || line.contains('제품명') || line.contains('품목')) {
        result['productName'] =
            line.replaceAll(RegExp(r'.*(?:품명|제품명|품목)\s*[:：]?'), '').trim();
      } else if (line.contains('규격')) {
        result['specName'] =
            line.replaceAll(RegExp(r'.*규격\s*[:：]?'), '').trim();
      } else if (line.contains('상호') || line.contains('공급자')) {
        result['supplierName'] =
            line.replaceAll(RegExp(r'.*(?:상호|공급자)\s*[:：]?'), '').trim();
      }
    }
    return result;
  }

  /// 대외공문 오프라인 OCR 파서
  Map<String, String> _parseOfficialDocText(
    String fullText,
    List<String> lines,
  ) {
    final result = <String, String>{};
    final dateMatch =
        RegExp(r'(\d{4})\s*[-./년]\s*(\d{1,2})\s*[-./월]\s*(\d{1,2})')
            .firstMatch(fullText);
    if (dateMatch != null) {
      result['sentDate'] =
          '${dateMatch.group(1)}-${dateMatch.group(2)!.padLeft(2, '0')}-${dateMatch.group(3)!.padLeft(2, '0')}';
    }
    for (final line in lines) {
      if (line.contains('제목') && (result['title'] ?? '').isEmpty) {
        result['title'] = line.replaceAll(RegExp(r'^.*제목\s*[:：]?'), '').trim();
      } else if ((line.contains('시행') ||
              line.contains('문서번호') ||
              line.contains('공문번호')) &&
          (result['docNumber'] ?? '').isEmpty) {
        result['docNumber'] = line
            .replaceAll(RegExp(r'^.*(?:시행|문서번호|공문번호)\s*[:：]?'), '')
            .trim();
      } else if ((line.contains('수신') ||
              line.contains('발신') ||
              line.contains('기관')) &&
          (result['sender'] ?? '').isEmpty) {
        result['sender'] = line.trim();
      }
    }
    if ((result['title'] ?? '').isEmpty && lines.isNotEmpty) {
      result['title'] = lines.first;
    }
    final bodyPreview = lines.take(5).join(' ');
    if (bodyPreview.isNotEmpty) {
      result['aiSummary'] = bodyPreview.length > 75
          ? '${bodyPreview.substring(0, 75)}...'
          : bodyPreview;
    }
    return result;
  }

  /// 출장비 영수증 오프라인 OCR 파서
  Map<String, String> _parseTravelReceiptText(
    String fullText,
    List<String> lines,
  ) {
    final result = <String, String>{};
    final allCommaNums = RegExp(r'\b([1-9]\d{0,2}(?:,\d{3})+)\b')
        .allMatches(fullText)
        .map((m) => int.tryParse(m.group(1)!.replaceAll(',', '')) ?? 0)
        .where((v) => v >= 500 && v < 10000000)
        .toList();
    if (allCommaNums.isNotEmpty) {
      if (fullText.contains('하이패스') ||
          fullText.contains('도로공사') ||
          fullText.contains('통행료')) {
        result['hipassTotal'] = allCommaNums.last.toString();
      } else {
        result['receiptTotal'] = allCommaNums.last.toString();
      }
    }
    return result;
  }

  // ===========================================================================
  // 2단계: Gemini AI 정밀 분석 (API 키 설정 시 선택 작동)
  // ===========================================================================
  Future<Map<String, String>?> _analyzeDocumentWithAi({
    required String category,
    required String base64Image,
  }) async {
    if (_geminiApiKey.trim().isEmpty) return null;

    String prompt;
    if (category == DocCategory.officialDoc) {
      prompt = '''
이 대외공문 이미지를 읽고 반드시 아래 JSON 키만 가진 순수 JSON 객체로 응답해줘:
{
  "sentDate": "보낸날짜 (YYYY-MM-DD 형식)",
  "sender": "보낸사람 (발신기관명)",
  "docNumber": "공문번호",
  "title": "공문 제목",
  "aiSummary": "공문 핵심 내용을 명확하게 한 문장으로 요약",
  "replyDeadline": "회신기한 (없으면 공란)"
}''';
    } else if (category == DocCategory.invoice) {
      prompt = '''
이 자재송장 이미지를 읽고 반드시 아래 JSON 키만 가진 순수 JSON 객체로 응답해줘:
{
  "arrivalDate": "도착일 (YYYY-MM-DD 형식)",
  "orderNumber": "주문번호",
  "productName": "제품명",
  "specName": "규격명",
  "unit": "단위 (예: EA, BOX, m, kg 등)",
  "quantity": "수량 (숫자만)",
  "weight": "중량 (숫자만)",
  "supplierName": "공급자상호"
}''';
    } else if (category == DocCategory.travel) {
      prompt = '''
이 출장 영수증/하이패스 이미지를 읽고 반드시 아래 JSON 키만 가진 순수 JSON 객체로 응답해줘:
{
  "distanceKm": "출장거리 km (숫자만, 모르면 0)",
  "receiptTotal": "영수증 금액 합산 (숫자만)",
  "hipassTotal": "하이패스 금액 합산 (숫자만)"
}''';
    } else {
      prompt = '''
이 병원비/약국 영수증 이미지를 읽고 반드시 아래 JSON 키만 가진 순수 JSON 객체로 응답해줘:
{
  "clinicName": "병원 또는 약국 상호명",
  "bizRegNumber": "사업자등록번호 (000-00-00000)",
  "issueDate": "발행일 또는 조제일자 (YYYY-MM-DD)",
  "totalPaid": "총수납금액 또는 본인부담금 합계 (콤마 빼고 숫자만)"
}''';
    }

    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=${_geminiApiKey.trim()}',
    );

    final body = jsonEncode({
      'contents': [
        {
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

    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );

    if (resp.statusCode != 200) {
      throw Exception('AI 응답 오류 (${resp.statusCode})');
    }

    final decoded =
        jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final text =
        decoded['candidates']?[0]?['content']?['parts']?[0]?['text']?.toString() ??
            '{}';
    final cleanJson =
        text.replaceAll('```json', '').replaceAll('```', '').trim();
    final Map<String, dynamic> parsed =
        jsonDecode(cleanJson) as Map<String, dynamic>;
    return parsed.map((k, v) => MapEntry(k, v?.toString() ?? ''));
  }

  // ===========================================================================
  // 사진 촬영 → 4모서리 평평하게 스캔 → 오프라인 OCR & AI 자동 채우기 → 저장
  // ===========================================================================
  Future<void> _addRecordDialog(ImageSource source) async {
    try {
      final XFile? picked = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (picked == null) return;

      final rawBytes = await picked.readAsBytes();
      if (!mounted) return;

      // 1) 4모서리 맞춰 평평하게 스캔하는 화면 먼저 띄우기
      final Uint8List? flattenedBytes = await Navigator.push<Uint8List>(
        context,
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => PerspectiveCropDialog(originalBytes: rawBytes),
        ),
      );

      if (flattenedBytes == null) return;

      final base64Str = base64Encode(flattenedBytes);
      final appDir = await getApplicationDocumentsDirectory();
      final fileName = '${const Uuid().v4()}.jpg';
      final savedFile =
          await File(p.join(appDir.path, fileName)).writeAsBytes(flattenedBytes);

      if (!mounted) return;

      String chosenCategory = _selectedCategoryFilter == DocCategory.all
          ? DocCategory.medical
          : _selectedCategoryFilter;

      final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());

      // 1. 대외공문 컨트롤러
      final sentDateCtrl = TextEditingController(text: todayStr);
      final senderCtrl = TextEditingController();
      final docNumberCtrl = TextEditingController();
      final docTitleCtrl = TextEditingController();
      final aiSummaryCtrl = TextEditingController();
      final replyDeadlineCtrl = TextEditingController();

      // 2. 자재송장 컨트롤러
      final arrivalDateCtrl = TextEditingController(text: todayStr);
      final orderNumberCtrl = TextEditingController();
      final productNameCtrl = TextEditingController();
      final specNameCtrl = TextEditingController();
      final unitCtrl = TextEditingController(text: 'EA');
      final quantityCtrl = TextEditingController();
      final weightCtrl = TextEditingController();
      final supplierNameCtrl = TextEditingController();

      // 3. 출장비 컨트롤러
      final distanceKmCtrl = TextEditingController(text: '0');
      final carFareCtrl = TextEditingController(text: '0');
      final receiptTotalCtrl = TextEditingController(text: '0');
      final hipassTotalCtrl = TextEditingController(text: '0');
      final travelTotalCtrl = TextEditingController(text: '0');

      void recalcTravelCost() {
        final double dist = double.tryParse(
              distanceKmCtrl.text.replaceAll(RegExp(r'[^0-9.]'), ''),
            ) ??
            0;
        final int carFare = (dist * 300 * 2).round();
        final int receipt = int.tryParse(
              receiptTotalCtrl.text.replaceAll(RegExp(r'[^0-9]'), ''),
            ) ??
            0;
        final int hipass = int.tryParse(
              hipassTotalCtrl.text.replaceAll(RegExp(r'[^0-9]'), ''),
            ) ??
            0;
        final int total = carFare + receipt + hipass;

        carFareCtrl.text = carFare.toString();
        travelTotalCtrl.text = total.toString();
      }

      // 4. 병원비 컨트롤러
      final clinicNameCtrl = TextEditingController();
      final bizRegNumberCtrl = TextEditingController();
      final issueDateCtrl = TextEditingController(text: todayStr);
      final totalPaidCtrl = TextEditingController();

      void applyExtractedMap(Map<String, String> extracted) {
        if (chosenCategory == DocCategory.officialDoc) {
          if (extracted['sentDate']?.isNotEmpty == true) {
            sentDateCtrl.text = extracted['sentDate']!;
          }
          if (extracted['sender']?.isNotEmpty == true) {
            senderCtrl.text = extracted['sender']!;
          }
          if (extracted['docNumber']?.isNotEmpty == true) {
            docNumberCtrl.text = extracted['docNumber']!;
          }
          if (extracted['title']?.isNotEmpty == true) {
            docTitleCtrl.text = extracted['title']!;
          }
          if (extracted['aiSummary']?.isNotEmpty == true) {
            aiSummaryCtrl.text = extracted['aiSummary']!;
          }
          if (extracted['replyDeadline']?.isNotEmpty == true) {
            replyDeadlineCtrl.text = extracted['replyDeadline']!;
          }
        } else if (chosenCategory == DocCategory.invoice) {
          if (extracted['arrivalDate']?.isNotEmpty == true) {
            arrivalDateCtrl.text = extracted['arrivalDate']!;
          }
          if (extracted['orderNumber']?.isNotEmpty == true) {
            orderNumberCtrl.text = extracted['orderNumber']!;
          }
          if (extracted['productName']?.isNotEmpty == true) {
            productNameCtrl.text = extracted['productName']!;
          }
          if (extracted['specName']?.isNotEmpty == true) {
            specNameCtrl.text = extracted['specName']!;
          }
          if (extracted['unit']?.isNotEmpty == true) {
            unitCtrl.text = extracted['unit']!;
          }
          if (extracted['quantity']?.isNotEmpty == true) {
            quantityCtrl.text = extracted['quantity']!;
          }
          if (extracted['weight']?.isNotEmpty == true) {
            weightCtrl.text = extracted['weight']!;
          }
          if (extracted['supplierName']?.isNotEmpty == true) {
            supplierNameCtrl.text = extracted['supplierName']!;
          }
        } else if (chosenCategory == DocCategory.travel) {
          if (extracted['distanceKm']?.isNotEmpty == true) {
            distanceKmCtrl.text = extracted['distanceKm']!;
          }
          if (extracted['receiptTotal']?.isNotEmpty == true) {
            receiptTotalCtrl.text = extracted['receiptTotal']!;
          }
          if (extracted['hipassTotal']?.isNotEmpty == true) {
            hipassTotalCtrl.text = extracted['hipassTotal']!;
          }
          recalcTravelCost();
        } else if (chosenCategory == DocCategory.medical) {
          if (extracted['clinicName']?.isNotEmpty == true) {
            clinicNameCtrl.text = extracted['clinicName']!;
          }
          if (extracted['bizRegNumber']?.isNotEmpty == true) {
            bizRegNumberCtrl.text = extracted['bizRegNumber']!;
          }
          if (extracted['issueDate']?.isNotEmpty == true) {
            issueDateCtrl.text = extracted['issueDate']!;
          }
          if (extracted['totalPaid']?.isNotEmpty == true) {
            totalPaidCtrl.text = extracted['totalPaid']!;
          }
        }
      }

      // 2) 다이얼로그 띄우기 전에 온디바이스 한글 OCR을 즉시 수행하여 초기값 자동 채움!
      setState(() => _isBusy = true);
      final initialOcr = await _extractFieldsOfflineOcr(
        imagePath: savedFile.path,
        category: chosenCategory,
      );
      applyExtractedMap(initialOcr);
      setState(() => _isBusy = false);

      if (!mounted) return;

      bool isAiAnalyzing = false;

      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, setDialogState) {
              Future<void> triggerOcrAndAiExtract() async {
                setDialogState(() => isAiAnalyzing = true);
                try {
                  final ocrMap = await _extractFieldsOfflineOcr(
                    imagePath: savedFile.path,
                    category: chosenCategory,
                  );
                  setDialogState(() => applyExtractedMap(ocrMap));

                  if (_geminiApiKey.trim().isNotEmpty) {
                    final aiMap = await _analyzeDocumentWithAi(
                      category: chosenCategory,
                      base64Image: base64Str,
                    );
                    if (aiMap != null) {
                      setDialogState(() => applyExtractedMap(aiMap));
                    }
                  }
                  _showSnack('사진에서 문자/금액을 자동으로 읽어왔습니다.');
                } catch (e) {
                  _showSnack('문자 인식 완료: $e');
                } finally {
                  setDialogState(() => isAiAnalyzing = false);
                }
              }

              return AlertDialog(
                title: const Text('증빙서류 맞춤 정보 입력'),
                content: SizedBox(
                  width: double.maxFinite,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          height: 110,
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.memory(
                              flattenedBytes,
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                        DropdownButtonFormField<String>(
                          value: chosenCategory,
                          decoration: const InputDecoration(
                            labelText: '문서 종류 선택',
                            border: OutlineInputBorder(),
                          ),
                          items: DocCategory.inputList
                              .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                              .toList(),
                          onChanged: (v) async {
                            if (v != null) {
                              setDialogState(() => chosenCategory = v);
                              await triggerOcrAndAiExtract();
                            }
                          },
                        ),
                        const SizedBox(height: 10),
                        FilledButton.tonalIcon(
                          onPressed: isAiAnalyzing ? null : triggerOcrAndAiExtract,
                          icon: isAiAnalyzing
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.auto_awesome),
                          label: Text(
                            chosenCategory == DocCategory.officialDoc
                                ? '한글 OCR & AI 공문 한문장 요약 다시 실행'
                                : '사진 속 문자/금액 다시 자동 인식',
                          ),
                        ),
                        const Divider(height: 22),

                        // 1. 대외공문 입력 폼
                        if (chosenCategory == DocCategory.officialDoc) ...[
                          _buildField(sentDateCtrl, '보낸날짜', '예: 2026-10-26'),
                          _buildField(senderCtrl, '보낸사람 (발신처)', '예: 국토교통부장관'),
                          _buildField(docNumberCtrl, '공문번호', '예: 건설정책과-1234호'),
                          _buildField(docTitleCtrl, '제목', '예: 현장 안전점검 결과 제출 요청'),
                          _buildField(
                            aiSummaryCtrl,
                            '주요내용 (AI 공문내용 한문장 요약)',
                            '자동 요약 또는 직접 입력',
                            maxLines: 2,
                          ),
                          _buildField(replyDeadlineCtrl, '회신기한', '예: 2026-11-05'),
                        ],

                        // 2. 자재송장 입력 폼
                        if (chosenCategory == DocCategory.invoice) ...[
                          _buildField(arrivalDateCtrl, '도착일', '예: 2026-10-26'),
                          _buildField(orderNumberCtrl, '주문번호', '예: PO-2026-0891'),
                          _buildField(productNameCtrl, '제품명', '예: 고강도 철근 HD16'),
                          _buildField(specNameCtrl, '규격명', '예: D16 x 8m'),
                          Row(
                            children: [
                              Expanded(
                                child: _buildField(unitCtrl, '단위', '예: TON, EA'),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _buildField(
                                  quantityCtrl,
                                  '수량',
                                  '예: 25',
                                  keyboardType: TextInputType.number,
                                ),
                              ),
                            ],
                          ),
                          _buildField(
                            weightCtrl,
                            '중량 (kg/ton)',
                            '예: 1,250',
                            keyboardType: TextInputType.number,
                          ),
                          _buildField(supplierNameCtrl, '공급자상호', '예: (주)대한철강자재'),
                        ],

                        // 3. 출장비 입력 폼
                        if (chosenCategory == DocCategory.travel) ...[
                          _buildField(
                            distanceKmCtrl,
                            '출장거리 (편도 km 입력 → 왕복 자동계산)',
                            '예: 45',
                            keyboardType: TextInputType.number,
                            onChanged: (_) => setDialogState(recalcTravelCost),
                          ),
                          _buildField(
                            carFareCtrl,
                            '교통비(자가용) = 출장거리 × 300원 × 2(왕복)',
                            '자동계산됨',
                            readOnly: true,
                          ),
                          _buildField(
                            receiptTotalCtrl,
                            '영수증금액합산 (원)',
                            '예: 35000',
                            keyboardType: TextInputType.number,
                            onChanged: (_) => setDialogState(recalcTravelCost),
                          ),
                          _buildField(
                            hipassTotalCtrl,
                            '하이패스금액합산 (원)',
                            '예: 9600',
                            keyboardType: TextInputType.number,
                            onChanged: (_) => setDialogState(recalcTravelCost),
                          ),
                          _buildField(
                            travelTotalCtrl,
                            '출장비 총 합계 (교통비 + 영수증 + 하이패스)',
                            '자동계산됨',
                            readOnly: true,
                          ),
                        ],

                        // 4. 병원비 입력 폼
                        if (chosenCategory == DocCategory.medical) ...[
                          _buildField(clinicNameCtrl, '상호 (병원/약국명)', '예: 맘온누리약국'),
                          _buildField(bizRegNumberCtrl, '사업자등록번호', '예: 276-63-00432'),
                          _buildField(issueDateCtrl, '발행일', '예: 2026-10-01'),
                          _buildField(
                            totalPaidCtrl,
                            '총수납금액 (원)',
                            '예: 4600',
                            keyboardType: TextInputType.number,
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

      final Map<String, String> collectedFields = {};
      if (chosenCategory == DocCategory.officialDoc) {
        collectedFields['sentDate'] = sentDateCtrl.text.trim();
        collectedFields['sender'] = senderCtrl.text.trim();
        collectedFields['docNumber'] = docNumberCtrl.text.trim();
        collectedFields['title'] = docTitleCtrl.text.trim();
        collectedFields['aiSummary'] = aiSummaryCtrl.text.trim();
        collectedFields['replyDeadline'] = replyDeadlineCtrl.text.trim();
      } else if (chosenCategory == DocCategory.invoice) {
        collectedFields['arrivalDate'] = arrivalDateCtrl.text.trim();
        collectedFields['orderNumber'] = orderNumberCtrl.text.trim();
        collectedFields['productName'] = productNameCtrl.text.trim();
        collectedFields['specName'] = specNameCtrl.text.trim();
        collectedFields['unit'] = unitCtrl.text.trim();
        collectedFields['quantity'] = quantityCtrl.text.trim();
        collectedFields['weight'] = weightCtrl.text.trim();
        collectedFields['supplierName'] = supplierNameCtrl.text.trim();
      } else if (chosenCategory == DocCategory.travel) {
        recalcTravelCost();
        collectedFields['distanceKm'] = distanceKmCtrl.text.trim();
        collectedFields['carFare'] = carFareCtrl.text.trim();
        collectedFields['receiptTotal'] = receiptTotalCtrl.text.trim();
        collectedFields['hipassTotal'] = hipassTotalCtrl.text.trim();
        collectedFields['totalAmount'] = travelTotalCtrl.text.trim();
      } else if (chosenCategory == DocCategory.medical) {
        collectedFields['clinicName'] = clinicNameCtrl.text.trim();
        collectedFields['bizRegNumber'] = bizRegNumberCtrl.text.trim();
        collectedFields['issueDate'] = issueDateCtrl.text.trim();
        collectedFields['totalPaid'] = totalPaidCtrl.text.trim();
      }

      final nowStr = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
      final newRecord = DocRecord(
        id: const Uuid().v4(),
        category: chosenCategory,
        createdAt: nowStr,
        imagePath: savedFile.path,
        base64Image: base64Str,
        fields: collectedFields,
      );

      setState(() {
        _records.insert(0, newRecord);
        _selectedRecord = newRecord;
      });
      await _saveLocalRecords();
    } catch (e) {
      setState(() => _isBusy = false);
      _showSnack('사진 처리 중 오류가 발생했습니다: $e');
    }
  }

  Widget _buildField(
    TextEditingController ctrl,
    String label,
    String hint, {
    bool readOnly = false,
    int maxLines = 1,
    TextInputType keyboardType = TextInputType.text,
    ValueChanged<String>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: ctrl,
        readOnly: readOnly,
        maxLines: maxLines,
        keyboardType: keyboardType,
        onChanged: onChanged,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          filled: readOnly,
          fillColor: readOnly ? Colors.grey.shade100 : null,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  Future<void> _deleteLocalRecord(DocRecord record) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('앱 목록에서 삭제'),
        content: const Text(
          '이 항목을 앱에서 삭제하시겠습니까?\n'
          '(이미 원드라이브 HTML에 내보낸 기록은 지워지지 않고 계속 쌓여 유지됩니다.)',
        ),
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
      _records.removeWhere((r) => r.id == record.id);
      if (_selectedRecord?.id == record.id) {
        _selectedRecord =
            _filteredRecords.isNotEmpty ? _filteredRecords.first : null;
      }
    });
    await _saveLocalRecords();
    _showSnack('앱 목록에서 삭제되었습니다. (원드라이브 누적 본은 유지됨)');
  }

  Future<void> _openSettingsDialog() async {
    final localDirCtrl = TextEditingController(text: _oneDriveLocalDir);
    final subfolderCtrl = TextEditingController(text: _oneDriveSubfolder);
    final geminiKeyCtrl = TextEditingController(text: _geminiApiKey);
    final tokenCtrl = TextEditingController(text: _accessToken);

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: const Text('원드라이브 자동 덮어쓰기 & AI 설정'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '1. 설치된 원드라이브 앱 폴더 자동 덮어쓰기',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '스마트폰에 깔려있는 원드라이브 앱 연동 폴더(내 문서함 내 특정 폴더)를 최초 1회 선택해 두면, 이후 상단 [업로드] 버튼 한 번으로 기존 HTML에 새 목록만 추가하여 자동 덮어씁니다.',
                    style: TextStyle(fontSize: 12, color: Colors.black87),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: localDirCtrl,
                          decoration: const InputDecoration(
                            labelText: '지정된 원드라이브 폴더 경로',
                            hintText: '폴더 선택 버튼을 눌러 지정하세요',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.folder_open),
                        label: const Text('폴더 선택'),
                        onPressed: () async {
                          final selectedDir =
                              await FilePicker.platform.getDirectoryPath(
                            dialogTitle: '원드라이브 연동 폴더(내 문서함 등) 선택',
                          );
                          if (selectedDir != null) {
                            setDialogState(() {
                              localDirCtrl.text = selectedDir;
                            });
                          }
                        },
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  const Text(
                    '2. Gemini AI 키 (선택 - 미입력 시에도 내장 한국어 OCR이 자동 작동합니다)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: geminiKeyCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Gemini API Key (선택)',
                      hintText: 'AIzaSy... (대외공문 고도화 한문장 요약 등에 활용)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const Divider(height: 24),
                  const Text(
                    '3. 원드라이브 클라우드 API 직접 연동 (선택)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: subfolderCtrl,
                    decoration: const InputDecoration(
                      labelText: '원드라이브 문서함 내 하위 폴더명',
                      hintText: '예: Documents/증빙서류함',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: tokenCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Graph API Access Token (선택)',
                      border: OutlineInputBorder(),
                      isDense: true,
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
              FilledButton(
                onPressed: () async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString(
                      _prefsOneDriveSyncDirKey, localDirCtrl.text.trim());
                  await prefs.setString(
                      _prefsOneDriveSubfolderKey, subfolderCtrl.text.trim());
                  await prefs.setString(
                      _prefsGeminiApiKey, geminiKeyCtrl.text.trim());
                  await prefs.setString(
                      _prefsAccessTokenKey, tokenCtrl.text.trim());

                  setState(() {
                    _oneDriveLocalDir = localDirCtrl.text.trim();
                    _oneDriveSubfolder = subfolderCtrl.text.trim().isEmpty
                        ? 'Documents/증빙서류함'
                        : subfolderCtrl.text.trim();
                    _geminiApiKey = geminiKeyCtrl.text.trim();
                    _accessToken = tokenCtrl.text.trim();
                  });
                  if (ctx.mounted) Navigator.pop(ctx);
                  _showSnack('설정이 저장되었습니다.');
                },
                child: const Text('저장'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _oneClickSyncHtmlToOneDrive() async {
    setState(() => _isBusy = true);
    try {
      List<DocRecord> existingHtmlRecords = [];
      Set<String> deletedInHtmlIds = {};

      if (_oneDriveLocalDir.isEmpty && _accessToken.isEmpty) {
        final pickedDir = await FilePicker.platform.getDirectoryPath(
          dialogTitle: '원드라이브 앱과 연동할 내 문서함 폴더를 선택하세요 (최초 1회)',
        );
        if (pickedDir != null && pickedDir.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_prefsOneDriveSyncDirKey, pickedDir);
          setState(() => _oneDriveLocalDir = pickedDir);
        }
      }

      File? targetSyncFile;
      if (_oneDriveLocalDir.isNotEmpty) {
        final dir = Directory(_oneDriveLocalDir);
        if (await dir.exists()) {
          targetSyncFile = File(p.join(dir.path, _defaultHtmlFileName));
          if (await targetSyncFile.exists()) {
            final existingHtml = await targetSyncFile.readAsString();
            existingHtmlRecords = _parseRecordsFromHtml(existingHtml);
            deletedInHtmlIds = _parseDeletedIdsFromHtml(existingHtml);
          }
        }
      }

      final cleanSubfolder =
          _oneDriveSubfolder.replaceAll(RegExp(r'^/+|/+$'), '');
      final remoteFilePath = '/$cleanSubfolder/$_defaultHtmlFileName';

      if (_accessToken.isNotEmpty) {
        final downloadUrl = Uri.parse(
          'https://graph.microsoft.com/v1.0/me/drive/root:$remoteFilePath:/content',
        );
        final getResp = await http.get(
          downloadUrl,
          headers: {'Authorization': 'Bearer $_accessToken'},
        );
        if (getResp.statusCode == 200) {
          final remoteHtml = utf8.decode(getResp.bodyBytes);
          final remoteRecords = _parseRecordsFromHtml(remoteHtml);
          final remoteDeleted = _parseDeletedIdsFromHtml(remoteHtml);
          deletedInHtmlIds.addAll(remoteDeleted);
          for (final r in remoteRecords) {
            existingHtmlRecords.add(r);
          }
        }
      }

      final appDir = await getApplicationDocumentsDirectory();
      final internalBackupFile = File(p.join(appDir.path, _defaultHtmlFileName));
      if (existingHtmlRecords.isEmpty && await internalBackupFile.exists()) {
        final backupHtml = await internalBackupFile.readAsString();
        existingHtmlRecords = _parseRecordsFromHtml(backupHtml);
        deletedInHtmlIds.addAll(_parseDeletedIdsFromHtml(backupHtml));
      }

      final Map<String, DocRecord> mergedMap = {};
      for (final rec in existingHtmlRecords) {
        if (!deletedInHtmlIds.contains(rec.id)) {
          mergedMap[rec.id] = rec;
        }
      }
      for (final rec in _records) {
        if (!deletedInHtmlIds.contains(rec.id)) {
          mergedMap[rec.id] = rec;
        }
      }

      final mergedList = mergedMap.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      final updatedHtml =
          _buildCumulativeHtmlDocument(mergedList, deletedInHtmlIds);

      await internalBackupFile.writeAsString(updatedHtml, flush: true);

      bool savedDirectly = false;

      if (targetSyncFile != null) {
        await targetSyncFile.writeAsString(updatedHtml, flush: true);
        savedDirectly = true;
      }

      if (_accessToken.isNotEmpty) {
        final uploadUrl = Uri.parse(
          'https://graph.microsoft.com/v1.0/me/drive/root:$remoteFilePath:/content',
        );
        final putResp = await http.put(
          uploadUrl,
          headers: {
            'Authorization': 'Bearer $_accessToken',
            'Content-Type': 'text/html; charset=utf-8',
          },
          body: utf8.encode(updatedHtml),
        );
        if (putResp.statusCode == 200 || putResp.statusCode == 201) {
          savedDirectly = true;
        }
      }

      if (savedDirectly) {
        _showSnack(
          '원드라이브 지정 폴더에 [$_defaultHtmlFileName] 자동 덮어쓰기 완료! (누적 총 ${mergedList.length}건)',
        );
      } else {
        await Share.shareXFiles(
          [XFile(internalBackupFile.path, mimeType: 'text/html')],
          text: '원드라이브 문서함에 덮어쓸 누적 HTML (${mergedList.length}건)',
        );
      }
    } catch (e) {
      _showSnack('원드라이브 HTML 덮어쓰기 중 오류: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  List<DocRecord> _parseRecordsFromHtml(String htmlContent) {
    final regex = RegExp(
      r'/\*ARCHIVE_DATA_START\*/(.*?)/\*ARCHIVE_DATA_END\*/',
      dotAll: true,
    );
    final match = regex.firstMatch(htmlContent);
    if (match == null) return [];
    try {
      final jsonStr = match.group(1)!.trim();
      final List<dynamic> decoded = jsonDecode(jsonStr) as List<dynamic>;
      return decoded
          .map((e) => DocRecord.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Set<String> _parseDeletedIdsFromHtml(String htmlContent) {
    final regex = RegExp(
      r'/\*DELETED_IDS_START\*/(.*?)/\*DELETED_IDS_END\*/',
      dotAll: true,
    );
    final match = regex.firstMatch(htmlContent);
    if (match == null) return {};
    try {
      final jsonStr = match.group(1)!.trim();
      final List<dynamic> decoded = jsonDecode(jsonStr) as List<dynamic>;
      return decoded.map((e) => e.toString()).toSet();
    } catch (_) {
      return {};
    }
  }

  String _buildCumulativeHtmlDocument(
    List<DocRecord> records,
    Set<String> deletedIds,
  ) {
    final recordsJson = jsonEncode(records.map((r) => r.toJson()).toList());
    final deletedIdsJson = jsonEncode(deletedIds.toList());

    return '''<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>증빙서류 누적 아카이브 (대외공문·자재송장·출장비·병원비)</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Malgun Gothic", "맑은 고딕", sans-serif;
      background: #f3f4f6;
      color: #1f2937;
      height: 100vh;
      display: flex;
      flex-direction: column;
    }
    header {
      background: #1e3a8a;
      color: #ffffff;
      padding: 12px 18px;
      display: flex;
      justify-content: space-between;
      align-items: center;
      flex-wrap: wrap;
      gap: 8px;
    }
    header h1 { font-size: 17px; font-weight: 700; }
    .toolbar { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
    .toolbar select, .toolbar button {
      padding: 6px 12px;
      border-radius: 6px;
      border: none;
      font-size: 13px;
      cursor: pointer;
    }
    .btn-save { background: #10b981; color: white; font-weight: 600; }
    .btn-save:hover { background: #059669; }
    #list-pane {
      height: 48vh;
      overflow-y: auto;
      background: #ffffff;
      border-bottom: 2px solid #cbd5e1;
      padding: 12px;
    }
    table { width: 100%; border-collapse: collapse; font-size: 13px; }
    th, td {
      padding: 9px 8px;
      border-bottom: 1px solid #e5e7eb;
      text-align: left;
      vertical-align: top;
    }
    th { background: #f8fafc; color: #334155; position: sticky; top: 0; font-weight: 700; }
    tr.item-row { cursor: pointer; transition: background 0.15s; }
    tr.item-row:hover { background: #eff6ff; }
    tr.item-row.active { background: #dbeafe; font-weight: 600; }
    .badge {
      display: inline-block;
      padding: 3px 8px;
      border-radius: 9999px;
      font-size: 11px;
      font-weight: 700;
      background: #e0e7ff;
      color: #1e40af;
    }
    .btn-del {
      background: #ef4444;
      color: white;
      border: none;
      padding: 4px 10px;
      border-radius: 4px;
      cursor: pointer;
      font-size: 12px;
    }
    #preview-pane {
      flex: 1;
      background: #0f172a;
      color: #f8fafc;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: flex-start;
      padding: 12px;
      overflow: auto;
    }
    #preview-info {
      margin-bottom: 8px;
      font-size: 13px;
      line-height: 1.5;
      background: #1e293b;
      padding: 8px 14px;
      border-radius: 6px;
      width: 100%;
      max-width: 900px;
    }
    #preview-img {
      max-width: 95%;
      max-height: 36vh;
      object-fit: contain;
      border-radius: 8px;
      box-shadow: 0 4px 16px rgba(0,0,0,0.5);
    }
  </style>
</head>
<body>
  <header>
    <h1>증빙서류 누적 아카이브 (<span id="count-label">0</span>건)</h1>
    <div class="toolbar">
      <select id="category-filter" onchange="renderList()">
        <option value="전체">전체 분류</option>
        <option value="대외공문">1. 대외공문</option>
        <option value="자재송장">2. 자재송장</option>
        <option value="출장비">3. 출장비</option>
        <option value="병원비">4. 병원비</option>
      </select>
      <button class="btn-save" onclick="downloadUpdatedHtml()">삭제 반영된 HTML 파일 저장</button>
    </div>
  </header>

  <div id="list-pane">
    <table>
      <thead>
        <tr>
          <th style="width: 95px;">분류</th>
          <th style="width: 220px;">대표 제목 / 건명</th>
          <th>문서별 세부 입력 항목</th>
          <th style="width: 145px;">등록일시</th>
          <th style="width: 70px;">삭제</th>
        </tr>
      </thead>
      <tbody id="list-body"></tbody>
    </table>
  </div>

  <div id="preview-pane">
    <div id="preview-info">상단 목록을 클릭하면 문서별 상세 필드와 평평하게 스캔된 사진이 아래에 표시됩니다.</div>
    <img id="preview-img" style="display:none;" alt="증빙서류 사진" />
  </div>

  <script>
    let archiveRecords = /*ARCHIVE_DATA_START*/ $recordsJson /*ARCHIVE_DATA_END*/;
    let deletedIds = /*DELETED_IDS_START*/ $deletedIdsJson /*DELETED_IDS_END*/;
    let selectedId = archiveRecords.length > 0 ? archiveRecords[0].id : null;

    function formatFieldsSummary(item) {
      const f = item.fields || {};
      if (item.category === '대외공문') {
        return `<b>보낸날짜:</b> \${escapeHtml(f.sentDate || '-')} | <b>보낸사람:</b> \${escapeHtml(f.sender || '-')} | <b>공문번호:</b> \${escapeHtml(f.docNumber || '-')} | <b>회신기한:</b> \${escapeHtml(f.replyDeadline || '-')}<br/><b>주요내용(AI요약):</b> \${escapeHtml(f.aiSummary || '-')}`;
      } else if (item.category === '자재송장') {
        return `<b>도착일:</b> \${escapeHtml(f.arrivalDate || '-')} | <b>주문번호:</b> \${escapeHtml(f.orderNumber || '-')} | <b>제품/규격:</b> \${escapeHtml(f.productName || '-')} (\${escapeHtml(f.specName || '-')}) | <b>수량/단위:</b> \${escapeHtml(f.quantity || '-')}\${escapeHtml(f.unit || '')} | <b>중량:</b> \${escapeHtml(f.weight || '-')} | <b>공급자:</b> \${escapeHtml(f.supplierName || '-')}`;
      } else if (item.category === '출장비') {
        return `<b>출장거리:</b> \${escapeHtml(f.distanceKm || '0')}km | <b>교통비(자가용 왕복):</b> \${Number(f.carFare || 0).toLocaleString()}원 | <b>영수증합산:</b> \${Number(f.receiptTotal || 0).toLocaleString()}원 | <b>하이패스합산:</b> \${Number(f.hipassTotal || 0).toLocaleString()}원 | <b>총합계:</b> \${Number(f.totalAmount || 0).toLocaleString()}원`;
      } else if (item.category === '병원비') {
        return `<b>상호:</b> \${escapeHtml(f.clinicName || '-')} | <b>사업자등록번호:</b> \${escapeHtml(f.bizRegNumber || '-')} | <b>발행일:</b> \${escapeHtml(f.issueDate || '-')} | <b>총수납금액:</b> \${Number(f.totalPaid || 0).toLocaleString()}원`;
      }
      return '';
    }

    function getTitle(item) {
      const f = item.fields || {};
      if (item.category === '대외공문') return f.title || '대외공문';
      if (item.category === '자재송장') return (f.productName || '자재송장') + (f.supplierName ? ' (' + f.supplierName + ')' : '');
      if (item.category === '출장비') return '왕복 ' + (f.distanceKm || '0') + 'km 출장 (' + Number(f.totalAmount || 0).toLocaleString() + '원)';
      if (item.category === '병원비') return (f.clinicName || '병원비') + ' (' + Number(f.totalPaid || 0).toLocaleString() + '원)';
      return item.category;
    }

    function renderList() {
      const filter = document.getElementById('category-filter').value;
      const tbody = document.getElementById('list-body');
      tbody.innerHTML = '';

      const filtered = archiveRecords.filter(r => filter === '전체' || r.category === filter);
      document.getElementById('count-label').textContent = filtered.length;

      filtered.forEach(item => {
        const tr = document.createElement('tr');
        tr.className = 'item-row' + (item.id === selectedId ? ' active' : '');
        tr.onclick = () => { selectedId = item.id; renderList(); };

        tr.innerHTML = `
          <td><span class="badge">\${escapeHtml(item.category)}</span></td>
          <td>\${escapeHtml(getTitle(item))}</td>
          <td>\${formatFieldsSummary(item)}</td>
          <td>\${escapeHtml(item.createdAt)}</td>
          <td><button class="btn-del" onclick="deleteRecord(event, '\${item.id}')">삭제</button></td>
        `;
        tbody.appendChild(tr);
      });

      updatePreview();
    }

    function updatePreview() {
      const item = archiveRecords.find(r => r.id === selectedId);
      const infoEl = document.getElementById('preview-info');
      const imgEl = document.getElementById('preview-img');

      if (!item) {
        infoEl.textContent = '선택된 항목이 없습니다.';
        imgEl.style.display = 'none';
        return;
      }

      infoEl.innerHTML = `<div><b>[\${escapeHtml(item.category)}] \${escapeHtml(getTitle(item))}</b></div><div style="margin-top:4px;">\${formatFieldsSummary(item)}</div>`;
      imgEl.src = 'data:image/jpeg;base64,' + item.base64Image;
      imgEl.style.display = 'block';
    }

    function deleteRecord(event, id) {
      event.stopPropagation();
      if (!confirm('이 항목을 HTML 누적 목록에서 삭제하시겠습니까?')) return;
      archiveRecords = archiveRecords.filter(r => r.id !== id);
      if (!deletedIds.includes(id)) deletedIds.push(id);
      if (selectedId === id) {
        selectedId = archiveRecords.length > 0 ? archiveRecords[0].id : null;
      }
      renderList();
    }

    function downloadUpdatedHtml() {
      let currentHtml = document.documentElement.outerHTML;
      currentHtml = currentHtml.replace(
        /\\/\\*ARCHIVE_DATA_START\\*\\/[\\s\\S]*?\\/\\*ARCHIVE_DATA_END\\*\\//,
        '/*ARCHIVE_DATA_START*/ ' + JSON.stringify(archiveRecords) + ' /*ARCHIVE_DATA_END*/'
      );
      currentHtml = currentHtml.replace(
        /\\/\\*DELETED_IDS_START\\*\\/[\\s\\S]*?\\/\\*DELETED_IDS_END\\*\\//,
        '/*DELETED_IDS_START*/ ' + JSON.stringify(deletedIds) + ' /*DELETED_IDS_END*/'
      );
      const blob = new Blob(['<!DOCTYPE html>\\n' + currentHtml], { type: 'text/html;charset=utf-8' });
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = '$_defaultHtmlFileName';
      a.click();
    }

    function escapeHtml(str) {
      return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
    }

    renderList();
  </script>
</body>
</html>''';
  }

  Future<void> _exportAndSharePdf() async {
    final targetRecords = _filteredRecords;
    if (targetRecords.isEmpty) {
      _showSnack('내보낼 증빙서류 항목이 없습니다.');
      return;
    }

    setState(() => _isBusy = true);
    try {
      final koreanFont = await PdfGoogleFonts.nanumGothicRegular();
      final koreanBoldFont = await PdfGoogleFonts.nanumGothicBold();

      final pdf = pw.Document();
      final nowDateStr = DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now());

      int totalTravelSum = 0;
      int totalMedicalSum = 0;
      for (final r in targetRecords) {
        if (r.category == DocCategory.travel) {
          totalTravelSum += int.tryParse(
                (r.fields['totalAmount'] ?? '0').replaceAll(RegExp(r'[^0-9]'), ''),
              ) ??
              0;
        } else if (r.category == DocCategory.medical) {
          totalMedicalSum += int.tryParse(
                (r.fields['totalPaid'] ?? '0').replaceAll(RegExp(r'[^0-9]'), ''),
              ) ??
              0;
        }
      }

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(28),
          build: (pw.Context ctx) {
            return [
              pw.Container(
                padding: const pw.EdgeInsets.all(12),
                decoration: pw.BoxDecoration(
                  color: PdfColors.indigo900,
                  borderRadius: pw.BorderRadius.circular(6),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          '증빙서류 종합 요약표 ($_selectedCategoryFilter)',
                          style: pw.TextStyle(
                            font: koreanBoldFont,
                            fontSize: 16,
                            color: PdfColors.white,
                          ),
                        ),
                        pw.SizedBox(height: 4),
                        pw.Text(
                          '출력일시: $nowDateStr  |  총 ${targetRecords.length}건',
                          style: pw.TextStyle(
                            font: koreanFont,
                            fontSize: 10,
                            color: PdfColors.grey200,
                          ),
                        ),
                      ],
                    ),
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        if (totalTravelSum > 0)
                          pw.Text(
                            '출장비 합계: ${NumberFormat('#,###').format(totalTravelSum)}원',
                            style: pw.TextStyle(
                              font: koreanBoldFont,
                              fontSize: 10,
                              color: PdfColors.amber200,
                            ),
                          ),
                        if (totalMedicalSum > 0)
                          pw.Text(
                            '병원비 합계: ${NumberFormat('#,###').format(totalMedicalSum)}원',
                            style: pw.TextStyle(
                              font: koreanBoldFont,
                              fontSize: 10,
                              color: PdfColors.green200,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 14),
              pw.TableHelper.fromTextArray(
                headers: ['순번', '분류', '기준일자', '제목 / 상호 / 품명', '핵심 세부내역 (요약)', '금액 / 수량 / 기한'],
                headerStyle: pw.TextStyle(
                  font: koreanBoldFont,
                  fontSize: 9.5,
                  color: PdfColors.white,
                ),
                headerDecoration: const pw.BoxDecoration(
                  color: PdfColors.blueGrey800,
                ),
                cellStyle: pw.TextStyle(
                  font: koreanFont,
                  fontSize: 8.5,
                ),
                cellPadding: const pw.EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 6,
                ),
                columnWidths: {
                  0: const pw.FixedColumnWidth(28),
                  1: const pw.FixedColumnWidth(48),
                  2: const pw.FixedColumnWidth(58),
                  3: const pw.FlexColumnWidth(1.4),
                  4: const pw.FlexColumnWidth(2.3),
                  5: const pw.FixedColumnWidth(75),
                },
                data: List.generate(targetRecords.length, (index) {
                  final r = targetRecords[index];
                  return [
                    '${index + 1}',
                    r.category,
                    r.referenceDate,
                    r.displayTitle,
                    r.summaryKeyDetails,
                    r.summaryAmountOrMetric,
                  ];
                }),
              ),
            ];
          },
        ),
      );

      for (int i = 0; i < targetRecords.length; i++) {
        final rec = targetRecords[i];
        final imgBytes = base64Decode(rec.base64Image);
        final pdfImage = pw.MemoryImage(imgBytes);
        final detailPairs = _getCategoryFieldPairs(rec);

        pdf.addPage(
          pw.Page(
            pageFormat: PdfPageFormat.a4,
            margin: const pw.EdgeInsets.all(24),
            build: (pw.Context ctx) {
              return pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  pw.Container(
                    padding: const pw.EdgeInsets.all(10),
                    decoration: pw.BoxDecoration(
                      color: PdfColors.blue50,
                      borderRadius: pw.BorderRadius.circular(6),
                      border: pw.Border.all(color: PdfColors.blue200),
                    ),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          '[#${i + 1} ${rec.category}] ${rec.displayTitle}',
                          style: pw.TextStyle(
                            font: koreanBoldFont,
                            fontSize: 14,
                            color: PdfColors.blue900,
                          ),
                        ),
                        pw.SizedBox(height: 6),
                        pw.Wrap(
                          spacing: 14,
                          runSpacing: 4,
                          children: detailPairs.map((pair) {
                            return pw.RichText(
                              text: pw.TextSpan(
                                children: [
                                  pw.TextSpan(
                                    text: '${pair.key}: ',
                                    style: pw.TextStyle(
                                      font: koreanBoldFont,
                                      fontSize: 10,
                                      color: PdfColors.blueGrey800,
                                    ),
                                  ),
                                  pw.TextSpan(
                                    text: pair.value,
                                    style: pw.TextStyle(
                                      font: koreanFont,
                                      fontSize: 10,
                                      color: PdfColors.black,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                  pw.SizedBox(height: 10),
                  pw.Expanded(
                    child: pw.Container(
                      padding: const pw.EdgeInsets.all(4),
                      decoration: pw.BoxDecoration(
                        border: pw.Border.all(color: PdfColors.grey400, width: 0.8),
                      ),
                      child: pw.Center(
                        child: pw.Image(pdfImage, fit: pw.BoxFit.contain),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      }

      final Uint8List pdfBytes = await pdf.save();
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
      final pdfFile = File(
        p.join(tempDir.path, '증빙서류_스캔PDF_${_selectedCategoryFilter}_$timestamp.pdf'),
      );
      await pdfFile.writeAsBytes(pdfBytes, flush: true);

      await Share.shareXFiles(
        [XFile(pdfFile.path, mimeType: 'application/pdf')],
        text: '증빙서류 스캔 PDF (${targetRecords.length}건)',
      );
    } catch (e) {
      _showSnack('PDF 생성 중 오류가 발생했습니다: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  List<MapEntry<String, String>> _getCategoryFieldPairs(DocRecord rec) {
    final f = rec.fields;
    switch (rec.category) {
      case DocCategory.officialDoc:
        return [
          MapEntry('보낸날짜', f['sentDate'] ?? '-'),
          MapEntry('보낸사람', f['sender'] ?? '-'),
          MapEntry('공문번호', f['docNumber'] ?? '-'),
          MapEntry('제목', f['title'] ?? '-'),
          MapEntry('회신기한', f['replyDeadline'] ?? '-'),
          MapEntry('주요내용(AI 1문장 요약)', f['aiSummary'] ?? '-'),
        ];
      case DocCategory.invoice:
        return [
          MapEntry('도착일', f['arrivalDate'] ?? '-'),
          MapEntry('주문번호', f['orderNumber'] ?? '-'),
          MapEntry('제품명', f['productName'] ?? '-'),
          MapEntry('규격명', f['specName'] ?? '-'),
          MapEntry('단위', f['unit'] ?? '-'),
          MapEntry('수량', f['quantity'] ?? '-'),
          MapEntry('중량', f['weight'] ?? '-'),
          MapEntry('공급자상호', f['supplierName'] ?? '-'),
        ];
      case DocCategory.travel:
        return [
          MapEntry('출장거리(편도)', '${f['distanceKm'] ?? '0'} km'),
          MapEntry('교통비(자가용=거리×300×2)', '${DocRecord._formatCurrency(f['carFare'])}원'),
          MapEntry('영수증금액합산', '${DocRecord._formatCurrency(f['receiptTotal'])}원'),
          MapEntry('하이패스금액합산', '${DocRecord._formatCurrency(f['hipassTotal'])}원'),
          MapEntry('총 출장비 합계', '${DocRecord._formatCurrency(f['totalAmount'])}원'),
        ];
      case DocCategory.medical:
        return [
          MapEntry('상호', f['clinicName'] ?? '-'),
          MapEntry('사업자등록번호', f['bizRegNumber'] ?? '-'),
          MapEntry('발행일', f['issueDate'] ?? '-'),
          MapEntry('총수납금액', '${DocRecord._formatCurrency(f['totalPaid'])}원'),
        ];
      default:
        return [];
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final items = _filteredRecords;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
        title: const Text('증빙서류 스냅 (공문·송장·출장·병원)'),
        actions: [
          IconButton(
            tooltip: '원드라이브 폴더 & AI 설정',
            icon: Icon(
              (_oneDriveLocalDir.isNotEmpty || _accessToken.isNotEmpty)
                  ? Icons.cloud_done
                  : Icons.settings,
            ),
            onPressed: _openSettingsDialog,
          ),
          IconButton(
            tooltip: '원드라이브 특정 폴더에 HTML 자동 덮어쓰기',
            icon: const Icon(Icons.cloud_upload),
            onPressed: _isBusy ? null : _oneClickSyncHtmlToOneDrive,
          ),
          IconButton(
            tooltip: '요약표 포함 PDF 내보내기 및 공유',
            icon: const Icon(Icons.picture_as_pdf),
            onPressed: _isBusy ? null : _exportAndSharePdf,
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                color: Colors.grey.shade100,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: DocCategory.filterList.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (ctx, idx) {
                    final cat = DocCategory.filterList[idx];
                    final selected = cat == _selectedCategoryFilter;
                    return ChoiceChip(
                      label: Text(cat),
                      selected: selected,
                      onSelected: (_) {
                        setState(() {
                          _selectedCategoryFilter = cat;
                          final currentList = _filteredRecords;
                          if (!currentList.any((r) => r.id == _selectedRecord?.id)) {
                            _selectedRecord =
                                currentList.isNotEmpty ? currentList.first : null;
                          }
                        });
                      },
                    );
                  },
                ),
              ),
              Expanded(
                flex: 1,
                child: items.isEmpty
                    ? const Center(
                        child: Text(
                          '등록된 증빙서류가 없습니다.\n우측 하단 [서류 촬영] 버튼을 눌러 추가하세요.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (ctx, idx) {
                          final rec = items[idx];
                          final isSelected = _selectedRecord?.id == rec.id;
                          return ListTile(
                            selected: isSelected,
                            selectedTileColor: Colors.blue.shade50,
                            leading: CircleAvatar(
                              backgroundColor: Colors.indigo.shade100,
                              child: Text(
                                rec.category.substring(0, 2),
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.indigo,
                                ),
                              ),
                            ),
                            title: Text(
                              rec.displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            subtitle: Text(
                              rec.displaySubtitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: IconButton(
                              icon: const Icon(
                                Icons.delete_outline,
                                color: Colors.redAccent,
                              ),
                              onPressed: () => _deleteLocalRecord(rec),
                            ),
                            onTap: () => setState(() => _selectedRecord = rec),
                          );
                        },
                      ),
              ),
              const Divider(height: 2, thickness: 2),
              Expanded(
                flex: 1,
                child: Container(
                  width: double.infinity,
                  color: const Color(0xFF0F172A),
                  child: _selectedRecord == null
                      ? const Center(
                          child: Text(
                            '위 목록에서 항목을 선택하면\n문서별 세부 항목과 평평하게 스캔된 사진이 여기에 표시됩니다.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white70),
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              color: Colors.black54,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '[${_selectedRecord!.category}] ${_selectedRecord!.displayTitle}',
                                    style: const TextStyle(
                                      color: Colors.amberAccent,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13.5,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 2,
                                    children: _getCategoryFieldPairs(_selectedRecord!)
                                        .map(
                                          (e) => Text(
                                            '${e.key}: ${e.value}',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 11.5,
                                            ),
                                          ),
                                        )
                                        .toList(),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: InteractiveViewer(
                                minScale: 0.8,
                                maxScale: 4.5,
                                child: Center(
                                  child: _buildRecordImage(_selectedRecord!),
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
          if (_isBusy)
            Container(
              color: Colors.black45,
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'gallery_btn',
            tooltip: '갤러리에서 사진 불러오기',
            onPressed: () => _addRecordDialog(ImageSource.gallery),
            child: const Icon(Icons.photo_library),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.extended(
            heroTag: 'camera_btn',
            onPressed: () => _addRecordDialog(ImageSource.camera),
            icon: const Icon(Icons.camera_alt),
            label: const Text('서류 촬영'),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordImage(DocRecord record) {
    final file = File(record.imagePath);
    if (file.existsSync()) {
      return Image.file(file, fit: BoxFit.contain);
    }
    if (record.base64Image.isNotEmpty) {
      return Image.memory(
        base64Decode(record.base64Image),
        fit: BoxFit.contain,
      );
    }
    return const Text(
      '이미지를 불러올 수 없습니다.',
      style: TextStyle(color: Colors.white),
    );
  }
}
