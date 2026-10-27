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
      title: '증빙서류 스냅 v14',
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

/// ★ 출장비 전용 5대 구분 (큰 카테고리와는 별도로 구분하여 자동 판별 및 구분별 합산 표기)
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

// =============================================================================
// 백그라운드 Isolate에서 실행되는 초고화질 + 초고속 4점 평탄화 함수
// (모서리를 움직이지 않았을 때는 0.01초 만에 원본 바이트 그대로 통과시켜 지연시간 제거!)
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

  // 모서리를 건드리지 않고 회전/보정도 없으면 0.01초 만에 원본 바이트 즉시 반환!
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

  // 가로 문서든 세로 문서든 가로:세로 실제 비례(scale)를 100% 보존하여 왜곡 원천 차단!
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
  double? _baseAspectRatio; // 이미지 디코딩 완료 전까지 대기하여 가로사진 찌그러짐 완벽 방지
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
        title: const Text('가로/세로 정비율 스캔 (v14)'),
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

  /// 사용자가 직접 입력·등록한 큰 세부 카테고리 (예: 출장명, 병원 병명 등)
  String get subCategory {
    return fields['subCategory']?.trim() ?? '';
  }

  /// ★ 출장비 전용 구분 ('자차', '택시', '기차', '식대', '통행료')
  String get travelDivision {
    final div = fields['travelDivision']?.trim() ?? '';
    return div.isNotEmpty ? div : TravelDivision.meal;
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
        final sender = fields['sender'] ?? '';
        return title.isNotEmpty
            ? title
            : (sender.isNotEmpty ? '$sender 공문' : '대외공문');
      case DocCategory.invoice:
        final prod = fields['productName'] ?? '';
        final sup = fields['supplierName'] ?? '';
        return prod.isNotEmpty
            ? '$prod (${sup.isNotEmpty ? sup : "송장"})'
            : (sup.isNotEmpty ? '$sup 자재송장' : '자재송장');
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
        return '발신: ${fields['sender'] ?? '-'} | 문서번호: ${fields['docNumber'] ?? '-'}\n요약: ${fields['aiSummary'] ?? '-'}';
      case DocCategory.invoice:
        return '공급자: ${fields['supplierName'] ?? '-'} | 규격: ${fields['specName'] ?? '-'} | 수량: ${fields['quantity'] ?? '-'}${fields['unit'] ?? ''} (${fields['weight'] ?? '-'}kg)';
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

  List<DocRecord> _records = [];
  String _selectedCategoryFilter = DocCategory.officialDoc;
  String _selectedSubCategoryFilter = '전체';
  String _selectedTravelDivisionFilter = '전체'; // 출장비 전용 구분 필터 ('전체', '자차', '택시', '기차', '식대', '통행료')
  DocRecord? _selectedRecord;
  bool _isBusy = false;

  // ★ 리스트와 사진 사이의 높이를 자유롭게 조절하는 분할 비율 (0.2 ~ 0.8)
  double _listSplitRatio = 0.48;

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
          (prefs.getDouble(_prefsSplitRatioKey) ?? 0.48).clamp(0.18, 0.82);
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

  /// 대분류 + 사용자 등록 카테고리 필터가 적용된 목록
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

  /// 출장비 탭인 경우 구분('자차', '택시', '기차', '식대', '통행료') 필터까지 적용된 최종 목록
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

  /// ★ 출장비 구분별('자차', '택시', '기차', '식대', '통행료') 합산 금액
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
  // 1단계: 온디바이스 한국어 OCR (오프라인 백업 및 0.3초 즉시 추출)
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

      final fullText = mergedRows.join('\n');

      if (category == DocCategory.medical) {
        return _parseMedicalReceiptText(fullText, mergedRows);
      } else if (category == DocCategory.invoice) {
        return _parseInvoiceText(fullText, mergedRows);
      } else if (category == DocCategory.officialDoc) {
        return _parseOfficialDocText(fullText, mergedRows);
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

  /// ★ [출장비] 5대 구분('자차', '택시', '기차', '식대', '통행료') 자동 판별 및 지도 '실시간 추천' km 정밀 파서
  Map<String, String> _parseTravelReceiptText(
    String fullText,
    List<String> lines,
    List<TextBlock> blocks,
  ) {
    final result = <String, String>{};

    // 날짜 추출
    final dateMatch = RegExp(r'(\d{4})\s*[-./년]\s*(\d{1,2})\s*[-./월]\s*(\d{1,2})')
        .firstMatch(fullText);
    if (dateMatch != null) {
      result['date'] =
          '${dateMatch.group(1)}-${dateMatch.group(2)!.padLeft(2, '0')}-${dateMatch.group(3)!.padLeft(2, '0')}';
    }

    // 1) 지도 화면 여부 판별 ('실시간 추천', '안내시작', '전체경로', '큰길우선', '택시비' 등)
    final bool isMapRoute = RegExp(
      r'(?:실\s*시\s*간\s*추\s*천|안\s*내\s*시\s*작|전\s*체\s*경\s*로|큰\s*길\s*우\s*선|거\s*리\s*우\s*선|최\s*적\s*경\s*로|추천경로)',
    ).hasMatch(fullText);

    if (isMapRoute) {
      result['travelDivision'] = TravelDivision.car;
      double? detectedKm;

      // '실시간 추천' 블록과 X좌표(가로 위치)가 가장 가까운 아래쪽 '00km' 텍스트를 최우선 추출!
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
              // '실시간 추천' 카드(왼쪽 카드) 영역 내에 있는 첫 번째 km 값 선택
              final dx = (l.boundingBox.left - realtimeBox.left).abs();
              if (dx < bestDist) {
                bestDist = dx;
                detectedKm = double.tryParse(kmMatch.group(1)!);
              }
            }
          }
        }
      }

      // 만약 박스 매칭이 안 되었으면 전체 텍스트에서 첫 번째 등장하는 '00km' 추출
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

    // 2) 기차 (코레일, SRT, KTX, 열차, 승차권)
    if (RegExp(r'(?:코레일|KORAIL|SRT|KTX|한국철도|승차권|열차|무궁화|새마을|ITX)',
            caseSensitive: false)
        .hasMatch(fullText)) {
      result['travelDivision'] = TravelDivision.train;
      result['merchantName'] =
          fullText.toUpperCase().contains('SRT') ? 'SRT 승차권' : '코레일(기차)';
    }
    // 3) 택시 (카카오 T, 카카오택시, 개인택시, 법인택시, 택시요금)
    else if (RegExp(r'(?:카카오\s*T|카카오택시|택시|개인택시|법인택시|미터기|호출료)',
            caseSensitive: false)
        .hasMatch(fullText)) {
      result['travelDivision'] = TravelDivision.taxi;
      result['merchantName'] =
          fullText.contains('카카오') ? '카카오택시' : '택시요금';
    }
    // 4) 통행료 (하이패스, 한국도로공사, 톨게이트, 통행료)
    else if (RegExp(r'(?:하이패스|도로공사|통행료|톨게이트| 영업소|고속도로|hi-pass)',
            caseSensitive: false)
        .hasMatch(fullText)) {
      result['travelDivision'] = TravelDivision.toll;
      result['merchantName'] = '하이패스 통행료';
    }
    // 5) 그 외 일반 영수증 → '식대'
    else {
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

    // 영수증 결제 금액 추출
    final amountPatterns = [
      RegExp(r'(?:합\s*계|총\s*액|결\s*제\s*금\s*액|승\s*인\s*금\s*액|요\s*금|운\s*임|금\s*액)[^\d\n]*([1-9]\d{0,2}(?:,\d{3})+|\d{3,7})'),
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

  /// [대외공문] 헤더/푸터 노이즈 제거 및 정밀 파서
  Map<String, String> _parseOfficialDocText(
    String fullText,
    List<String> lines,
  ) {
    final result = <String, String>{};

    // 상단/하단 웹 URL(inhae.go.kr 등), Page.001/001, PDF 파일명 등 노이즈 줄 완벽 제거!
    final cleanLines = lines.where((l) {
      if (RegExp(
        r'\.pdf\b|Page\s*[.\d/]+|http|www\.|\.go\.kr|\.co\.kr|\.or\.kr|파일\s*편집',
        caseSensitive: false,
      ).hasMatch(l)) {
        return false;
      }
      return true;
    }).toList();

    final dateMatch = RegExp(
      r'(?:시\s*행\s*일\s*자|시\s*행\s*일|보\s*낸\s*날\s*짜|일\s*자|시\s*행)?[^\d\n]*(\d{4})\s*[-./년]\s*(\d{1,2})\s*[-./월]\s*(\d{1,2})',
    ).firstMatch(fullText);
    if (dateMatch != null) {
      result['sentDate'] =
          '${dateMatch.group(1)}-${dateMatch.group(2)!.padLeft(2, '0')}-${dateMatch.group(3)!.padLeft(2, '0')}';
    }

    for (final line in cleanLines) {
      final labelMatch = RegExp(
        r'(?:문\s*서\s*번\s*호|공\s*문\s*번\s*호|분\s*류\s*기\s*호|시\s*행)\s*[:：]?\s*([^\n]+)',
      ).firstMatch(line);
      if (labelMatch != null) {
        String rawNum = labelMatch.group(1)!.trim();
        rawNum = rawNum.replaceAll(RegExp(r'\(\s*\d{4}.*$'), '').trim();
        if (rawNum.isNotEmpty) {
          result['docNumber'] = rawNum;
          break;
        }
      }
    }
    if ((result['docNumber'] ?? '').isEmpty) {
      for (final line in cleanLines) {
        if (RegExp(r'\b\d{2,3}-\d{3,4}-\d{4}\b').hasMatch(line)) continue;
        final patternMatch = RegExp(
          r'([가-힣A-Za-z0-9().\-_]+\s*제?\s*\d{2,4}\s*-\s*\d{1,6}\s*호?|[가-힣A-Za-z]{2,12}\s*-\s*\d{1,5}(?:\s*호)?)',
        ).firstMatch(line);
        if (patternMatch != null) {
          final cand = patternMatch.group(1)!.trim();
          if (!RegExp(r'^\d{4}-\d{1,2}-\d{1,2}$').hasMatch(cand)) {
            result['docNumber'] = cand;
            break;
          }
        }
      }
    }

    // 발신처: 번호('1.', '2.', '3.')로 시작하는 본문 줄은 절대 발신처가 될 수 없도록 차단!
    for (final line in cleanLines) {
      if (RegExp(r'^\d+[.)]').hasMatch(line.trim())) continue;
      final senderLabel = RegExp(
        r'(?:발\s*신\s*처|발\s*신\s*기\s*관|발\s*신|보\s*낸\s*사\s*람)\s*[:：]\s*([^\n]+)',
      ).firstMatch(line);
      if (senderLabel != null) {
        result['sender'] = senderLabel.group(1)!.trim();
        break;
      }
    }
    if ((result['sender'] ?? '').isEmpty && cleanLines.isNotEmpty) {
      for (final line in cleanLines.reversed.take(7)) {
        if (RegExp(r'^\d+[.)]').hasMatch(line.trim())) continue;
        if (line.length > 30) continue; // 긴 문장은 본문이므로 제외
        if (line.contains('귀하') ||
            line.contains('수신') ||
            line.contains('붙임') ||
            line.contains('첨부') ||
            line.contains('끝.')) {
          continue;
        }
        if (RegExp(
                r'(?:주식회사|\(주\)|대표이사|현장소장|소장|본부장|장관|시장|구청장|시청|구청|청장|공단|공사|협회|조합|단장|원장)')
            .hasMatch(line)) {
          result['sender'] = line.trim();
          break;
        }
      }
    }

    for (int i = 0; i < cleanLines.length; i++) {
      final line = cleanLines[i];
      final titleMatch = RegExp(
        r'(?:제\s*목|건\s*명|안\s*건)\s*[:：]?\s*(.+)',
      ).firstMatch(line);
      if (titleMatch != null) {
        final t = titleMatch.group(1)!.trim();
        if (t.length >= 2) {
          result['title'] = t;
          break;
        } else if (i + 1 < cleanLines.length) {
          result['title'] = cleanLines[i + 1].trim();
          break;
        }
      }
    }

    final deadlineMatch = RegExp(
      r'(?:회\s*신\s*기\s*한|제\s*출\s*기\s*한|기\s*한|기\s*일|까\s*지)\s*[:：]?\s*([^\n]{4,25}?(?:\d{1,2}\s*[-./월]\s*\d{1,2}\s*일?|\d{4}\s*[-./]\s*\d{1,2}\s*[-./]\s*\d{1,2}))',
    ).firstMatch(fullText);
    if (deadlineMatch != null) {
      result['replyDeadline'] = deadlineMatch.group(1)!.trim();
    }

    // 요약: '2.', '3.' 등 실제 용건 문장만 깔끔하게 추출
    final numberedBody = <String>[];
    for (final line in cleanLines) {
      if (RegExp(
              r'(?:귀\s*하|무궁한|루궁한|발찬|발전을|기원합니다|번창하심을|수\s*신\s*[:：]|수\s*진\s*|참\s*조\s*[:：]|문\s*서\s*번\s*호|붙\s*임|첨\s*부|제\s*목)')
          .hasMatch(line)) {
        continue;
      }
      if (line == result['title'] || line == result['sender']) continue;
      if (line.length >= 6) {
        numberedBody.add(line.replaceAll('끝.', '').trim());
      }
    }

    if (numberedBody.isNotEmpty) {
      String summary = numberedBody.join(' ').replaceAll(RegExp(r'\s+'), ' ');
      if (summary.length > 110) {
        summary = '${summary.substring(0, 110)}...';
      }
      result['aiSummary'] = summary;
    }

    return result;
  }

  Map<String, String> _parseInvoiceText(String fullText, List<String> lines) {
    final result = <String, String>{};

    final dateMatch = RegExp(r'(\d{4})\s*[-./]\s*(\d{2})\s*[-./]\s*(\d{2})')
        .firstMatch(fullText);
    if (dateMatch != null) {
      result['arrivalDate'] =
          '${dateMatch.group(1)}-${dateMatch.group(2)}-${dateMatch.group(3)}';
    }

    final orderMatch = RegExp(
      r'([A-Z]-\d-\d{8}-\d{4,6}|\b\d{10,14}\b)',
    ).firstMatch(fullText);
    if (orderMatch != null) {
      result['orderNumber'] = orderMatch.group(1)!;
    }

    final steelSpecMatch = RegExp(
      r'\b((?:U?SHD|HD|SD|KS\s*D|D\d{2})\s*[0-9A-Za-z\-*xX.\s]{2,20})\b',
    ).firstMatch(fullText);
    if (steelSpecMatch != null) {
      result['specName'] = steelSpecMatch.group(1)!.trim();
    }

    final supplierMatch = RegExp(
      r'([가-힣A-Za-z0-9]+(?:제철|철강|자재|산업|건업|물산|상사|테크|금속|시멘트|레미콘)(?:\(주\)|주식회사)?)',
    ).firstMatch(fullText);
    if (supplierMatch != null) {
      result['supplierName'] = supplierMatch.group(1)!;
    } else if (fullText.toUpperCase().contains('HYUNDAI STEEL')) {
      result['supplierName'] = '현대제철(주)';
    }

    for (final line in lines) {
      if ((result['productName'] ?? '').isEmpty &&
          (line.contains('품명') ||
              line.contains('제품명') ||
              line.contains('이형봉강') ||
              line.contains('철근'))) {
        if (line.contains('이형봉강')) {
          result['productName'] = '이형봉강(철근)';
        } else {
          final cleaned =
              line.replaceAll(RegExp(r'.*(?:품명|제품명|품목)\s*[:：]?'), '').trim();
          if (cleaned.isNotEmpty) result['productName'] = cleaned;
        }
      }
    }

    final weightMatch = RegExp(
      r'\b(\d{1,2}\.\d{3}|\d{1,3},\d{3})\b',
    ).allMatches(fullText);
    if (weightMatch.isNotEmpty) {
      result['weight'] = weightMatch.last.group(1)!;
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
  // ★ 2단계: 초고속 Gemini Vision AI 분석
  // - 전송용 이미지만 메모리에서 경량화하여 업로드 시간을 5초 → 1초로 단축!
  // - 병렬/빠른 타임아웃 적용으로 답답한 대기시간 완전히 해소!
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

    // 보관용 원본 화질은 건드리지 않고, AI 전송용 패킷만 가볍게 만들어 응답 속도 4배 향상!
    final aiBytes = await compute(_compressForAiPayloadIsolate, imageBytes);
    final base64Image = base64Encode(aiBytes);

    String prompt;
    if (category == DocCategory.officialDoc) {
      prompt = '''
이 대외공문 이미지를 읽고 아래 JSON 키만 가진 순수 JSON 객체로 응답해줘:
- sentDate: 문서 시행일 또는 보낸날짜 (YYYY-MM-DD 형식)
- sender: 공문을 보낸 발신기관/회사/지자체명 (문서 상단 헤더 또는 하단 직인 옆 발신명의. 본문 문장을 넣지 말 것)
- docNumber: '시행 OO-123', '문서번호', '제2025-00호' 등 문맥상 공문 번호
- title: 수신자('~귀하')나 파일명('.pdf')을 제외한 실제 공문 제목/건명
- aiSummary: '1. 귀사의 무궁한 발전을 기원합니다'나 하단 주소/페이지 번호는 완전히 빼고, 핵심 용건과 요청사항만 자연스러운 한 문장으로 요약
- replyDeadline: 회신기한/제출기한 (없으면 공란)
''';
    } else if (category == DocCategory.invoice) {
      prompt = '''
이 자재송장/거래명세서 이미지를 읽고 아래 JSON 키만 가진 순수 JSON 객체로 응답해줘:
{
  "arrivalDate": "도착일/출하일/발행일 (YYYY-MM-DD 형식)",
  "orderNumber": "송장번호(예: J-1-20210908-01336) 또는 주문번호",
  "productName": "제품명/품명(예: 이형봉강)",
  "specName": "규격명/강종(예: D16, SD400, KS D 3504 등)",
  "unit": "단위 (예: MT, TON, EA, kg 등)",
  "quantity": "수량 합계 (숫자만, 예: 486)",
  "weight": "중량 합계 (숫자만, 예: 19.996)",
  "supplierName": "공급자상호 (예: 현대제철(주))",
  "amount": "공급가액 또는 합계금액 (없으면 0)"
}''';
    } else if (category == DocCategory.travel) {
      prompt = '''
이 출장비 증빙 이미지를 보고 다음 규칙에 따라 5가지 구분('자차', '택시', '기차', '식대', '통행료') 중 하나로 자동 분류하여 순수 JSON으로 응답해줘:
1) 내비게이션/지도 경로 화면이면: travelDivision을 "자차"로 하고, 화면의 "실시간 추천" 란에 적힌 거리(km) 숫자만 distanceKm에 넣고(예: "25"), totalAmount에는 거리×2×300 계산값(예: 25*2*300 = "15000")을 넣어줘. (주의: 지도 화면에 적힌 예상 택시비는 절대 가져오지 말 것!)
2) 택시 영수증이나 카카오T/카카오택시 증빙이면: travelDivision을 "택시"로 하고 결제금액을 totalAmount에 넣어줘.
3) 코레일(KORAIL), KTX, SRT 등 열차 영수증/승차권이면: travelDivision을 "기차"로 하고 결제금액을 totalAmount에 넣어줘.
4) 하이패스, 한국도로공사, 톨게이트 영수증이면: travelDivision을 "통행료"로 하고 결제금액을 totalAmount에 넣어줘.
5) 그 외 일반 식당/카페/영수증이면: travelDivision을 "식대"로 하고 결제금액을 totalAmount에 넣어줘.

JSON 형식:
{
  "travelDivision": "자차 또는 택시 또는 기차 또는 식대 또는 통행료",
  "distanceKm": "자차일 때 실시간 추천 km 숫자만 (자차가 아니면 0)",
  "totalAmount": "금액 숫자만 (콤마 제외)",
  "merchantName": "가맹점명/노선명/내역 요약",
  "date": "일자 (YYYY-MM-DD, 없으면 공란)"
}''';
    } else {
      prompt = '''
이 병원비/약국 영수증 이미지를 읽고 아래 JSON 키만 가진 순수 JSON 객체로 응답해줘:
{
  "clinicName": "병원 또는 약국 상호명",
  "bizRegNumber": "사업자등록번호 (000-00-00000)",
  "issueDate": "발행일 또는 조제일자 (YYYY-MM-DD)",
  "totalPaid": "총수납금액 또는 본인부담금 합계 (콤마 빼고 숫자만)"
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

    final endpoints = [
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent',
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent',
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent',
    ];

    http.Response? lastResp;
    for (final urlStr in endpoints) {
      try {
        final uri = Uri.parse(urlStr);
        final resp = await http
            .post(
              uri,
              headers: {
                'Content-Type': 'application/json',
                'x-goog-api-key': key,
              },
              body: body,
            )
            .timeout(const Duration(seconds: 7));
        lastResp = resp;
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
          return parsed.map((k, v) => MapEntry(k, v?.toString() ?? ''));
        }
      } catch (_) {}
    }

    throw Exception('AI 응답 오류 (${lastResp?.statusCode ?? "시간초과"})');
  }

  // ===========================================================================
  // 사진 촬영 → 즉시 입력 다이얼로그 오픈 (0초 대기!) & 백그라운드 자동 채우기
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
      final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());

      // 1. 대외공문 컨트롤러
      final sentDateCtrl = TextEditingController(text: todayStr);
      final senderCtrl = TextEditingController();
      final docNumberCtrl = TextEditingController();
      final docTitleCtrl = TextEditingController();
      final aiSummaryCtrl = TextEditingController();
      final replyDeadlineCtrl = TextEditingController();
      final docAmountCtrl = TextEditingController(text: '0');

      // 2. 자재송장 컨트롤러
      final arrivalDateCtrl = TextEditingController(text: todayStr);
      final orderNumberCtrl = TextEditingController();
      final productNameCtrl = TextEditingController();
      final specNameCtrl = TextEditingController();
      final unitCtrl = TextEditingController(text: 'MT');
      final quantityCtrl = TextEditingController();
      final weightCtrl = TextEditingController();
      final supplierNameCtrl = TextEditingController();
      final invoiceAmountCtrl = TextEditingController(text: '0');

      // 3. 출장비 컨트롤러 (5대 구분: 자차 / 택시 / 기차 / 식대 / 통행료)
      String chosenTravelDivision = _selectedTravelDivisionFilter != '전체'
          ? _selectedTravelDivisionFilter
          : TravelDivision.car;
      final travelDistanceKmCtrl = TextEditingController(text: '0');
      final travelAmountCtrl = TextEditingController(text: '0');
      final travelMerchantCtrl = TextEditingController();
      final travelDateCtrl = TextEditingController(text: todayStr);

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
          if (extracted['amount']?.isNotEmpty == true) {
            invoiceAmountCtrl.text = extracted['amount']!;
          }
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
            travelDateCtrl.text = extracted['date']!;
          }
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

      // ★ 화면이 멈춰 있는 느낌을 없애기 위해 입력 다이얼로그를 0.0초 만에 즉시 띄우고,
      // 다이얼로그 안에서 OCR과 AI가 비동기로 동시에 돌아가며 칸을 실시간으로 채웁니다!
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
                  // 1) 0.3초 만에 끝나는 내장 한국어 OCR 결과를 먼저 즉시 반영
                  final ocrMap = await _extractFieldsOfflineOcr(
                    imagePath: savedFile.path,
                    category: chosenCategory,
                  );
                  if (ctx.mounted) {
                    setDialogState(() => applyExtractedMap(ocrMap));
                  }

                  // 2) Gemini API 키가 있으면 경량화된 패킷으로 초고속 문맥 분석하여 덮어쓰기
                  if (_geminiApiKey.trim().isNotEmpty) {
                    final aiMap = await _analyzeDocumentWithAi(
                      category: chosenCategory,
                      imageBytes: flattenedBytes,
                    );
                    if (aiMap != null && ctx.mounted) {
                      setDialogState(() => applyExtractedMap(aiMap));
                    }
                  }
                } catch (e) {
                  _showSnack('$e');
                } finally {
                  if (ctx.mounted) {
                    setDialogState(() => isAiAnalyzing = false);
                  }
                }
              }

              // 다이얼로그가 열리자마자 자동으로 백그라운드 인식 시작
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
                    const Text('증빙서류 입력 (v14)', style: TextStyle(fontSize: 18)),
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
                        // 가로/세로 어떤 사진이든 찌그러짐 없이 원본 비율 그대로 보여주는 미리보기
                        Container(
                          height: 145,
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
                        const SizedBox(height: 12),

                        // 내가 등록한 큰 세부 카테고리 (출장명, 현장명, 병명 등)
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
                                  hintText: '예: 여의도출장, 갑상선, 안전공문 등',
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
                        const SizedBox(height: 10),

                        FilledButton.tonalIcon(
                          onPressed:
                              isAiAnalyzing ? null : triggerOcrAndAiExtract,
                          icon: const Icon(Icons.auto_awesome, size: 18),
                          label: const Text('문자/금액 다시 자동 인식'),
                        ),
                        const Divider(height: 22),

                        // 1. 대외공문 입력 폼
                        if (chosenCategory == DocCategory.officialDoc) ...[
                          _buildField(sentDateCtrl, '보낸날짜', '예: 2026-10-27'),
                          _buildField(
                              senderCtrl, '보낸사람 (발신처)', '예: 김해시장 / 대림건설(주)'),
                          _buildField(
                            docNumberCtrl,
                            '공문번호 (문서번호/시행번호)',
                            '예: 도시관리과-12345',
                          ),
                          _buildField(
                            docTitleCtrl,
                            '제목',
                            '예: 민원 사항 알림 및 조치계획 제출 요청',
                          ),
                          _buildField(
                            aiSummaryCtrl,
                            '주요내용 (핵심 용건 1문장 요약)',
                            '공문 핵심 내용 요약',
                            maxLines: 2,
                          ),
                          _buildField(
                              replyDeadlineCtrl, '회신기한', '예: 2026-11-05'),
                          _buildField(
                            docAmountCtrl,
                            '관련 금액 (원, 있을 경우 합계 반영)',
                            '없으면 0',
                            keyboardType: TextInputType.number,
                          ),
                        ],

                        // 2. 자재송장 입력 폼
                        if (chosenCategory == DocCategory.invoice) ...[
                          _buildField(arrivalDateCtrl, '도착일', '예: 2026-10-27'),
                          _buildField(orderNumberCtrl, '주문번호 / 송장번호',
                              '예: J-1-20210908-01336'),
                          _buildField(
                              productNameCtrl, '제품명', '예: 이형봉강(철근)'),
                          _buildField(
                              specNameCtrl, '규격명', '예: KS D 3504 SD400 D16'),
                          Row(
                            children: [
                              Expanded(
                                child: _buildField(
                                    unitCtrl, '단위', '예: MT, TON, EA'),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _buildField(
                                  quantityCtrl,
                                  '수량',
                                  '예: 486',
                                  keyboardType: TextInputType.number,
                                ),
                              ),
                            ],
                          ),
                          _buildField(
                            weightCtrl,
                            '중량 (kg/MT)',
                            '예: 19.996',
                            keyboardType: TextInputType.number,
                          ),
                          _buildField(
                              supplierNameCtrl, '공급자상호', '예: 현대제철(주)'),
                          _buildField(
                            invoiceAmountCtrl,
                            '송장 금액 (원, 입력 시 카테고리 합계 반영)',
                            '없으면 0',
                            keyboardType: TextInputType.number,
                          ),
                        ],

                        // ★ 3. 출장비 입력 폼 (자차 / 택시 / 기차 / 식대 / 통행료 자동 구분)
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
                          _buildField(travelDateCtrl, '일자', '예: 2026-10-27'),
                        ],

                        // 4. 병원비 입력 폼
                        if (chosenCategory == DocCategory.medical) ...[
                          _buildField(
                              clinicNameCtrl, '상호 (병원/약국명)', '예: 맘온누리약국'),
                          _buildField(
                              bizRegNumberCtrl, '사업자등록번호', '예: 276-63-00432'),
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

      final enteredSubCategory = subCategoryCtrl.text.trim();
      if (enteredSubCategory.isNotEmpty) {
        await _registerUserSubCategory(chosenCategory, enteredSubCategory);
      }

      final Map<String, String> collectedFields = {
        'subCategory': enteredSubCategory,
      };
      if (chosenCategory == DocCategory.officialDoc) {
        collectedFields['sentDate'] = sentDateCtrl.text.trim();
        collectedFields['sender'] = senderCtrl.text.trim();
        collectedFields['docNumber'] = docNumberCtrl.text.trim();
        collectedFields['title'] = docTitleCtrl.text.trim();
        collectedFields['aiSummary'] = aiSummaryCtrl.text.trim();
        collectedFields['replyDeadline'] = replyDeadlineCtrl.text.trim();
        collectedFields['amount'] = docAmountCtrl.text.trim();
      } else if (chosenCategory == DocCategory.invoice) {
        collectedFields['arrivalDate'] = arrivalDateCtrl.text.trim();
        collectedFields['orderNumber'] = orderNumberCtrl.text.trim();
        collectedFields['productName'] = productNameCtrl.text.trim();
        collectedFields['specName'] = specNameCtrl.text.trim();
        collectedFields['unit'] = unitCtrl.text.trim();
        collectedFields['quantity'] = quantityCtrl.text.trim();
        collectedFields['weight'] = weightCtrl.text.trim();
        collectedFields['supplierName'] = supplierNameCtrl.text.trim();
        collectedFields['amount'] = invoiceAmountCtrl.text.trim();
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
        _selectedCategoryFilter = chosenCategory;
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
          '(이미 내보낸 누적 HTML의 기록은 지워지지 않고 계속 쌓여 유지됩니다.)',
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
    _showSnack('앱 목록에서 삭제되었습니다. (누적 HTML 본은 유지됨)');
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
            title: const Text('Gemini AI & 원드라이브 설정 (v14)'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '1. Gemini AI 키 등록 (AQ... 및 AIza... 완벽 지원)',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13.5,
                      color: Color(0xFF1E3A8A),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Google AI Studio에서 발급받은 AQ... (또는 AIza...)로 시작하는 전체 키를 복사해서 넣어주세요.',
                    style: TextStyle(fontSize: 12, color: Colors.black87),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: geminiKeyCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Gemini API Key (AQ... 또는 AIza...)',
                      hintText: 'AQ.Ab8RN6Kn9w6efyyhTymTa...',
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
                            labelText: '로컬 백업 폴더 경로',
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
  // HTML 내보내기 (현재 필터링된 카테고리만 + 드래그 가능한 상하 크기 조절 바 포함!)
  // ===========================================================================
  Future<void> _exportAndUploadHtmlToOneDrive() async {
    setState(() => _isBusy = true);
    try {
      final String filterScopeName = _selectedSubCategoryFilter != '전체'
          ? '${_selectedCategoryFilter}_$_selectedSubCategoryFilter'
          : _selectedCategoryFilter;
      final String targetHtmlFileName = '증빙서류_$filterScopeName.html';

      List<DocRecord> existingHtmlRecords = [];
      Set<String> deletedInHtmlIds = {};

      final appDir = await getApplicationDocumentsDirectory();
      final internalMasterFile = File(p.join(appDir.path, targetHtmlFileName));
      if (await internalMasterFile.exists()) {
        final backupHtml = await internalMasterFile.readAsString();
        existingHtmlRecords.addAll(_parseRecordsFromHtml(backupHtml));
        deletedInHtmlIds.addAll(_parseDeletedIdsFromHtml(backupHtml));
      }

      File? targetLocalFile;
      if (_oneDriveLocalDir.isNotEmpty) {
        final dir = Directory(_oneDriveLocalDir);
        if (await dir.exists()) {
          targetLocalFile = File(p.join(dir.path, targetHtmlFileName));
          if (await targetLocalFile.exists()) {
            final localHtml = await targetLocalFile.readAsString();
            existingHtmlRecords.addAll(_parseRecordsFromHtml(localHtml));
            deletedInHtmlIds.addAll(_parseDeletedIdsFromHtml(localHtml));
          }
        }
      }

      bool matchesCurrentFilter(DocRecord r) {
        if (_selectedCategoryFilter != DocCategory.all &&
            r.category != _selectedCategoryFilter) {
          return false;
        }
        if (_selectedSubCategoryFilter != '전체') {
          if (_selectedSubCategoryFilter == '미지정') {
            return r.subCategory.isEmpty;
          }
          return r.subCategory == _selectedSubCategoryFilter;
        }
        return true;
      }

      final Map<String, DocRecord> mergedMap = {};
      for (final rec in existingHtmlRecords) {
        if (!deletedInHtmlIds.contains(rec.id) && matchesCurrentFilter(rec)) {
          mergedMap[rec.id] = rec;
        }
      }
      for (final rec in _filteredRecords) {
        if (!deletedInHtmlIds.contains(rec.id) && matchesCurrentFilter(rec)) {
          mergedMap[rec.id] = rec;
        }
      }

      final mergedList = mergedMap.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      if (mergedList.isEmpty) {
        _showSnack('현재 선택된 [$filterScopeName] 카테고리에 내보낼 항목이 없습니다.');
        return;
      }

      final updatedHtml = _buildTopBottomHtmlDocument(
        records: mergedList,
        deletedIds: deletedInHtmlIds,
        scopeTitle: filterScopeName,
        fileName: targetHtmlFileName,
      );

      await internalMasterFile.writeAsString(updatedHtml, flush: true);
      if (targetLocalFile != null) {
        try {
          await targetLocalFile.writeAsString(updatedHtml, flush: true);
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
          body: utf8.encode(updatedHtml),
        );
        if (putResp.statusCode == 200 || putResp.statusCode == 201) {
          uploadedViaApi = true;
        }
      }

      if (uploadedViaApi) {
        _showSnack(
          '원드라이브($remoteFilePath)에 [$filterScopeName] HTML 업로드 완료! (${mergedList.length}건)',
        );
      } else {
        await Share.shareXFiles(
          [XFile(internalMasterFile.path, mimeType: 'text/html')],
          subject: targetHtmlFileName,
          text: '[$filterScopeName] 누적 HTML (${mergedList.length}건) - 원드라이브 아이콘을 눌러 업로드하세요.',
        );
      }
    } catch (e) {
      _showSnack('HTML 내보내기 중 오류: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _importExistingHtmlFromOneDrive() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['html', 'htm'],
      );
      if (picked == null || picked.files.single.path == null) return;

      final file = File(picked.files.single.path!);
      final htmlContent = await file.readAsString();
      final importedRecords = _parseRecordsFromHtml(htmlContent);
      final importedDeletedIds = _parseDeletedIdsFromHtml(htmlContent);

      final appDir = await getApplicationDocumentsDirectory();
      final String filterScopeName = _selectedSubCategoryFilter != '전체'
          ? '${_selectedCategoryFilter}_$_selectedSubCategoryFilter'
          : _selectedCategoryFilter;
      final internalMasterFile =
          File(p.join(appDir.path, '증빙서류_$filterScopeName.html'));
      await internalMasterFile.writeAsString(htmlContent, flush: true);

      for (final r in importedRecords) {
        if (r.subCategory.isNotEmpty) {
          await _registerUserSubCategory(r.category, r.subCategory);
        }
      }

      _showSnack(
        '기존 HTML 파일(총 ${importedRecords.length}건, 삭제이력 ${importedDeletedIds.length}건)을 불러왔습니다.',
      );
    } catch (e) {
      _showSnack('HTML 불러오기 실패: $e');
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

  String _buildTopBottomHtmlDocument({
    required List<DocRecord> records,
    required Set<String> deletedIds,
    required String scopeTitle,
    required String fileName,
  }) {
    final recordsJson = jsonEncode(records.map((r) => r.toJson()).toList());
    final deletedIdsJson = jsonEncode(deletedIds.toList());

    return '''<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>증빙서류 아카이브 - $scopeTitle</title>
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
      flex-wrap: wrap;
      gap: 8px;
    }
    header h1 { font-size: 16px; font-weight: 700; }
    .btn-save {
      background: #10b981;
      color: white;
      font-weight: 600;
      padding: 6px 12px;
      border-radius: 6px;
      border: none;
      font-size: 12.5px;
      cursor: pointer;
    }
    #totals-bar, #division-bar {
      background: #ffffff;
      border-bottom: 1px solid #cbd5e1;
      padding: 6px 12px;
      display: flex;
      overflow-x: auto;
      white-space: nowrap;
      gap: 8px;
      align-items: center;
      font-size: 12px;
    }
    #division-bar { background: #fffbeb; }
    .total-chip {
      background: #f8fafc;
      border: 1px solid #cbd5e1;
      padding: 4px 10px;
      border-radius: 999px;
      cursor: pointer;
      display: inline-block;
    }
    .total-chip.active {
      background: #dbeafe;
      border-color: #2563eb;
      color: #1e3a8a;
      font-weight: 700;
    }
    .total-chip.grand {
      background: #1e3a8a;
      color: #ffffff;
      border-color: #1e3a8a;
      font-weight: 700;
    }
    /* 상단 리스트 영역 */
    #list-pane {
      height: 44vh;
      min-height: 15vh;
      max-height: 75vh;
      overflow-y: auto;
      background: #ffffff;
      padding: 8px 10px;
    }
    /* 리스트와 사진 사이 크기 조절 드래그 핸들 바 */
    #resizer-bar {
      height: 18px;
      background: #cbd5e1;
      cursor: ns-resize;
      display: flex;
      align-items: center;
      justify-content: center;
      user-select: none;
      touch-action: none;
    }
    #resizer-handle {
      width: 48px;
      height: 5px;
      background: #475569;
      border-radius: 999px;
    }
    .record-card {
      padding: 10px 12px;
      border-bottom: 1px solid #e2e8f0;
      cursor: pointer;
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 10px;
      border-radius: 6px;
    }
    .record-card:hover { background: #f8fafc; }
    .record-card.active {
      background: #dbeafe;
      border-left: 4px solid #1e3a8a;
    }
    .card-left { flex: 1; min-width: 0; }
    .card-title-row {
      display: flex;
      align-items: center;
      gap: 6px;
      flex-wrap: wrap;
      margin-bottom: 4px;
    }
    .badge-major {
      padding: 2px 6px;
      border-radius: 4px;
      font-size: 11px;
      font-weight: 700;
      background: #e2e8f0;
      color: #334155;
    }
    .badge-sub {
      padding: 2px 8px;
      border-radius: 999px;
      font-size: 11px;
      font-weight: 700;
      background: #e0e7ff;
      color: #1e40af;
    }
    .badge-div {
      padding: 2px 8px;
      border-radius: 999px;
      font-size: 11px;
      font-weight: 700;
      background: #fef3c7;
      color: #92400e;
    }
    .card-title {
      font-size: 14px;
      font-weight: 700;
      color: #0f172a;
    }
    .card-details {
      font-size: 12.5px;
      color: #475569;
      line-height: 1.45;
      word-break: keep-all;
    }
    .card-right {
      display: flex;
      flex-direction: column;
      align-items: flex-end;
      gap: 6px;
      flex-shrink: 0;
    }
    .card-amount {
      font-size: 13.5px;
      font-weight: 700;
      color: #1e3a8a;
    }
    .btn-del {
      background: #ef4444;
      color: white;
      border: none;
      padding: 4px 9px;
      border-radius: 4px;
      cursor: pointer;
      font-size: 11.5px;
    }
    #preview-pane {
      flex: 1;
      background: #0f172a;
      color: #f8fafc;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: flex-start;
      padding: 10px 12px;
      overflow-y: auto;
    }
    #preview-info {
      margin-bottom: 8px;
      font-size: 12.5px;
      line-height: 1.45;
      background: #1e293b;
      padding: 8px 12px;
      border-radius: 6px;
      width: 100%;
    }
    #preview-img {
      max-width: 100%;
      max-height: 100%;
      object-fit: contain;
      border-radius: 6px;
      box-shadow: 0 4px 16px rgba(0,0,0,0.5);
    }
  </style>
