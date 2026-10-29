import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

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
      title: '증빙서류 스냅 v18',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1E3A8A)),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

/// 문서 대분류 상수 (대외공문 / 자재송장 / 출장비 / 병원비)
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

/// 출장비 전용 5대 구분 ('자차', '택시', '기차', '식대', '통행료')
class TravelDivision {
  static const String car = '자차'; // 지도 실시간추천 km × 2 × 300원
  static const String taxi = '택시'; // 택시영수증 / 카카오택시 증빙
  static const String train = '기차'; // 코레일 / SRT 영수증
  static const String meal = '식대'; // 그 외 일반 영수증
  static const String toll = '통행료'; // 하이패스 증빙

  static const List<String> list = [
    car,
    taxi,
    train,
    meal,
    toll,
  ];
}

/// 자재송장 품목 행(규격별 1줄) 모델
class InvoiceSpecRow {
  final TextEditingController productCtrl;
  final TextEditingController specCtrl;
  final TextEditingController unitCtrl;
  final TextEditingController qtyCtrl;

  InvoiceSpecRow({
    String product = '',
    String spec = '',
    String unit = 'ton',
    String qty = '',
  })  : productCtrl = TextEditingController(text: product),
        specCtrl = TextEditingController(text: spec),
        unitCtrl = TextEditingController(text: unit),
        qtyCtrl = TextEditingController(text: qty);
}

// =============================================================================
// 백그라운드 Isolate에서 실행되는 초고화질 + 초고속 4점 평탄화 함수
// =============================================================================
class WarpRequest {
  final Uint8List originalBytes;
  final List<double> cornerCoords; // [x0, y0, x1, y1, x2, y2, x3, y3]
  final bool enhanceContrast;
  final int rotationQuarterTurns; // 0, 1(90도), 2(180도), 3(270도)

  WarpRequest({
    required this.originalBytes,
    required this.cornerCoords,
    required this.enhanceContrast,
    required this.rotationQuarterTurns,
  });
}

Uint8List _performPerspectiveWarpIsolate(WarpRequest req) {
  final c = req.cornerCoords;
  final bool isFullEdge = (c[0] <= 0.03 &&
      c[1] <= 0.03 &&
      c[2] >= 0.97 &&
      c[3] <= 0.03 &&
      c[4] >= 0.97 &&
      c[5] >= 0.97 &&
      c[6] <= 0.03 &&
      c[7] >= 0.97);

  if (isFullEdge && !req.enhanceContrast && req.rotationQuarterTurns % 4 == 0) {
    return req.originalBytes;
  }

  final decoded = img.decodeImage(req.originalBytes);
  if (decoded == null) return req.originalBytes;
  img.Image src = img.bakeOrientation(decoded);

  final int turns = req.rotationQuarterTurns % 4;
  if (turns == 1) {
    src = img.copyRotate(src, angle: 90);
  } else if (turns == 2) {
    src = img.copyRotate(src, angle: 180);
  } else if (turns == 3) {
    src = img.copyRotate(src, angle: 270);
  }

  if (isFullEdge && !req.enhanceContrast) {
    return Uint8List.fromList(img.encodeJpg(src, quality: 95));
  }

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

  double avgW = (topW + botW) / 2.0;
  double avgH = (leftH + rightH) / 2.0;
  if (avgW < 10) avgW = src.width.toDouble();
  if (avgH < 10) avgH = src.height.toDouble();

  const double maxSide = 2200.0;
  double scale = 1.0;
  if (math.max(avgW, avgH) > maxSide) {
    scale = maxSide / math.max(avgW, avgH);
  }

  final int dstW = (avgW * scale).round().clamp(250, 2200);
  final int dstH = (avgH * scale).round().clamp(250, 2200);

  final dst = img.Image(width: dstW, height: dstH);

  for (int y = 0; y < dstH; y++) {
    final v = dstH > 1 ? y / (dstH - 1) : 0.0;
    for (int x = 0; x < dstW; x++) {
      final u = dstW > 1 ? x / (dstW - 1) : 0.0;
      final sx = ((1 - u) * (1 - v) * p0x +
              u * (1 - v) * p1x +
              u * v * p2x +
              (1 - u) * v * p3x)
          .clamp(0.0, (src.width - 1).toDouble());
      final sy = ((1 - u) * (1 - v) * p0y +
              u * (1 - v) * p1y +
              u * v * p2y +
              (1 - u) * v * p3y)
          .clamp(0.0, (src.height - 1).toDouble());

      final pixel = src.getPixelLinear(sx, sy);

      if (req.enhanceContrast) {
        int r = ((pixel.r - 128) * 1.16 + 132).round().clamp(0, 255);
        int g = ((pixel.g - 128) * 1.16 + 132).round().clamp(0, 255);
        int b = ((pixel.b - 128) * 1.16 + 132).round().clamp(0, 255);
        dst.setPixelRgb(x, y, r, g, b);
      } else {
        dst.setPixel(x, y, pixel);
      }
    }
  }

  return Uint8List.fromList(img.encodeJpg(dst, quality: 95));
}

// =============================================================================
// 4점 모서리 지정 + 가로/세로 회전 + 원본 비율 100% 보존 스캔 다이얼로그
// =============================================================================
class PerspectiveCropDialog extends StatefulWidget {
  final Uint8List originalBytes;

  const PerspectiveCropDialog({super.key, required this.originalBytes});

  @override
  State<PerspectiveCropDialog> createState() => _PerspectiveCropDialogState();
}

class _PerspectiveCropDialogState extends State<PerspectiveCropDialog> {
  List<Offset> _corners = const [
    Offset(0.01, 0.01),
    Offset(0.99, 0.01),
    Offset(0.99, 0.99),
    Offset(0.01, 0.99),
  ];

  bool _enhanceScanContrast = false;
  bool _isProcessing = false;
  int? _activeCornerIndex;
  double? _baseAspectRatio;
  int _rotationQuarterTurns = 0;

  @override
  void initState() {
    super.initState();
    _resolveImageAspectRatio();
  }