</head>
<body>
  <header>
    <h1>[$scopeTitle] 증빙서류 (<span id="count-label">0</span>건)</h1>
    <button class="btn-save" onclick="downloadUpdatedHtml()">삭제 반영된 HTML 저장</button>
  </header>

  <div id="totals-bar"></div>
  <div id="division-bar" style="display:none;"></div>

  <!-- 상단 리스트 영역 -->
  <div id="list-pane"></div>

  <!-- 리스트와 사진 크기 조절 바 -->
  <div id="resizer-bar" title="위아래로 드래그하여 크기 조절">
    <div id="resizer-handle"></div>
  </div>

  <!-- 하단 증빙사진 영역 -->
  <div id="preview-pane">
    <div id="preview-info">위 목록에서 항목을 터치하면 아래에 고화질 증빙사진이 표시됩니다.</div>
    <img id="preview-img" style="display:none;" alt="증빙서류 사진" />
  </div>

  <script>
    let archiveRecords = /*ARCHIVE_DATA_START*/ $recordsJson /*ARCHIVE_DATA_END*/;
    let deletedIds = /*DELETED_IDS_START*/ $deletedIdsJson /*DELETED_IDS_END*/;
    let selectedSubCat = '전체';
    let selectedTravelDiv = '전체';
    let selectedId = archiveRecords.length > 0 ? archiveRecords[0].id : null;

    // 상하 크기 조절 드래그 이벤트
    const resizer = document.getElementById('resizer-bar');
    const listPane = document.getElementById('list-pane');
    let isResizing = false;
    resizer.addEventListener('pointerdown', (e) => {
      isResizing = true;
      resizer.setPointerCapture(e.pointerId);
    });
    resizer.addEventListener('pointermove', (e) => {
      if (!isResizing) return;
      const rect = listPane.getBoundingClientRect();
      const newH = Math.max(100, Math.min(window.innerHeight - 160, e.clientY - rect.top));
      listPane.style.height = newH + 'px';
    });
    resizer.addEventListener('pointerup', () => { isResizing = false; });

    function getSubCat(item) {
      const f = item.fields || {};
      return (f.subCategory && f.subCategory.trim() !== '') ? f.subCategory.trim() : '';
    }

    function getTravelDiv(item) {
      const f = item.fields || {};
      return (f.travelDivision && f.travelDivision.trim() !== '') ? f.travelDivision.trim() : '식대';
    }

    function getAmount(item) {
      const f = item.fields || {};
      let raw = '0';
      if (item.category === '출장비') raw = f.totalAmount || '0';
      else if (item.category === '병원비') raw = f.totalPaid || '0';
      else raw = f.amount || '0';
      const num = parseInt(String(raw).replace(/[^0-9]/g, ''), 10);
      return isNaN(num) ? 0 : num;
    }

    function formatFieldsSummary(item) {
      const f = item.fields || {};
      if (item.category === '대외공문') {
        return `보낸날짜: \${escapeHtml(f.sentDate || '-')} | 발신: \${escapeHtml(f.sender || '-')} | 공문번호: \${escapeHtml(f.docNumber || '-')} | 회신기한: \${escapeHtml(f.replyDeadline || '-')}<br/><b>요약:</b> \${escapeHtml(f.aiSummary || '-')}`;
      } else if (item.category === '자재송장') {
        return `도착일: \${escapeHtml(f.arrivalDate || '-')} | 송장번호: \${escapeHtml(f.orderNumber || '-')} | 품명/규격: \${escapeHtml(f.productName || '-')} (\${escapeHtml(f.specName || '-')}) | 수량/중량: \${escapeHtml(f.quantity || '-')}\${escapeHtml(f.unit || '')} / \${escapeHtml(f.weight || '-')} | 공급자: \${escapeHtml(f.supplierName || '-')}`;
      } else if (item.category === '출장비') {
        const div = getTravelDiv(item);
        if (div === '자차') {
          return `구분: <b>자차</b> | 실시간추천 \${escapeHtml(f.distanceKm || '0')}km × 2 × 300원 = \${Number(f.totalAmount || 0).toLocaleString()}원`;
        }
        return `구분: <b>\${escapeHtml(div)}</b> | 내역: \${escapeHtml(f.merchantName || '-')} | 일자: \${escapeHtml(f.date || '-')}`;
      } else if (item.category === '병원비') {
        return `상호: \${escapeHtml(f.clinicName || '-')} | 사업자번호: \${escapeHtml(f.bizRegNumber || '-')} | 발행일: \${escapeHtml(f.issueDate || '-')}`;
      }
      return '';
    }

    function getTitle(item) {
      const f = item.fields || {};
      if (item.category === '대외공문') return f.title || '대외공문';
      if (item.category === '자재송장') return (f.productName || '자재송장') + (f.supplierName ? ' (' + f.supplierName + ')' : '');
      if (item.category === '출장비') {
        const div = getTravelDiv(item);
        if (div === '자차') return `[자차] \${f.distanceKm || '0'}km × 2 × 300원`;
        return `[\${div}] \${f.merchantName || div}`;
      }
      if (item.category === '병원비') return f.clinicName || '병원비';
      return item.category;
    }

    function renderTotals() {
      const grandSum = archiveRecords.reduce((acc, r) => acc + getAmount(r), 0);
      const subMap = {};
      archiveRecords.forEach(r => {
        const sc = getSubCat(r);
        if (!sc) return;
        if (!subMap[sc]) subMap[sc] = { count: 0, sum: 0 };
        subMap[sc].count += 1;
        subMap[sc].sum += getAmount(r);
      });

      let html = `<div class="total-chip \${selectedSubCat === '전체' ? 'grand' : ''}" onclick="selectedSubCat='전체'; renderList();">전체 합계 (\${archiveRecords.length}건): \${grandSum.toLocaleString()}원</div>`;
      Object.keys(subMap).forEach(sc => {
        const info = subMap[sc];
        const activeCls = selectedSubCat === sc ? 'active' : '';
        html += `<div class="total-chip \${activeCls}" onclick="selectedSubCat='\${escapeHtml(sc)}'; renderList();"><b>\${escapeHtml(sc)}</b> (\${info.count}건): \${info.sum.toLocaleString()}원</div>`;
      });
      document.getElementById('totals-bar').innerHTML = html;

      // 출장비 항목이 있으면 자차/택시/기차/식대/통행료 구분별 합산 표시
      const subFiltered = archiveRecords.filter(r => selectedSubCat === '전체' || getSubCat(r) === selectedSubCat);
      const travelItems = subFiltered.filter(r => r.category === '출장비');
      const divBar = document.getElementById('division-bar');
      if (travelItems.length > 0) {
        divBar.style.display = 'flex';
        const divs = ['전체', '자차', '택시', '기차', '식대', '통행료'];
        let dHtml = '';
        divs.forEach(d => {
          const list = d === '전체' ? travelItems : travelItems.filter(r => getTravelDiv(r) === d);
          const sum = list.reduce((acc, r) => acc + getAmount(r), 0);
          const cls = selectedTravelDiv === d ? 'active' : '';
          dHtml += `<div class="total-chip \${cls}" onclick="selectedTravelDiv='\${d}'; renderList();"><b>\${d}</b> (\${list.length}건 · \${sum.toLocaleString()}원)</div>`;
        });
        divBar.innerHTML = dHtml;
      } else {
        divBar.style.display = 'none';
      }
    }

    function renderList() {
      renderTotals();
      let filtered = archiveRecords.filter(r => selectedSubCat === '전체' || getSubCat(r) === selectedSubCat);
      if (selectedTravelDiv !== '전체') {
        filtered = filtered.filter(r => r.category !== '출장비' || getTravelDiv(r) === selectedTravelDiv);
      }
      document.getElementById('count-label').textContent = filtered.length;

      listPane.innerHTML = '';

      filtered.forEach(item => {
        const div = document.createElement('div');
        div.className = 'record-card' + (item.id === selectedId ? ' active' : '');
        div.onclick = () => { selectedId = item.id; renderList(); };
        const amt = getAmount(item);
        const sc = getSubCat(item);
        const tDiv = item.category === '출장비' ? getTravelDiv(item) : '';

        div.innerHTML = `
          <div class="card-left">
            <div class="card-title-row">
              <span class="badge-major">\${escapeHtml(item.category)}</span>
              \${sc ? '<span class="badge-sub">' + escapeHtml(sc) + '</span>' : ''}
              \${tDiv ? '<span class="badge-div">' + escapeHtml(tDiv) + '</span>' : ''}
              <span class="card-title">\${escapeHtml(getTitle(item))}</span>
            </div>
            <div class="card-details">\${formatFieldsSummary(item)}</div>
          </div>
          <div class="card-right">
            <div class="card-amount">\${amt > 0 ? amt.toLocaleString() + '원' : ''}</div>
            <button class="btn-del" onclick="deleteRecord(event, '\${item.id}')">삭제</button>
          </div>
        `;
        listPane.appendChild(div);
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

      const amt = getAmount(item);
      const sc = getSubCat(item);
      const catHeader = sc ? `\${escapeHtml(item.category)} &gt; \${escapeHtml(sc)}` : escapeHtml(item.category);
      infoEl.innerHTML = `<div><b>[\${catHeader}] \${escapeHtml(getTitle(item))}</b> \${amt > 0 ? '(' + amt.toLocaleString() + '원)' : ''}</div><div style="margin-top:3px;">\${formatFieldsSummary(item)}</div>`;
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
      a.download = '$fileName';
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
          MapEntry('카테고리', subLabel),
          MapEntry('보낸날짜', f['sentDate'] ?? '-'),
          MapEntry('보낸사람', f['sender'] ?? '-'),
          MapEntry('공문번호', f['docNumber'] ?? '-'),
          MapEntry('제목', f['title'] ?? '-'),
          MapEntry('회신기한', f['replyDeadline'] ?? '-'),
          MapEntry('주요내용(1문장 요약)', f['aiSummary'] ?? '-'),
        ];
      case DocCategory.invoice:
        return [
          MapEntry('카테고리', subLabel),
          MapEntry('도착일', f['arrivalDate'] ?? '-'),
          MapEntry('주문/송장번호', f['orderNumber'] ?? '-'),
          MapEntry('제품명', f['productName'] ?? '-'),
          MapEntry('규격명', f['specName'] ?? '-'),
          MapEntry('단위', f['unit'] ?? '-'),
          MapEntry('수량', f['quantity'] ?? '-'),
          MapEntry('중량', f['weight'] ?? '-'),
          MapEntry('공급자상호', f['supplierName'] ?? '-'),
        ];
      case DocCategory.travel:
        final div = rec.travelDivision;
        if (div == TravelDivision.car) {
          final km = f['distanceKm'] ?? '0';
          return [
            MapEntry('카테고리', subLabel),
            MapEntry('구분', '자차'),
            MapEntry('산출내역', '${km}km × 2 × 300원 = ${DocRecord._formatCurrency(f['totalAmount'])}원'),
            MapEntry('일자', f['date'] ?? '-'),
          ];
        }
        return [
          MapEntry('카테고리', subLabel),
          MapEntry('구분', div),
          MapEntry('내역/상호', f['merchantName'] ?? '-'),
          MapEntry('금액', '${DocRecord._formatCurrency(f['totalAmount'])}원'),
          MapEntry('일자', f['date'] ?? '-'),
        ];
      case DocCategory.medical:
        return [
          MapEntry('카테고리', subLabel),
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
    final subCategories = _userRegisteredSubCategoriesForCurrentTab;
    final majorTotalSum = _sumByMajorCategory(_selectedCategoryFilter);
    final currentSubTotalSum = _sumBySubCategory(_selectedSubCategoryFilter);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
        title: const Text('증빙서류 스냅 v14'),
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
          IconButton(
            tooltip: '기존 HTML 파일 불러오기',
            icon: const Icon(Icons.folder_open, size: 20),
            onPressed: _isBusy ? null : _importExistingHtmlFromOneDrive,
          ),
          TextButton.icon(
            onPressed: _isBusy ? null : _exportAndUploadHtmlToOneDrive,
            icon: const Icon(Icons.cloud_upload, color: Colors.white, size: 18),
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

                    // ★ 출장비 탭 전용: '자차', '택시', '기차', '식대', '통행료' 각 구분별 합산 금액 표시 바!
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

              // ★ 3) 리스트 영역 + 드래그로 크기 조절하는 슬라이더 바 + 사진 영역
              Expanded(
                child: LayoutBuilder(
                  builder: (ctx, constraints) {
                    final totalH = constraints.maxHeight;
                    const double dividerBarHeight = 24.0;
                    final double usableH =
                        math.max(100.0, totalH - dividerBarHeight);
                    final double listH =
                        (usableH * _listSplitRatio).clamp(60.0, usableH - 60.0);
                    final double photoH = usableH - listH;

                    return Column(
                      children: [
                        // 상단: 문서 목록 리스트
                        SizedBox(
                          height: listH,
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
                                  separatorBuilder: (_, __) =>
                                      const Divider(height: 1),
                                  itemBuilder: (ctx, idx) {
                                    final rec = items[idx];
                                    final isSelected =
                                        _selectedRecord?.id == rec.id;
                                    final mySubOptions =
                                        _userSubCategoriesMap[rec.category] ??
                                            <String>[];
                                    final badgeText = rec.subCategory.isNotEmpty
                                        ? rec.subCategory
                                        : '카테고리 지정';

                                    return ListTile(
                                      dense: true,
                                      selected: isSelected,
                                      selectedTileColor: Colors.blue.shade50,
                                      leading: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          // 1) 큰 세부 카테고리 선택 배지
                                          PopupMenuButton<String>(
                                            tooltip: '내 카테고리 선택 또는 신규 등록',
                                            onSelected: (newSub) =>
                                                _changeRecordSubCategory(
                                                    rec, newSub),
                                            itemBuilder: (_) => [
                                              ...mySubOptions.map(
                                                (sc) => PopupMenuItem(
                                                  value: sc,
                                                  child: Text(sc),
                                                ),
                                              ),
                                              if (mySubOptions.isNotEmpty)
                                                const PopupMenuDivider(),
                                              const PopupMenuItem(
                                                value: '__ADD_NEW__',
                                                child: Row(
                                                  children: [
                                                    Icon(Icons.add,
                                                        size: 16,
                                                        color:
                                                            Colors.blueAccent),
                                                    SizedBox(width: 6),
                                                    Text(
                                                      '새 카테고리 등록...',
                                                      style: TextStyle(
                                                        color:
                                                            Colors.blueAccent,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 7,
                                                vertical: 5,
                                              ),
                                              decoration: BoxDecoration(
                                                color: rec
                                                        .subCategory.isNotEmpty
                                                    ? Colors.indigo.shade100
                                                    : Colors.grey.shade200,
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(
                                                    badgeText,
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color: rec.subCategory
                                                              .isNotEmpty
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
                                          // 2) 출장비인 경우 별도의 구분('자차', '택시', '기차', '식대', '통행료') 배지 표시!
                                          if (rec.category ==
                                              DocCategory.travel) ...[
                                            const SizedBox(width: 4),
                                            PopupMenuButton<String>(
                                              tooltip: '출장비 구분 변경',
                                              onSelected: (newDiv) =>
                                                  _changeRecordTravelDivision(
                                                      rec, newDiv),
                                              itemBuilder: (_) =>
                                                  TravelDivision.list
                                                      .map(
                                                        (d) => PopupMenuItem(
                                                          value: d,
                                                          child:
                                                              Text('[$d]로 변경'),
                                                        ),
                                                      )
                                                      .toList(),
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 7,
                                                  vertical: 5,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: Colors.amber.shade200,
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                ),
                                                child: Text(
                                                  rec.travelDivision,
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.bold,
                                                    color:
                                                        Colors.brown.shade900,
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
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600),
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
                                        onPressed: () =>
                                            _deleteLocalRecord(rec),
                                      ),
                                      onTap: () => setState(
                                          () => _selectedRecord = rec),
                                    );
                                  },
                                ),
                        ),

                        // ★ 중단: 위아래로 드래그하여 리스트와 사진 크기를 조절하는 슬라이더 바!
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

                        // 하단: 선택한 항목의 세부 내용 및 초고화질 증빙사진
                        SizedBox(
                          height: photoH,
                          child: Container(
                            width: double.infinity,
                            color: const Color(0xFF0F172A),
                            child: _selectedRecord == null
                                ? const Center(
                                    child: Text(
                                      '위 목록에서 항목을 선택하면\n문서별 세부 항목과 증빙사진이 여기에 표시됩니다.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: Colors.white70),
                                    ),
                                  )
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 6,
                                        ),
                                        color: Colors.black54,
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '[${_selectedRecord!.category}${_selectedRecord!.subCategory.isNotEmpty ? " > ${_selectedRecord!.subCategory}" : ""}] ${_selectedRecord!.displayTitle}',
                                              style: const TextStyle(
                                                color: Colors.amberAccent,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 13,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 3),
                                            Wrap(
                                              spacing: 10,
                                              runSpacing: 2,
                                              children: _getCategoryFieldPairs(
                                                      _selectedRecord!)
                                                  .map(
                                                    (e) => Text(
                                                      '${e.key}: ${e.value}',
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 11,
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
                                          maxScale: 5.0,
                                          child: Center(
                                            child: _buildRecordImage(
                                                _selectedRecord!),
                                          ),
                                        ),
                                      ),
                                    ],
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
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      );
    }
    if (record.base64Image.isNotEmpty) {
      return Image.memory(
        base64Decode(record.base64Image),
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      );
    }
    return const Text(
      '이미지를 불러올 수 없습니다.',
      style: TextStyle(color: Colors.white),
    );
  }
}