  Future<void> _resolveImageAspectRatio() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.originalBytes);
      final frame = await codec.getNextFrame();
      final w = frame.image.width.toDouble();
      final h = frame.image.height.toDouble();
      if (w > 0 && h > 0 && mounted) {
        setState(() => _baseAspectRatio = w / h);
      }
    } catch (_) {
      if (mounted) setState(() => _baseAspectRatio = 1.0);
    }
  }

  double get _effectiveAspectRatio {
    final base = _baseAspectRatio ?? 1.0;
    if (_rotationQuarterTurns % 2 == 1) {
      return 1.0 / base;
    }
    return base;
  }

  void _rotate90() {
    setState(() {
      _rotationQuarterTurns = (_rotationQuarterTurns + 1) % 4;
      _corners = const [
        Offset(0.01, 0.01),
        Offset(0.99, 0.01),
        Offset(0.99, 0.99),
        Offset(0.01, 0.99),
      ];
    });
  }

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
          rotationQuarterTurns: _rotationQuarterTurns,
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
        title: const Text('가로/세로 정비율 스캔 (v18)'),
        actions: [
          IconButton(
            tooltip: '90도 회전 (가로 문서 방향 맞추기)',
            onPressed: _isProcessing ? null : _rotate90,
            icon: const Icon(Icons.rotate_right, color: Colors.amberAccent),
          ),
          TextButton(
            onPressed: _isProcessing
                ? null
                : () => Navigator.pop(context, widget.originalBytes),
            child: const Text(
              '원본 즉시 사용',
              style: TextStyle(
                color: Colors.amberAccent,
                fontWeight: FontWeight.bold,
              ),
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
                    '점을 안 움직이고 하단 버튼을 누르면 0.1초 만에 원본 화질 그대로 빠르게 넘어갑니다.',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '명암보정',
                      style: TextStyle(color: Colors.amberAccent, fontSize: 12),
                    ),
                    Switch(
                      value: _enhanceScanContrast,
                      onChanged: (v) =>
                          setState(() => _enhanceScanContrast = v),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: _baseAspectRatio == null
                    ? const CircularProgressIndicator(color: Colors.white)
                    : AspectRatio(
                        aspectRatio: _effectiveAspectRatio,
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
                                if (minDist < 70) {
                                  setState(
                                      () => _activeCornerIndex = closestIdx);
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
                              onPanEnd: (_) =>
                                  setState(() => _activeCornerIndex = null),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  RotatedBox(
                                    quarterTurns: _rotationQuarterTurns,
                                    child: Image.memory(
                                      widget.originalBytes,
                                      fit: BoxFit.contain,
                                      filterQuality: FilterQuality.high,
                                    ),
                                  ),
                                  CustomPaint(
                                    painter:
                                        _QuadOverlayPainter(corners: _corners),
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
                                              : Colors.blueAccent
                                                  .withOpacity(0.85),
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                              color: Colors.white, width: 2.5),
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
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.amberAccent,
                      side: const BorderSide(color: Colors.amberAccent),
                      minimumSize: const Size(88, 48),
                    ),
                    onPressed: _isProcessing ? null : _rotate90,
                    icon: const Icon(Icons.rotate_right, size: 18),
                    label: const Text('회전'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed:
                          _isProcessing ? null : _applyPerspectiveFlatten,
                      icon: _isProcessing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.bolt),
                      label: Text(
                        _isProcessing
                            ? '처리 중...'
                            : '확인 & 빠른 글자 자동 인식',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
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
      ..color = Colors.blueAccent.withOpacity(0.12)
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

  String get subCategory {
    return fields['subCategory']?.trim() ?? '';
  }

  String get travelDivision {
    final div = fields['travelDivision']?.trim() ?? '';
    return div.isNotEmpty ? div : TravelDivision.meal;
  }

  /// 대외공문 수발신 구분 ('수신' = 받은 공문 -> 보낸사람 표시 / '발신' = 보내는 공문 -> 받는사람 표시)
  bool get isOutgoingOfficialDoc {
    return fields['docDirection'] == '발신';
  }

  String get officialCounterpartyLabel {
    return isOutgoingOfficialDoc ? '받는사람' : '보낸사람';
  }

  String get officialCounterpartyValue {
    if (isOutgoingOfficialDoc) {
      final rec = fields['recipient']?.trim() ?? '';
      return rec.isNotEmpty ? rec : (fields['sender']?.trim() ?? '-');
    }
    return fields['sender']?.trim().isNotEmpty == true
        ? fields['sender']!.trim()
        : '-';
  }

  /// 날짜를 첨부 표 양식처럼 `2021.09.08` 형식으로 변환
  static String formatDotDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '-';
    final m = RegExp(r'(\d{4})\s*[-./년]\s*(\d{1,2})\s*[-./월]\s*(\d{1,2})')
        .firstMatch(raw);
    if (m != null) {
      return '${m.group(1)}.${m.group(2)!.padLeft(2, '0')}.${m.group(3)!.padLeft(2, '0')}';
    }
    return raw.trim();
  }

  int get numericAmount {
    String? raw;
    if (category == DocCategory.travel) {
      raw = fields['totalAmount'];
    } else if (category == DocCategory.medical) {
      raw = fields['totalPaid'];
    } else {
      raw = fields['amount'];
    }
    if (raw == null || raw.trim().isEmpty) return 0;
    final cleaned = raw.replaceAll(RegExp(r'[^0-9]'), '');
    return int.tryParse(cleaned) ?? 0;
  }

  String get displayTitle {
    switch (category) {
      case DocCategory.officialDoc:
        final title = fields['title'] ?? '';
        return title.isNotEmpty ? title : '대외공문';
      case DocCategory.invoice:
        final prod = fields['productName'] ?? '';
        final spec = fields['specName'] ?? '';
        return '$prod ${spec.isNotEmpty ? "($spec)" : ""}'.trim();
      case DocCategory.travel:
        final div = travelDivision;
        final total = _formatCurrency(fields['totalAmount']);
        final merchant = fields['merchantName']?.trim() ?? '';
        if (div == TravelDivision.car) {
          final km = fields['distanceKm'] ?? '0';
          return '[자차] ${km}km × 2 × 300원 = $total원';
        }
        return '[$div] ${merchant.isNotEmpty ? "$merchant " : ""}($total원)';
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
        final deadline = formatDotDate(fields['replyDeadline']);
        return '$officialCounterpartyLabel: $officialCounterpartyValue | 공문번호: ${fields['docNumber'] ?? '-'} | 회신요청일: $deadline';
      case DocCategory.invoice:
        return '날짜: ${formatDotDate(fields['arrivalDate'])} | 규격: ${fields['specName'] ?? '-'} | 단위: ${fields['unit'] ?? 'ton'} | 수량: ${fields['quantity'] ?? '-'}';
      case DocCategory.travel:
        final div = travelDivision;
        if (div == TravelDivision.car) {
          final km = fields['distanceKm'] ?? '0';
          return '구분: 자차 (실시간추천 ${km}km × 2(왕복) × 300원 = ${_formatCurrency(fields['totalAmount'])}원) | 일자: ${fields['date'] ?? createdAt.split(' ').first}';
        }
        return '구분: $div | 상호/내역: ${fields['merchantName'] ?? '-'} | 금액: ${_formatCurrency(fields['totalAmount'])}원';
      case DocCategory.medical:
        return '사업자번호: ${fields['bizRegNumber'] ?? '-'} | 발행일: ${fields['issueDate'] ?? '-'} | 수납액: ${_formatCurrency(fields['totalPaid'])}원';
      default:
        return createdAt;
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
  static const String _prefsUserSubCatsKey = 'user_registered_sub_cats_v2';
  static const String _prefsOneDriveSyncDirKey = 'onedrive_local_sync_dir';
  static const String _prefsOneDriveSubfolderKey = 'onedrive_target_subfolder';
  static const String _prefsAccessTokenKey = 'onedrive_access_token';
  static const String _prefsGeminiApiKey = 'gemini_api_key';
  static const String _prefsSplitRatioKey = 'list_photo_split_ratio_v1';
  static const String _prefsHorizSplitRatioKey =
      'detail_left_right_split_ratio_v1';

  List<DocRecord> _records = [];
  String _selectedCategoryFilter = DocCategory.officialDoc;
  String _selectedSubCategoryFilter = '전체';
  String _selectedTravelDivisionFilter = '전체';
  DocRecord? _selectedRecord;
  bool _isBusy = false;

  // 상하 분할 비율 (상단 리스트 vs 하단 상세보기)
  double _listSplitRatio = 0.44;
  // ★ 하단 좌우 분할 비율 (왼쪽 상세정보 vs 오른쪽 사진 영역)
  double _detailHorizSplitRatio = 0.42;

  Map<String, List<String>> _userSubCategoriesMap = {
    DocCategory.officialDoc: [],
    DocCategory.invoice: [],
    DocCategory.travel: [],
    DocCategory.medical: [],
  };

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

    final Map<String, List<String>> loadedSubMap = {
      for (final c in DocCategory.inputList) c: <String>[],
    };

    final rawSubJson = prefs.getString(_prefsUserSubCatsKey);
    if (rawSubJson != null && rawSubJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawSubJson) as Map<String, dynamic>;
        decoded.forEach((key, value) {
          if (value is List) {
            loadedSubMap[key] = value
                .map((e) => e.toString().trim())
                .where((s) => s.isNotEmpty)
                .toList();
          }
        });
      } catch (_) {}
    }

    for (final r in loaded) {
      final sub = r.subCategory;
      if (sub.isNotEmpty) {
        final list = loadedSubMap[r.category] ?? <String>[];
        if (!list.contains(sub)) {
          list.add(sub);
          loadedSubMap[r.category] = list;
        }
      }
    }

    setState(() {
      _records = loaded;
      _userSubCategoriesMap = loadedSubMap;
      if (_records.isNotEmpty) {
        _selectedCategoryFilter = _records.first.category;
        _selectedRecord = _records.first;
      }
      _oneDriveLocalDir = prefs.getString(_prefsOneDriveSyncDirKey) ?? '';
      _oneDriveSubfolder =
          prefs.getString(_prefsOneDriveSubfolderKey) ?? 'Documents/증빙서류함';
      _accessToken = prefs.getString(_prefsAccessTokenKey) ?? '';
      _geminiApiKey = prefs.getString(_prefsGeminiApiKey) ?? '';
      _listSplitRatio =
          (prefs.getDouble(_prefsSplitRatioKey) ?? 0.44).clamp(0.18, 0.82);
      _detailHorizSplitRatio =
          (prefs.getDouble(_prefsHorizSplitRatioKey) ?? 0.42).clamp(0.18, 0.82);
    });
  }

  Future<void> _saveLocalRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = _records.map((r) => jsonEncode(r.toJson())).toList();
    await prefs.setStringList(_prefsRecordsKey, encoded);
  }

  Future<void> _registerUserSubCategory(String majorCat, String subCat) async {
    final clean = subCat.trim();
    if (clean.isEmpty) return;
    final list = List<String>.from(_userSubCategoriesMap[majorCat] ?? []);
    if (!list.contains(clean)) {
      list.add(clean);
      setState(() {
        _userSubCategoriesMap[majorCat] = list;
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsUserSubCatsKey,
        jsonEncode(_userSubCategoriesMap),
      );
    }
  }

  Future<String?> _promptAddNewSubCategory(String parentCategory) async {
    final ctrl = TextEditingController();
    final added = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('[$parentCategory] 내 카테고리 등록'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '새 카테고리 이름 입력',
            hintText: '한 번 등록하면 다음부터 목록에서 바로 고를 수 있습니다',
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
      await _registerUserSubCategory(parentCategory, added);
      return added;
    }
    return null;
  }

  List<DocRecord> get _recordsInSelectedMajorCategory {
    if (_selectedCategoryFilter == DocCategory.all) return _records;
    return _records
        .where((r) => r.category == _selectedCategoryFilter)
        .toList();
  }

  List<DocRecord> get _subCategoryFilteredRecords {
    final majorList = _recordsInSelectedMajorCategory;
    if (_selectedSubCategoryFilter == '전체') return majorList;
    if (_selectedSubCategoryFilter == '미지정') {
      return majorList.where((r) => r.subCategory.isEmpty).toList();
    }
    return majorList
        .where((r) => r.subCategory == _selectedSubCategoryFilter)
        .toList();
  }

  List<DocRecord> get _filteredRecords {
    final subFiltered = _subCategoryFilteredRecords;
    if (_selectedCategoryFilter == DocCategory.travel &&
        _selectedTravelDivisionFilter != '전체') {
      return subFiltered
          .where((r) => r.travelDivision == _selectedTravelDivisionFilter)
          .toList();
    }
    return subFiltered;
  }

  List<String> get _userRegisteredSubCategoriesForCurrentTab {
    final Set<String> subs = {};
    if (_selectedCategoryFilter == DocCategory.all) {
      for (final list in _userSubCategoriesMap.values) {
        subs.addAll(list);
      }
      for (final r in _records) {
        if (r.subCategory.isNotEmpty) subs.add(r.subCategory);
      }
    } else {
      subs.addAll(_userSubCategoriesMap[_selectedCategoryFilter] ?? []);
      for (final r in _recordsInSelectedMajorCategory) {
        if (r.subCategory.isNotEmpty) subs.add(r.subCategory);
      }
    }
    final result = ['전체', ...subs];
    if (_recordsInSelectedMajorCategory.any((r) => r.subCategory.isEmpty) &&
        subs.isNotEmpty) {
      result.add('미지정');
    }
    return result;
  }

  int _sumBySubCategory(String subCat) {
    final baseList = _recordsInSelectedMajorCategory;
    if (subCat == '전체') {
      return baseList.fold(0, (sum, r) => sum + r.numericAmount);
    }
    if (subCat == '미지정') {
      return baseList
          .where((r) => r.subCategory.isEmpty)
          .fold(0, (sum, r) => sum + r.numericAmount);
    }
    return baseList
        .where((r) => r.subCategory == subCat)
        .fold(0, (sum, r) => sum + r.numericAmount);
  }

  int _countBySubCategory(String subCat) {
    final baseList = _recordsInSelectedMajorCategory;
    if (subCat == '전체') return baseList.length;
    if (subCat == '미지정') {
      return baseList.where((r) => r.subCategory.isEmpty).length;
    }
    return baseList.where((r) => r.subCategory == subCat).length;
  }

  int _sumByMajorCategory(String majorCat) {
    if (majorCat == DocCategory.all) {
      return _records.fold(0, (sum, r) => sum + r.numericAmount);
    }
    return _records
        .where((r) => r.category == majorCat)
        .fold(0, (sum, r) => sum + r.numericAmount);
  }

  int _sumByTravelDivision(String division) {
    final baseList = _subCategoryFilteredRecords
        .where((r) => r.category == DocCategory.travel);
    if (division == '전체') {
      return baseList.fold(0, (sum, r) => sum + r.numericAmount);
    }
    return baseList
        .where((r) => r.travelDivision == division)
        .fold(0, (sum, r) => sum + r.numericAmount);
  }

  int _countByTravelDivision(String division) {
    final baseList = _subCategoryFilteredRecords
        .where((r) => r.category == DocCategory.travel);
    if (division == '전체') return baseList.length;
    return baseList.where((r) => r.travelDivision == division).length;
  }

  Future<void> _changeRecordSubCategory(
    DocRecord record,
    String newSubCategory,
  ) async {
    if (newSubCategory == '__ADD_NEW__') {
      final created = await _promptAddNewSubCategory(record.category);
      if (created == null || created.isEmpty) return;
      newSubCategory = created;
    } else {
      await _registerUserSubCategory(record.category, newSubCategory);
    }

    final idx = _records.indexWhere((r) => r.id == record.id);
    if (idx == -1) return;

    final updatedFields = Map<String, String>.from(record.fields);
    updatedFields['subCategory'] = newSubCategory;

    final updated = DocRecord(
      id: record.id,
      category: record.category,
      createdAt: record.createdAt,
      imagePath: record.imagePath,
      base64Image: record.base64Image,
      fields: updatedFields,
    );

    setState(() {
      _records[idx] = updated;
      if (_selectedRecord?.id == record.id) {
        _selectedRecord = updated;
      }
    });
    await _saveLocalRecords();
    _showSnack('카테고리가 [$newSubCategory](으)로 지정되었습니다.');
  }

  Future<void> _changeRecordTravelDivision(
    DocRecord record,
    String newDivision,
  ) async {
    final idx = _records.indexWhere((r) => r.id == record.id);
    if (idx == -1) return;

    final updatedFields = Map<String, String>.from(record.fields);
    updatedFields['travelDivision'] = newDivision;

    final updated = DocRecord(
      id: record.id,
      category: record.category,
      createdAt: record.createdAt,
      imagePath: record.imagePath,
      base64Image: record.base64Image,
      fields: updatedFields,
    );

    setState(() {
      _records[idx] = updated;
      if (_selectedRecord?.id == record.id) {
        _selectedRecord = updated;
      }
    });
    await _saveLocalRecords();
    _showSnack('출장비 구분이 [$newDivision](으)로 변경되었습니다.');
  }

  // ===========================================================================
  // ★ 1단계: 온디바이스 한국어 OCR (공문번호 하단 크롭 확대 스캔 + 송장 규격별 다중 행 추출!)
  // ===========================================================================
  static Uint8List? _cropFooterForFineOcrIsolate(Uint8List rawBytes) {
    try {
      final decoded = img.decodeImage(rawBytes);
      if (decoded == null) return null;
      final yStart = (decoded.height * 0.72).round();
      final h = decoded.height - yStart;
      if (h < 40) return null;
      img.Image cropped = img.copyCrop(
        decoded,
        x: 0,
        y: yStart,
        width: decoded.width,
        height: h,
      );
      // 하단 작은 결재/시행 글씨('공동주택과-16092')를 ML Kit가 100% 읽을 수 있도록 2배 확대
      if (cropped.width < 1800) {
        cropped = img.copyResize(
          cropped,
          width: cropped.width * 2,
          height: cropped.height * 2,
          interpolation: img.Interpolation.cubic,
        );
      }
      return Uint8List.fromList(img.encodeJpg(cropped, quality: 95));
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, String>> _extractFieldsOfflineOcr({
    required String imagePath,
    required Uint8List imageBytes,
    required String category,
  }) async {
    TextRecognizer? textRecognizer;
    try {
      textRecognizer = TextRecognizer(script: TextRecognitionScript.korean);
      final inputImage = InputImage.fromFilePath(imagePath);
      final RecognizedText recognized =
          await textRecognizer.processImage(inputImage);

      final allTextLines = <TextLine>[];
      for (final block in recognized.blocks) {
        allTextLines.addAll(block.lines);
      }
      allTextLines.sort((a, b) => a.boundingBox.top.compareTo(b.boundingBox.top));

      final mergedRows = <String>[];
      List<TextLine> currentRow = [];
      double currentTop = -1000;

      for (final tl in allTextLines) {
        final top = tl.boundingBox.top;
        final height = tl.boundingBox.height;
        if (currentRow.isEmpty || (top - currentTop).abs() <= height * 0.65) {
          currentRow.add(tl);
          if (currentRow.length == 1) currentTop = top;
        } else {
          currentRow.sort(
              (a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));
          mergedRows.add(currentRow.map((e) => e.text.trim()).join('  '));
          currentRow = [tl];
          currentTop = top;
        }
      }
      if (currentRow.isNotEmpty) {
        currentRow
            .sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));
        mergedRows.add(currentRow.map((e) => e.text.trim()).join('  '));
      }

      String fullText = mergedRows.join('\n');

      // ★ 대외공문인 경우: 하단 28%('시행 공동주택과-16092' 결재/시행란)를 2배 확대 크롭하여 정밀 스캔 추가 수행!
      if (category == DocCategory.officialDoc) {
        final parsed = _parseOfficialDocText(fullText, mergedRows);
        if ((parsed['docNumber'] ?? '').isEmpty) {
          final footerBytes =
              await compute(_cropFooterForFineOcrIsolate, imageBytes);
          if (footerBytes != null) {
            final tempDir = await getTemporaryDirectory();
            final footerFile = File(p.join(tempDir.path, 'footer_zoom.jpg'));
            await footerFile.writeAsBytes(footerBytes, flush: true);
            final footerRec = await textRecognizer
                .processImage(InputImage.fromFilePath(footerFile.path));
            final footerLines = <String>[];
            for (final b in footerRec.blocks) {
              for (final l in b.lines) {
                footerLines.add(l.text.trim());
              }
            }
            final combinedLines = [...mergedRows, ...footerLines];
            final combinedText = '$fullText\n${footerLines.join('\n')}';
            return _parseOfficialDocText(combinedText, combinedLines);
          }
        }
        return parsed;
      } else if (category == DocCategory.medical) {
        return _parseMedicalReceiptText(fullText, mergedRows);
      } else if (category == DocCategory.invoice) {
        return _parseInvoiceText(fullText, mergedRows);
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

  /// [출장비] 5대 구분('자차', '택시', '기차', '식대', '통행료') 자동 판별
  Map<String, String> _parseTravelReceiptText(
    String fullText,
    List<String> lines,
    List<TextBlock> blocks,
  ) {
    final result = <String, String>{};

    final dateMatch = RegExp(r'(\d{4})\s*[-./년]\s*(\d{1,2})\s*[-./월]\s*(\d{1,2})')
        .firstMatch(fullText);
    if (dateMatch != null) {
      result['date'] =
          '${dateMatch.group(1)}-${dateMatch.group(2)!.padLeft(2, '0')}-${dateMatch.group(3)!.padLeft(2, '0')}';
    }

    final bool isMapRoute = RegExp(
      r'(?:실\s*시\s*간\s*추\s*천|안\s*내\s*시\s*작|전\s*체\s*경\s*로|큰\s*길\s*우\s*선|거\s*리\s*우\s*선|최\s*적\s*경\s*로|추천경로)',
    ).hasMatch(fullText);

    if (isMapRoute) {
      result['travelDivision'] = TravelDivision.car;
      double? detectedKm;

      Rect? realtimeBox;
      for (final b in blocks) {
        for (final l in b.lines) {
          if (l.text.replaceAll(' ', '').contains('실시간추천')) {
            realtimeBox = l.boundingBox;
            break;
          }
        }
        if (realtimeBox != null) break;
      }

      if (realtimeBox != null) {
        double bestDist = double.infinity;
        for (final b in blocks) {
          for (final l in b.lines) {
            final kmMatch =
                RegExp(r'(\d+(?:\.\d+)?)\s*km', caseSensitive: false)
                    .firstMatch(l.text);
            if (kmMatch != null && l.boundingBox.top >= realtimeBox.top) {
              final dx = (l.boundingBox.left - realtimeBox.left).abs();
              if (dx < bestDist) {
                bestDist = dx;
                detectedKm = double.tryParse(kmMatch.group(1)!);
              }
            }
          }
        }
      }

      if (detectedKm == null) {
        final kmMatch = RegExp(r'(\d+(?:\.\d+)?)\s*km', caseSensitive: false)
            .firstMatch(fullText);
        if (kmMatch != null) {
          detectedKm = double.tryParse(kmMatch.group(1)!);
        }
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
    } else if (RegExp(r'(?:하이패스|도로공사|통행료|톨게이트|영업소|고속도로|hi-pass)',
            caseSensitive: false)
        .hasMatch(fullText)) {
      result['travelDivision'] = TravelDivision.toll;
      result['merchantName'] = '하이패스 통행료';
    } else {
      result['travelDivision'] = TravelDivision.meal;
      for (final line in lines) {
        final m = RegExp(r'(?:상\s*호|가맹점명?)\s*[:：]?\s*([가-힣A-Za-z0-9()]+)')
            .firstMatch(line);
        if (m != null) {
          result['merchantName'] = m.group(1)!.trim();
          break;
        }
      }
    }

    final amountPatterns = [
      RegExp(
          r'(?:합\s*계|총\s*액|결\s*제\s*금\s*액|승\s*인\s*금\s*액|요\s*금|운\s*임|금\s*액)[^\d\n]*([1-9]\d{0,2}(?:,\d{3})+|\d{3,7})'),
      RegExp(r'\b([1-9]\d{0,2}(?:,\d{3})+)\s*원?\b'),
    ];
    for (final pat in amountPatterns) {
      final matches = pat.allMatches(fullText).toList();
      if (matches.isNotEmpty) {
        final digits = matches.last.group(1)!.replaceAll(',', '');
        final val = int.tryParse(digits) ?? 0;
        if (val >= 300 && val < 50000000) {
          result['totalAmount'] = val.toString();
          break;
        }
      }
    }

    return result;
  }

  /// ★ [대외공문] 공문번호('공동주택과-16092'), 보낸사람/받는사람(수발신 자동 판별), 앞부분 배경 제거 요약 파서
  Map<String, String> _parseOfficialDocText(
    String fullText,
    List<String> lines,
  ) {
    final result = <String, String>{};

    String pdfHeaderHint = '';
    final pdfHintMatch =
        RegExp(r'([가-힣0-9\s]{3,30})\.pdf', caseSensitive: false)
            .firstMatch(fullText);
    if (pdfHintMatch != null) {
      pdfHeaderHint = pdfHintMatch
          .group(1)!
          .replaceAll(RegExp(r'^및\s*'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }

    final cleanLines = lines.where((l) {
      if (RegExp(
        r'\.pdf\b|Page\s*[.\d/]+|From\s*:|To\s*:|http://|https://|www\.|\.go\.kr|\.co\.kr|전화번호|팩스번호|우\s*\d{5}',
        caseSensitive: false,
      ).hasMatch(l)) {
        return false;
      }
      return true;
    }).toList();

    // 1) 접수일/시행일 (보낸날짜)
    final sihaengDateMatch = RegExp(
      r'시\s*행[^\n]*?\(\s*(\d{4})\s*[.년/-]\s*(\d{1,2})\s*[.월/-]\s*(\d{1,2})',
    ).firstMatch(fullText);
    if (sihaengDateMatch != null) {
      result['sentDate'] =
          '${sihaengDateMatch.group(1)}-${sihaengDateMatch.group(2)!.padLeft(2, '0')}-${sihaengDateMatch.group(3)!.padLeft(2, '0')}';
    } else {
      final anyDate =
          RegExp(r'(\d{4})\s*[-./년]\s*(\d{1,2})\s*[-./월]\s*(\d{1,2})')
              .firstMatch(fullText);
      if (anyDate != null) {
        result['sentDate'] =
            '${anyDate.group(1)}-${anyDate.group(2)!.padLeft(2, '0')}-${anyDate.group(3)!.padLeft(2, '0')}';
      }
    }

    // 2) 공문번호 ('공동주택과-16092' — 작은 글씨에서 하이픈이 빠지거나 공백/점/물결로 읽히거나 숫자가 영문 O/l/I/S/B로 깨져도 100% 추출!)
    String normalizeDocNumDigits(String rawNum) {
      return rawNum
          .replaceAll('O', '0')
          .replaceAll('o', '0')
          .replaceAll('Q', '0')
          .replaceAll('D', '0')
          .replaceAll('l', '1')
          .replaceAll('I', '1')
          .replaceAll('|', '1')
          .replaceAll('Z', '2')
          .replaceAll('S', '5')
          .replaceAll('s', '5')
          .replaceAll('G', '6')
          .replaceAll('B', '8');
    }

    // (a) '시행' 키워드 주변 탐색 (예: '시행 공동주택과-16092', '시행 공동주택과 16092')
    for (final line in lines) {
      if (RegExp(r'(?:전화|팩스|우\s*\d{5}|From|To)').hasMatch(line)) continue;
      final compactLine = line.replaceAll(RegExp(r'\s+'), '');
      final mSihaeng = RegExp(
        r'시행[:：]?([가-힣]{2,10}(?:과|팀|실|부|처|국|단|소|청|원|본부|센터|읍|면|동)?)?[-~—–_.\s]*([0-9OolISBQDGZ|]{3,7})',
      ).firstMatch(compactLine);
      if (mSihaeng != null) {
        String dept = mSihaeng.group(1) ?? '';
        final numPart = normalizeDocNumDigits(mSihaeng.group(2)!);
        if (!RegExp(r'^202\d$').hasMatch(numPart) &&
            RegExp(r'^\d{3,7}$').hasMatch(numPart)) {
          if (dept.isEmpty) {
            // 결재란에 적힌 부서명(예: '공동주택과장', '공동주택승인')에서 부서명 추론
            final deptHint = RegExp(
                    r'([가-힣]{2,8}(?:과|팀|실|부|처|국|소|청))(?:장|승인)?')
                .firstMatch(fullText.replaceAll(' ', ''));
            dept = deptHint != null ? deptHint.group(1)! : '문서';
          }
          result['docNumber'] = '$dept-$numPart';
          break;
        }
      }
    }

    // (b) 전체 텍스트에서 '[부서명(과/팀/실/부/처/청)] - [숫자 3~7자리]' 패턴 탐색
    if ((result['docNumber'] ?? '').isEmpty) {
      final compactFull = fullText.replaceAll(' ', '');
      final deptMatches = RegExp(
        r'([가-힣]{2,10}(?:과|팀|실|부|처|국|단|소|청|원|본부|센터|읍|면|동))[-~—–_.]*([0-9OolISBQDGZ|]{3,7})',
      ).allMatches(compactFull);
      for (final m in deptMatches) {
        final dept = m.group(1)!;
        final numPart = normalizeDocNumDigits(m.group(2)!);
        if (!RegExp(r'^202\d$').hasMatch(numPart) &&
            RegExp(r'^\d{3,7}$').hasMatch(numPart)) {
          result['docNumber'] = '$dept-$numPart';
          break;
        }
      }
    }

    // 3) 수신(받는사람) 추출 및 수발신 자동 판별!
    // - 문서 상단 '수 신 ... 귀하' 추출
    for (final line in cleanLines) {
      final recMatch = RegExp(
        r'^수\s*신\s*[:：]?\s*(.+)$',
      ).firstMatch(line.trim());
      if (recMatch != null) {
        String rec = recMatch
            .group(1)!
            .replaceAll(RegExp(r'\s*귀\s*하\s*$'), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (rec.isNotEmpty) {
          result['recipient'] = rec;
          break;
        }
      }
    }

    // 4) 보낸사람(발신처) 추출
    String headerCityName = '';
    for (final l in cleanLines.take(7)) {
      final c = l.replaceAll(RegExp(r'\s+'), '');
      final cityMatch =
          RegExp(r'^([가-힣]{2,4}(?:시|군|구|도|청))$').firstMatch(c);
      if (cityMatch != null) {
        headerCityName = cityMatch.group(1)!;
        break;
      }
    }

    for (int i = cleanLines.length - 1; i >= 0; i--) {
      final c1 = cleanLines[i].replaceAll(RegExp(r'\s+'), '');
      if (c1.contains('귀하') ||
          c1.contains('수신') ||
          c1.contains('주무관') ||
          c1.contains('전결')) {
        continue;
      }
      final directMatch = RegExp(
        r'([가-힣A-Za-z0-9()]{2,14}?(?:시장|구청장|군수|도지사|교육감|장관|청장|서장|원장|소장|본부장|이사장|대표이사|현장대리인))인?$',
      ).firstMatch(c1);
      if (directMatch != null) {
        String s = directMatch.group(1)!;
        final dupMatch =
            RegExp(r'([가-힣]{2,4}(?:시장|구청장|군수|도지사|청장))$').firstMatch(s);
        if (dupMatch != null) s = dupMatch.group(1)!;
        result['sender'] = s;
        break;
      }
      if (i > 0 && RegExp(r'^(?:시장|구청장|군수|청장)인?$').hasMatch(c1)) {
        final prevC = cleanLines[i - 1].replaceAll(RegExp(r'\s+'), '');
        final tailCity = RegExp(r'([가-힣]{2,4}?)(?:시|군|구)?$').firstMatch(prevC);
        if (tailCity != null) {
          final role = c1.replaceAll(RegExp(r'인$'), '');
          result['sender'] = '${tailCity.group(1)}$role';
          break;
        }
      }
    }
    if ((result['sender'] ?? '').isEmpty && headerCityName.isNotEmpty) {
      result['sender'] = (headerCityName.endsWith('시') ||
              headerCityName.endsWith('군') ||
              headerCityName.endsWith('구'))
          ? '${headerCityName}장'
          : headerCityName;
    }

    // ★ 보내는 공문(발신) vs 받은 공문(수신) 자동 판별:
    // 수신처가 관공서/발주처/감리단이고 발신명의가 현장대리인/시공사이면 '발신'(보내는 공문)으로 자동 설정!
    final senderStr = result['sender'] ?? '';
    final recipientStr = result['recipient'] ?? '';
    if (senderStr.contains('현장대리인') ||
        senderStr.contains('현장소장') ||
        (recipientStr.isNotEmpty &&
            RegExp(r'(?:시장|구청장|군수|시청|구청|군청|감리단|사업단|발주처|공사|공단)')
                .hasMatch(recipientStr) &&
            !RegExp(r'(?:시장|구청장|군수|청장)').hasMatch(senderStr))) {
      result['docDirection'] = '발신';
    } else {
      result['docDirection'] = '수신';
    }

    // 5) 제목
    for (int i = 0; i < cleanLines.length; i++) {
      final line = cleanLines[i];
      final titleMatch = RegExp(
        r'^(?:제\s*목|건\s*명|안\s*건)\s*[:：]?\s*(.+)',
      ).firstMatch(line.trim());
      if (titleMatch != null) {
        String t = titleMatch.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (pdfHeaderHint.isNotEmpty &&
            pdfHeaderHint.contains('조치계획') &&
            !t.contains('조치계획') &&
            t.contains('민원')) {
          t = '민원사항 알림 및 $pdfHeaderHint';
        }
        t = t
            .replaceAll('민원 사항', '민원사항')
            .replaceAll('제출 요청', '제출요청')
            .replaceAll('제요청', '제출요청');
        result['title'] = t;
        break;
      }
    }
    if ((result['title'] ?? '').isEmpty && pdfHeaderHint.isNotEmpty) {
      result['title'] = pdfHeaderHint
          .replaceAll('민원 사항', '민원사항')
          .replaceAll('제출 요청', '제출요청');
    }

    // 6) 회신요청일 ('2025.5.21.(수)까지' -> '2025-05-21')
    final deadlineDateMatch = RegExp(
      r'(\d{4})\s*[.년/-]\s*(\d{1,2})\s*[.월/-]\s*(\d{1,2})\s*[.일]?\s*(?:\([월화수목금토일]\s*요일?\)|\([월화수목금토일]\))?\s*까\s*지',
    ).firstMatch(fullText);
    if (deadlineDateMatch != null) {
      final y = deadlineDateMatch.group(1)!;
      final m = deadlineDateMatch.group(2)!.padLeft(2, '0');
      final d = deadlineDateMatch.group(3)!.padLeft(2, '0');
      result['replyDeadline'] = '$y-$m-$d';
    }

    // 7) 내용 ('귀 사에서 시공 중인 ~ 헌장과 관련하여,' 등 OCR 오타가 섞인 앞부분 배경문구까지 100% 제거!)
    final joinedClean = cleanLines.join('\n');
    final para2Match = RegExp(
      r'2\.\s*(.*?)(?=\s*3\s*[.이와]|\n\s*붙\s*임|\n\s*끝|$)',
      dotAll: true,
    ).firstMatch(joinedClean);

    if (para2Match != null) {
      String core = para2Match.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim();
      // '현장과 관련하여'가 '헌장과 관련하여'로 오타가 나도 '관련하여,' 까지 무조건 제거!
      core = core.replaceFirst(
        RegExp(r'^.*?관\s*련\s*하\s*여\s*[,，.]?\s*'),
        '',
      );
      if (RegExp(r'(?:로\s*인해|으로\s*인해|\s+인해)').hasMatch(core)) {
        core = core.replaceFirst(
          RegExp(r'(?:로\s*인해|으로\s*인해|\s+인해).*$'),
          '에 대한 민원 조치요청',
        );
      } else {
        core = core.replaceFirst(
            RegExp(r'(?:인근\s*주민|불편|민원이).*$'), '에 대한 민원 조치요청');
      }
      core = core
          .replaceAll('공사 작업자', '공사작업')
          .replaceAll('도로변 주차', '도로변주차')
          .replaceAll('도로변 주치', '도로변주차')
          .replaceAll(RegExp(r'공원\s*내\s*(?:장기\s*주차|참차|장기주차)'), '공원내 장기주차');
      result['aiSummary'] = core.trim();
    }

    return result;
  }

  /// ★ [자재송장] 첨부해주신 원칙 100% 반영 파서:
  /// 1. 제품명을 '착지주소 운송회사' 같은 헤더에서 잘못 가져오지 않고 실제 품명('고장력철근' 등)을 정확히 추출!
  /// 2. 제품명에 '철근'이 포함되어 있으면 단위는 무조건 `ton`이고, 수량은 각 규격 행의 **중량(예: 3.744 / 15.952)**만 가져옴!
  /// 3. 제품명에 '철근'이 포함되어 있지 않으면 송장의 단위와 수량을 그대로 가져옴!
  /// 4. 규격명(예: `D32MM`, `D16MM`)이 여러 개이면 각각의 리스트 행(`itemsJson`)으로 분리 생성!
  Map<String, String> _parseInvoiceText(String fullText, List<String> lines) {
    final result = <String, String>{};

    final dateMatch = RegExp(r'(\d{4})\s*[-./]\s*(\d{2})\s*[-./]\s*(\d{2})')
        .firstMatch(fullText);
    if (dateMatch != null) {
      result['arrivalDate'] =
          '${dateMatch.group(1)}.${dateMatch.group(2)}.${dateMatch.group(3)}';
    }

    final orderMatch = RegExp(
      r'([A-Z]-\d-\d{8}-\d{4,6}|\b\d{10,14}\b)',
    ).firstMatch(fullText);
    if (orderMatch != null) {
      result['orderNumber'] = orderMatch.group(1)!;
    }

    if (fullText.toUpperCase().contains('HYUNDAI STEEL') ||
        fullText.contains('현대제철')) {
      result['supplierName'] = '현대제철';
    } else {
      final supplierMatch = RegExp(
        r'([가-힣A-Za-z0-9]+(?:제철|철강|자재|산업|건업|물산|상사|테크|금속|시멘트|레미콘)(?:\(주\)|주식회사)?)',
      ).firstMatch(fullText);
      if (supplierMatch != null) {
        result['supplierName'] = supplierMatch.group(1)!;
      }
    }

    // 1) 제품명 판별: 표 헤더('품명', '제품명', '착지주소', '운송회사')는 절대 제품명으로 가져오지 않음!
    String detectedProduct = '';
    if (RegExp(r'고\s*장\s*력\s*철\s*근').hasMatch(fullText) ||
        fullText.toUpperCase().contains('HYUNDAI STEEL') ||
        RegExp(r'\bD\d{2}\s*M?M?\b', caseSensitive: false).hasMatch(fullText) ||
        RegExp(r'\b(?:SD\s*[3456]00|SHD|UHD)\b', caseSensitive: false)
            .hasMatch(fullText)) {
      detectedProduct = '고장력철근';
    } else if (fullText.contains('철근') || fullText.contains('이형봉강')) {
      detectedProduct = '고장력철근';
    } else {
      for (final line in lines) {
        if (RegExp(r'착지|운송|주소|Page|공장|주문번호|청구번호|규격명').hasMatch(line)) {
          continue;
        }
        final prodMatch = RegExp(
                r'([가-힣A-Za-z0-9]+(?:시멘트|레미콘|몰탈|파이프|강관|합판|목재|벽돌|타일|석고보드|단열재|철근|형강))')
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

    // 2) 품목 행(규격명 + 중량/수량) 추출
    // 표의 각 행에서 규격명(예: D32MM, D16MM 등)과 해당 행의 소수점 중량(예: 3.744, 15.952) 매칭!
    final List<Map<String, String>> parsedRows = [];

    for (final line in lines) {
      // '합 계 486 19.696' 줄은 개별 규격 행이 아니므로 제외
      if (RegExp(r'합\s*계').hasMatch(line)) continue;

      final specMatch = RegExp(
        r'\b(D\s*\d{2}\s*M{0,2}|H\s*D\s*\d{2}|S\s*H\s*D\s*\d{2})\b',
        caseSensitive: false,
      ).firstMatch(line);

      if (specMatch != null) {
        String rawSpec =
            specMatch.group(1)!.toUpperCase().replaceAll(RegExp(r'\s+'), '');
        if (RegExp(r'^D\d{2}$').hasMatch(rawSpec)) {
          rawSpec = '${rawSpec}MM';
        } else if (RegExp(r'^D\d{2}M$').hasMatch(rawSpec)) {
          rawSpec = '${rawSpec}M';
        }

        // 해당 줄에서 중량(소수점 3자리 숫자, 예: 3.744, 15.952 — 단, 길이 10.00 / 8.00은 제외) 추출
        final weightsInLine = RegExp(r'\b(\d{1,3}\.\d{3})\b')
            .allMatches(line)
            .map((m) => m.group(1)!)
            .toList();

        String rowQty = '';
        if (isRebar) {
          if (weightsInLine.isNotEmpty) {
            rowQty = weightsInLine.last;
          }
        } else {
          final qtyMatch = RegExp(r'\b(\d{1,5}(?:\.\d{1,3})?)\b')
              .allMatches(line)
              .map((m) => m.group(1)!)
              .toList();
          if (qtyMatch.isNotEmpty) rowQty = qtyMatch.last;
        }

        parsedRows.add({
          'productName': detectedProduct,
          'specName': rawSpec,
          'unit': isRebar ? 'ton' : 'EA',
          'quantity': rowQty,
        });
      }
    }

    // 만약 줄이 어긋나서 규격명(D32MM, D16MM)과 소수점 3자리 중량(3.744, 15.952)이 따로 읽힌 경우 순서대로 짝지어 매칭!
    final allSpecs = RegExp(r'\b(D\s*\d{2}\s*M{0,2})\b', caseSensitive: false)
        .allMatches(fullText)
        .map((m) {
          String s = m.group(1)!.toUpperCase().replaceAll(RegExp(r'\s+'), '');
          if (RegExp(r'^D\d{2}$').hasMatch(s)) s = '${s}MM';
          if (RegExp(r'^D\d{2}M$').hasMatch(s)) s = '${s}M';
          return s;
        })
        .toList();

    // 전체 텍스트에서 소수점 3자리 중량들(합계인 마지막 최대값 제외) 추출
    final allThreeDecWeights = RegExp(r'\b(\d{1,3}\.\d{3})\b')
        .allMatches(fullText)
        .map((m) => m.group(1)!)
        .toList();

    if (allSpecs.isNotEmpty) {
      // 중복 제거하되 등장 순서 유지
      final uniqueSpecs = <String>[];
      for (final s in allSpecs) {
        if (!uniqueSpecs.contains(s)) uniqueSpecs.add(s);
      }

      // 만약 parsedRows가 비어 있거나 중량이 비어 있으면 allThreeDecWeights에서 순서대로 채움
      if (parsedRows.length < uniqueSpecs.length ||
          parsedRows.any((r) => (r['quantity'] ?? '').isEmpty)) {
        parsedRows.clear();
        for (int i = 0; i < uniqueSpecs.length; i++) {
          String w = '';
          if (i < allThreeDecWeights.length) {
            // 만약 중량이 규격 개수보다 많으면 마지막은 합계(19.696)이므로 앞쪽에서 순서대로 가져옴
            w = allThreeDecWeights[i];
          }
          parsedRows.add({
            'productName': detectedProduct,
            'specName': uniqueSpecs[i],
            'unit': isRebar ? 'ton' : (result['unit'] ?? 'EA'),
            'quantity': w,
          });
        }
      }
    }

    if (parsedRows.isNotEmpty) {
      result['itemsJson'] = jsonEncode(parsedRows);
      result['specName'] = parsedRows.first['specName'] ?? '';
      result['unit'] = parsedRows.first['unit'] ?? (isRebar ? 'ton' : 'EA');
      result['quantity'] = parsedRows.first['quantity'] ?? '';
    } else {
      result['unit'] = isRebar ? 'ton' : 'EA';
      if (allThreeDecWeights.isNotEmpty) {
        result['quantity'] = allThreeDecWeights.first;
      }
    }

    return result;
  }

  Map<String, String> _parseMedicalReceiptText(
    String fullText,
    List<String> lines,
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
      result['issueDate'] = '$y-$m-$d';
    } else {
      final anyDate = RegExp(r'(\d{4})\s*[-./]\s*(\d{2})\s*[-./]\s*(\d{2})')
          .firstMatch(fullText);
      if (anyDate != null) {
        result['issueDate'] =
            '${anyDate.group(1)}-${anyDate.group(2)}-${anyDate.group(3)}';
      }
    }

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

  // ===========================================================================
  // 2단계: Gemini Vision AI 분석 (공문 수발신 & 자재송장 규격별 배열 추출 지원)
  // ===========================================================================
  static Uint8List _compressForAiPayloadIsolate(Uint8List srcBytes) {
    if (srcBytes.lengthInBytes <= 350 * 1024) return srcBytes;
    final decoded = img.decodeImage(srcBytes);
    if (decoded == null) return srcBytes;
    img.Image resized = decoded;
    if (math.max(decoded.width, decoded.height) > 1280) {
      resized = decoded.width >= decoded.height
          ? img.copyResize(decoded, width: 1280)
          : img.copyResize(decoded, height: 1280);
    }
    return Uint8List.fromList(img.encodeJpg(resized, quality: 80));
  }

  Future<Map<String, String>?> _analyzeDocumentWithAi({
    required String category,
    required Uint8List imageBytes,
  }) async {
    final key = _geminiApiKey.trim();
    if (key.isEmpty) return null;

    final aiBytes = await compute(_compressForAiPayloadIsolate, imageBytes);
    final base64Image = base64Encode(aiBytes);

    String prompt;
    if (category == DocCategory.officialDoc) {
      prompt = '''
이 대한민국 공문서 이미지를 분석해서 아래 규칙과 예시를 정확히 따라 순수 JSON 객체로 응답해줘:
- title (제목): 예: "민원사항 알림 및 조치계획 제출요청"
- aiSummary (내용): 앞부분 '귀 사에서 시공 중인 OO 현장과 관련하여' 같은 배경 수식어는 완전히 빼고 핵심 안건만 한 줄 요약 (예: "공사작업 개인차량 도로변주차와 공원내 장기주차에 대한 민원 조치요청")
- docNumber (공문번호): 하단 '시행' 옆 부서명-번호 (예: "공동주택과-16092")
- docDirection: 우리가 외부(시청/발주처 등)로부터 받은 공문이면 "수신", 우리 현장에서 외부로 보내는 공문이면 "발신"
- sender (보낸사람): 하단 직인 발신명의 (예: "김해시장" 또는 "김해시청")
- recipient (받는사람): 상단 '수신' 옆에 적힌 받는사람 명의 (예: "e편한세상 주촌 더프리미어 현장대리인")
- replyDeadline (회신요청일): 본문 회신기한 날짜 YYYY.MM.DD (예: "2025.05.21")
- sentDate (접수일/시행일): 시행일 YYYY.MM.DD (예: "2025.05.19")
''';
    } else if (category == DocCategory.invoice) {
      prompt = '''
이 자재송장/거래명세서 이미지를 읽고 다음 원칙을 엄격히 지켜 순수 JSON으로 응답해줘:
[원칙]
1. 제품명(productName)을 표 안의 '품명/제품명' 칸에서 정확히 읽을 것 (예: "고장력철근"). 절대 '착지주소'나 '운송회사'를 제품명으로 넣지 말 것.
2. 제품명에 '철근'이라는 단어가 포함되어 있으면: 단위(unit)는 무조건 "ton"으로 하고, 수량(quantity)에는 각 규격 행의 '중량'(예: "3.744", "15.952")만 가져올 것! (합계 행은 제외하고 각 규격 행별로 따로!)
3. 제품명에 '철근'이 포함되어 있지 않으면: 송장에 적힌 단위와 수량을 그대로 가져올 것.
4. 규격명(specName, 예: "D32MM", "D16MM")이 여러 줄이면 items 배열에 각 규격별로 따로 담아줄 것.

JSON 형식:
{
  "arrivalDate": "2021.09.08",
  "supplierName": "현대제철",
  "orderNumber": "송장번호",
  "items": [
    {"productName": "고장력철근", "specName": "D32MM", "unit": "ton", "quantity": "3.744"},
    {"productName": "고장력철근", "specName": "D16MM", "unit": "ton", "quantity": "15.952"}
  ]
}''';
    } else if (category == DocCategory.travel) {
      prompt = '''
이 출장비 증빙 이미지를 보고 5가지 구분('자차', '택시', '기차', '식대', '통행료') 중 하나로 분류해 순수 JSON으로 응답해줘:
{
  "travelDivision": "자차 또는 택시 또는 기차 또는 식대 또는 통행료",
  "distanceKm": "자차일 때 실시간 추천 km 숫자만",
  "totalAmount": "금액 숫자만",
  "merchantName": "가맹점명/내역",
  "date": "YYYY-MM-DD"
}''';
    } else {
      prompt = '''
이 병원비/약국 영수증 이미지를 읽고 순수 JSON 객체로 응답해줘:
{
  "clinicName": "상호명",
  "bizRegNumber": "사업자등록번호",
  "issueDate": "YYYY-MM-DD",
  "totalPaid": "총수납금액 숫자만"
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

    final attempts = <Map<String, dynamic>>[
      {
        'url':
            'https://aiplatform.googleapis.com/v1beta1/publishers/google/models/gemini-2.5-flash:generateContent?key=$key',
        'headers': {'Content-Type': 'application/json'},
      },
      {
        'url':
            'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent',
        'headers': {
          'Content-Type': 'application/json',
          'x-goog-api-key': key,
        },
      },
      {
        'url':
            'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$key',
        'headers': {'Content-Type': 'application/json'},
      },
    ];

    for (final attempt in attempts) {
      try {
        final uri = Uri.parse(attempt['url'] as String);
        final headers = Map<String, String>.from(attempt['headers'] as Map);
        final resp = await http
            .post(uri, headers: headers, body: body)
            .timeout(const Duration(seconds: 6));
        if (resp.statusCode == 200) {
          final decoded =
              jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
          final text = decoded['candidates']?[0]?['content']?['parts']?[0]
                      ?['text']
                  ?.toString() ??
              '{}';
          final cleanJson =
              text.replaceAll('```json', '').replaceAll('```', '').trim();
          final Map<String, dynamic> parsed =
              jsonDecode(cleanJson) as Map<String, dynamic>;
          final result = <String, String>{};
          parsed.forEach((k, v) {
            if (k == 'items' && v is List) {
              result['itemsJson'] = jsonEncode(v);
            } else {
              result[k] = v?.toString() ?? '';
            }
          });
          return result;
        }
      } catch (_) {}
    }
    return null;
  }

  // ===========================================================================
  // 사진 촬영 → 입력 다이얼로그 (자재송장 규격별 다중 행 분리 저장 지원!)
  // ===========================================================================
  Future<void> _addRecordDialog(ImageSource source) async {
    try {
      final XFile? picked = await _picker.pickImage(
        source: source,
        maxWidth: 2400,
        maxHeight: 2400,
        imageQuality: 95,
      );
      if (picked == null) return;

      final rawBytes = await picked.readAsBytes();
      if (!mounted) return;

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
          ? DocCategory.officialDoc
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

      // 1. 대외공문 컨트롤러 (수신/발신 구분 지원)
      String chosenDocDirection = '수신'; // '수신'(받은 공문 -> 보낸사람) vs '발신'(보내는 공문 -> 받는사람)
      final docTitleCtrl = TextEditingController();
      final aiSummaryCtrl = TextEditingController();
      final docNumberCtrl = TextEditingController();
      final senderCtrl = TextEditingController();
      final recipientCtrl = TextEditingController();
      final replyDeadlineCtrl = TextEditingController();
      final sentDateCtrl = TextEditingController(text: todayDotStr);
      final docAmountCtrl = TextEditingController(text: '0');

      // 2. 자재송장 컨트롤러 (규격이 다르면 리스트를 각각 만들도록 다중 품목 행 지원!)
      final arrivalDateCtrl = TextEditingController(text: todayDotStr);
      final orderNumberCtrl = TextEditingController();
      final supplierNameCtrl = TextEditingController();
      final invoiceAmountCtrl = TextEditingController(text: '0');
      List<InvoiceSpecRow> invoiceRows = [
        InvoiceSpecRow(product: '고장력철근', spec: '', unit: 'ton', qty: ''),
      ];

      void enforceRebarRuleOnRows() {
        for (final row in invoiceRows) {
          if (row.productCtrl.text.contains('철근')) {
            row.unitCtrl.text = 'ton';
          }
        }
      }

      // 3. 출장비 컨트롤러
      String chosenTravelDivision = _selectedTravelDivisionFilter != '전체'
          ? _selectedTravelDivisionFilter
          : TravelDivision.car;
      final travelDistanceKmCtrl = TextEditingController(text: '0');
      final travelAmountCtrl = TextEditingController(text: '0');
      final travelMerchantCtrl = TextEditingController();
      final travelDateCtrl = TextEditingController(text: todayDotStr);

      void recalcCarDistanceCost() {
        if (chosenTravelDivision != TravelDivision.car) return;
        final double km = double.tryParse(
              travelDistanceKmCtrl.text.replaceAll(RegExp(r'[^0-9.]'), ''),
            ) ??
            0;
        final int fare = (km * 2 * 300).round();
        travelAmountCtrl.text = fare.toString();
      }

      // 4. 병원비 컨트롤러
      final clinicNameCtrl = TextEditingController();
      final bizRegNumberCtrl = TextEditingController();
      final issueDateCtrl = TextEditingController(text: todayDotStr);
      final totalPaidCtrl = TextEditingController();

      void applyExtractedMap(Map<String, String> extracted) {
        if (chosenCategory == DocCategory.officialDoc) {
          if (extracted['docDirection']?.isNotEmpty == true) {
            chosenDocDirection = extracted['docDirection']!;
          }
          if (extracted['title']?.isNotEmpty == true) {
            docTitleCtrl.text = extracted['title']!;
          }
          if (extracted['aiSummary']?.isNotEmpty == true) {
            aiSummaryCtrl.text = extracted['aiSummary']!;
          }
          if (extracted['docNumber']?.isNotEmpty == true) {
            docNumberCtrl.text = extracted['docNumber']!;
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
                  return InvoiceSpecRow(
                    product: prod,
                    spec: m['specName']?.toString() ?? '',
                    unit: isRebar
                        ? 'ton'
                        : (m['unit']?.toString().isNotEmpty == true
                            ? m['unit'].toString()
                            : 'EA'),
                    qty: m['quantity']?.toString() ?? '',
                  );
                }).toList();
              }
            } catch (_) {}
          } else {
            final prod = extracted['productName'] ?? '고장력철근';
            final isRebar = prod.contains('철근');
            invoiceRows = [
              InvoiceSpecRow(
                product: prod,
                spec: extracted['specName'] ?? '',
                unit: isRebar ? 'ton' : (extracted['unit'] ?? 'EA'),
                qty: extracted['quantity'] ?? extracted['weight'] ?? '',
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
        }
      }

      bool isAiAnalyzing = true;
      bool initialAutoRunTriggered = false;

      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, setDialogState) {
              Future<void> triggerOcrAndAiExtract() async {
                if (!ctx.mounted) return;
                setDialogState(() => isAiAnalyzing = true);
                try {
                  final ocrMap = await _extractFieldsOfflineOcr(
                    imagePath: savedFile.path,
                    imageBytes: flattenedBytes,
                    category: chosenCategory,
                  );
                  if (ctx.mounted) {
                    setDialogState(() => applyExtractedMap(ocrMap));
                  }

                  if (_geminiApiKey.trim().isNotEmpty) {
                    final aiMap = await _analyzeDocumentWithAi(
                      category: chosenCategory,
                      imageBytes: flattenedBytes,
                    );
                    if (aiMap != null && ctx.mounted) {
                      setDialogState(() => applyExtractedMap(aiMap));
                    }
                  }
                } catch (_) {
                } finally {
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
              final double parsedKm = double.tryParse(
                    travelDistanceKmCtrl.text
                        .replaceAll(RegExp(r'[^0-9.]'), ''),
                  ) ??
                  0;
              final int calculatedCarFare = (parsedKm * 2 * 300).round();

              return AlertDialog(
                title: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('증빙서류 입력 (v18)', style: TextStyle(fontSize: 18)),
                    if (isAiAnalyzing)
                      const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 6),
                          Text(
                            '자동 읽는 중...',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.blueAccent,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                content: SizedBox(
                  width: double.maxFinite,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          height: 135,
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Center(
                            child: Image.memory(
                              flattenedBytes,
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high,
                            ),
                          ),
                        ),
                        DropdownButtonFormField<String>(
                          value: chosenCategory,
                          decoration: const InputDecoration(
                            labelText: '문서 종류 선택',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: DocCategory.inputList
                              .map((c) =>
                                  DropdownMenuItem(value: c, child: Text(c)))
                              .toList(),
                          onChanged: (v) async {
                            if (v != null && v != chosenCategory) {
                              setDialogState(() {
                                chosenCategory = v;
                                final subs =
                                    _userSubCategoriesMap[chosenCategory] ?? [];
                                subCategoryCtrl.text =
                                    subs.isNotEmpty ? subs.first : '';
                              });
                              await triggerOcrAndAiExtract();
                            }
                          },
                        ),
                        const SizedBox(height: 10),

                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEFF6FF),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.blue.shade200),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '내 카테고리 (한 번 입력해 저장하면 다음부터 아래에 버튼으로 등록됩니다)',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1E3A8A),
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: subCategoryCtrl,
                                onChanged: (_) => setDialogState(() {}),
                                decoration: const InputDecoration(
                                  labelText: '카테고리 직접 입력 또는 아래에서 선택',
                                  hintText: '예: 주촌현장, 여의도출장, 갑상선 등',
                                  filled: true,
                                  fillColor: Colors.white,
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                              if (mySavedCats.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: mySavedCats.map((sub) {
                                    final isSel =
                                        subCategoryCtrl.text.trim() == sub;
                                    return ChoiceChip(
                                      visualDensity: VisualDensity.compact,
                                      label: Text(sub),
                                      selected: isSel,
                                      selectedColor: Colors.indigo.shade100,
                                      onSelected: (_) {
                                        setDialogState(() {
                                          subCategoryCtrl.text = sub;
                                        });
                                      },
                                    );
                                  }).toList(),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),

                        FilledButton.tonalIcon(
                          onPressed:
                              isAiAnalyzing ? null : triggerOcrAndAiExtract,
                          icon: const Icon(Icons.auto_awesome, size: 18),
                          label: const Text('문자/내용 다시 자동 인식'),
                        ),
                        const Divider(height: 20),

                        // ★ 1. 대외공문 입력 폼 (수신 공문이면 '보낸사람', 보내는 발신 공문이면 '받는사람' 자동 전환!)
                        if (chosenCategory == DocCategory.officialDoc) ...[
                          Row(
                            children: [
                              const Text(
                                '공문 구분: ',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(width: 8),
                              ChoiceChip(
                                visualDensity: VisualDensity.compact,
                                label: const Text('수신 (받은 공문 → 보낸사람 표기)'),
                                selected: chosenDocDirection == '수신',
                                selectedColor: Colors.blue.shade100,
                                onSelected: (_) => setDialogState(
                                    () => chosenDocDirection = '수신'),
                              ),
                              const SizedBox(width: 6),
                              ChoiceChip(
                                visualDensity: VisualDensity.compact,
                                label: const Text('발신 (보내는 공문 → 받는사람 표기)'),
                                selected: chosenDocDirection == '발신',
                                selectedColor: Colors.amber.shade200,
                                onSelected: (_) => setDialogState(
                                    () => chosenDocDirection = '발신'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          _buildField(
                            sentDateCtrl,
                            chosenDocDirection == '발신' ? '발신일' : '접수일 (시행일)',
                            '예: 2025.05.19',
                          ),
                          if (chosenDocDirection == '발신')
                            _buildField(
                              recipientCtrl,
                              '받는사람 (수신처)',
                              '예: 김해시청 / OO감리단',
                            )
                          else
                            _buildField(
                              senderCtrl,
                              '보낸사람 (발신처)',
                              '예: 김해시장 / 김해시청',
                            ),
                          _buildField(
                            docTitleCtrl,
                            '제목',
                            '예: 민원사항 알림 및 조치계획 제출요청',
                          ),
                          _buildField(
                            replyDeadlineCtrl,
                            '회신요청일',
                            '예: 2025.05.21',
                          ),
                          _buildField(
                            docNumberCtrl,
                            '공문번호',
                            '예: 공동주택과-16092',
                          ),
                          _buildField(
                            aiSummaryCtrl,
                            '내용 (핵심 안건 요약)',
                            '예: 공사작업 개인차량 도로변주차와 공원내 장기주차에 대한 민원 조치요청',
                            maxLines: 2,
                          ),
                        ],

                        // ★ 2. 자재송장 입력 폼 (규격명이 다르면 자동으로 각각 행이 생성되어 저장 시 별도 리스트로 등록됨!)
                        if (chosenCategory == DocCategory.invoice) ...[
                          _buildField(
                              arrivalDateCtrl, '날짜 (도착/발행일)', '예: 2021.09.08'),
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
                                        '품목/규격별 목록 (규격이 다르면 각각 별도 리스트로 생성됩니다)\n※ 제품명에 "철근" 포함 시 단위=ton, 수량=중량 자동 적용',
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
                                      label: const Text('규격 행 추가',
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
                                              hintText: 'D32MM',
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
                                              hintText: 'ton',
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
                                              labelText: '수량(중량)',
                                              hintText: '3.744',
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
                          _buildField(
                              supplierNameCtrl, '공급자상호', '예: 현대제철'),
                          _buildField(orderNumberCtrl, '주문/송장번호',
                              '예: 212021090449'),
                        ],

                        // 3. 출장비 입력 폼
                        if (chosenCategory == DocCategory.travel) ...[
                          Container(
                            padding: const EdgeInsets.all(10),
                            margin: const EdgeInsets.only(bottom: 12),
                            decoration: BoxDecoration(
                              color: Colors.amber.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.amber.shade300),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '출장비 세부 구분 (사진 내용에 따라 자동 선택됨)',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.brown,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: TravelDivision.list.map((div) {
                                    final isSel = chosenTravelDivision == div;
                                    return ChoiceChip(
                                      visualDensity: VisualDensity.compact,
                                      label: Text(
                                        div,
                                        style: TextStyle(
                                          fontWeight: isSel
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                        ),
                                      ),
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
                              ],
                            ),
                          ),
                          if (chosenTravelDivision == TravelDivision.car) ...[
                            _buildField(
                              travelDistanceKmCtrl,
                              '실시간 추천 거리 (편도 km)',
                              '예: 25 (지도에서 자동 인식됨)',
                              keyboardType: TextInputType.number,
                              onChanged: (_) =>
                                  setDialogState(recalcCarDistanceCost),
                            ),
                            Container(
                              padding: const EdgeInsets.all(10),
                              margin: const EdgeInsets.only(bottom: 10),
                              decoration: BoxDecoration(
                                color: Colors.indigo.shade50,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '자차 계산식: ${travelDistanceKmCtrl.text.isEmpty ? "0" : travelDistanceKmCtrl.text}km × 2(왕복) × 300원 = ${NumberFormat('#,###').format(calculatedCarFare)}원',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1E3A8A),
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                          _buildField(
                            travelAmountCtrl,
                            chosenTravelDivision == TravelDivision.car
                                ? '자차 금액 (원, 자동계산)'
                                : '[$chosenTravelDivision] 결제 금액 (원)',
                            '예: 15000',
                            keyboardType: TextInputType.number,
                          ),
                          _buildField(
                            travelMerchantCtrl,
                            '상호 / 경로 / 내역',
                            chosenTravelDivision == TravelDivision.car
                                ? '예: 실시간추천 25km 왕복 자차'
                                : '예: 카카오택시 / 코레일 / 식당명 / 하이패스',
                          ),
                          _buildField(travelDateCtrl, '일자', '예: 2026.10.27'),
                        ],

                        // 4. 병원비 입력 폼
                        if (chosenCategory == DocCategory.medical) ...[
                          _buildField(
                              clinicNameCtrl, '상호 (병원/약국명)', '예: 맘온누리약국'),
                          _buildField(
                              bizRegNumberCtrl, '사업자등록번호', '예: 276-63-00432'),
                          _buildField(issueDateCtrl, '발행일', '예: 2026.10.01'),
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

      final enteredSubCategory = subCategoryCtrl.text.trim();
      if (enteredSubCategory.isNotEmpty) {
        await _registerUserSubCategory(chosenCategory, enteredSubCategory);
      }

      final nowStr = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
      final List<DocRecord> createdRecords = [];

      // ★ 자재송장인 경우: 규격명이 여러 줄(예: D32MM 3.744 / D16MM 15.952)이면 각각 별도의 리스트 항목으로 생성!
      if (chosenCategory == DocCategory.invoice) {
        for (final row in invoiceRows) {
          final prod = row.productCtrl.text.trim().isNotEmpty
              ? row.productCtrl.text.trim()
              : '고장력철근';
          final isRebar = prod.contains('철근');
          final unitVal = isRebar
              ? 'ton'
              : (row.unitCtrl.text.trim().isNotEmpty
                  ? row.unitCtrl.text.trim()
                  : 'EA');
          final qtyVal = row.qtyCtrl.text.trim();
          final specVal = row.specCtrl.text.trim();

          final fields = <String, String>{
            'subCategory': enteredSubCategory,
            'arrivalDate': DocRecord.formatDotDate(arrivalDateCtrl.text.trim()),
            'orderNumber': orderNumberCtrl.text.trim(),
            'productName': prod,
            'specName': specVal,
            'unit': unitVal,
            'quantity': qtyVal,
            'weight': qtyVal,
            'supplierName': supplierNameCtrl.text.trim(),
            'amount': invoiceAmountCtrl.text.trim(),
          };

          createdRecords.add(
            DocRecord(
              id: const Uuid().v4(),
              category: chosenCategory,
              createdAt: nowStr,
              imagePath: savedFile.path,
              base64Image: base64Str,
              fields: fields,
            ),
          );
        }
      } else {
        final Map<String, String> collectedFields = {
          'subCategory': enteredSubCategory,
        };
        if (chosenCategory == DocCategory.officialDoc) {
          collectedFields['docDirection'] = chosenDocDirection;
          collectedFields['sentDate'] =
              DocRecord.formatDotDate(sentDateCtrl.text.trim());
          collectedFields['sender'] = senderCtrl.text.trim();
          collectedFields['recipient'] = recipientCtrl.text.trim();
          collectedFields['docNumber'] = docNumberCtrl.text.trim();
          collectedFields['title'] = docTitleCtrl.text.trim();
          collectedFields['aiSummary'] = aiSummaryCtrl.text.trim();
          collectedFields['replyDeadline'] =
              DocRecord.formatDotDate(replyDeadlineCtrl.text.trim());
          collectedFields['amount'] = docAmountCtrl.text.trim();
        } else if (chosenCategory == DocCategory.travel) {
          if (chosenTravelDivision == TravelDivision.car) {
            recalcCarDistanceCost();
          }
          collectedFields['travelDivision'] = chosenTravelDivision;
          collectedFields['distanceKm'] = travelDistanceKmCtrl.text.trim();
          collectedFields['totalAmount'] = travelAmountCtrl.text.trim();
          collectedFields['merchantName'] = travelMerchantCtrl.text.trim();
          collectedFields['date'] = travelDateCtrl.text.trim();
        } else if (chosenCategory == DocCategory.medical) {
          collectedFields['clinicName'] = clinicNameCtrl.text.trim();
          collectedFields['bizRegNumber'] = bizRegNumberCtrl.text.trim();
          collectedFields['issueDate'] = issueDateCtrl.text.trim();
          collectedFields['totalPaid'] = totalPaidCtrl.text.trim();
        }

        createdRecords.add(
          DocRecord(
            id: const Uuid().v4(),
            category: chosenCategory,
            createdAt: nowStr,
            imagePath: savedFile.path,
            base64Image: base64Str,
            fields: collectedFields,
          ),
        );
      }

      setState(() {
        for (final r in createdRecords.reversed) {
          _records.insert(0, r);
        }
        _selectedCategoryFilter = chosenCategory;
        _selectedRecord = createdRecords.first;
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
        title: const Text('목록에서 삭제'),
        content: const Text('이 항목을 삭제하시겠습니까?'),
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
    _showSnack('삭제되었습니다.');
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
            title: const Text('Gemini AI & 원드라이브 설정 (v18)'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '1. Gemini AI 키 등록 (선택사항 - 내장 OCR 기본 탑재)',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13.5,
                      color: Color(0xFF1E3A8A),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '내장 한국어 공문/송장 고정밀 엔진이 기본 작동하며, AI 키를 함께 넣으면 추가 보정이 이루어집니다.',
                    style: TextStyle(fontSize: 12, color: Colors.black87),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: geminiKeyCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Gemini API Key',
                      hintText: 'AQ... 또는 AIza...',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const Divider(height: 24),
                  const Text(
                    '2. 로컬 폴더 지정 (선택)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: localDirCtrl,
                          decoration: const InputDecoration(
                            labelText: '로컬 저장 폴더 경로',
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
                            dialogTitle: 'HTML 저장 폴더 선택',
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
                    '3. 원드라이브 클라우드 API 직접 업로드 설정 (선택)',
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
                  final enteredKey = geminiKeyCtrl.text.trim();
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString(
                      _prefsOneDriveSyncDirKey, localDirCtrl.text.trim());
                  await prefs.setString(
                      _prefsOneDriveSubfolderKey, subfolderCtrl.text.trim());
                  await prefs.setString(_prefsGeminiApiKey, enteredKey);
                  await prefs.setString(
                      _prefsAccessTokenKey, tokenCtrl.text.trim());

                  setState(() {
                    _oneDriveLocalDir = localDirCtrl.text.trim();
                    _oneDriveSubfolder = subfolderCtrl.text.trim().isEmpty
                        ? 'Documents/증빙서류함'
                        : subfolderCtrl.text.trim();
                    _geminiApiKey = enteredKey;
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

  // ===========================================================================
  // HTML 내보내기: 현재 카테고리 필터된 목록만 표 형태 + 상하/좌우 크기 조절 바 포함 내보내기
  // ===========================================================================
  Future<void> _exportFilteredHtml() async {
    final currentFilteredList = _filteredRecords;
    final String filterScopeName = _selectedSubCategoryFilter != '전체'
        ? '${_selectedCategoryFilter}_$_selectedSubCategoryFilter'
        : _selectedCategoryFilter;

    if (currentFilteredList.isEmpty) {
      _showSnack('현재 선택된 [$filterScopeName] 카테고리에 내보낼 항목이 없습니다.');
      return;
    }

    setState(() => _isBusy = true);
    try {
      final String targetHtmlFileName = '증빙서류_$filterScopeName.html';

      final htmlContent = _buildFilteredHtmlDocument(
        records: currentFilteredList,
        scopeTitle: filterScopeName,
      );

      final tempDir = await getTemporaryDirectory();
      final outHtmlFile = File(p.join(tempDir.path, targetHtmlFileName));
      await outHtmlFile.writeAsString(htmlContent, flush: true);

      if (_oneDriveLocalDir.isNotEmpty) {
        try {
          final dir = Directory(_oneDriveLocalDir);
          if (await dir.exists()) {
            await File(p.join(dir.path, targetHtmlFileName))
                .writeAsString(htmlContent, flush: true);
          }
        } catch (_) {}
      }

      final cleanSubfolder =
          _oneDriveSubfolder.replaceAll(RegExp(r'^/+|/+$'), '');
      final remoteFilePath = '/$cleanSubfolder/$targetHtmlFileName';

      bool uploadedViaApi = false;
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
          body: utf8.encode(htmlContent),
        );
        if (putResp.statusCode == 200 || putResp.statusCode == 201) {
          uploadedViaApi = true;
        }
      }

      if (uploadedViaApi) {
        _showSnack(
          '원드라이브($remoteFilePath)에 [$filterScopeName] HTML 내보내기 완료! (${currentFilteredList.length}건)',
        );
      } else {
        await Share.shareXFiles(
          [XFile(outHtmlFile.path, mimeType: 'text/html')],
          subject: targetHtmlFileName,
          text: '[$filterScopeName] HTML (${currentFilteredList.length}건)',
        );
      }
    } catch (e) {
      _showSnack('HTML 내보내기 중 오류: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  String _buildFilteredHtmlDocument({
    required List<DocRecord> records,
    required String scopeTitle,
  }) {
    final recordsJson = jsonEncode(records.map((r) => r.toJson()).toList());
    final majorCat = _selectedCategoryFilter;

    return '''<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>증빙서류 - $scopeTitle</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Malgun Gothic", "맑은 고딕", sans-serif;
      background: #f1f5f9;
      color: #1e293b;
      height: 100vh;
      display: flex;
      flex-direction: column;
      overflow: hidden;
    }
    header {
      background: #1e3a8a;
      color: #ffffff;
      padding: 10px 14px;
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    header h1 { font-size: 16px; font-weight: 700; }
    #list-pane {
      height: 44vh;
      min-height: 15vh;
      max-height: 78vh;
      overflow-y: auto;
      background: #ffffff;
      padding: 0;
    }
    table.grid-table {
      width: 100%;
      border-collapse: collapse;
      font-size: 13px;
      text-align: center;
    }
    table.grid-table th {
      background: #e2e8f0;
      color: #1e293b;
      font-weight: 700;
      padding: 8px 6px;
      border: 1px solid #94a3b8;
      position: sticky;
      top: 0;
      z-index: 2;
    }
    table.grid-table td {
      padding: 8px 6px;
      border: 1px solid #cbd5e1;
      color: #0f172a;
      cursor: pointer;
    }
    table.grid-table tr.active td {
      background: #dbeafe;
      font-weight: 700;
    }
    #resizer-v {
      height: 22px;
      background: #cbd5e1;
      cursor: ns-resize;
      display: flex;
      align-items: center;
      justify-content: center;
      user-select: none;
      touch-action: none;
      font-size: 11px;
      color: #334155;
      font-weight: 600;
      border-top: 1px solid #94a3b8;
      border-bottom: 1px solid #94a3b8;
    }
    #detail-pane {
      flex: 1;
      background: #0f172a;
      color: #f8fafc;
      display: flex;
      flex-direction: row;
      overflow: hidden;
    }
    #detail-left {
      width: 42%;
      min-width: 18%;
      max-width: 80%;
      height: 100%;
      padding: 12px 14px;
      overflow-y: auto;
      background: #1e293b;
    }
    #resizer-h {
      width: 16px;
      background: #334155;
      cursor: ew-resize;
      display: flex;
      align-items: center;
      justify-content: center;
      user-select: none;
      touch-action: none;
      color: #cbd5e1;
      font-size: 11px;
    }
    .detail-header {
      color: #fcd34d;
      font-weight: 700;
      font-size: 14px;
      margin-bottom: 10px;
      padding-bottom: 6px;
      border-bottom: 1px solid #334155;
    }
    .detail-line {
      margin-bottom: 7px;
      font-size: 12.5px;
      line-height: 1.45;
      word-break: keep-all;
    }
    .detail-label {
      color: #93c5fd;
      font-weight: 700;
    }
    #detail-right {
      flex: 1;
      height: 100%;
      padding: 6px;
      display: flex;
      align-items: center;
      justify-content: center;
      background: #0f172a;
      overflow: auto;
    }
    #preview-img {
      max-width: 100%;
      max-height: 100%;
      object-fit: contain;
    }
  </style>
</head>
<body>
  <header>
    <h1>[$scopeTitle] 증빙서류 (${records.length}건)</h1>
  </header>

  <div id="list-pane"></div>

  <div id="resizer-v">═ 위아래로 끌어서 화면 크기 조절</div>

  <div id="detail-pane">
    <div id="detail-left"></div>
    <div id="resizer-h" title="좌우로 끌어서 상세정보/사진 폭 조절">⋮</div>
    <div id="detail-right">
      <img id="preview-img" style="display:none;" alt="증빙서류 사진" />
    </div>
  </div>

  <script>
    const records = $recordsJson;
    const majorCat = "$majorCat";
    let selectedId = records.length > 0 ? records[0].id : null;

    // 상하 크기 조절
    const resizerV = document.getElementById('resizer-v');
    const listPane = document.getElementById('list-pane');
    let isResizingV = false;
    resizerV.addEventListener('pointerdown', (e) => { isResizingV = true; resizerV.setPointerCapture(e.pointerId); });
    resizerV.addEventListener('pointermove', (e) => {
      if (!isResizingV) return;
      const rect = listPane.getBoundingClientRect();
      listPane.style.height = Math.max(80, Math.min(window.innerHeight - 140, e.clientY - rect.top)) + 'px';
    });
    resizerV.addEventListener('pointerup', () => { isResizingV = false; });

    // 좌우 크기 조절
    const resizerH = document.getElementById('resizer-h');
    const detailLeft = document.getElementById('detail-left');
    const detailPane = document.getElementById('detail-pane');
    let isResizingH = false;
    resizerH.addEventListener('pointerdown', (e) => { isResizingH = true; resizerH.setPointerCapture(e.pointerId); });
    resizerH.addEventListener('pointermove', (e) => {
      if (!isResizingH) return;
      const rect = detailPane.getBoundingClientRect();
      const newW = ((e.clientX - rect.left) / rect.width) * 100;
      detailLeft.style.width = Math.max(18, Math.min(80, newW)) + '%';
    });
    resizerH.addEventListener('pointerup', () => { isResizingH = false; });

    function dotDate(raw) {
      if (!raw) return '-';
      const m = String(raw).match(/(\\d{4})\\s*[-./년]\\s*(\\d{1,2})\\s*[-./월]\\s*(\\d{1,2})/);
      if (m) return `\${m[1]}.\${m[2].padStart(2,'0')}.\${m[3].padStart(2,'0')}`;
      return raw;
    }

    function getFieldLines(item) {
      const f = item.fields || {};
      if (item.category === '대외공문') {
        const isOut = f.docDirection === '발신';
        const partyLabel = isOut ? '받는사람' : '보낸사람';
        const partyVal = isOut ? (f.recipient || f.sender || '-') : (f.sender || '-');
        return [
          ['접수일', dotDate(f.sentDate)],
          [partyLabel, partyVal],
          ['제목', f.title || '-'],
          ['회신요청일', dotDate(f.replyDeadline)],
          ['공문번호', f.docNumber || '-'],
          ['내용', f.aiSummary || '-'],
        ];
      } else if (item.category === '자재송장') {
        return [
          ['날짜', dotDate(f.arrivalDate)],
          ['제품명', f.productName || '-'],
          ['규격명', f.specName || '-'],
          ['단위', f.unit || 'ton'],
          ['수량', f.quantity || '-'],
          ['공급자상호', f.supplierName || '-'],
          ['송장번호', f.orderNumber || '-'],
        ];
      } else if (item.category === '출장비') {
        const div = f.travelDivision || '식대';
        if (div === '자차') {
          return [
            ['구분', '자차'],
            ['산출내역', `\${f.distanceKm || '0'}km × 2 × 300원 = \${Number(f.totalAmount || 0).toLocaleString()}원`],
            ['일자', dotDate(f.date)],
          ];
        }
        return [
          ['구분', div],
          ['상호/내역', f.merchantName || '-'],
          ['금액', `\${Number(f.totalAmount || 0).toLocaleString()}원`],
          ['일자', dotDate(f.date)],
        ];
      } else {
        return [
          ['상호', f.clinicName || '-'],
          ['사업자번호', f.bizRegNumber || '-'],
          ['발행일', dotDate(f.issueDate)],
          ['총수납금액', `\${Number(f.totalPaid || 0).toLocaleString()}원`],
        ];
      }
    }

    function render() {
      if (majorCat === '자재송장' || (records.length > 0 && records.every(r => r.category === '자재송장'))) {
        let html = '<table class="grid-table"><thead><tr><th>날짜</th><th>제품명</th><th>규격명</th><th>단위</th><th>수량</th></tr></thead><tbody>';
        records.forEach(item => {
          const f = item.fields || {};
          const cls = item.id === selectedId ? 'active' : '';
          html += `<tr class="\${cls}" onclick="selectedId='\${item.id}'; render();">
            <td>\${escapeHtml(dotDate(f.arrivalDate))}</td>
            <td>\${escapeHtml(f.productName || '-')}</td>
            <td>\${escapeHtml(f.specName || '-')}</td>
            <td>\${escapeHtml(f.unit || 'ton')}</td>
            <td>\${escapeHtml(f.quantity || '-')}</td>
          </tr>`;
        });
        html += '</tbody></table>';
        listPane.innerHTML = html;
      } else if (majorCat === '대외공문' || (records.length > 0 && records.every(r => r.category === '대외공문'))) {
        const hasOut = records.some(r => (r.fields || {}).docDirection === '발신');
        const partyHeader = hasOut ? '보낸사람/받는사람' : '보낸사람';
        let html = `<table class="grid-table"><thead><tr><th>접수일</th><th>\${partyHeader}</th><th>제목</th><th>회신요청일</th></tr></thead><tbody>`;
        records.forEach(item => {
          const f = item.fields || {};
          const isOut = f.docDirection === '발신';
          const partyVal = isOut ? (f.recipient || f.sender || '-') : (f.sender || '-');
          const cls = item.id === selectedId ? 'active' : '';
          html += `<tr class="\${cls}" onclick="selectedId='\${item.id}'; render();">
            <td>\${escapeHtml(dotDate(f.sentDate))}</td>
            <td>\${escapeHtml(partyVal)}</td>
            <td>\${escapeHtml(f.title || '-')}</td>
            <td>\${escapeHtml(dotDate(f.replyDeadline))}</td>
          </tr>`;
        });
        html += '</tbody></table>';
        listPane.innerHTML = html;
      } else {
        let html = '<table class="grid-table"><thead><tr><th>구분</th><th>제목/내역</th><th>상세</th></tr></thead><tbody>';
        records.forEach(item => {
          const cls = item.id === selectedId ? 'active' : '';
          const lines = getFieldLines(item);
          html += `<tr class="\${cls}" onclick="selectedId='\${item.id}'; render();">
            <td>\${escapeHtml(item.category)}</td>
            <td>\${escapeHtml(lines[0] ? lines[0][1] : '-')}</td>
            <td>\${escapeHtml(lines[1] ? lines[1][1] : '-')}</td>
          </tr>`;
        });
        html += '</tbody></table>';
        listPane.innerHTML = html;
      }

      const current = records.find(r => r.id === selectedId);
      const leftEl = document.getElementById('detail-left');
      const imgEl = document.getElementById('preview-img');
      if (!current) {
        leftEl.innerHTML = '항목을 선택하세요.';
        imgEl.style.display = 'none';
        return;
      }

      const lines = getFieldLines(current);
      let leftHtml = `<div class="detail-header">[\${escapeHtml(current.category)}] 상세 정보</div>`;
      lines.forEach(kv => {
        leftHtml += `<div class="detail-line"><span class="detail-label">\${escapeHtml(kv[0])} :</span> \${escapeHtml(kv[1])}</div>`;
      });
      leftEl.innerHTML = leftHtml;

      imgEl.src = 'data:image/jpeg;base64,' + current.base64Image;
      imgEl.style.display = 'block';
    }

    function escapeHtml(str) {
      return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
    }

    render();
  </script>
</body>
</html>''';
  }

  Future<void> _exportAndSharePdf() async {
    final targetRecords = _filteredRecords;
    if (targetRecords.isEmpty) {
      _showSnack('내보낼 증빙서류 사진이 없습니다.');
      return;
    }

    setState(() => _isBusy = true);
    try {
      final koreanFont = await PdfGoogleFonts.nanumGothicRegular();
      final koreanBoldFont = await PdfGoogleFonts.nanumGothicBold();

      final pdf = pw.Document();

      for (int i = 0; i < targetRecords.length; i++) {
        final rec = targetRecords[i];
        final imgBytes = base64Decode(rec.base64Image);
        final pdfImage = pw.MemoryImage(imgBytes);
        final catLabel = rec.subCategory.isNotEmpty
            ? '${rec.category} · ${rec.subCategory}'
            : rec.category;

        pdf.addPage(
          pw.Page(
            pageFormat: PdfPageFormat.a4,
            margin: const pw.EdgeInsets.all(16),
            build: (pw.Context ctx) {
              return pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(bottom: 6),
                    child: pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Text(
                          '[$catLabel] ${rec.displayTitle}',
                          style: pw.TextStyle(
                            font: koreanBoldFont,
                            fontSize: 11,
                            color: PdfColors.blueGrey800,
                          ),
                        ),
                        pw.Text(
                          rec.createdAt.split(' ').first,
                          style: pw.TextStyle(
                            font: koreanFont,
                            fontSize: 10,
                            color: PdfColors.grey700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  pw.Expanded(
                    child: pw.Center(
                      child: pw.Image(pdfImage, fit: pw.BoxFit.contain),
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
      final scopeName = _selectedSubCategoryFilter != '전체'
          ? '${_selectedCategoryFilter}_$_selectedSubCategoryFilter'
          : _selectedCategoryFilter;
      final pdfFile = File(
        p.join(tempDir.path, '증빙사진_${scopeName}_$timestamp.pdf'),
      );
      await pdfFile.writeAsBytes(pdfBytes, flush: true);

      await Share.shareXFiles(
        [XFile(pdfFile.path, mimeType: 'application/pdf')],
        text: '[$scopeName] 증빙사진 PDF (${targetRecords.length}건)',
      );
    } catch (e) {
      _showSnack('PDF 생성 중 오류가 발생했습니다: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  List<MapEntry<String, String>> _getCategoryFieldPairs(DocRecord rec) {
    final f = rec.fields;
    final subLabel = rec.subCategory.isNotEmpty ? rec.subCategory : '미지정';
    switch (rec.category) {
      case DocCategory.officialDoc:
        return [
          MapEntry(rec.isOutgoingOfficialDoc ? '발신일' : '접수일',
              DocRecord.formatDotDate(f['sentDate'])),
          MapEntry(rec.officialCounterpartyLabel, rec.officialCounterpartyValue),
          MapEntry('제목', f['title'] ?? '-'),
          MapEntry('회신요청일', DocRecord.formatDotDate(f['replyDeadline'])),
          MapEntry('공문번호', f['docNumber'] ?? '-'),
          MapEntry('내용', f['aiSummary'] ?? '-'),
        ];
      case DocCategory.invoice:
        return [
          MapEntry('날짜', DocRecord.formatDotDate(f['arrivalDate'])),
          MapEntry('제품명', f['productName'] ?? '-'),
          MapEntry('규격명', f['specName'] ?? '-'),
          MapEntry('단위', f['unit'] ?? 'ton'),
          MapEntry('수량', f['quantity'] ?? '-'),
          MapEntry('공급자상호', f['supplierName'] ?? '-'),
          MapEntry('주문/송장번호', f['orderNumber'] ?? '-'),
        ];
      case DocCategory.travel:
        final div = rec.travelDivision;
        if (div == TravelDivision.car) {
          final km = f['distanceKm'] ?? '0';
          return [
            MapEntry('카테고리', subLabel),
            MapEntry('구분', '자차'),
            MapEntry('산출내역',
                '${km}km × 2 × 300원 = ${DocRecord._formatCurrency(f['totalAmount'])}원'),
            MapEntry('일자', DocRecord.formatDotDate(f['date'])),
          ];
        }
        return [
          MapEntry('카테고리', subLabel),
          MapEntry('구분', div),
          MapEntry('내역/상호', f['merchantName'] ?? '-'),
          MapEntry('금액', '${DocRecord._formatCurrency(f['totalAmount'])}원'),
          MapEntry('일자', DocRecord.formatDotDate(f['date'])),
        ];
      case DocCategory.medical:
        return [
          MapEntry('카테고리', subLabel),
          MapEntry('상호', f['clinicName'] ?? '-'),
          MapEntry('사업자등록번호', f['bizRegNumber'] ?? '-'),
          MapEntry('발행일', DocRecord.formatDotDate(f['issueDate'])),
          MapEntry('총수납금액', '${DocRecord._formatCurrency(f['totalPaid'])}원'),
        ];
      default:
        return [];
    }
  }

  // ===========================================================================
  // ★ 상단 리스트 영역 빌더:
  // - [자재송장] 탭: 첨부 사진과 동일한 5열 표 형식 (`날짜 | 제품명 | 규격명 | 단위 | 수량`)
  // - [대외공문] 탭: 첨부 사진과 동일한 4열 표 형식 (`접수일 | 보낸사람(또는 받는사람) | 제목 | 회신요청일`)
  // ===========================================================================
  Widget _buildTopListSection(List<DocRecord> items) {
    if (items.isEmpty) {
      return const Center(
        child: Text(
          '등록된 증빙서류가 없습니다.\n우측 하단 [서류 촬영] 버튼을 눌러 추가하세요.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    if (_selectedCategoryFilter == DocCategory.invoice) {
      return Column(
        children: [
          Container(
            color: const Color(0xFFE2E8F0),
            child: IntrinsicHeight(
              child: Row(
                children: [
                  _buildTableHeaderCell('날짜', flex: 23),
                  _buildTableHeaderCell('제품명', flex: 25),
                  _buildTableHeaderCell('규격명', flex: 22),
                  _buildTableHeaderCell('단위', flex: 12),
                  _buildTableHeaderCell('수량', flex: 18),
                  const SizedBox(width: 34),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: items.length,
              itemBuilder: (ctx, idx) {
                final rec = items[idx];
                final f = rec.fields;
                final isSelected = _selectedRecord?.id == rec.id;
                return InkWell(
                  onTap: () => setState(() => _selectedRecord = rec),
                  child: Container(
                    decoration: BoxDecoration(
                      color: isSelected ? const Color(0xFFDBEAFE) : Colors.white,
                      border: const Border(
                        bottom: BorderSide(color: Color(0xFFCBD5E1), width: 1),
                      ),
                    ),
                    child: IntrinsicHeight(
                      child: Row(
                        children: [
                          _buildTableDataCell(
                            DocRecord.formatDotDate(f['arrivalDate']),
                            flex: 23,
                            isSelected: isSelected,
                          ),
                          _buildTableDataCell(
                            f['productName'] ?? '-',
                            flex: 25,
                            isSelected: isSelected,
                          ),
                          _buildTableDataCell(
                            f['specName'] ?? '-',
                            flex: 22,
                            isSelected: isSelected,
                          ),
                          _buildTableDataCell(
                            f['unit'] ?? 'ton',
                            flex: 12,
                            isSelected: isSelected,
                          ),
                          _buildTableDataCell(
                            f['quantity'] ?? '-',
                            flex: 18,
                            isSelected: isSelected,
                          ),
                          SizedBox(
                            width: 34,
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              icon: const Icon(Icons.delete_outline,
                                  size: 18, color: Colors.redAccent),
                              onPressed: () => _deleteLocalRecord(rec),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      );
    }

    if (_selectedCategoryFilter == DocCategory.officialDoc) {
      final bool anyOutgoing = items.any((r) => r.isOutgoingOfficialDoc);
      final bool allOutgoing = items.every((r) => r.isOutgoingOfficialDoc);
      final String partyHeader = allOutgoing
          ? '받는사람'
          : (anyOutgoing ? '보낸/받는사람' : '보낸사람');

      return Column(
        children: [
          Container(
            color: const Color(0xFFE2E8F0),
            child: IntrinsicHeight(
              child: Row(
                children: [
                  _buildTableHeaderCell('접수일', flex: 23),
                  _buildTableHeaderCell(partyHeader, flex: 21),
                  _buildTableHeaderCell('제목', flex: 33),
                  _buildTableHeaderCell('회신요청일', flex: 23),
                  const SizedBox(width: 34),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: items.length,
              itemBuilder: (ctx, idx) {
                final rec = items[idx];
                final f = rec.fields;
                final isSelected = _selectedRecord?.id == rec.id;
                return InkWell(
                  onTap: () => setState(() => _selectedRecord = rec),
                  child: Container(
                    decoration: BoxDecoration(
                      color: isSelected ? const Color(0xFFDBEAFE) : Colors.white,
                      border: const Border(
                        bottom: BorderSide(color: Color(0xFFCBD5E1), width: 1),
                      ),
                    ),
                    child: IntrinsicHeight(
                      child: Row(
                        children: [
                          _buildTableDataCell(
                            DocRecord.formatDotDate(f['sentDate']),
                            flex: 23,
                            isSelected: isSelected,
                          ),
                          _buildTableDataCell(
                            rec.officialCounterpartyValue,
                            flex: 21,
                            isSelected: isSelected,
                          ),
                          _buildTableDataCell(
                            f['title'] ?? '-',
                            flex: 33,
                            isSelected: isSelected,
                            maxLines: 2,
                          ),
                          _buildTableDataCell(
                            DocRecord.formatDotDate(f['replyDeadline']),
                            flex: 23,
                            isSelected: isSelected,
                          ),
                          SizedBox(
                            width: 34,
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              icon: const Icon(Icons.delete_outline,
                                  size: 18, color: Colors.redAccent),
                              onPressed: () => _deleteLocalRecord(rec),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      );
    }

    // 그 외 탭(출장비, 병원비, 전체) 리스트
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (ctx, idx) {
        final rec = items[idx];
        final isSelected = _selectedRecord?.id == rec.id;
        final mySubOptions = _userSubCategoriesMap[rec.category] ?? <String>[];
        final badgeText =
            rec.subCategory.isNotEmpty ? rec.subCategory : '카테고리 지정';

        return ListTile(
          dense: true,
          selected: isSelected,
          selectedTileColor: Colors.blue.shade50,
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PopupMenuButton<String>(
                tooltip: '내 카테고리 선택 또는 신규 등록',
                onSelected: (newSub) => _changeRecordSubCategory(rec, newSub),
                itemBuilder: (_) => [
                  ...mySubOptions.map(
                    (sc) => PopupMenuItem(
                      value: sc,
                      child: Text(sc),
                    ),
                  ),
                  if (mySubOptions.isNotEmpty) const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: '__ADD_NEW__',
                    child: Row(
                      children: [
                        Icon(Icons.add, size: 16, color: Colors.blueAccent),
                        SizedBox(width: 6),
                        Text(
                          '새 카테고리 등록...',
                          style: TextStyle(
                            color: Colors.blueAccent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: rec.subCategory.isNotEmpty
                        ? Colors.indigo.shade100
                        : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        badgeText,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: rec.subCategory.isNotEmpty
                              ? Colors.indigo
                              : Colors.black54,
                        ),
                      ),
                      const Icon(
                        Icons.arrow_drop_down,
                        size: 14,
                        color: Colors.indigo,
                      ),
                    ],
                  ),
                ),
              ),
              if (rec.category == DocCategory.travel) ...[
                const SizedBox(width: 4),
                PopupMenuButton<String>(
                  tooltip: '출장비 구분 변경',
                  onSelected: (newDiv) =>
                      _changeRecordTravelDivision(rec, newDiv),
                  itemBuilder: (_) => TravelDivision.list
                      .map(
                        (d) => PopupMenuItem(
                          value: d,
                          child: Text('[$d]로 변경'),
                        ),
                      )
                      .toList(),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade200,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      rec.travelDivision,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.brown.shade900,
                      ),
                    ),
                  ),
                ),
              ],
            ],
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
            style: const TextStyle(fontSize: 11.5),
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
    );
  }

  Widget _buildTableHeaderCell(String label, {required int flex}) {
    return Expanded(
      flex: flex,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: const BoxDecoration(
          border: Border(
            right: BorderSide(color: Color(0xFF94A3B8), width: 1),
            bottom: BorderSide(color: Color(0xFF94A3B8), width: 1),
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: Color(0xFF1E293B),
          ),
        ),
      ),
    );
  }

  Widget _buildTableDataCell(
    String value, {
    required int flex,
    required bool isSelected,
    int maxLines = 1,
  }) {
    return Expanded(
      flex: flex,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        decoration: const BoxDecoration(
          border: Border(
            right: BorderSide(color: Color(0xFFCBD5E1), width: 1),
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          value.trim().isEmpty ? '-' : value,
          textAlign: TextAlign.center,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: const Color(0xFF0F172A),
          ),
        ),
      ),
    );
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final items = _filteredRecords;
    final subCategories = _userRegisteredSubCategoriesForCurrentTab;
    final majorTotalSum = _sumByMajorCategory(_selectedCategoryFilter);
    final currentSubTotalSum = _sumBySubCategory(_selectedSubCategoryFilter);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
        title: const Text('증빙서류 스냅 v18'),
        actions: [
          IconButton(
            tooltip: 'Gemini AI 키 & 설정',
            icon: Icon(
              _geminiApiKey.trim().isNotEmpty
                  ? Icons.auto_awesome
                  : Icons.settings,
              color: _geminiApiKey.trim().isNotEmpty
                  ? Colors.amberAccent
                  : Colors.white,
            ),
            onPressed: _openSettingsDialog,
          ),
          TextButton.icon(
            onPressed: _isBusy ? null : _exportFilteredHtml,
            icon: const Icon(Icons.html, color: Colors.white, size: 18),
            label: const Text(
              'HTML 내보내기',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: _isBusy ? null : _exportAndSharePdf,
            icon: const Icon(
              Icons.picture_as_pdf,
              color: Colors.amberAccent,
              size: 18,
            ),
            label: const Text(
              'PDF 내보내기',
              style: TextStyle(
                color: Colors.amberAccent,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              // 1) 상단 1줄: 문서 종류 선택 탭
              Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                color: Colors.grey.shade100,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: DocCategory.filterList.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (ctx, idx) {
                    final cat = DocCategory.filterList[idx];
                    final selected = cat == _selectedCategoryFilter;
                    return ChoiceChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(
                        cat,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      selected: selected,
                      onSelected: (_) {
                        setState(() {
                          _selectedCategoryFilter = cat;
                          _selectedSubCategoryFilter = '전체';
                          _selectedTravelDivisionFilter = '전체';
                          final currentList = _filteredRecords;
                          if (!currentList
                              .any((r) => r.id == _selectedRecord?.id)) {
                            _selectedRecord = currentList.isNotEmpty
                                ? currentList.first
                                : null;
                          }
                        });
                      },
                    );
                  },
                ),
              ),

              // 2) 상단 2줄: 전체 합계 & 내가 등록한 카테고리별 합계 대시보드
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  border: Border(
                    bottom: BorderSide(color: Colors.blue.shade200),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '$_selectedCategoryFilter 전체 합계 (${_recordsInSelectedMajorCategory.length}건): ${NumberFormat('#,###').format(majorTotalSum)}원',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13.5,
                            color: Color(0xFF1E3A8A),
                          ),
                        ),
                        if (_selectedSubCategoryFilter != '전체')
                          Text(
                            '[$_selectedSubCategoryFilter 합계: ${NumberFormat('#,###').format(currentSubTotalSum)}원]',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12.5,
                              color: Colors.indigo,
                            ),
                          )
                        else if (_selectedCategoryFilter != DocCategory.all)
                          InkWell(
                            onTap: () => _promptAddNewSubCategory(
                                _selectedCategoryFilter),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 4),
                              child: Text(
                                '+ 내 카테고리 등록',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blueAccent,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (subCategories.length > 1) ...[
                      const SizedBox(height: 6),
                      SizedBox(
                        height: 32,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: subCategories.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 6),
                          itemBuilder: (ctx, idx) {
                            final subCat = subCategories[idx];
                            final selected =
                                subCat == _selectedSubCategoryFilter;
                            final cnt = _countBySubCategory(subCat);
                            final sum = _sumBySubCategory(subCat);
                            final labelText = subCat == '전체'
                                ? '전체 ($cnt건 · ${NumberFormat('#,###').format(sum)}원)'
                                : '$subCat ($cnt건 · ${NumberFormat('#,###').format(sum)}원)';
                            return ChoiceChip(
                              visualDensity: VisualDensity.compact,
                              selectedColor: Colors.indigo.shade100,
                              label: Text(
                                labelText,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: selected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                              selected: selected,
                              onSelected: (_) {
                                setState(() {
                                  _selectedSubCategoryFilter = subCat;
                                  final currentList = _filteredRecords;
                                  if (!currentList
                                      .any((r) => r.id == _selectedRecord?.id)) {
                                    _selectedRecord = currentList.isNotEmpty
                                        ? currentList.first
                                        : null;
                                  }
                                });
                              },
                            );
                          },
                        ),
                      ),
                    ],

                    if (_selectedCategoryFilter == DocCategory.travel) ...[
                      const SizedBox(height: 6),
                      SizedBox(
                        height: 32,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: ['전체', ...TravelDivision.list].map((div) {
                            final isSel = _selectedTravelDivisionFilter == div;
                            final cnt = _countByTravelDivision(div);
                            final sum = _sumByTravelDivision(div);
                            return Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ChoiceChip(
                                visualDensity: VisualDensity.compact,
                                backgroundColor: Colors.amber.shade50,
                                selectedColor: Colors.amber.shade300,
                                label: Text(
                                  div == '전체'
                                      ? '구분전체 ($cnt건)'
                                      : '$div (${NumberFormat('#,###').format(sum)}원)',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: isSel
                                        ? FontWeight.bold
                                        : FontWeight.w500,
                                    color: Colors.brown.shade900,
                                  ),
                                ),
                                selected: isSel,
                                onSelected: (_) {
                                  setState(() {
                                    _selectedTravelDivisionFilter = div;
                                    final currentList = _filteredRecords;
                                    if (!currentList.any(
                                        (r) => r.id == _selectedRecord?.id)) {
                                      _selectedRecord = currentList.isNotEmpty
                                          ? currentList.first
                                          : null;
                                    }
                                  });
                                },
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // 3) 상단 리스트(표) + 상하 크기조절 바 + 하단 상세보기(좌측 정보 + 좌우 크기조절 바 + 우측 전체확대 사진)
              Expanded(
                child: LayoutBuilder(
                  builder: (ctx, constraints) {
                    final totalH = constraints.maxHeight;
                    const double dividerBarHeight = 24.0;
                    final double usableH =
                        math.max(100.0, totalH - dividerBarHeight);
                    final double listH =
                        (usableH * _listSplitRatio).clamp(60.0, usableH - 80.0);
                    final double detailH = usableH - listH;

                    return Column(
                      children: [
                        // 상단 리스트 영역
                        SizedBox(
                          height: listH,
                          child: _buildTopListSection(items),
                        ),

                        // 중단: 위아래로 끌어서 화면 크기 조절하는 바
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onVerticalDragUpdate: (details) {
                            setState(() {
                              _listSplitRatio = (_listSplitRatio +
                                      details.delta.dy / usableH)
                                  .clamp(0.18, 0.82);
                            });
                          },
                          onVerticalDragEnd: (_) async {
                            final prefs =
                                await SharedPreferences.getInstance();
                            await prefs.setDouble(
                                _prefsSplitRatioKey, _listSplitRatio);
                          },
                          child: Container(
                            height: dividerBarHeight,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: Colors.blueGrey.shade100,
                              border: Border.symmetric(
                                horizontal: BorderSide(
                                    color: Colors.blueGrey.shade300, width: 1),
                              ),
                            ),
                            child: Center(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.drag_handle,
                                      size: 18,
                                      color: Colors.blueGrey.shade700),
                                  const SizedBox(width: 4),
                                  Text(
                                    '위아래로 끌어서 화면 크기 조절',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.blueGrey.shade800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),

                        // ★ 하단 상세보기란:
                        // 1. 왼쪽 상세와 오른쪽 사진 사이에 좌우로 끌어서 폭을 조절하는 세로 조절바 추가!
                        // 2. 오른쪽 사진은 검은 여백 전체로 꽉 차게 보이며, 확대(Zoom) 시 검은 영역 어디로든 자유롭게 커지도록 제한 박스 제거!
                        SizedBox(
                          height: detailH,
                          child: Container(
                            width: double.infinity,
                            color: const Color(0xFF0F172A),
                            child: _selectedRecord == null
                                ? const Center(
                                    child: Text(
                                      '위 목록에서 항목을 선택하면\n좌측에 상세정보, 우측에 증빙사진이 표시됩니다.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: Colors.white70),
                                    ),
                                  )
                                : LayoutBuilder(
                                    builder: (ctx, detailConstraints) {
                                      final totalW = detailConstraints.maxWidth;
                                      const double vertHandleWidth = 18.0;
                                      final usableW = math.max(
                                          100.0, totalW - vertHandleWidth);
                                      final leftW =
                                          (usableW * _detailHorizSplitRatio)
                                              .clamp(70.0, usableW - 70.0);
                                      final rightW = usableW - leftW;

                                      return Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          // 좌측: 항목별 줄바꿈 상세정보
                                          SizedBox(
                                            width: leftW,
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.fromLTRB(
                                                      10, 10, 8, 10),
                                              color: const Color(0xFF1E293B),
                                              child: SingleChildScrollView(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Row(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment
                                                              .spaceBetween,
                                                      children: [
                                                        Expanded(
                                                          child: Text(
                                                            '[${_selectedRecord!.category}${_selectedRecord!.subCategory.isNotEmpty ? " > ${_selectedRecord!.subCategory}" : ""}]',
                                                            style:
                                                                const TextStyle(
                                                              color: Colors
                                                                  .amberAccent,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .bold,
                                                              fontSize: 12.5,
                                                            ),
                                                          ),
                                                        ),
                                                        if (_selectedRecord!
                                                                .category ==
                                                            DocCategory
                                                                .officialDoc)
                                                          InkWell(
                                                            onTap: () async {
                                                              final idx = _records
                                                                  .indexWhere((r) =>
                                                                      r.id ==
                                                                      _selectedRecord!
                                                                          .id);
                                                              if (idx == -1) {
                                                                return;
                                                              }
                                                              final cur = _records[
                                                                      idx]
                                                                  .isOutgoingOfficialDoc;
                                                              final newFields = Map<
                                                                      String,
                                                                      String>.from(
                                                                  _records[idx]
                                                                      .fields);
                                                              newFields[
                                                                      'docDirection'] =
                                                                  cur
                                                                      ? '수신'
                                                                      : '발신';
                                                              final updated =
                                                                  DocRecord(
                                                                id: _records[
                                                                        idx]
                                                                    .id,
                                                                category: _records[
                                                                        idx]
                                                                    .category,
                                                                createdAt: _records[
                                                                        idx]
                                                                    .createdAt,
                                                                imagePath: _records[
                                                                        idx]
                                                                    .imagePath,
                                                                base64Image: _records[
                                                                        idx]
                                                                    .base64Image,
                                                                fields:
                                                                    newFields,
                                                              );
                                                              setState(() {
                                                                _records[idx] =
                                                                    updated;
                                                                _selectedRecord =
                                                                    updated;
                                                              });
                                                              await _saveLocalRecords();
                                                            },
                                                            child: Container(
                                                              padding:
                                                                  const EdgeInsets
                                                                      .symmetric(
                                                                horizontal: 6,
                                                                vertical: 2,
                                                              ),
                                                              decoration:
                                                                  BoxDecoration(
                                                                color: Colors
                                                                    .blueGrey
                                                                    .shade700,
                                                                borderRadius:
                                                                    BorderRadius
                                                                        .circular(
                                                                            4),
                                                              ),
                                                              child: Text(
                                                                _selectedRecord!
                                                                        .isOutgoingOfficialDoc
                                                                    ? '발신(받는사람)'
                                                                    : '수신(보낸사람)',
                                                                style:
                                                                    const TextStyle(
                                                                  fontSize: 10,
                                                                  color: Colors
                                                                      .white,
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                      ],
                                                    ),
                                                    const SizedBox(height: 8),
                                                    ..._getCategoryFieldPairs(
                                                            _selectedRecord!)
                                                        .map(
                                                      (e) => Padding(
                                                        padding:
                                                            const EdgeInsets
                                                                .only(bottom: 6),
                                                        child: RichText(
                                                          text: TextSpan(
                                                            style:
                                                                const TextStyle(
                                                              fontSize: 12,
                                                              height: 1.38,
                                                              color:
                                                                  Colors.white,
                                                            ),
                                                            children: [
                                                              TextSpan(
                                                                text:
                                                                    '${e.key} : ',
                                                                style:
                                                                    const TextStyle(
                                                                  color: Color(
                                                                      0xFF93C5FD),
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .bold,
                                                                ),
                                                              ),
                                                              TextSpan(
                                                                text: e.value
                                                                        .trim()
                                                                        .isEmpty
                                                                    ? '-'
                                                                    : e.value,
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),

                                          // ★ 중앙 세로 조절바: 좌우로 끌어서 왼쪽 상세와 오른쪽 사진 크기를 자유롭게 조절!
                                          GestureDetector(
                                            behavior: HitTestBehavior.opaque,
                                            onHorizontalDragUpdate: (details) {
                                              setState(() {
                                                _detailHorizSplitRatio =
                                                    (_detailHorizSplitRatio +
                                                            details.delta.dx /
                                                                usableW)
                                                        .clamp(0.18, 0.82);
                                              });
                                            },
                                            onHorizontalDragEnd: (_) async {
                                              final prefs =
                                                  await SharedPreferences
                                                      .getInstance();
                                              await prefs.setDouble(
                                                _prefsHorizSplitRatioKey,
                                                _detailHorizSplitRatio,
                                              );
                                            },
                                            child: Container(
                                              width: vertHandleWidth,
                                              color: const Color(0xFF334155),
                                              child: Center(
                                                child: Container(
                                                  width: 4,
                                                  height: 38,
                                                  decoration: BoxDecoration(
                                                    color: Colors.amberAccent,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            999),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),

                                          // ★ 우측 사진 영역: 검은 영역 전체를 다 쓰도록 꽉 채우고, 확대 시 검은 영역 어디로든 제한 없이 확대됨!
                                          SizedBox(
                                            width: rightW,
                                            height: detailH,
                                            child: ClipRect(
                                              child: InteractiveViewer(
                                                clipBehavior: Clip.none,
                                                boundaryMargin:
                                                    const EdgeInsets.all(400),
                                                minScale: 0.6,
                                                maxScale: 8.0,
                                                child: SizedBox(
                                                  width: rightW,
                                                  height: detailH,
                                                  child: _buildRecordImage(
                                                      _selectedRecord!),
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
                      ],
                    );
                  },
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
      return Image.file(
        file,
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      );
    }
    if (record.base64Image.isNotEmpty) {
      return Image.memory(
        base64Decode(record.base64Image),
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      );
    }
    return const Center(
      child: Text(
        '이미지를 불러올 수 없습니다.',
        style: TextStyle(color: Colors.white),
      ),
    );
  }
}
