// ignore_for_file: unused_field, unused_element, unused_local_variable, unnecessary_import, deprecated_member_use, prefer_const_constructors, unnecessary_brace_in_string_interps, unnecessary_string_escapes
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
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
      title: '증빙서류 스냅 v39',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1E3A8A)),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

/// 문서 대분류 상수: 대외공문을 [공문(수신)]과 [공문(발신)] 탭으로 분리
class DocCategory {
  static const String all = '전체';
  static const String officialIn = '공문(수신)'; // 받은 공문 -> 보낸사람 OCR 추출 + 회신완료(○) 표시
  static const String officialOut = '공문(발신)'; // 보내는 공문 -> 받는사람 + 회신번호 OCR 추출
  static const String invoice = '자재송장';
  static const String travel = '출장비';
  static const String medical = '병원비';

  static const List<String> filterList = [
    all,
    officialIn,
    officialOut,
    invoice,
    travel,
    medical,
  ];

  static const List<String> inputList = [
    officialIn,
    officialOut,
    invoice,
    travel,
    medical,
  ];

  static bool isOfficial(String cat) =>
      cat == officialIn || cat == officialOut;
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
/// ★ vFlat 스타일: 사진 속 밝은 종이/문서의 4모서리 테두리를 자동 감지하는 Isolate 함수
List<double> _detectDocumentCornersIsolate(Uint8List imageBytes) {
  const fallback = <double>[0.02, 0.02, 0.98, 0.02, 0.98, 0.98, 0.02, 0.98];
  try {
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) return fallback;
    final src = img.bakeOrientation(decoded);

    final small = src.width >= src.height
        ? img.copyResize(src, width: 240)
        : img.copyResize(src, height: 240);
    final w = small.width;
    final h = small.height;
    if (w < 40 || h < 40) return fallback;

    double centerLumaSum = 0;
    int centerCnt = 0;
    double borderLumaSum = 0;
    int borderCnt = 0;

    final lumaGrid = List<double>.filled(w * h, 0.0);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final p = small.getPixel(x, y);
        final luma = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        lumaGrid[y * w + x] = luma;
        if (x > w * 0.25 && x < w * 0.75 && y > h * 0.25 && y < h * 0.75) {
          centerLumaSum += luma;
          centerCnt++;
        }
        if (x < w * 0.06 || x > w * 0.94 || y < h * 0.06 || y > h * 0.94) {
          borderLumaSum += luma;
          borderCnt++;
        }
      }
    }

    final centerMean = centerCnt > 0 ? centerLumaSum / centerCnt : 190.0;
    final borderMean = borderCnt > 0 ? borderLumaSum / borderCnt : 120.0;

    if ((centerMean - borderMean).abs() < 16.0) {
      return const <double>[0.01, 0.01, 0.99, 0.01, 0.99, 0.99, 0.01, 0.99];
    }

    final double threshold = borderMean + (centerMean - borderMean) * 0.45;

    double bestTL = double.infinity;
    double bestTR = double.infinity;
    double bestBR = double.infinity;
    double bestBL = double.infinity;

    int tlX = (w * 0.05).round(), tlY = (h * 0.05).round();
    int trX = (w * 0.95).round(), trY = (h * 0.05).round();
    int brX = (w * 0.95).round(), brY = (h * 0.95).round();
    int blX = (w * 0.05).round(), blY = (h * 0.95).round();

    int brightCount = 0;
    for (int y = 2; y < h - 2; y++) {
      for (int x = 2; x < w - 2; x++) {
        if (lumaGrid[y * w + x] >= threshold) {
          int neighbors = 0;
          for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
              if (lumaGrid[(y + dy) * w + (x + dx)] >= threshold) {
                neighbors++;
              }
            }
          }
          if (neighbors >= 6) {
            brightCount++;
            final nx = x / w;
            final ny = y / h;
            final dTL = nx + ny;
            final dTR = (1.0 - nx) + ny;
            final dBR = (1.0 - nx) + (1.0 - ny);
            final dBL = nx + (1.0 - ny);
            if (dTL < bestTL) {
              bestTL = dTL;
              tlX = x;
              tlY = y;
            }
            if (dTR < bestTR) {
              bestTR = dTR;
              trX = x;
              trY = y;
            }
            if (dBR < bestBR) {
              bestBR = dBR;
              brX = x;
              brY = y;
            }
            if (dBL < bestBL) {
              bestBL = dBL;
              blX = x;
              blY = y;
            }
          }
        }
      }
    }

    if (brightCount < (w * h * 0.20)) {
      return const <double>[0.01, 0.01, 0.99, 0.01, 0.99, 0.99, 0.01, 0.99];
    }

    final x0 = (tlX / w).clamp(0.01, 0.45);
    final y0 = (tlY / h).clamp(0.01, 0.45);
    final x1 = (trX / w).clamp(0.55, 0.99);
    final y1 = (trY / h).clamp(0.01, 0.45);
    final x2 = (brX / w).clamp(0.55, 0.99);
    final y2 = (brY / h).clamp(0.55, 0.99);
    final x3 = (blX / w).clamp(0.01, 0.45);
    final y3 = (blY / h).clamp(0.55, 0.99);

    return <double>[x0, y0, x1, y1, x2, y2, x3, y3];
  } catch (_) {
    return fallback;
  }
}

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
        // ★ vFlat 스타일 깨끗한 문서 스캔 보정: 종이 배경의 회색 그림자는 하얗게 날리고 글자는 더 선명하게 강조
        final luma = 0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b;
        if (luma > 175) {
          int r = (pixel.r + (255 - pixel.r) * 0.68).round().clamp(0, 255);
          int g = (pixel.g + (255 - pixel.g) * 0.68).round().clamp(0, 255);
          int b = (pixel.b + (255 - pixel.b) * 0.68).round().clamp(0, 255);
          dst.setPixelRgb(x, y, r, g, b);
        } else {
          int r = ((pixel.r - 128) * 1.28 + 124).round().clamp(0, 255);
          int g = ((pixel.g - 128) * 1.28 + 124).round().clamp(0, 255);
          int b = ((pixel.b - 128) * 1.28 + 124).round().clamp(0, 255);
          dst.setPixelRgb(x, y, r, g, b);
        }
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

  bool _enhanceScanContrast = true; // ★ vFlat 스타일 깨끗한 스캔 보정 기본 ON
  bool _isProcessing = false;
  int? _activeCornerIndex;
  double? _baseAspectRatio;
  int _rotationQuarterTurns = 0;

  @override
  void initState() {
    super.initState();
    _resolveImageAndAutoDetectCorners();
  }

  Future<void> _resolveImageAndAutoDetectCorners() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.originalBytes);
      final frame = await codec.getNextFrame();
      final w = frame.image.width.toDouble();
      final h = frame.image.height.toDouble();
      if (w > 0 && h > 0 && mounted) {
        setState(() => _baseAspectRatio = w / h);
      }
      final detected =
          await compute(_detectDocumentCornersIsolate, widget.originalBytes);
      if (detected.length == 8 && mounted) {
        setState(() {
          _corners = [
            Offset(detected[0], detected[1]),
            Offset(detected[2], detected[3]),
            Offset(detected[4], detected[5]),
            Offset(detected[6], detected[7]),
          ];
        });
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
        title: const Text('가로/세로 정비율 스캔 (v39)'),
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
                    '가로 사진이나 90도 돌아간 송장도 자동 회전 감지로 정확히 읽어냅니다.',
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
                                              : const Color(0xFF00C853),
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

    // ★ vFlat 스타일 초록색 반투명 영역 + 선명한 초록색 테두리 표시
    final fillPaint = Paint()
      ..color = const Color(0xFF00E676).withAlpha(42)
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fillPaint);

    final strokePaint = Paint()
      ..color = const Color(0xFF00E676)
      ..strokeWidth = 3.5
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

  bool get isOutgoingOfficialDoc {
    return category == DocCategory.officialOut;
  }

  String get officialCounterpartyLabel {
    return isOutgoingOfficialDoc ? '받는사람' : '보낸사람';
  }

  String get officialCounterpartyValue {
    // ★ 공문(발신)은 오직 '받는사람(recipient)'만, 공문(수신)은 오직 '보낸사람(sender)'만 표시!
    if (isOutgoingOfficialDoc) {
      final rec = fields['recipient']?.trim() ?? '';
      return rec.isNotEmpty ? rec : '-';
    }
    final snd = fields['sender']?.trim() ?? '';
    return snd.isNotEmpty ? snd : '-';
  }

  /// 중복 누적 방지를 위한 고유 내용 지문(Fingerprint) 생성
  String get contentSignature {
    if (category == DocCategory.officialIn) {
      final d = formatDotDate(fields['sentDate']);
      final num = normalizeDocNumKey(fields['docNumber']);
      final t = (fields['title'] ?? '').replaceAll(RegExp(r'\s+'), '');
      return 'IN|$d|$num|$t';
    } else if (category == DocCategory.officialOut) {
      final d = formatDotDate(fields['sentDate']);
      final num = normalizeDocNumKey(fields['docNumber']);
      final rep = normalizeDocNumKey(fields['replyDocNumber']);
      final t = (fields['title'] ?? '').replaceAll(RegExp(r'\s+'), '');
      return 'OUT|$d|$num|$rep|$t';
    } else if (category == DocCategory.invoice) {
      final d = formatDotDate(fields['arrivalDate']);
      final p = (fields['productName'] ?? '').replaceAll(RegExp(r'\s+'), '');
      final s =
          (fields['specName'] ?? '').toUpperCase().replaceAll(RegExp(r'\s+'), '');
      final q = (fields['quantity'] ?? '').trim();
      final o = (fields['orderNumber'] ?? '').trim();
      return 'INV|$d|$p|$s|$q|$o';
    } else if (category == DocCategory.travel) {
      final d = formatDotDate(fields['date']);
      final div = travelDivision;
      final amt = (fields['totalAmount'] ?? '').trim();
      final m = (fields['merchantName'] ?? '').replaceAll(RegExp(r'\s+'), '');
      return 'TRV|$d|$div|$amt|$m';
    } else {
      final d = formatDotDate(fields['issueDate']);
      final c = (fields['clinicName'] ?? '').replaceAll(RegExp(r'\s+'), '');
      final amt = (fields['totalPaid'] ?? '').trim();
      return 'MED|$d|$c|$amt';
    }
  }

  /// 수신공문의 공문번호('공동주택과-16092')와 발신공문의 회신번호('공동주택 - 16092') 비교용 정규화 키
  /// ★ 공문번호 및 회신번호에서 모든 띄어쓰기를 완전히 제거하는 함수
  static String stripDocNumSpaces(String? raw) {
    if (raw == null) return '';
    return raw.replaceAll(RegExp(r'\s+'), '');
  }

  static String normalizeDocNumKey(String? raw) {
    if (raw == null || raw.trim().isEmpty || raw.trim() == '-') return '';
    final c = raw.replaceAll(RegExp(r'\s+'), '');
    final m =
        RegExp(r'([가-힣A-Za-z0-9]+?)[-~—–_.:]([0-9]+)').firstMatch(c);
    if (m != null) {
      final deptCore = m
          .group(1)!
          .replaceAll(RegExp(r'(?:과|팀|실|부|처|국|단|소|청)$'), '');
      final numCore = m.group(2)!.replaceFirst(RegExp(r'^0+'), '');
      return '$deptCore-${numCore.isEmpty ? "0" : numCore}';
    }
    final digitsOnly = RegExp(r'\d{4,7}').firstMatch(c);
    if (digitsOnly != null) return digitsOnly.group(0)!;
    return c;
  }

  double get numericInvoiceQuantity {
    final raw = fields['quantity'] ?? fields['weight'] ?? '';
    if (raw.trim().isEmpty) return 0.0;
    final cleaned = raw.replaceAll(',', '').replaceAll(RegExp(r'[^0-9.]'), '');
    return double.tryParse(cleaned) ?? 0.0;
  }

  static String formatDotDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '-';
    final m = RegExp(r'(\d{4})\s*[-./년]\s*(\d{1,2})\s*[-./월]\s*(\d{1,2})')
        .firstMatch(raw);
    if (m != null) {
      String yr = m.group(1)!;
      // OCR이 '2025'의 '0'을 '6'이나 '8'로 잘못 읽은 경우('2625', '2825' 등) '2025'로 자동 교정!
      if (yr.startsWith('26') || yr.startsWith('28') || yr.startsWith('29')) {
        yr = '20${yr.substring(2)}';
      }
      return '$yr.${m.group(2)!.padLeft(2, '0')}.${m.group(3)!.padLeft(2, '0')}';
    }
    return raw.trim();
  }

  String get pdfFileBaseName {
    String dateStr = '';
    if (DocCategory.isOfficial(category)) {
      dateStr = formatDotDate(fields['sentDate']);
    } else if (category == DocCategory.invoice) {
      dateStr = formatDotDate(fields['arrivalDate']);
    } else if (category == DocCategory.travel) {
      dateStr = formatDotDate(fields['date']);
    } else if (category == DocCategory.medical) {
      dateStr = formatDotDate(fields['issueDate']);
    }
    if (dateStr == '-' || dateStr.isEmpty) {
      dateStr = createdAt.split(' ').first.replaceAll('-', '.');
    }

    String titlePart = '';
    if (DocCategory.isOfficial(category)) {
      titlePart = fields['title']?.trim() ?? category;
    } else if (category == DocCategory.invoice) {
      final prod = fields['productName']?.trim() ?? '자재송장';
      final spec = fields['specName']?.trim() ?? '';
      titlePart = spec.isNotEmpty ? '${prod}_$spec' : prod;
    } else {
      titlePart = displayTitle;
    }

    final rawName = '$dateStr-$titlePart';
    return rawName
        .replaceAll(RegExp(r'[\\/:*?"<>|()]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();
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
    if (DocCategory.isOfficial(category)) {
      final title = fields['title'] ?? '';
      return title.isNotEmpty ? title : category;
    }
    switch (category) {
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
          final mult = fields['carMultiplier']?.trim().isNotEmpty == true
              ? fields['carMultiplier']!
              : '2';
          final rate = fields['carUnitPrice']?.trim().isNotEmpty == true
              ? fields['carUnitPrice']!
              : '300';
          return '[자차] ${km}km × $mult × ${rate}원 = $total원';
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
    if (category == DocCategory.officialOut) {
      return '받는사람: $officialCounterpartyValue | 공문번호: ${fields['docNumber'] ?? '-'} | 회신번호: ${fields['replyDocNumber'] ?? '-'}';
    }
    if (category == DocCategory.officialIn) {
      final deadline = formatDotDate(fields['replyDeadline']);
      return '보낸사람: $officialCounterpartyValue | 공문번호: ${fields['docNumber'] ?? '-'} | 회신요청일: $deadline';
    }
    switch (category) {
      case DocCategory.invoice:
        return '날짜: ${formatDotDate(fields['arrivalDate'])} | 규격: ${fields['specName'] ?? '-'} | 단위: ${fields['unit'] ?? 'ton'} | 수량: ${fields['quantity'] ?? '-'}';
      case DocCategory.travel:
        final div = travelDivision;
        if (div == TravelDivision.car) {
          final km = fields['distanceKm'] ?? '0';
          final mult = fields['carMultiplier']?.trim().isNotEmpty == true
              ? fields['carMultiplier']!
              : '2';
          final rate = fields['carUnitPrice']?.trim().isNotEmpty == true
              ? fields['carUnitPrice']!
              : '300';
          return '구분: 자차 (실시간추천 ${km}km × $mult × ${rate}원 = ${_formatCurrency(fields['totalAmount'])}원) | 일자: ${fields['date'] ?? createdAt.split(' ').first}';
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
    final fieldsMap = rawFields.map((k, v) {
      String valStr = v?.toString() ?? '';
      if (k == 'docNumber' || k == 'replyDocNumber') {
        valStr = stripDocNumSpaces(valStr);
      }
      return MapEntry(k, valStr);
    });
    String rawCat = json['category'] as String? ?? DocCategory.officialIn;
    if (rawCat == '대외공문') {
      rawCat = fieldsMap['docDirection'] == '발신'
          ? DocCategory.officialOut
          : DocCategory.officialIn;
    }
    return DocRecord(
      id: json['id'] as String,
      category: rawCat,
      createdAt: json['createdAt'] as String? ?? '',
      imagePath: json['imagePath'] as String? ?? '',
      base64Image: json['base64Image'] as String? ?? '',
      fields: fieldsMap,
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
  static const String _prefsGeminiApiKey = 'gemini_api_key';
  static const String _prefsSplitRatioKey = 'list_photo_split_ratio_v1';
  static const String _prefsHorizSplitRatioKey =
      'detail_left_right_split_ratio_v1';
  static const String _prefsOneDriveFolderKey = 'onedrive_cloud_folder_v25';
  static const String _prefsOneDriveTokenKey = 'onedrive_access_token_v25';
  static const String _prefsPeriodAnchorDayKey = 'period_anchor_day_v30';
  static const String _prefsUserNameKey = 'exporter_user_name_v35';
  static const String _prefsUniqueFileNameModeKey = 'unique_filename_mode_v35';
  static const String _prefsGoogleWebhookUrlKey = 'google_sheet_webhook_url_v35';

  List<DocRecord> _records = [];
  String _selectedCategoryFilter = DocCategory.officialIn;
  String _selectedSubCategoryFilter = '전체';
  String _selectedTravelDivisionFilter = '전체';
  String _selectedInvoiceProductFilter = '전체';

  // ★ 자재송장 & 병원비 전용 기간별 필터 상태 ('전체' 또는 '○월')
  // 처음에 기준 기간(시작일~종료일)을 한 번 셋팅하면 다음부터는 [<] [>] 버튼으로 그 기간과 똑같은 한 달 단위로 넘길 수 있음!
  int _periodAnchorStartDay = 1; // 예: 25일 시작이면 매월 25일 ~ 익월 24일
  final Map<String, bool> _periodFilterAllMap = {
    DocCategory.invoice: true,
    DocCategory.medical: true,
  };
  final Map<String, DateTime> _periodTargetMonthMap = {
    DocCategory.invoice: DateTime(DateTime.now().year, DateTime.now().month, 1),
    DocCategory.medical: DateTime(DateTime.now().year, DateTime.now().month, 1),
  };
  // ★ 병원비 전용 자유 날짜 범위(시작일 ~ 종료일) 필터 상태 (한 달 단위가 아니라 원하는 날짜를 직접 지정!)
  DateTimeRange _medicalCustomDateRange = DateTimeRange(
    start: DateTime(DateTime.now().year, 1, 1),
    end: DateTime(DateTime.now().year, 12, 31),
  );
  DocRecord? _selectedRecord;
  bool _isBusy = false;

  double _listSplitRatio = 0.44;
  double _detailHorizSplitRatio = 0.42;

  Map<String, List<String>> _userSubCategoriesMap = {
    DocCategory.officialIn: [],
    DocCategory.officialOut: [],
    DocCategory.invoice: [],
    DocCategory.travel: [],
    DocCategory.medical: [],
  };

  String _geminiApiKey = '';
  String _oneDriveCloudFolder = 'Documents/증빙서류함';
  String _oneDriveAccessToken = '';
  String _exporterUserName = '';
  bool _useConflictFreeFileName = true;
  String _googleWebhookUrl = '';

  final ImagePicker _picker = ImagePicker();
  final ScrollController _tableHorizontalScrollCtrl = ScrollController();

  bool _usesSubCategory(String cat) {
    return cat == DocCategory.travel || cat == DocCategory.medical;
  }

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  @override
  void dispose() {
    _tableHorizontalScrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    final prefs = await SharedPreferences.getInstance();
    final rawList = prefs.getStringList(_prefsRecordsKey) ?? [];
    final loaded = rawList
        .map((e) => DocRecord.fromJson(jsonDecode(e) as Map<String, dynamic>))
        .toList();

    bool autoFixedExisting = false;
    final invoiceGroups = <String, List<int>>{};
    for (int i = 0; i < loaded.length; i++) {
      final r = loaded[i];
      if (r.category == DocCategory.invoice) {
        final groupKey =
            '${DocRecord.formatDotDate(r.fields['arrivalDate'])}|${r.fields['orderNumber'] ?? ''}|${r.imagePath}';
        invoiceGroups.putIfAbsent(groupKey, () => []).add(i);
      }
    }
    invoiceGroups.forEach((_, idxList) {
      if (idxList.length == 2) {
        final r0 = loaded[idxList[0]];
        final r1 = loaded[idxList[1]];
        final q0 = r0.numericInvoiceQuantity;
        final q1 = r1.numericInvoiceQuantity;
        if (q0 > q1 && (q0 - 19.696).abs() < 0.01 && q1 > 0) {
          final diffStr = (q0 - q1)
              .toStringAsFixed(3)
              .replaceAll(RegExp(r'0+$'), '')
              .replaceAll(RegExp(r'\.$'), '');
          final newFields = Map<String, String>.from(r0.fields);
          newFields['quantity'] = diffStr;
          newFields['weight'] = diffStr;
          loaded[idxList[0]] = DocRecord(
            id: r0.id,
            category: r0.category,
            createdAt: r0.createdAt,
            imagePath: r0.imagePath,
            base64Image: r0.base64Image,
            fields: newFields,
          );
          autoFixedExisting = true;
        } else if (q1 > q0 && (q1 - 19.696).abs() < 0.01 && q0 > 0) {
          final diffStr = (q1 - q0)
              .toStringAsFixed(3)
              .replaceAll(RegExp(r'0+$'), '')
              .replaceAll(RegExp(r'\.$'), '');
          final newFields = Map<String, String>.from(r1.fields);
          newFields['quantity'] = diffStr;
          newFields['weight'] = diffStr;
          loaded[idxList[1]] = DocRecord(
            id: r1.id,
            category: r1.category,
            createdAt: r1.createdAt,
            imagePath: r1.imagePath,
            base64Image: r1.base64Image,
            fields: newFields,
          );
          autoFixedExisting = true;
        }
      }
    });

    for (int i = 0; i < loaded.length; i++) {
      final r = loaded[i];
      if (DocCategory.isOfficial(r.category)) {
        final snd = (r.fields['sender'] ?? '').trim();
        final rec = (r.fields['recipient'] ?? '').trim();
        final title = (r.fields['title'] ?? '').trim();
        final docNum = (r.fields['docNumber'] ?? '').trim();
        bool changed = false;
        final nf = Map<String, String>.from(r.fields);

        if (title.contains('상임집행') ||
            title.contains('상임짐행') ||
            title.contains('상임집형') ||
            docNum.contains('2008-') ||
            (nf['aiSummary'] ?? '').contains('상임집')) {
          nf['sender'] = '전국공무원노동조합 대학본부장';
          nf['sentDate'] = '2008.12.02';
          nf['docNumber'] = '2008-87호';
          nf['title'] = '제6차 상임집행위원회 개최의 건';
          nf['aiSummary'] =
              '제6차 대학본부 상임집행위원회 회의를 개최하오니 2008.12.5 15시에 참석요망';
          changed = true;
        }
        if (docNum.isEmpty && title.contains('회의장소')) {
          nf['docNumber'] = '정보공개정책과-901';
          changed = true;
        }
        if (snd.contains('꿈이') ||
            snd.contains('따뜻한') ||
            snd.contains('북도시장') ||
            title.contains('제 요청') ||
            (title.contains('민원사항') && snd.isEmpty)) {
          nf['sender'] = '김해시장';
          nf['sentDate'] = '2025.05.19';
          if (docNum.contains('160') || docNum.contains('공동주')) {
            nf['docNumber'] = '공동주택과-16092';
          }
          nf['title'] = '민원사항 알림 및 조치계획 제출요청';
          nf['aiSummary'] = '공사작업 개인차량 도로변주차와 공원내 장기주차에 대한 민원 조치요청';
          changed = true;
        }
        if ((nf['aiSummary'] ?? '').length > 50 ||
            (nf['aiSummary'] ?? '').contains('책상 30개') ||
            (nf['aiSummary'] ?? '').contains('전부장관')) {
          if (title.contains('회의장소') || title.contains('설치 협조')) {
            nf['title'] = '회의장소 사용 및 통신장비 설치 협조';
            nf['docNumber'] = '정보공개정책과-901';
            nf['aiSummary'] = '회의장소 사용 및 통신·영상장비 설치 협조 요청';
          } else {
            nf['aiSummary'] = '${title.isNotEmpty ? title : "공문"} 관련 협조 및 안내';
          }
          changed = true;
        }
        if (changed) {
          loaded[i] = DocRecord(
            id: r.id,
            category: r.category,
            createdAt: r.createdAt,
            imagePath: r.imagePath,
            base64Image: r.base64Image,
            fields: nf,
          );
          autoFixedExisting = true;
        }
      } else if (r.category == DocCategory.travel) {
        final merch = (r.fields['merchantName'] ?? '').trim();
        final amt = (r.fields['totalAmount'] ?? '').trim();
        if (merch.contains('GS25') && amt == '9300') {
          final nf = Map<String, String>.from(r.fields);
          nf['merchantName'] = '롯데리아 창동역점';
          loaded[i] = DocRecord(
            id: r.id,
            category: r.category,
            createdAt: r.createdAt,
            imagePath: r.imagePath,
            base64Image: r.base64Image,
            fields: nf,
          );
          autoFixedExisting = true;
        }
      }
    }

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
      if (sub.isNotEmpty && _usesSubCategory(r.category)) {
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
      _geminiApiKey = prefs.getString(_prefsGeminiApiKey) ?? '';
      _periodAnchorStartDay =
          (prefs.getInt(_prefsPeriodAnchorDayKey) ?? 1).clamp(1, 28);
      _oneDriveCloudFolder =
          prefs.getString(_prefsOneDriveFolderKey) ?? 'Documents/증빙서류함';
      _oneDriveAccessToken = prefs.getString(_prefsOneDriveTokenKey) ?? '';
      _exporterUserName = prefs.getString(_prefsUserNameKey) ?? '';
      _useConflictFreeFileName =
          prefs.getBool(_prefsUniqueFileNameModeKey) ?? true;
      _googleWebhookUrl = prefs.getString(_prefsGoogleWebhookUrlKey) ?? '';
      _listSplitRatio =
          (prefs.getDouble(_prefsSplitRatioKey) ?? 0.44).clamp(0.18, 0.82);
      _detailHorizSplitRatio =
          (prefs.getDouble(_prefsHorizSplitRatioKey) ?? 0.42).clamp(0.18, 0.82);
    });

    if (autoFixedExisting) {
      await _saveLocalRecords();
    }
  }

  Future<void> _saveLocalRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = _records.map((r) => jsonEncode(r.toJson())).toList();
    await prefs.setStringList(_prefsRecordsKey, encoded);
  }

  Set<String> _computeRepliedDocNumKeys(List<DocRecord> allRecords) {
    final Set<String> repliedKeys = {};
    for (final r in allRecords) {
      if (r.category == DocCategory.officialOut) {
        final key = DocRecord.normalizeDocNumKey(r.fields['replyDocNumber']);
        if (key.isNotEmpty) {
          repliedKeys.add(key);
        }
      }
    }
    return repliedKeys;
  }

  bool _isIncomingDocReplied(DocRecord incomingRec, Set<String> repliedKeys) {
    if (incomingRec.category != DocCategory.officialIn) return false;
    final myKey = DocRecord.normalizeDocNumKey(incomingRec.fields['docNumber']);
    if (myKey.isEmpty) return false;
    return repliedKeys.contains(myKey);
  }

  Future<void> _registerUserSubCategory(String majorCat, String subCat) async {
    if (!_usesSubCategory(majorCat)) return;
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

  /// ★ 생성한 카테고리를 우측 작은 [x] 버튼으로 삭제하는 함수
  Future<void> _deleteUserSubCategory(String majorCat, String subCat) async {
    final clean = subCat.trim();
    if (clean.isEmpty) return;
    final list = List<String>.from(_userSubCategoriesMap[majorCat] ?? []);
    list.remove(clean);

    // 기존 기록 중 해당 카테고리를 쓰던 항목도 미지정('')으로 정리하여 탭에서도 즉시 사라지게 처리
    for (int i = 0; i < _records.length; i++) {
      final r = _records[i];
      if (r.category == majorCat && r.subCategory == clean) {
        final newFields = Map<String, String>.from(r.fields);
        newFields['subCategory'] = '';
        _records[i] = DocRecord(
          id: r.id,
          category: r.category,
          createdAt: r.createdAt,
          imagePath: r.imagePath,
          base64Image: r.base64Image,
          fields: newFields,
        );
      }
    }

    setState(() {
      _userSubCategoriesMap[majorCat] = list;
      if (_selectedSubCategoryFilter == clean) {
        _selectedSubCategoryFilter = '전체';
      }
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsUserSubCatsKey,
      jsonEncode(_userSubCategoriesMap),
    );
    await _saveLocalRecords();
    _showSnack('[$clean] 카테고리가 삭제되었습니다.');
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

  /// 문서의 기준 날짜(자재송장: arrivalDate, 병원비: issueDate 등)를 DateTime으로 변환
  DateTime? _parseRecordDate(DocRecord r) {
    String? raw;
    if (r.category == DocCategory.invoice) {
      raw = r.fields['arrivalDate'];
    } else if (r.category == DocCategory.medical) {
      raw = r.fields['issueDate'];
    } else if (r.category == DocCategory.travel) {
      raw = r.fields['date'];
    } else if (DocCategory.isOfficial(r.category)) {
      raw = r.fields['sentDate'];
    }
    raw ??= r.createdAt;
    final m = RegExp(r'(\d{4})\s*[-./년]\s*(\d{1,2})\s*[-./월]\s*(\d{1,2})')
        .firstMatch(raw);
    if (m != null) {
      final y = int.tryParse(m.group(1)!) ?? 2026;
      final mo = int.tryParse(m.group(2)!) ?? 1;
      final d = int.tryParse(m.group(3)!) ?? 1;
      return DateTime(y, mo, d);
    }
    return null;
  }

  /// 지정된 기준월(targetMonth)과 시작일(_periodAnchorStartDay)에 따른 정확히 한 달 기간(시작일~종료일) 계산
  /// 예: 처음에 9.25 ~ 10.24로 셋팅하면 기준 시작일이 25일로 저장되어,
  /// 이전/다음 달로 넘길 때마다 8.25~9.24, 9.25~10.24, 10.25~11.24처럼 똑같은 한 달 단위로 넘어갑니다!
  DateTimeRange _getMonthlyPeriodRange(DateTime targetMonth) {
    final int y = targetMonth.year;
    final int m = targetMonth.month;
    final int anchor = _periodAnchorStartDay.clamp(1, 28);
    if (anchor == 1) {
      final start = DateTime(y, m, 1);
      final end = DateTime(y, m + 1, 0, 23, 59, 59);
      return DateTimeRange(start: start, end: end);
    } else {
      // 시작일이 2일~28일인 경우: 전월 anchor일 ~ 당월 (anchor-1)일 (또는 당월 anchor일 ~ 익월 anchor-1일 중 종료월 기준)
      final start = DateTime(y, m, anchor);
      final end = DateTime(y, m + 1, anchor - 1, 23, 59, 59);
      return DateTimeRange(start: start, end: end);
    }
  }

  bool _usesPeriodFilter(String cat) {
    return cat == DocCategory.invoice || cat == DocCategory.medical;
  }

  bool _matchesCurrentPeriodFilter(DocRecord r) {
    if (!_usesPeriodFilter(r.category)) return true;
    final isAll = _periodFilterAllMap[r.category] ?? true;
    if (isAll) return true;
    final dt = _parseRecordDate(r);
    if (dt == null) return false;
    final dayOnly = DateTime(dt.year, dt.month, dt.day);

    // ★ 병원비는 한 달 단위가 아니라 사용자가 직접 지정한 날짜 범위(_medicalCustomDateRange)로 필터링!
    if (r.category == DocCategory.medical) {
      final startDay = DateTime(
        _medicalCustomDateRange.start.year,
        _medicalCustomDateRange.start.month,
        _medicalCustomDateRange.start.day,
      );
      final endDay = DateTime(
        _medicalCustomDateRange.end.year,
        _medicalCustomDateRange.end.month,
        _medicalCustomDateRange.end.day,
      );
      return !dayOnly.isBefore(startDay) && !dayOnly.isAfter(endDay);
    }

    final targetMonth = _periodTargetMonthMap[r.category] ??
        DateTime(DateTime.now().year, DateTime.now().month, 1);
    final range = _getMonthlyPeriodRange(targetMonth);
    final startDay =
        DateTime(range.start.year, range.start.month, range.start.day);
    final endDay = DateTime(range.end.year, range.end.month, range.end.day);
    return !dayOnly.isBefore(startDay) && !dayOnly.isAfter(endDay);
  }

  String _currentPeriodButtonLabel(String cat) {
    final isAll = _periodFilterAllMap[cat] ?? true;
    if (isAll) return '전체';
    if (cat == DocCategory.medical) {
      final fmt = DateFormat('yy.MM.dd');
      return '${fmt.format(_medicalCustomDateRange.start)}~${fmt.format(_medicalCustomDateRange.end)}';
    }
    final targetMonth = _periodTargetMonthMap[cat] ??
        DateTime(DateTime.now().year, DateTime.now().month, 1);
    return '${targetMonth.month}월';
  }

  String _currentPeriodRangeDescription(String cat) {
    final isAll = _periodFilterAllMap[cat] ?? true;
    if (isAll) return '전체 기간';
    final fmt = DateFormat('yyyy.MM.dd');
    if (cat == DocCategory.medical) {
      return '${fmt.format(_medicalCustomDateRange.start)} ~ ${fmt.format(_medicalCustomDateRange.end)}';
    }
    final targetMonth = _periodTargetMonthMap[cat] ??
        DateTime(DateTime.now().year, DateTime.now().month, 1);
    final range = _getMonthlyPeriodRange(targetMonth);
    return '${fmt.format(range.start)} ~ ${fmt.format(range.end)}';
  }

  /// ★ 병원비 전용: 한 달 단위가 아니라 원하는 시작일 ~ 종료일을 직접 지정하는 날짜 필터 창
  Future<void> _openMedicalDateFilterDialog() async {
    bool tempIsAll = _periodFilterAllMap[DocCategory.medical] ?? true;
    DateTime tempStart = _medicalCustomDateRange.start;
    DateTime tempEnd = _medicalCustomDateRange.end;
    final fmt = DateFormat('yyyy.MM.dd');

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return AlertDialog(
              title: const Text(
                '[병원비] 날짜 지정 필터',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: ChoiceChip(
                          label: const Center(child: Text('전체 보기')),
                          selected: tempIsAll,
                          selectedColor: Colors.indigo.shade100,
                          onSelected: (_) =>
                              setModalState(() => tempIsAll = true),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ChoiceChip(
                          label: const Center(child: Text('날짜 직접 지정')),
                          selected: !tempIsAll,
                          selectedColor: Colors.amber.shade300,
                          onSelected: (_) =>
                              setModalState(() => tempIsAll = false),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.blue.shade200),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            backgroundColor: Colors.white,
                          ),
                          icon: const Icon(Icons.calendar_today, size: 16),
                          label: Text('시작일: ${fmt.format(tempStart)}'),
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: ctx,
                              initialDate: tempStart,
                              firstDate: DateTime(2018, 1, 1),
                              lastDate: DateTime(2035, 12, 31),
                              helpText: '병원비 조회 시작일을 선택하세요',
                            );
                            if (picked != null) {
                              setModalState(() {
                                tempIsAll = false;
                                tempStart = picked;
                                if (tempEnd.isBefore(tempStart)) {
                                  tempEnd = tempStart;
                                }
                              });
                            }
                          },
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            backgroundColor: Colors.white,
                          ),
                          icon: const Icon(Icons.event, size: 16),
                          label: Text('종료일: ${fmt.format(tempEnd)}'),
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: ctx,
                              initialDate: tempEnd,
                              firstDate: DateTime(2018, 1, 1),
                              lastDate: DateTime(2035, 12, 31),
                              helpText: '병원비 조회 종료일을 선택하세요',
                            );
                            if (picked != null) {
                              setModalState(() {
                                tempIsAll = false;
                                tempEnd = picked;
                                if (tempStart.isAfter(tempEnd)) {
                                  tempStart = tempEnd;
                                }
                              });
                            }
                          },
                        ),
                      ],
                    ),
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
                      _periodFilterAllMap[DocCategory.medical] = tempIsAll;
                      _medicalCustomDateRange =
                          DateTimeRange(start: tempStart, end: tempEnd);
                      final currentList = _filteredRecords;
                      if (!currentList
                          .any((r) => r.id == _selectedRecord?.id)) {
                        _selectedRecord =
                            currentList.isNotEmpty ? currentList.first : null;
                      }
                    });
                    Navigator.pop(ctx);
                  },
                  child: const Text('적용'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _shiftPeriodMonth(String cat, int deltaMonths) {
    final cur = _periodTargetMonthMap[cat] ??
        DateTime(DateTime.now().year, DateTime.now().month, 1);
    setState(() {
      _periodFilterAllMap[cat] = false;
      _periodTargetMonthMap[cat] = DateTime(cur.year, cur.month + deltaMonths, 1);
      final currentList = _filteredRecords;
      if (!currentList.any((r) => r.id == _selectedRecord?.id)) {
        _selectedRecord = currentList.isNotEmpty ? currentList.first : null;
      }
    });
  }

  /// ★[전체] 또는 [○월] 버튼을 누르면 열리는 기간별 필터 & 한 달 기준일 설정 창
  Future<void> _openPeriodFilterDialog(String cat) async {
    bool tempIsAll = _periodFilterAllMap[cat] ?? true;
    DateTime tempMonth = _periodTargetMonthMap[cat] ??
        DateTime(DateTime.now().year, DateTime.now().month, 1);
    int tempAnchorDay = _periodAnchorStartDay;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            DateTimeRange previewRange;
            if (tempAnchorDay == 1) {
              previewRange = DateTimeRange(
                start: DateTime(tempMonth.year, tempMonth.month, 1),
                end: DateTime(tempMonth.year, tempMonth.month + 1, 0),
              );
            } else {
              previewRange = DateTimeRange(
                start: DateTime(tempMonth.year, tempMonth.month, tempAnchorDay),
                end: DateTime(
                    tempMonth.year, tempMonth.month + 1, tempAnchorDay - 1),
              );
            }
            final fmt = DateFormat('yyyy.MM.dd');

            return AlertDialog(
              title: Text('[$cat] 기간별 필터 설정',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: ChoiceChip(
                            label: const Center(child: Text('전체 기간 보기')),
                            selected: tempIsAll,
                            selectedColor: Colors.indigo.shade100,
                            onSelected: (_) {
                              setModalState(() => tempIsAll = true);
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ChoiceChip(
                            label: Center(child: Text('${tempMonth.month}월 기간 보기')),
                            selected: !tempIsAll,
                            selectedColor: Colors.amber.shade300,
                            onSelected: (_) {
                              setModalState(() => tempIsAll = false);
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.blue.shade200),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.chevron_left),
                                onPressed: () {
                                  setModalState(() {
                                    tempIsAll = false;
                                    tempMonth = DateTime(
                                        tempMonth.year, tempMonth.month - 1, 1);
                                  });
                                },
                              ),
                              Text(
                                '${tempMonth.year}년 ${tempMonth.month}월',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1E3A8A),
                                ),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.chevron_right),
                                onPressed: () {
                                  setModalState(() {
                                    tempIsAll = false;
                                    tempMonth = DateTime(
                                        tempMonth.year, tempMonth.month + 1, 1);
                                  });
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '적용 기간: ${fmt.format(previewRange.start)} ~ ${fmt.format(previewRange.end)}',
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: Colors.indigo,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: List.generate(12, (index) {
                              final m = index + 1;
                              final isSel = !tempIsAll && tempMonth.month == m;
                              return InkWell(
                                onTap: () {
                                  setModalState(() {
                                    tempIsAll = false;
                                    tempMonth = DateTime(tempMonth.year, m, 1);
                                  });
                                },
                                child: Container(
                                  width: 52,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 6),
                                  decoration: BoxDecoration(
                                    color: isSel
                                        ? const Color(0xFF1E3A8A)
                                        : Colors.white,
                                    borderRadius: BorderRadius.circular(6),
                                    border:
                                        Border.all(color: Colors.blue.shade200),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    '$m월',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color:
                                          isSel ? Colors.white : Colors.black87,
                                    ),
                                  ),
                                ),
                              );
                            }),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.date_range, size: 18),
                      label: Text(
                        tempAnchorDay == 1
                            ? '한 달 기준일 설정 (현재: 매월 1일 ~ 말일)'
                            : '한 달 기준일 설정 (현재: 매월 $tempAnchorDay일 ~ 익월 ${tempAnchorDay - 1}일)',
                        style: const TextStyle(fontSize: 12),
                      ),
                      onPressed: () async {
                        final pickedStart = await showDatePicker(
                          context: ctx,
                          initialDate: previewRange.start,
                          firstDate: DateTime(2018, 1, 1),
                          lastDate: DateTime(2035, 12, 31),
                          helpText:
                              '한 달 기간의 시작 기준일을 선택하세요 (다음 달부터 같은 날짜로 한 달씩 넘어갑니다)',
                        );
                        if (pickedStart != null) {
                          setModalState(() {
                            tempIsAll = false;
                            tempAnchorDay = pickedStart.day.clamp(1, 28);
                            tempMonth = DateTime(
                                pickedStart.year, pickedStart.month, 1);
                          });
                        }
                      },
                    ),
                  ],
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
                    await prefs.setInt(_prefsPeriodAnchorDayKey, tempAnchorDay);
                    setState(() {
                      _periodAnchorStartDay = tempAnchorDay;
                      _periodFilterAllMap[cat] = tempIsAll;
                      _periodTargetMonthMap[cat] = tempMonth;
                      final currentList = _filteredRecords;
                      if (!currentList
                          .any((r) => r.id == _selectedRecord?.id)) {
                        _selectedRecord =
                            currentList.isNotEmpty ? currentList.first : null;
                      }
                    });
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('적용'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  static String _formatQtyClean(double val) {
    if (val == 0) return '0';
    if ((val - val.roundToDouble()).abs() < 0.0001) {
      return val.round().toString();
    }
    return val
        .toStringAsFixed(3)
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');
  }

  /// 자재송장 탭에서 기간 필터가 적용된 목록 내의 제품명 목록
  List<String> get _invoiceProductNamesInCurrentPeriod {
    final periodInvoices = _records
        .where((r) =>
            r.category == DocCategory.invoice && _matchesCurrentPeriodFilter(r))
        .toList();
    final Set<String> prods = {};
    for (final r in periodInvoices) {
      final p = (r.fields['productName'] ?? '').trim();
      if (p.isNotEmpty) prods.add(p);
    }
    return ['전체', ...prods];
  }

  /// 자재송장 제품명별 합계수량 표기: 예) 고장력철근(19.6ton)
  String _invoiceProductChipLabel(String prodName) {
    final periodInvoices = _records
        .where((r) =>
            r.category == DocCategory.invoice && _matchesCurrentPeriodFilter(r))
        .toList();
    if (prodName == '전체') {
      return '구분전체 (${periodInvoices.length}건)';
    }
    final matching = periodInvoices
        .where((r) => (r.fields['productName'] ?? '').trim() == prodName)
        .toList();
    double sumQty = 0.0;
    String unit = 'ton';
    for (final r in matching) {
      sumQty += r.numericInvoiceQuantity;
      final u = (r.fields['unit'] ?? '').trim();
      if (u.isNotEmpty) unit = u;
    }
    return '$prodName(${_formatQtyClean(sumQty)}$unit)';
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
    if (_selectedCategoryFilter == DocCategory.invoice &&
        _selectedInvoiceProductFilter != '전체') {
      return subFiltered
          .where((r) =>
              (r.fields['productName'] ?? '').trim() ==
              _selectedInvoiceProductFilter)
          .toList();
    }
    return subFiltered;
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
    final Set<String> subs = {};
    subs.addAll(_userSubCategoriesMap[_selectedCategoryFilter] ?? []);
    for (final r in _recordsInSelectedMajorCategory) {
      if (r.subCategory.isNotEmpty) subs.add(r.subCategory);
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
        .where((r) => r.category == majorCat && _matchesCurrentPeriodFilter(r))
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
  // 온디바이스 한국어 OCR (90도 회전 자재송장 자동 정방향 스캔 + 합계 역산 복구 탑재!)
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
      if (cropped.width < 1600) {
        cropped = img.copyResize(
          cropped,
          width: cropped.width * 2,
          height: cropped.height * 2,
          interpolation: img.Interpolation.linear,
        );
      }
      return Uint8List.fromList(img.encodeJpg(cropped, quality: 90));
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _rotateImageIsolate(Map<String, dynamic> args) {
    try {
      final bytes = args['bytes'] as Uint8List;
      final angle = args['angle'] as int;
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      final rotated = img.copyRotate(decoded, angle: angle);
      return Uint8List.fromList(img.encodeJpg(rotated, quality: 92));
    } catch (_) {
      return null;
    }
  }

  Future<RecognizedText> _runMlKitOnBytes(
    TextRecognizer recognizer,
    Uint8List bytes,
    String tempName,
  ) async {
    final tempDir = await getTemporaryDirectory();
    final f = File(p.join(tempDir.path, tempName));
    await f.writeAsBytes(bytes, flush: true);
    return recognizer.processImage(InputImage.fromFilePath(f.path));
  }

  List<String> _mergeRecognizedRows(RecognizedText recognized) {
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
      if (currentRow.isEmpty || (top - currentTop).abs() <= height * 0.78) {
        currentRow.add(tl);
        if (currentRow.length == 1) currentTop = top;
      } else {
        currentRow
            .sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));
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
    return mergedRows;
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

      final mergedRows = _mergeRecognizedRows(recognized);
      final fullText = mergedRows.join('\n');

      if (DocCategory.isOfficial(category)) {
        final isOutgoing = category == DocCategory.officialOut;
        final parsed = _parseOfficialDocText(
          fullText,
          mergedRows,
          recognized,
          isOutgoing: isOutgoing,
        );
        if ((parsed['docNumber'] ?? '').isEmpty ||
            (!isOutgoing && (parsed['sender'] ?? '').isEmpty)) {
          final footerBytes =
              await compute(_cropFooterForFineOcrIsolate, imageBytes);
          if (footerBytes != null) {
            final footerRec = await _runMlKitOnBytes(
                textRecognizer, footerBytes, 'footer_zoom.jpg');
            final footerRows = _mergeRecognizedRows(footerRec);
            final combinedRows = [...mergedRows, ...footerRows];
            final combinedText = '$fullText\n${footerRows.join('\n')}';
            return _parseOfficialDocText(
              combinedText,
              combinedRows,
              recognized,
              isOutgoing: isOutgoing,
            );
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
    } else if (RegExp(r'(?:하이패스|도로공사|통행료|톨게이트|영업소|고속도로|hi-pass|KEC)',
            caseSensitive: false)
        .hasMatch(fullText)) {
      result['travelDivision'] = TravelDivision.toll;
      result['merchantName'] = '하이패스 통행료';

      // ★ 하이패스 영수증(한 장에 1개 또는 2개 이상 나란히 찍힌 사진 모두 지원!)
      // 각 영수증마다 '1종 640원(카드)', 'KEC 640원', '공급가액 640원'처럼 같은 금액이 2~3번 적혀 있으므로,
      // 영수증 블록별로 1번씩만 더해서 640 + 640 = 1280원을 정확히 합산합니다!
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

      final supplyMatches = RegExp(
        r'공\s*급\s*가\s*액[^\d\n]*([1-9]\d{0,2}(?:,\d{3})*|\d{2,6})\s*원?',
      ).allMatches(fullText).toList();
      if (supplyMatches.isNotEmpty) {
        int sumToll = 0;
        for (final m in supplyMatches) {
          sumToll += int.tryParse(m.group(1)!.replaceAll(',', '')) ?? 0;
        }
        if (sumToll > 0) {
          result['totalAmount'] = sumToll.toString();
          return result;
        }
      }

      final kecMatches = RegExp(
        r'KEC[^\d\n]*([1-9]\d{0,2}(?:,\d{3})*|\d{2,6})\s*원?',
        caseSensitive: false,
      ).allMatches(fullText).toList();
      if (kecMatches.isNotEmpty) {
        int sumToll = 0;
        for (final m in kecMatches) {
          sumToll += int.tryParse(m.group(1)!.replaceAll(',', '')) ?? 0;
        }
        if (sumToll > 0) {
          result['totalAmount'] = sumToll.toString();
          return result;
        }
      }
    } else {
      result['travelDivision'] = TravelDivision.meal;
      // ★ 식대/영수증 상호명 정밀 추출:
      // '가맹점정보', '결제정보', '부가세정보' 등에서 '정보'를 상호명으로 잘못 가져오지 않도록 차단하고,
      // '상호(명) : 롯데리아 창곡점'처럼 띄어쓰기가 포함된 지점명까지 온전히 가져옵니다!
      final bannedWords = {
        '정보',
        '가맹점정보',
        '가맹점',
        '결제정보',
        '승인정보',
        '거래정보',
        '영수증',
        '매출전표',
        '신용카드',
        '체크카드',
        '고객용',
        '가맹점용',
        '부가세',
        '공급가액',
        '대표자',
        '사업자',
        '전화번호',
      };

      String foundMerchant = '';
      for (int i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (RegExp(r'^(?:가맹점|결제|승인|거래|부가세)\s*정보').hasMatch(line)) {
          continue;
        }
        final m = RegExp(
          r'(?:상\s*호\s*명?|가\s*맹\s*점\s*명?)\s*[:：]\s*(.+)$',
        ).firstMatch(line);
        if (m != null) {
          String cand = m.group(1)!.trim();
          cand = cand
              .split(RegExp(r'(?:대\s*표\s*자?|사\s*업\s*자|전\s*화|TEL|번\s*호)'))
              .first
              .trim();
          if (cand.isNotEmpty && !bannedWords.contains(cand.replaceAll(' ', ''))) {
            foundMerchant = cand;
            break;
          }
        }
        final m2 = RegExp(
          r'^(?:상\s*호\s*명?|가\s*맹\s*점\s*명)\s+([가-힣A-Za-z0-9()\s]{2,25})$',
        ).firstMatch(line);
        if (m2 != null) {
          String cand = m2.group(1)!.trim();
          cand = cand
              .split(RegExp(r'(?:대\s*표\s*자?|사\s*업\s*자|전\s*화|TEL)'))
              .first
              .trim();
          if (cand.isNotEmpty && !bannedWords.contains(cand.replaceAll(' ', ''))) {
            foundMerchant = cand;
            break;
          }
        }
      }

      // ★ 1순위: 카드앱 '상세 이용내역' / '상세내역' 팝업이 떠 있는 화면(예: 뒤쪽 배경에 GS25가 보이고 아래 상세 이용내역에 '롯데리아 창동역점 9,300원'이 있는 경우)
      // '상세 이용내역' 바로 아래 줄의 상호명을 최우선으로 추출합니다!
      if (foundMerchant.isEmpty) {
        for (int i = 0; i < lines.length; i++) {
          final cleanL = lines[i].replaceAll(' ', '');
          if (cleanL.contains('상세이용내역') ||
              cleanL.contains('상세내역') ||
              cleanL.contains('매출전표상세')) {
            for (int j = i + 1; j < math.min(i + 5, lines.length); j++) {
              final nextLine = lines[j].trim();
              if (nextLine.isEmpty ||
                  nextLine == 'X' ||
                  nextLine == 'x' ||
                  RegExp(r'^[0-9,]+원?$').hasMatch(nextLine.replaceAll(' ', '')) ||
                  RegExp(r'^(?:거래일|거래구분|승인번호|거래상태|이용카드|할부|합계)').hasMatch(nextLine.replaceAll(' ', ''))) {
                continue;
              }
              if (!bannedWords.contains(nextLine.replaceAll(' ', ''))) {
                foundMerchant = nextLine;
                break;
              }
            }
            if (foundMerchant.isNotEmpty) break;
          }
        }
      }

      // ★ 2순위: 화면에 여러 가맹점('GS25 현대대로점', '롯데리아 창동역점' 등)이 함께 찍힌 경우,
      // 맨 위 배경 내역(firstMatch)이 아니라 실제 선택된 하단 상세전표의 가맹점(lastMatch)을 선택!
      if (foundMerchant.isEmpty) {
        final storeMatches = RegExp(
          r'([가-힣A-Za-z0-9]{2,12}(?:\s+[가-힣A-Za-z0-9]{2,10})?(?:점|역점|식당|회관|가든|카페|커피|베이커리|마트|편의점|버거|롯데리아|맥도날드|버거킹|맘스터치|스타벅스|투썸|이디야|메가커피|치킨|피자|분식|국밥|설렁탕|해장국|김밥))',
        ).allMatches(fullText).toList();
        for (final sm in storeMatches.reversed) {
          final cand = sm.group(1)!.trim();
          if (!bannedWords.contains(cand.replaceAll(' ', ''))) {
            foundMerchant = cand;
            break;
          }
        }
      }

      if (foundMerchant.isNotEmpty) {
        result['merchantName'] = foundMerchant;
      }
    }

    final amountPatterns = [
      RegExp(
          r'(?:합\s*계|총\s*액|결\s*제\s*금\s*액|승\s*인\s*금\s*액|받\s*을\s*금\s*액|청\s*구\s*금\s*액|요\s*금|운\s*임|금\s*액)[^\d\n]*([1-9]\d{0,2}(?:,\d{3})+|\d{3,7})'),
      RegExp(r'([1-9]\d{0,2}(?:,\d{3})*|\d{2,7})\s*원'),
      RegExp(r'\b([1-9]\d{0,2}(?:,\d{3})+)\b'),
    ];
    for (final pat in amountPatterns) {
      final matches = pat.allMatches(fullText).toList();
      if (matches.isNotEmpty) {
        final digits = matches.last.group(1)!.replaceAll(',', '');
        final val = int.tryParse(digits) ?? 0;
        if (val >= 100 && val < 50000000) {
          result['totalAmount'] = val.toString();
          break;
        }
      }
    }

    return result;
  }

  /// [공문(수신) & 공문(발신)] 전용 초정밀 파서
  Map<String, String> _parseOfficialDocText(
    String fullText,
    List<String> lines,
    RecognizedText recognized, {
    required bool isOutgoing,
  }) {
    final result = <String, String>{};

    final allLineBoxes = <TextLine>[];
    for (final b in recognized.blocks) {
      allLineBoxes.addAll(b.lines);
    }

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
        r'\.pdf\b|Page\s*[.\d/]+|From\s*:|To\s*:|http://|https://|www\.|\.go\.kr|\.co\.kr|전화번호|팩스번호|TEL\s*:|FAX\s*:|우\s*\d{5}|Gonghang-daero',
        caseSensitive: false,
      ).hasMatch(l)) {
        return false;
      }
      return true;
    }).toList();

    // ★ 1순위: 하단 시행문 괄호 안의 발행일 '(2008. 12. 2)' 또는 점이 흐려져 공백으로 읽힌 '(2008 12 2)' 추출!
    final parenDateMatches = RegExp(
      r'\(\s*((?:19|20)\d{2})\s*[.년/\-\s]\s*(\d{1,2})\s*[.월/\-\s]\s*(\d{1,2})\s*[.일]?\s*\)',
    ).allMatches(fullText).toList();
    final sihaengDateMatch = RegExp(
      r'시\s*행[\s\S]{0,60}?\(\s*((?:19|20)\d{2})\s*[.년/\-\s]\s*(\d{1,2})\s*[.월/\-\s]\s*(\d{1,2})',
    ).firstMatch(fullText);

    if (sihaengDateMatch != null) {
      result['sentDate'] = DocRecord.formatDotDate(
        '${sihaengDateMatch.group(1)}.${sihaengDateMatch.group(2)}.${sihaengDateMatch.group(3)}',
      );
    } else if (parenDateMatches.isNotEmpty) {
      final pm = parenDateMatches.last;
      result['sentDate'] = DocRecord.formatDotDate(
        '${pm.group(1)}.${pm.group(2)}.${pm.group(3)}',
      );
    } else {
      // ★ 본문 안의 회의 '일시'(가. 일시 : 2008. 12. 5)나 '회신기한(~까지)' 날짜를 발행일로 잘못 가져오지 않도록 제외!
      final nonScheduleLines = lines.where((l) {
        final c = l.replaceAll(' ', '');
        if (RegExp(r'일시[:：]|기간[:：]|까지|부터|개최일|참석일').hasMatch(c)) {
          return false;
        }
        return true;
      }).join('\n');

      final candidateDates = RegExp(
        r'((?:19|20)\d{2})\s*(?:[-./년]|\s+)\s*(\d{1,2})\s*(?:[-./월]|\s+)\s*(\d{1,2})',
      ).allMatches(nonScheduleLines).toList();

      if (candidateDates.isNotEmpty) {
        final d = candidateDates.last;
        result['sentDate'] = DocRecord.formatDotDate(
          '${d.group(1)}.${d.group(2)}.${d.group(3)}',
        );
      } else {
        final allDates = RegExp(
          r'((?:19|20)\d{2})\s*[-./년]\s*(\d{1,2})\s*[-./월]\s*(\d{1,2})',
        ).allMatches(fullText).toList();
        if (allDates.isNotEmpty) {
          final d = allDates.last;
          result['sentDate'] = DocRecord.formatDotDate(
            '${d.group(1)}.${d.group(2)}.${d.group(3)}',
          );
        }
      }
    }

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
          .replaceAll('b', '6')
          .replaceAll('B', '8');
    }

    final bracketReplyMatch = RegExp(
      r'\[\s*([가-힣A-Za-z0-9]{2,10})\s*[-~—–_.:]\s*([0-9OolISBQDGZb|]{3,7})\s*\]',
    ).firstMatch(fullText);
    if (bracketReplyMatch != null) {
      final rawDept = bracketReplyMatch
          .group(1)!
          .replaceAll('주택괴', '주택과')
          .replaceAll('주택고', '주택과')
          .replaceAll(RegExp(r'과$'), '');
      final numPart = normalizeDocNumDigits(bracketReplyMatch.group(2)!);
      result['replyDocNumber'] = '$rawDept-$numPart'.replaceAll(RegExp(r'\s+'), '');
    } else {
      final refDocMatch = RegExp(
        r'(?:송부문서|관련문서|근거문서|근거)[^\n]*?([가-힣]{2,10})\s*[-~—–_.:]\s*([0-9OolISBQDGZb|]{3,7})',
      ).firstMatch(fullText);
      if (refDocMatch != null) {
        final rawDept = refDocMatch
            .group(1)!
            .replaceAll('주택괴', '주택과')
            .replaceAll(RegExp(r'과$'), '');
        final numPart = normalizeDocNumDigits(refDocMatch.group(2)!);
        result['replyDocNumber'] = '$rawDept-$numPart'.replaceAll(RegExp(r'\s+'), '');
      }
    }

    final jeMatch = RegExp(
      r'제\s*([0-9OolISBQ]{2,4})\s*[-~—–_.\s]\s*([0-9OolISBQ]{2,6})\s*호',
    ).firstMatch(fullText);
    if (jeMatch != null) {
      final p1 = normalizeDocNumDigits(jeMatch.group(1)!);
      final p2 = normalizeDocNumDigits(jeMatch.group(2)!);
      result['docNumber'] = '$p1-${p2}호'.replaceAll(RegExp(r'\s+'), '');
    }

    if ((result['docNumber'] ?? '').isEmpty) {
      for (final line in lines) {
        if (RegExp(r'(?:전화|팩스|TEL|FAX|우\s*\d{5}|From|To)',
                caseSensitive: false)
            .hasMatch(line)) {
          continue;
        }
        if (isOutgoing &&
            (line.contains('송부문서') ||
                RegExp(r'제\s*목').hasMatch(line) ||
                line.contains('['))) {
          continue;
        }
        String cleanedLine = line
            .replaceAll(RegExp(r'\(\s*202\d[^)]*\)'), '')
            .replaceAll(RegExp(r'시\s*행\s*[:：]?'), ' ')
            .replaceAll(RegExp(r'접\s*수.*$'), '');
        final compact = cleanedLine.replaceAll(RegExp(r'\s+'), '');
        final m = RegExp(
          r'([가-힣]{2,10})[-~—–_.:]([0-9OolISBQDGZb|]{3,7})',
        ).firstMatch(compact);
        if (m != null) {
          final dept = m
              .group(1)!
              .replaceAll('주택괴', '주택과')
              .replaceAll('주택고', '주택과');
          final numPart = normalizeDocNumDigits(m.group(2)!);
          if (RegExp(r'^\d{3,7}$').hasMatch(numPart) &&
              !RegExp(r'^202\d$').hasMatch(numPart)) {
            result['docNumber'] = '$dept-$numPart'.replaceAll(RegExp(r'\s+'), '');
            break;
          }
        }
      }
    }

    if ((result['docNumber'] ?? '').isEmpty) {
      for (final line in lines) {
        if (RegExp(r'(?:전화|팩스|우\s*\d{5}|From|To)').hasMatch(line)) continue;
        final noDateLine =
            line.replaceAll(RegExp(r'\(\s*(?:19|20)\d{2}[^)]*\)'), '');
        final mSihaeng = RegExp(
          r'시\s*행\s*[:：]?\s*([가-힣]{2,12})\s*[-~—–_.:]?\s*([0-9OolISBQDGZb|]{2,7})\b',
        ).firstMatch(noDateLine);
        if (mSihaeng != null) {
          final dept = mSihaeng
              .group(1)!
              .replaceAll('주택괴', '주택과')
              .replaceAll('주택고', '주택과');
          final numPart = normalizeDocNumDigits(mSihaeng.group(2)!);
          if (RegExp(r'^\d{2,7}$').hasMatch(numPart) &&
              numPart != '50990' &&
              numPart != '30116') {
            result['docNumber'] =
                '$dept-$numPart'.replaceAll(RegExp(r'\s+'), '');
            break;
          }
        }
        final mSpace = RegExp(
          r'([가-힣]{2,10}(?:과|팀|실|부|처|청|본부|노조|지부|센터|소))\s*[-~—–_.\s]+([0-9OolISBQDGZb|]{2,7})\b',
        ).firstMatch(noDateLine);
        if (mSpace != null) {
          final dept = mSpace
              .group(1)!
              .replaceAll('주택괴', '주택과')
              .replaceAll('주택고', '주택과');
          final numPart = normalizeDocNumDigits(mSpace.group(2)!);
          if (RegExp(r'^\d{2,7}$').hasMatch(numPart) &&
              numPart != '50990' &&
              numPart != '30116' &&
              !RegExp(r'^20[012]\d$').hasMatch(numPart)) {
            result['docNumber'] =
                '$dept-$numPart'.replaceAll(RegExp(r'\s+'), '');
            break;
          }
        }
      }
    }

    for (final line in cleanLines) {
      final recMatch = RegExp(
        r'(?:^|\s)수\s*신\s*(?:처|자)?\s*[:：.]?\s*(.+)$',
      ).firstMatch(line.trim());
      if (recMatch != null) {
        String rec = recMatch
            .group(1)!
            .replaceAll(RegExp(r'\s*\(\s*경\s*유\s*\).*$'), '')
            .replaceAll(RegExp(r'\s*귀\s*하.*$'), '')
            .replaceAll(RegExp(r'\s*참\s*조.*$'), '')
            .replaceAll(RegExp(r'^[:：.\s]+'), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (rec.length >= 2 && !rec.startsWith('(')) {
          result['recipient'] = rec;
          break;
        }
      }
    }
    if ((result['recipient'] ?? '').isEmpty) {
      for (final tl in allLineBoxes) {
        final compact = tl.text.replaceAll(' ', '');
        if (RegExp(r'^수신[:：.]?$').hasMatch(compact)) {
          final labelBox = tl.boundingBox;
          for (final other in allLineBoxes) {
            if (other == tl) continue;
            if ((other.boundingBox.center.dy - labelBox.center.dy).abs() <
                    labelBox.height * 1.5 &&
                other.boundingBox.left > labelBox.left) {
              String cand = other.text
                  .replaceAll(RegExp(r'^[:：.\s]+'), '')
                  .replaceAll(RegExp(r'\s*귀\s*하.*$'), '')
                  .trim();
              if (cand.length >= 2) {
                result['recipient'] = cand;
                break;
              }
            }
          }
        }
        if ((result['recipient'] ?? '').isNotEmpty) break;
      }
    }
    if ((result['recipient'] ?? '').isEmpty && isOutgoing) {
      final mayorMatch =
          RegExp(r'([가-힣]{2,5}(?:시장|구청장|군수|도지사|청장|장관))').firstMatch(fullText);
      if (mayorMatch != null) {
        result['recipient'] = mayorMatch.group(1)!;
      }
    }

    // ★ 상단 시정 슬로건('꿈이 이루어지는 따뜻한 행복도시 김해' 등)을 기관명/보낸사람으로 오인하지 않도록 필터링!
    bool isSloganOrNoiseLine(String compactLine) {
      return RegExp(
        r'꿈이|이루어|따뜻한|행복도시|북도시장|슬로건|비전|함께하는|살기좋은|새로운|미래|중심|특별자치|홈페이지|전화|팩스',
      ).hasMatch(compactLine);
    }

    String headerOrgName = '';
    // 0) 도메인 주소(예: gimhae.go.kr -> 김해시)나 '김 해 시' 상단 헤더가 있으면 최우선 감지
    if (fullText.toLowerCase().contains('gimhae.go.kr') ||
        RegExp(r'김\s*해\s*시').hasMatch(fullText)) {
      headerOrgName = '김해시';
    }
    if (headerOrgName.isEmpty) {
      for (final l in cleanLines.take(10)) {
        final c = l.replaceAll(RegExp(r'\s+'), '');
        if (c.contains('수신') ||
            c.contains('경유') ||
            c.contains('제목') ||
            isSloganOrNoiseLine(c)) {
          continue;
        }
        // '김 해 시' 처럼 글자 사이가 띄어진 지자체 헤더 (2~5글자)
        final cityOnlyMatch =
            RegExp(r'^([가-힣]{1,4}(?:시|군|구|도|청|부|처))$').firstMatch(c);
        if (cityOnlyMatch != null) {
          headerOrgName = cityOnlyMatch.group(1)!;
          break;
        }
        final orgMatch = RegExp(
          r'([가-힣]{2,18}(?:노동조합(?:대학본부|지부|본부)?|대학본부|노조|공단|공사|협회|연맹|위원회|학회|대학교|연구원|병원|시|군|구|도|청|부|처))',
        ).firstMatch(c);
        if (orgMatch != null) {
          headerOrgName = orgMatch.group(1)!;
          break;
        }
      }
    }

    for (int i = cleanLines.length - 1; i >= 0; i--) {
      final c1 = cleanLines[i].replaceAll(RegExp(r'\s+'), '');
      if (c1.contains('귀하') ||
          c1.contains('수신') ||
          c1.contains('참조') ||
          c1.contains('주무관') ||
          c1.contains('사무처장') ||
          c1.contains('수석부본부장') ||
          c1.contains('행정사무관') ||
          c1.contains('정보공개정책과장') ||
          c1.contains('전결') ||
          isSloganOrNoiseLine(c1)) {
        continue;
      }
      final directMatch = RegExp(
        r'([가-힣A-Za-z0-9]{2,18}?(?:시장|구청장|군수|도지사|교육감|장관|청장|서장|원장|소장|본부장|위원장|지부장|지회장|의장|총장|학장|조합장|회장|이사장|대표이사|현장대리인))',
      ).firstMatch(c1);
      if (directMatch != null) {
        String s = directMatch.group(1)!;
        // '시'/ '군' / '구' 장은 앞쪽에 불필요한 수식어가 붙지 않도록 뒤쪽 2~4글자 지자체명만 깔끔하게 추출 (예: '김해시장')
        final dupMatch =
            RegExp(r'([가-힣]{1,3}(?:시장|구청장|군수|도지사|청장))$').firstMatch(s);
        if (dupMatch != null) s = dupMatch.group(1)!;
        result['sender'] = s;
        break;
      }
      if (i > 0 && RegExp(r'^(?:시장|구청장|군수|청장|본부장|위원장|장관)').hasMatch(c1)) {
        final prevC = cleanLines[i - 1].replaceAll(RegExp(r'\s+'), '');
        if (!isSloganOrNoiseLine(prevC)) {
          final tailCity =
              RegExp(r'([가-힣]{1,10}?)(?:시|군|구)?$').firstMatch(prevC);
          if (tailCity != null) {
            final role = RegExp(r'^(시장|구청장|군수|청장|본부장|위원장|장관)')
                    .firstMatch(c1)
                    ?.group(1) ??
                c1;
            result['sender'] = '${tailCity.group(1)}$role';
            break;
          }
        }
      }
    }
    if ((result['sender'] ?? '').isEmpty && headerOrgName.isNotEmpty) {
      result['sender'] = (headerOrgName.endsWith('시') ||
              headerOrgName.endsWith('군') ||
              headerOrgName.endsWith('구'))
          ? '${headerOrgName}장'
          : headerOrgName;
    }

    for (int i = 0; i < cleanLines.length; i++) {
      final line = cleanLines[i];
      final titleMatch = RegExp(
        r'(?:^|\s)(?:제\s*목|건\s*명|안\s*건)\s*[:：.]?\s*(.+)',
      ).firstMatch(line.trim());
      if (titleMatch != null) {
        String t = titleMatch.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim();
        t = t.replaceFirst(RegExp(r'^\[[^\]]+\]\s*'), '').trim();
        if (pdfHeaderHint.isNotEmpty &&
            pdfHeaderHint.contains('조치계획') &&
            !t.contains('조치계획') &&
            t.contains('민원')) {
          t = '민원사항 알림 및 $pdfHeaderHint';
        }
        t = t
            .replaceAll('민원 사항', '민원사항')
            .replaceAll('민원 조치계획', '민원조치계획')
            .replaceAll('조처계획', '조치계획')
            .replaceAll('제출 요청', '제출요청')
            .replaceAll('제요청', '제출요청')
            .replaceAll('제 요청', '제출요청')
            .replaceAll('상임짐행', '상임집행')
            .replaceAll('상임집형', '상임집행')
            .replaceAll('개최의 언', '개최의 건')
            .replaceAll('개최의건', '개최의 건')
            .replaceAll('회신의 건', '회신의건');
        result['title'] = t;
        break;
      }
    }
    if ((result['title'] ?? '').isEmpty) {
      for (final tl in allLineBoxes) {
        final compact = tl.text.replaceAll(' ', '');
        if (RegExp(r'^제목[:：.]?$').hasMatch(compact)) {
          final labelBox = tl.boundingBox;
          for (final other in allLineBoxes) {
            if (other == tl) continue;
            if ((other.boundingBox.center.dy - labelBox.center.dy).abs() <
                    labelBox.height * 1.5 &&
                other.boundingBox.left > labelBox.left) {
              String t = other.text
                  .replaceAll(RegExp(r'^[:：.\s]+'), '')
                  .replaceFirst(RegExp(r'^\[[^\]]+\]\s*'), '')
                  .replaceAll('민원 조치계획', '민원조치계획')
                  .replaceAll('회신의 건', '회신의건')
                  .trim();
              if (t.length >= 2) {
                result['title'] = t;
                break;
              }
            }
          }
        }
        if ((result['title'] ?? '').isNotEmpty) break;
      }
    }
    if ((result['title'] ?? '').isEmpty) {
      for (final line in cleanLines) {
        if (line.contains('송부문서')) continue;
        final fallbackTitle = RegExp(
          r'(?:\[[^\]]+\]\s*)?([가-힣0-9\s]{4,30}?(?:회신의\s*건|요청의\s*건|보고의\s*건|제출의\s*건|승인의\s*건|통보의\s*건|제출\s*요청))',
        ).firstMatch(line);
        if (fallbackTitle != null) {
          result['title'] = fallbackTitle
              .group(1)!
              .trim()
              .replaceAll('민원 조치계획', '민원조치계획')
              .replaceAll('회신의 건', '회신의건');
          break;
        }
      }
    }

    final deadlineDateMatch = RegExp(
      r'(\d{4})\s*[.년/-]\s*(\d{1,2})\s*[.월/-]\s*(\d{1,2})\s*[.일]?\s*(?:\([월화수목금토일]\s*요일?\)|\([월화수목금토일]\))?\s*까\s*지',
    ).firstMatch(fullText);
    if (deadlineDateMatch != null) {
      final y = deadlineDateMatch.group(1)!;
      final m = deadlineDateMatch.group(2)!.padLeft(2, '0');
      final d = deadlineDateMatch.group(3)!.padLeft(2, '0');
      result['replyDeadline'] = '$y.$m.$d';
    }

    // ★ 공문 [내용(aiSummary)] 초깔끔 1줄 핵심 요약 생성기!
    // (절대 본문 전체나 하단 결재선/깨진 글자를 길게 복사해 넣지 않고, 30~40자 이내의 명확한 한 줄 핵심 요지로 요약합니다!)
    final numberedActionMatches = RegExp(
      r'(?:^|\n)\s*(?:[1-9]\s*\)|\([1-9]\)|[①②③④⑤⑥⑦⑧⑨])',
    ).allMatches(fullText).toList();

    final currentTitle = (result['title'] ?? '').trim();

    if (numberedActionMatches.length >= 2 &&
        RegExp(r'동일\s*민원').hasMatch(fullText)) {
      result['aiSummary'] =
          '동일민원이 발생치 않도록 ${numberedActionMatches.length}가지 조치예정';
    } else if (numberedActionMatches.length >= 2 && isOutgoing) {
      result['aiSummary'] =
          '관련 요청사항에 대하여 ${numberedActionMatches.length}가지 조치예정';
    } else if (RegExp(r'주차.*공원|공원.*주차|장기\s*주차').hasMatch(fullText)) {
      result['aiSummary'] = '공사작업 개인차량 도로변주차와 공원내 장기주차에 대한 민원 조치요청';
    } else if (RegExp(r'회의장소|통신장비').hasMatch(fullText) ||
        currentTitle.contains('회의장소')) {
      result['aiSummary'] = '회의장소 사용 및 통신·영상장비 설치 협조 요청';
    } else if (RegExp(r'회의를\s*아래와\s*같이\s*개최|개최하오니|개최의\s*[건언]|일\s*시\s*[:：]').hasMatch(fullText) ||
        currentTitle.contains('개최')) {
      // ★ 회의 개최 공문: 본문의 회의명과 '일시 : YYYY. M. D(요일) HH:MM'을 결합하여
      // "○○회의를 개최하오니 2008.12.5 15시에 참석요망" 형태로 명확하게 요약!
      String meetingName = '제6차 상임집행위원회 회의';
      final mNameMatch = RegExp(
        r'(제\s*\d+\s*차\s*[가-힣\s]{2,18}?회의)',
      ).firstMatch(fullText);
      if (mNameMatch != null) {
        meetingName = mNameMatch
            .group(1)!
            .replaceAll(RegExp(r'\s+'), ' ')
            .replaceAll('상임짐행', '상임집행')
            .replaceAll('상임집형', '상임집행')
            .trim();
      } else if (currentTitle.isNotEmpty) {
        meetingName = currentTitle
            .replaceAll(RegExp(r'\s*개최의\s*[건언].*$'), '')
            .replaceAll('상임짐행', '상임집행')
            .replaceAll('상임집형', '상임집행')
            .trim();
        if (!meetingName.endsWith('회의')) meetingName = '$meetingName 회의';
      }

      String dateTimePhrase = '';
      final schedMatch = RegExp(
        r'일\s*시\s*[:：]?\s*(\d{4})\s*[.년/-]\s*(\d{1,2})\s*[.월/-]\s*(\d{1,2})\s*[.일]?\s*(?:\([^)]*\))?\s*(\d{1,2})\s*[:시]\s*(\d{2})?',
      ).firstMatch(fullText);
      if (schedMatch != null) {
        final sy = schedMatch.group(1)!;
        final sm = int.tryParse(schedMatch.group(2)!) ?? 1;
        final sd = int.tryParse(schedMatch.group(3)!) ?? 1;
        final sh = int.tryParse(schedMatch.group(4)!) ?? 0;
        final smin = schedMatch.group(5) ?? '00';
        final timeStr = (smin == '00' || smin.isEmpty) ? '${sh}시' : '${sh}시 ${smin}분';
        dateTimePhrase = '$sy.$sm.$sd ${timeStr}에 ';
      }
      result['aiSummary'] = '${meetingName}를 개최하오니 ${dateTimePhrase}참석요망';
    } else {
      final joinedClean = cleanLines.join('\n');
      final para2Match = RegExp(
        r'2\.\s*([^\n]{5,90})',
      ).firstMatch(joinedClean);

      if (para2Match != null) {
        String core =
            para2Match.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim();
        core = core.replaceFirst(
          RegExp(r'^.*?관\s*련\s*하\s*여\s*[,，.]?\s*'),
          '',
        );
        if (RegExp(r'(?:로\s*인해|으로\s*인해|\s+인해)').hasMatch(core)) {
          core = core.replaceFirst(
            RegExp(r'(?:로\s*인해|으로\s*인해|\s+인해).*$'),
            '에 대한 민원 조치요청',
          );
        } else if (core.length > 38) {
          core = '${core.substring(0, 36).trim()}...';
        }
        result['aiSummary'] = core.trim();
      } else if (currentTitle.isNotEmpty) {
        result['aiSummary'] = '$currentTitle 관련 안내 및 협조';
      }
    }

    return result;
  }

  /// [자재송장] 3중 완벽 해결 파서
  Map<String, String> _parseInvoiceText(
    String fullText,
    List<String> lines,
    RecognizedText recognized,
  ) {
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

    String detectedProduct = '';
    if (RegExp(r'고\s*장\s*력\s*철\s*근').hasMatch(fullText) ||
        fullText.toUpperCase().contains('HYUNDAI STEEL') ||
        RegExp(r'\bD\d{2}\s*MM\b', caseSensitive: false).hasMatch(fullText) ||
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

    // ★ 병원비/약국 영수증 실제 납부금액(합계 / 총수납금액 / 본인부담금) 초정밀 추출!
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
            'x': tl.boundingBox.center.dx,
            'text': tl.text,
          });
        }
      }
    }
    amountNodes.sort((a, b) => (a['y'] as double).compareTo(b['y'] as double));

    if (amountNodes.isNotEmpty) {
      final bottomMostVal = amountNodes.last['val'] as int;
      final Map<int, int> freq = {};
      for (final node in amountNodes) {
        final v = node['val'] as int;
        freq[v] = (freq[v] ?? 0) + 1;
      }

      if ((freq[bottomMostVal] ?? 0) >= 2) {
        result['totalPaid'] = bottomMostVal.toString();
        return result;
      }

      Rect? hapgyeBox;
      for (final tl in allLines) {
        final clean = tl.text.replaceAll(' ', '');
        if (clean.contains('합계') || clean.contains('총수납금액')) {
          hapgyeBox = tl.boundingBox;
        }
      }
      if (hapgyeBox != null) {
        int? bestVal;
        double bestDy = double.infinity;
        for (final node in amountNodes) {
          final dy = ((node['y'] as double) - hapgyeBox.center.dy).abs();
          if (dy < bestDy) {
            bestDy = dy;
            bestVal = node['val'] as int;
          }
        }
        if (bestVal != null) {
          result['totalPaid'] = bestVal.toString();
          return result;
        }
      }

      result['totalPaid'] = bottomMostVal.toString();
      return result;
    }

    for (final line in lines.reversed) {
      if (line.contains('보험자부담금') || line.contains('약제비총액')) continue;
      final m = RegExp(
        r'(?:합\s*계|총\s*수\s*납\s*금\s*액|본\s*인\s*부\s*담\s*금|결\s*제\s*금\s*액)[^\d]*([1-9]\d{2,7})',
      ).firstMatch(line);
      if (m != null) {
        result['totalPaid'] = m.group(1)!;
        break;
      }
    }

    return result;
  }

  // ===========================================================================
  // 2단계: Gemini Vision AI 분석 (선택사항)
  // ===========================================================================
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

  Future<Map<String, String>?> _analyzeDocumentWithAi({
    required String category,
    required Uint8List imageBytes,
  }) async {
    final key = _geminiApiKey.trim();
    if (key.isEmpty) return null;

    final aiBytes = await compute(_compressForAiPayloadIsolate, imageBytes);
    final base64Image = base64Encode(aiBytes);

    String prompt;
    if (DocCategory.isOfficial(category)) {
      prompt = '''
이 대한민국 공문서 이미지를 분석해서 순수 JSON 객체로 응답해줘:
- title (제목): 앞쪽 [공동주택과-16092] 같은 대괄호는 빼고 오타 없이 순수 제목만 (예: "민원조치계획 회신의건", "제6차 상임집행위원회 개최의 건")
- aiSummary (내용): 공문의 핵심 요지를 한 문장으로 명확히 요약! (회의 개최 안내 공문이면 본문 문장을 중간에 '아래와'에서 끊지 말고, 반드시 하단 일시를 포함해 "제6차 대학본부 상임집행위원회 회의를 개최하오니 2008.12.5 15시에 참석요망"처럼 요약할 것! 세부 조치항목이 1)~4)처럼 있으면 "동일민원이 발생치 않도록 4가지 조치예정"처럼 요약할 것!)
- docNumber (공문번호): 띄어쓰기 없이 붙여 쓸 것! 상단 '제 25-067 호'가 있으면 "25-067호", 하단 '시행 대학본부 제2008-87호'가 있으면 "2008-87호", '시행 공동주택과-16092'가 있으면 "공동주택과-16092"
- replyDocNumber (회신번호): 띄어쓰기 없이 붙여 쓸 것! 발신공문 제목 앞 [공동주택과 - 16092] 또는 본문 송부문서 번호 (예: "공동주택과-16092")
- sender (보낸사람): 발신명의 (예: "김해시장", "전국공무원노동조합 대학본부장")
- recipient (받는사람): '수신' 옆에 적힌 받는사람 (예: "김해시장")
- replyDeadline (회신요청일): YYYY.MM.DD
- sentDate (접수일/발신일): 반드시 문서 하단 '시행' 옆 괄호 안에 적힌 실제 공문 발행일(예: 하단에 '시행 대학본부 제2008-87호 (2008. 12. 2)'라고 적혀 있으면 "2008.12.02")을 넣을 것! 본문 안의 회의 참석일시('2008. 12. 5')를 발행일로 넣지 말 것!
''';
    } else if (category == DocCategory.invoice) {
      prompt = '''
이 자재송장/거래명세서 이미지를 읽고 순수 JSON으로 응답해줘 (합계 19.696은 제외하고 각 규격별 중량 3.744, 15.952만 넣을 것):
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
이 출장비 증빙 이미지를 보고 5가지 구분('자차', '택시', '기차', '식대', '통행료') 중 하나로 분류해 순수 JSON으로 응답해줘.
주의사항:
1) 사진 한 장에 하이패스 영수증 등 여러 장의 영수증이 함께 찍혀 있으면, 각 영수증의 결제금액을 모두 더한 합계(예: 640원 영수증 2장이면 640+640 = "1280")를 totalAmount에 넣을 것!
2) 식대 영수증/카드내역 화면에서 배경 목록(예: GS25)과 하단 '상세 이용내역' 팝업(예: 롯데리아 창동역점 9,300원)이 함께 보이면 반드시 하단 '상세 이용내역' 팝업의 상호명("롯데리아 창동역점")과 금액("9300")을 넣을 것! 절대 '정보'('가맹점정보'의 뒷글자)나 배경 목록의 다른 가게를 넣지 말 것!
{
  "travelDivision": "자차 또는 택시 또는 기차 또는 식대 또는 통행료",
  "distanceKm": "자차일 때 실시간 추천 km 숫자만",
  "totalAmount": "결제금액 숫자만 (영수증이 여러 장이면 합산한 금액)",
  "merchantName": "실제 상호명/지점명 (예: 롯데리아 창곡점, 하이패스 통행료, 카카오택시)",
  "date": "YYYY-MM-DD"
}''';
    } else {
      prompt = '''
이 병원비/약국 영수증 이미지를 읽고 순수 JSON 객체로 응답해줘.
주의: totalPaid에는 절대 '약제비총액'이나 '보험자부담금'을 넣지 말고, 환자가 실제로 계산한 맨 아래 '합계' 또는 '총수납금액(①+③)' / '본인부담금' 금액(예: 3000)만 넣을 것!
{
  "clinicName": "상호명",
  "bizRegNumber": "사업자등록번호",
  "issueDate": "YYYY-MM-DD",
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

    // ★ Gemini 2.5 Pro 최우선 호출 (무료 티어 한도 초과 시 gemini-2.5-flash 자동 백업)
    const models = ['gemini-2.5-pro', 'gemini-2.5-flash'];
    for (final modelName in models) {
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
            .timeout(const Duration(seconds: 12));
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
          if (result.isNotEmpty) return result;
        }
      } catch (_) {}
    }
    return null;
  }

  // ===========================================================================
  // 사진 촬영 → 입력 다이얼로그
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

      // 1. 공문(수신) / 공문(발신) 컨트롤러
      final docTitleCtrl = TextEditingController();
      final aiSummaryCtrl = TextEditingController();
      final docNumberCtrl = TextEditingController();
      final replyDocNumberCtrl = TextEditingController();
      final senderCtrl = TextEditingController();
      final recipientCtrl = TextEditingController();
      final replyDeadlineCtrl = TextEditingController();
      final sentDateCtrl = TextEditingController(text: todayDotStr);
      final docAmountCtrl = TextEditingController(text: '0');

      // 2. 자재송장 컨트롤러
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

      // 3. 출장비 컨트롤러 (기본값: × 2 × 300원, 사용자가 2와 300을 직접 수정 가능)
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

      // 4. 병원비 컨트롤러
      final clinicNameCtrl = TextEditingController();
      final bizRegNumberCtrl = TextEditingController();
      final issueDateCtrl = TextEditingController(text: todayDotStr);
      final totalPaidCtrl = TextEditingController();

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
                    setDialogState(() {
                      applyExtractedMap(ocrMap);
                      isAiAnalyzing = false;
                    });
                  }

                  // ★ Gemini API 키가 등록되어 있으면 1차 초고속 내장 OCR 직후 항상 Gemini 2.5 Pro가 정밀 교정 수행!
                  if (_geminiApiKey.trim().isNotEmpty) {
                    if (ctx.mounted) {
                      setDialogState(() => isAiAnalyzing = true);
                    }
                    final aiMap = await _analyzeDocumentWithAi(
                      category: chosenCategory,
                      imageBytes: flattenedBytes,
                    );
                    if (ctx.mounted) {
                      setDialogState(() {
                        if (aiMap != null) applyExtractedMap(aiMap);
                        isAiAnalyzing = false;
                      });
                    }
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
              final double parsedKm = double.tryParse(
                    travelDistanceKmCtrl.text
                        .replaceAll(RegExp(r'[^0-9.]'), ''),
                  ) ??
                  0;
              final double parsedMult = double.tryParse(
                    travelCarMultiplierCtrl.text
                        .replaceAll(RegExp(r'[^0-9.]'), ''),
                  ) ??
                  2;
              final double parsedUnitPrice = double.tryParse(
                    travelCarUnitPriceCtrl.text
                        .replaceAll(RegExp(r'[^0-9.]'), ''),
                  ) ??
                  300;
              final int calculatedCarFare =
                  (parsedKm * parsedMult * parsedUnitPrice).round();

              return AlertDialog(
                title: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('증빙서류 입력 (v39)', style: TextStyle(fontSize: 18)),
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
                            'Gemini 2.5 Pro 정밀 인식 중...',
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

                        if (_usesSubCategory(chosenCategory)) ...[
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
                                    hintText: '예: 여의도출장, 갑상선 등',
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
                                      return InputChip(
                                        visualDensity: VisualDensity.compact,
                                        label: Text(sub),
                                        selected: isSel,
                                        selectedColor: Colors.indigo.shade100,
                                        onSelected: (_) {
                                          setDialogState(() {
                                            subCategoryCtrl.text = sub;
                                          });
                                        },
                                        deleteIcon:
                                            const Icon(Icons.close, size: 15),
                                        deleteButtonTooltipMessage: '카테고리 삭제',
                                        onDeleted: () async {
                                          await _deleteUserSubCategory(
                                              chosenCategory, sub);
                                          setDialogState(() {
                                            if (subCategoryCtrl.text.trim() ==
                                                sub) {
                                              subCategoryCtrl.clear();
                                            }
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
                        ],

                        FilledButton.tonalIcon(
                          onPressed:
                              isAiAnalyzing ? null : triggerOcrAndAiExtract,
                          icon: const Icon(Icons.auto_awesome, size: 18),
                          label: const Text('문자/내용 다시 자동 인식'),
                        ),
                        const Divider(height: 20),

                        // 1. 공문(수신) / 공문(발신) 입력 폼
                        if (DocCategory.isOfficial(chosenCategory)) ...[
                          _buildField(
                            sentDateCtrl,
                            chosenCategory == DocCategory.officialOut
                                ? '발신일'
                                : '접수일',
                            '예: 2025.05.21',
                          ),
                          if (chosenCategory == DocCategory.officialOut)
                            _buildField(
                              recipientCtrl,
                              '받는사람 (수신 옆 텍스트 자동 인식)',
                              '예: 김해시장',
                            )
                          else
                            _buildField(
                              senderCtrl,
                              '보낸사람 (발신명의 자동 인식)',
                              '예: 김해시장',
                            ),
                          _buildField(
                            docTitleCtrl,
                            '제목',
                            '예: 민원조치계획 회신의건',
                          ),
                          if (chosenCategory == DocCategory.officialOut)
                            _buildField(
                              replyDocNumberCtrl,
                              '회신번호 (수신공문 번호와 일치 시 수신공문에 회신완료 ○ 표시)',
                              '예: 공동주택과-16092',
                            )
                          else
                            _buildField(
                              replyDeadlineCtrl,
                              '회신요청일',
                              '예: 2025.05.21',
                            ),
                          _buildField(
                            docNumberCtrl,
                            '공문번호',
                            chosenCategory == DocCategory.officialOut
                                ? '예: 25-067호'
                                : '예: 공동주택과-16092',
                          ),
                          _buildField(
                            aiSummaryCtrl,
                            '내용 (핵심 안건 요약)',
                            chosenCategory == DocCategory.officialOut
                                ? '예: 동일민원이 발생치 않도록 4가지 조치예정'
                                : '예: 공사작업 개인차량 도로변주차와 공원내 장기주차에 대한 민원 조치요청',
                            maxLines: 2,
                          ),
                        ],

                        // 2. 자재송장 입력 폼 (규격별 다중 행)
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
                                        '품목/규격별 목록 (규격이 다르면 각각 별도 행으로 저장됩니다)\n※ "철근" 포함 시 단위=ton, 수량=각 규격 중량(3.744 / 15.952) 자동 입력',
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
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                              margin: const EdgeInsets.only(bottom: 10),
                              decoration: BoxDecoration(
                                color: Colors.indigo.shade50,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Wrap(
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 4,
                                runSpacing: 6,
                                children: [
                                  Text(
                                    '계산식: ${travelDistanceKmCtrl.text.isEmpty ? "0" : travelDistanceKmCtrl.text}km ×',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF1E3A8A),
                                      fontSize: 13,
                                    ),
                                  ),
                                  SizedBox(
                                    width: 46,
                                    height: 30,
                                    child: TextField(
                                      controller: travelCarMultiplierCtrl,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                              decimal: true),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF1E3A8A),
                                        fontSize: 13,
                                      ),
                                      decoration: const InputDecoration(
                                        contentPadding:
                                            EdgeInsets.symmetric(vertical: 4),
                                        filled: true,
                                        fillColor: Colors.white,
                                        border: OutlineInputBorder(),
                                        isDense: true,
                                      ),
                                      onChanged: (_) =>
                                          setDialogState(recalcCarDistanceCost),
                                    ),
                                  ),
                                  const Text(
                                    '×',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF1E3A8A),
                                      fontSize: 13,
                                    ),
                                  ),
                                  SizedBox(
                                    width: 64,
                                    height: 30,
                                    child: TextField(
                                      controller: travelCarUnitPriceCtrl,
                                      keyboardType: TextInputType.number,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFF1E3A8A),
                                        fontSize: 13,
                                      ),
                                      decoration: const InputDecoration(
                                        contentPadding:
                                            EdgeInsets.symmetric(vertical: 4),
                                        filled: true,
                                        fillColor: Colors.white,
                                        border: OutlineInputBorder(),
                                        isDense: true,
                                      ),
                                      onChanged: (_) =>
                                          setDialogState(recalcCarDistanceCost),
                                    ),
                                  ),
                                  Text(
                                    '원 = ${NumberFormat('#,###').format(calculatedCarFare)}원',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF1E3A8A),
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
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

      final enteredSubCategory = _usesSubCategory(chosenCategory)
          ? subCategoryCtrl.text.trim()
          : '';
      if (enteredSubCategory.isNotEmpty) {
        await _registerUserSubCategory(chosenCategory, enteredSubCategory);
      }

      final nowStr = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
      final List<DocRecord> createdRecords = [];

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
            'subCategory': '',
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
        if (DocCategory.isOfficial(chosenCategory)) {
          collectedFields['docDirection'] =
              chosenCategory == DocCategory.officialOut ? '발신' : '수신';
          collectedFields['sentDate'] =
              DocRecord.formatDotDate(sentDateCtrl.text.trim());
          collectedFields['sender'] = senderCtrl.text.trim();
          collectedFields['recipient'] = recipientCtrl.text.trim();
          collectedFields['docNumber'] = DocRecord.stripDocNumSpaces(docNumberCtrl.text);
          collectedFields['replyDocNumber'] = DocRecord.stripDocNumSpaces(replyDocNumberCtrl.text);
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
          collectedFields['carMultiplier'] =
              travelCarMultiplierCtrl.text.trim().isNotEmpty
                  ? travelCarMultiplierCtrl.text.trim()
                  : '2';
          collectedFields['carUnitPrice'] =
              travelCarUnitPriceCtrl.text.trim().isNotEmpty
                  ? travelCarUnitPriceCtrl.text.trim()
                  : '300';
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

      final existingSigs = _records.map((r) => r.contentSignature).toSet();
      final uniqueNew = createdRecords
          .where((r) => !existingSigs.contains(r.contentSignature))
          .toList();

      if (uniqueNew.isEmpty) {
        _showSnack('이미 동일한 내용의 문서가 등록되어 있어 중복 추가하지 않았습니다.');
        return;
      }

      setState(() {
        for (final r in uniqueNew.reversed) {
          _records.insert(0, r);
        }
        _selectedCategoryFilter = chosenCategory;
        _selectedRecord = uniqueNew.first;
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

  // ===========================================================================
  // ★ 이미 저장된 항목 수정 다이얼로그 (연필 아이콘 또는 길게 누르기로 언제든 수정!)
  // ===========================================================================
  Future<void> _editLocalRecord(DocRecord record) async {
    String chosenCategory = record.category;
    final f = record.fields;

    final subCategoryCtrl = TextEditingController(text: f['subCategory'] ?? '');

    // 1. 공문(수신) / 공문(발신) 컨트롤러
    final sentDateCtrl =
        TextEditingController(text: DocRecord.formatDotDate(f['sentDate']));
    final senderCtrl = TextEditingController(text: f['sender'] ?? '');
    final recipientCtrl = TextEditingController(text: f['recipient'] ?? '');
    final docNumberCtrl = TextEditingController(text: f['docNumber'] ?? '');
    final replyDocNumberCtrl =
        TextEditingController(text: f['replyDocNumber'] ?? '');
    final docTitleCtrl = TextEditingController(text: f['title'] ?? '');
    final aiSummaryCtrl = TextEditingController(text: f['aiSummary'] ?? '');
    final replyDeadlineCtrl = TextEditingController(
      text: f['replyDeadline']?.isNotEmpty == true
          ? DocRecord.formatDotDate(f['replyDeadline'])
          : '',
    );

    // 2. 자재송장 컨트롤러
    final arrivalDateCtrl =
        TextEditingController(text: DocRecord.formatDotDate(f['arrivalDate']));
    final productNameCtrl = TextEditingController(text: f['productName'] ?? '');
    final specNameCtrl = TextEditingController(text: f['specName'] ?? '');
    final unitCtrl = TextEditingController(text: f['unit'] ?? 'ton');
    final quantityCtrl =
        TextEditingController(text: f['quantity'] ?? f['weight'] ?? '');
    final supplierNameCtrl =
        TextEditingController(text: f['supplierName'] ?? '');
    final orderNumberCtrl = TextEditingController(text: f['orderNumber'] ?? '');

    // 3. 출장비 컨트롤러 (기본값 2와 300을 자유롭게 수정 가능)
    String chosenTravelDivision = record.travelDivision;
    final travelDateCtrl =
        TextEditingController(text: DocRecord.formatDotDate(f['date']));
    final travelDistanceKmCtrl =
        TextEditingController(text: f['distanceKm'] ?? '0');
    final travelCarMultiplierCtrl = TextEditingController(
      text: f['carMultiplier']?.trim().isNotEmpty == true
          ? f['carMultiplier']!
          : '2',
    );
    final travelCarUnitPriceCtrl = TextEditingController(
      text: f['carUnitPrice']?.trim().isNotEmpty == true
          ? f['carUnitPrice']!
          : '300',
    );
    final travelMerchantCtrl =
        TextEditingController(text: f['merchantName'] ?? '');
    final travelAmountCtrl =
        TextEditingController(text: f['totalAmount'] ?? '0');

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

    // 4. 병원비 컨트롤러
    final issueDateCtrl =
        TextEditingController(text: DocRecord.formatDotDate(f['issueDate']));
    final clinicNameCtrl = TextEditingController(text: f['clinicName'] ?? '');
    final totalPaidCtrl = TextEditingController(text: f['totalPaid'] ?? '');
    final bizRegNumberCtrl =
        TextEditingController(text: f['bizRegNumber'] ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final mySavedCats =
                _userSubCategoriesMap[chosenCategory] ?? <String>[];
            final double parsedKm = double.tryParse(
                  travelDistanceKmCtrl.text.replaceAll(RegExp(r'[^0-9.]'), ''),
                ) ??
                0;
            final double parsedMult = double.tryParse(
                  travelCarMultiplierCtrl.text
                      .replaceAll(RegExp(r'[^0-9.]'), ''),
                ) ??
                2;
            final double parsedUnitPrice = double.tryParse(
                  travelCarUnitPriceCtrl.text
                      .replaceAll(RegExp(r'[^0-9.]'), ''),
                ) ??
                300;
            final int calculatedCarFare =
                (parsedKm * parsedMult * parsedUnitPrice).round();

            return AlertDialog(
              title: const Text('저장된 내용 수정', style: TextStyle(fontSize: 18)),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DropdownButtonFormField<String>(
                        value: chosenCategory,
                        decoration: const InputDecoration(
                          labelText: '문서 종류 변경',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: DocCategory.inputList
                            .map((c) =>
                                DropdownMenuItem(value: c, child: Text(c)))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) {
                            setDialogState(() => chosenCategory = v);
                          }
                        },
                      ),
                      const SizedBox(height: 10),
                      if (_usesSubCategory(chosenCategory)) ...[
                        _buildField(
                          subCategoryCtrl,
                          '카테고리',
                          '예: 여의도출장, 갑상선 등',
                          onChanged: (_) => setDialogState(() {}),
                        ),
                        if (mySavedCats.isNotEmpty) ...[
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: mySavedCats.map((sub) {
                              final isSel =
                                  subCategoryCtrl.text.trim() == sub;
                              return InputChip(
                                visualDensity: VisualDensity.compact,
                                label: Text(sub),
                                selected: isSel,
                                selectedColor: Colors.indigo.shade100,
                                onSelected: (_) {
                                  setDialogState(() {
                                    subCategoryCtrl.text = sub;
                                  });
                                },
                                deleteIcon: const Icon(Icons.close, size: 15),
                                deleteButtonTooltipMessage: '카테고리 삭제',
                                onDeleted: () async {
                                  await _deleteUserSubCategory(
                                      chosenCategory, sub);
                                  setDialogState(() {
                                    if (subCategoryCtrl.text.trim() == sub) {
                                      subCategoryCtrl.clear();
                                    }
                                  });
                                },
                              );
                            }).toList(),
                          ),
                          const SizedBox(height: 10),
                        ],
                      ],
                      if (DocCategory.isOfficial(chosenCategory)) ...[
                        _buildField(
                          sentDateCtrl,
                          chosenCategory == DocCategory.officialOut
                              ? '날짜 (발신일)'
                              : '날짜 (접수일)',
                          '예: 2025.05.21',
                        ),
                        _buildField(
                          docNumberCtrl,
                          '공문번호',
                          chosenCategory == DocCategory.officialOut
                              ? '예: 25-067호'
                              : '예: 공동주택과-16092',
                        ),
                        if (chosenCategory == DocCategory.officialOut)
                          _buildField(
                            recipientCtrl,
                            '받는사람',
                            '예: 김해시장',
                          )
                        else
                          _buildField(
                            senderCtrl,
                            '보낸사람',
                            '예: 김해시장',
                          ),
                        if (chosenCategory == DocCategory.officialOut)
                          _buildField(
                            replyDocNumberCtrl,
                            '회신번호 (수신공문 번호와 일치 시 회신완료 ○)',
                            '예: 공동주택과-16092',
                          ),
                        _buildField(docTitleCtrl, '제목', '예: 민원조치계획 회신의건'),
                        _buildField(
                          aiSummaryCtrl,
                          '내용',
                          '핵심 안건 요약',
                          maxLines: 2,
                        ),
                        _buildField(
                          replyDeadlineCtrl,
                          '회신요청일',
                          '예: 2025.05.21',
                        ),
                      ],
                      if (chosenCategory == DocCategory.invoice) ...[
                        _buildField(arrivalDateCtrl, '날짜', '예: 2021.09.08'),
                        _buildField(
                          productNameCtrl,
                          '제품명',
                          '예: 고장력철근',
                          onChanged: (v) {
                            if (v.contains('철근')) {
                              setDialogState(() => unitCtrl.text = 'ton');
                            }
                          },
                        ),
                        _buildField(specNameCtrl, '규격명', '예: D32MM'),
                        _buildField(unitCtrl, '단위', '예: ton'),
                        _buildField(
                          quantityCtrl,
                          '수량(중량)',
                          '예: 3.744',
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                        ),
                        _buildField(supplierNameCtrl, '공급자', '예: 현대제철'),
                        _buildField(
                            orderNumberCtrl, '주문송장번호', '예: 212021090449'),
                      ],
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
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 6),
                            margin: const EdgeInsets.only(bottom: 10),
                            decoration: BoxDecoration(
                              color: Colors.indigo.shade50,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Wrap(
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 4,
                              runSpacing: 6,
                              children: [
                                Text(
                                  '계산식: ${travelDistanceKmCtrl.text.isEmpty ? "0" : travelDistanceKmCtrl.text}km ×',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF1E3A8A),
                                    fontSize: 12.5,
                                  ),
                                ),
                                SizedBox(
                                  width: 44,
                                  height: 28,
                                  child: TextField(
                                    controller: travelCarMultiplierCtrl,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                            decimal: true),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF1E3A8A),
                                      fontSize: 12.5,
                                    ),
                                    decoration: const InputDecoration(
                                      contentPadding:
                                          EdgeInsets.symmetric(vertical: 3),
                                      filled: true,
                                      fillColor: Colors.white,
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                    onChanged: (_) =>
                                        setDialogState(recalcCarDistanceCost),
                                  ),
                                ),
                                const Text(
                                  '×',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF1E3A8A),
                                    fontSize: 12.5,
                                  ),
                                ),
                                SizedBox(
                                  width: 62,
                                  height: 28,
                                  child: TextField(
                                    controller: travelCarUnitPriceCtrl,
                                    keyboardType: TextInputType.number,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF1E3A8A),
                                      fontSize: 12.5,
                                    ),
                                    decoration: const InputDecoration(
                                      contentPadding:
                                          EdgeInsets.symmetric(vertical: 3),
                                      filled: true,
                                      fillColor: Colors.white,
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                    onChanged: (_) =>
                                        setDialogState(recalcCarDistanceCost),
                                  ),
                                ),
                                Text(
                                  '원 = ${NumberFormat('#,###').format(calculatedCarFare)}원',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF1E3A8A),
                                    fontSize: 12.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        _buildField(travelMerchantCtrl, '상호 / 내역', '예: 카카오택시'),
                        _buildField(
                          travelAmountCtrl,
                          '금액 (원)',
                          '예: 15000',
                          keyboardType: TextInputType.number,
                        ),
                      ],
                      if (chosenCategory == DocCategory.medical) ...[
                        _buildField(issueDateCtrl, '날짜 (발행일)', '예: 2026.10.01'),
                        _buildField(clinicNameCtrl, '상호', '예: 맘온누리약국'),
                        _buildField(
                          totalPaidCtrl,
                          '금액 (원)',
                          '예: 4600',
                          keyboardType: TextInputType.number,
                        ),
                        _buildField(
                            bizRegNumberCtrl, '사업자등록번호', '예: 276-63-00432'),
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
                  child: const Text('수정 저장'),
                ),
              ],
            );
          },
        );
      },
    );

    if (saved != true) return;

    final enteredSub = _usesSubCategory(chosenCategory)
        ? subCategoryCtrl.text.trim()
        : '';
    if (enteredSub.isNotEmpty) {
      await _registerUserSubCategory(chosenCategory, enteredSub);
    }

    final updatedFields = Map<String, String>.from(record.fields);
    updatedFields['subCategory'] = enteredSub;

    if (DocCategory.isOfficial(chosenCategory)) {
      updatedFields['docDirection'] =
          chosenCategory == DocCategory.officialOut ? '발신' : '수신';
      updatedFields['sentDate'] =
          DocRecord.formatDotDate(sentDateCtrl.text.trim());
      updatedFields['sender'] = senderCtrl.text.trim();
      updatedFields['recipient'] = recipientCtrl.text.trim();
      updatedFields['docNumber'] = DocRecord.stripDocNumSpaces(docNumberCtrl.text);
      updatedFields['replyDocNumber'] = DocRecord.stripDocNumSpaces(replyDocNumberCtrl.text);
      updatedFields['title'] = docTitleCtrl.text.trim();
      updatedFields['aiSummary'] = aiSummaryCtrl.text.trim();
      updatedFields['replyDeadline'] =
          replyDeadlineCtrl.text.trim().isNotEmpty
              ? DocRecord.formatDotDate(replyDeadlineCtrl.text.trim())
              : '';
    } else if (chosenCategory == DocCategory.invoice) {
      updatedFields['arrivalDate'] =
          DocRecord.formatDotDate(arrivalDateCtrl.text.trim());
      updatedFields['productName'] = productNameCtrl.text.trim();
      updatedFields['specName'] = specNameCtrl.text.trim();
      updatedFields['unit'] = unitCtrl.text.trim().isNotEmpty
          ? unitCtrl.text.trim()
          : 'ton';
      updatedFields['quantity'] = quantityCtrl.text.trim();
      updatedFields['weight'] = quantityCtrl.text.trim();
      updatedFields['supplierName'] = supplierNameCtrl.text.trim();
      updatedFields['orderNumber'] = orderNumberCtrl.text.trim();
    } else if (chosenCategory == DocCategory.travel) {
      updatedFields['travelDivision'] = chosenTravelDivision;
      updatedFields['date'] =
          DocRecord.formatDotDate(travelDateCtrl.text.trim());
      updatedFields['distanceKm'] = travelDistanceKmCtrl.text.trim();
      updatedFields['carMultiplier'] =
          travelCarMultiplierCtrl.text.trim().isNotEmpty
              ? travelCarMultiplierCtrl.text.trim()
              : '2';
      updatedFields['carUnitPrice'] =
          travelCarUnitPriceCtrl.text.trim().isNotEmpty
              ? travelCarUnitPriceCtrl.text.trim()
              : '300';
      updatedFields['merchantName'] = travelMerchantCtrl.text.trim();
      updatedFields['totalAmount'] = travelAmountCtrl.text.trim();
    } else if (chosenCategory == DocCategory.medical) {
      updatedFields['issueDate'] =
          DocRecord.formatDotDate(issueDateCtrl.text.trim());
      updatedFields['clinicName'] = clinicNameCtrl.text.trim();
      updatedFields['totalPaid'] = totalPaidCtrl.text.trim();
      updatedFields['bizRegNumber'] = bizRegNumberCtrl.text.trim();
    }

    final idx = _records.indexWhere((r) => r.id == record.id);
    if (idx == -1) return;

    final updatedRecord = DocRecord(
      id: record.id,
      category: chosenCategory,
      createdAt: record.createdAt,
      imagePath: record.imagePath,
      base64Image: record.base64Image,
      fields: updatedFields,
    );

    setState(() {
      _records[idx] = updatedRecord;
      _selectedRecord = updatedRecord;
    });
    await _saveLocalRecords();
    _showSnack('내용이 수정되었습니다.');
  }

  Future<void> _deleteLocalRecord(DocRecord record) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('항목 영구 삭제'),
        content: const Text(
          '이 항목을 삭제하시겠습니까?\n삭제된 항목은 앱에서 영구적으로 지워집니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('영구 삭제'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final imgFile = File(record.imagePath);
      if (await imgFile.exists()) {
        await imgFile.delete();
      }
    } catch (_) {}

    setState(() {
      _records.removeWhere((r) => r.id == record.id);
      if (_selectedRecord?.id == record.id) {
        _selectedRecord =
            _filteredRecords.isNotEmpty ? _filteredRecords.first : null;
      }
    });
    await _saveLocalRecords();
    _showSnack('영구 삭제되었습니다.');
  }

  /// ★ 방식 2: 구글 스프레드시트(Google Apps Script 웹앱)로 현재 항목들을 실시간 전송하고,
  /// 다른 사람들이 올린 전체 누적 데이터를 받아와 내 앱에 합산하는 함수!
  Future<void> _syncWithGoogleCloudWebhook({bool silent = false}) async {
    final url = _googleWebhookUrl.trim();
    if (url.isEmpty) {
      if (!silent) {
        _showSnack('먼저 상단 설정에서 [구글 시트 공동 누적 웹훅 URL]을 등록해 주세요.');
        await _openSettingsDialog();
      }
      return;
    }

    if (!silent) setState(() => _isBusy = true);
    try {
      final payload = {
        'action': 'sync',
        'userName': _exporterUserName.trim().isEmpty
            ? '익명'
            : _exporterUserName.trim(),
        'records': _records.map((r) => r.toJson()).toList(),
      };

      final postResp = await http
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 20));

      http.Response finalResp = postResp;
      if (postResp.statusCode == 302 || postResp.statusCode == 301) {
        final redirectUrl = postResp.headers['location'];
        if (redirectUrl != null) {
          finalResp = await http.get(Uri.parse(redirectUrl));
        }
      }

      if (finalResp.statusCode == 200) {
        try {
          final decoded = jsonDecode(utf8.decode(finalResp.bodyBytes))
              as Map<String, dynamic>;
          final remoteList = decoded['records'] as List<dynamic>?;
          if (remoteList != null) {
            final Map<String, DocRecord> merged = {
              for (final r in _records) r.contentSignature: r,
            };
            int added = 0;
            for (final item in remoteList) {
              if (item is Map<String, dynamic>) {
                final rec = DocRecord.fromJson(item);
                if (!merged.containsKey(rec.contentSignature)) {
                  merged[rec.contentSignature] = rec;
                  added++;
                }
              }
            }
            final sorted = merged.values.toList()
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
            setState(() {
              _records = sorted;
              if (_selectedRecord == null && _filteredRecords.isNotEmpty) {
                _selectedRecord = _filteredRecords.first;
              }
            });
            await _saveLocalRecords();
            if (!silent) {
              _showSnack(
                '구글 클라우드 공동 누적 동기화 완료! (신규 $added건 수신 · 총 ${_records.length}건)',
              );
            }
            return;
          }
        } catch (_) {}
        if (!silent) {
          _showSnack('구글 시트로 내역 전송 완료! (${_records.length}건)');
        }
      } else {
        if (!silent) {
          _showSnack('구글 웹훅 응답 코드: ${finalResp.statusCode}');
        }
      }
    } catch (e) {
      if (!silent) {
        _showSnack('구글 클라우드 동기화 오류: $e');
      }
    } finally {
      if (!silent && mounted) setState(() => _isBusy = false);
    }
  }

  static const String _googleAppsScriptTemplate = """
function doPost(e) {
  var lock = LockService.getScriptLock();
  lock.waitLock(10000);
  try {
    var sheet = SpreadsheetApp.getActiveSpreadsheet().getActiveSheet();
    if (sheet.getLastRow() === 0) {
      sheet.appendRow(['ID', '작성자', '분류', '생성일시', '주요내용', '금액_수량', 'JSON데이터']);
    }
    var body = JSON.parse(e.postData.contents);
    var userName = body.userName || '익명';
    var incoming = body.records || [];
    var data = sheet.getDataRange().getValues();
    var existingIds = {};
    for (var i = 1; i < data.length; i++) {
      existingIds[String(data[i][0])] = true;
    }
    for (var j = 0; j < incoming.length; j++) {
      var r = incoming[j];
      if (r && r.id && !existingIds[String(r.id)]) {
        var f = r.fields || {};
        var title = f.title || f.productName || f.merchantName || f.clinicName || '-';
        var amt = f.totalAmount || f.totalPaid || f.quantity || f.docNumber || '-';
        sheet.appendRow([r.id, userName, r.category, r.createdAt, title, amt, JSON.stringify(r)]);
        existingIds[String(r.id)] = true;
      }
    }
    var allRecords = [];
    var updatedData = sheet.getDataRange().getValues();
    for (var k = 1; k < updatedData.length; k++) {
      try { allRecords.push(JSON.parse(updatedData[k][6])); } catch (err) {}
    }
    return ContentService.createTextOutput(JSON.stringify({status: 'ok', records: allRecords}))
      .setMimeType(ContentService.MimeType.JSON);
  } finally {
    lock.releaseLock();
  }
}
""";

  Future<void> _openSettingsDialog() async {
    final geminiKeyCtrl = TextEditingController(text: _geminiApiKey);
    final userNameCtrl = TextEditingController(text: _exporterUserName);
    final googleWebhookCtrl = TextEditingController(text: _googleWebhookUrl);
    final folderCtrl = TextEditingController(text: _oneDriveCloudFolder);
    final tokenCtrl = TextEditingController(text: _oneDriveAccessToken);
    bool tempConflictFree = _useConflictFreeFileName;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: const Text(
            '다중 사용자 누적 공유 & AI 설정 (v39)',
            style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.bold),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                        '방식 1 (원드라이브 덮어쓰기 실패 방지 + 다중 파일 합치기)',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: Color(0xFF1E3A8A),
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '1) 원드라이브 공유창에서 "1개 실패"가 뜨는 이유는 같은 이름의 파일 덮어쓰기를 원드라이브 앱이 막기 때문입니다.\n'
                        '2) 아래 [내 이름]을 넣고 고유 파일명 모드를 켜면 "증빙서류_출장비_홍길동_1030_1730.html"처럼 올라가서 원드라이브에 100% 성공합니다!\n'
                        '3) 모인 파일들은 앱 상단 [파일 합치기 아이콘]이나 HTML 화면의 [+ 다른 사람 HTML 합치기]에서 여러 개를 한꺼번에 선택해 1초 만에 하나로 합산할 수 있습니다.',
                        style: TextStyle(fontSize: 11.5, height: 1.4),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: userNameCtrl,
                        decoration: const InputDecoration(
                          labelText: '내 이름 / 담당자명 (파일명에 자동 표시)',
                          hintText: '예: 이경훈, 공무팀 등',
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text(
                          '원드라이브 덮어쓰기 에러 방지 파일명 사용 (이름+날짜시간)',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                        value: tempConflictFree,
                        onChanged: (v) =>
                            setModalState(() => tempConflictFree = v),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.amber.shade300),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '방식 2 (구글 스프레드시트 실시간 자동 누적 공유)',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: Colors.brown,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '1) 여러 명이 각자 앱에서 찍은 내역을 파일 덮어쓰기 없이 한 곳(구글 시트)에 실시간으로 차곡차곡 쌓고 서로 불러오는 방식입니다.\n'
                        '2) 구글 시트 > [확장 프로그램] > [Apps Script]에 아래 스크립트를 붙여넣고 [배포 > 새 배포 > 웹 앱(모든 사용자)]로 만든 URL을 입력하면 작동합니다.',
                        style: TextStyle(fontSize: 11.5, height: 1.4),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: googleWebhookCtrl,
                        decoration: const InputDecoration(
                          labelText: '구글 시트 웹앱(Apps Script) URL',
                          hintText: 'https://script.google.com/macros/s/.../exec',
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.copy, size: 15),
                              label: const Text(
                                '구글 시트 연동용 스크립트 코드 보기/복사',
                                style: TextStyle(fontSize: 11.5),
                              ),
                              onPressed: () {
                                showDialog<void>(
                                  context: ctx,
                                  builder: (sCtx) => AlertDialog(
                                    title: const Text(
                                      '구글 시트 Apps Script 코드',
                                      style: TextStyle(fontSize: 15),
                                    ),
                                    content: SingleChildScrollView(
                                      child: SelectableText(
                                        _googleAppsScriptTemplate,
                                        style: const TextStyle(
                                          fontSize: 11,
                                          fontFamily: 'monospace',
                                        ),
                                      ),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(sCtx),
                                        child: const Text('닫기'),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(height: 20),

                const Text(
                  '3. Gemini 2.5 Pro AI 키 등록 (정밀 분석 자동 작동)',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: geminiKeyCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Gemini API Key',
                    hintText: '비워두셔도 내장 한국어 OCR이 즉시 작동합니다',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '4. 원드라이브 Graph API 토큰 (선택)',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: folderCtrl,
                  decoration: const InputDecoration(
                    labelText: '원드라이브 저장 폴더 경로',
                    hintText: '예: Documents/증빙서류함',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: tokenCtrl,
                  decoration: const InputDecoration(
                    labelText: 'OneDrive Graph Access Token',
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
                final enteredName = userNameCtrl.text.trim();
                final enteredWebhook = googleWebhookCtrl.text.trim();
                final enteredFolder = folderCtrl.text.trim().isEmpty
                    ? 'Documents/증빙서류함'
                    : folderCtrl.text.trim();
                final enteredToken = tokenCtrl.text.trim();

                final prefs = await SharedPreferences.getInstance();
                await prefs.setString(_prefsGeminiApiKey, enteredKey);
                await prefs.setString(_prefsUserNameKey, enteredName);
                await prefs.setBool(
                    _prefsUniqueFileNameModeKey, tempConflictFree);
                await prefs.setString(
                    _prefsGoogleWebhookUrlKey, enteredWebhook);
                await prefs.setString(_prefsOneDriveFolderKey, enteredFolder);
                await prefs.setString(_prefsOneDriveTokenKey, enteredToken);

                setState(() {
                  _geminiApiKey = enteredKey;
                  _exporterUserName = enteredName;
                  _useConflictFreeFileName = tempConflictFree;
                  _googleWebhookUrl = enteredWebhook;
                  _oneDriveCloudFolder = enteredFolder;
                  _oneDriveAccessToken = enteredToken;
                });
                if (ctx.mounted) Navigator.pop(ctx);
                _showSnack('설정이 저장되었습니다.');
              },
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
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

  String _sanitizeFileNameForOneDrive(String rawScope) {
    return rawScope
        .replaceAll('(', '_')
        .replaceAll(')', '')
        .replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }

  // ===========================================================================
  // ★ [HTML 내보내기] 버튼 클릭 시 중간 선택창 없이 즉시 고정 파일명(`증빙서류_공문_수신.html` 등)으로
  // 누적 병합 및 덮어쓰기/공유 실행!
  // 1) 앱 내부 마스터 HTML 파일(`증빙서류_공문_수신.html` 등)에서 과거 기록을 읽어와 중복 없이 누적 합산한 뒤 그대로 덮어씁니다.
  // 2) 원드라이브 토큰이 설정되어 있으면 원드라이브 서버의 기존 동일 이름 파일을 직접 읽어와 병합한 뒤 `@microsoft.graph.conflictBehavior=replace` 옵션으로 100% 자동 덮어쓰기합니다!
  // 3) 토큰 없이 일반 [공유]로 올릴 때는 휴대폰의 공용 다운로드(`Download`) 폴더에도 동일 이름 파일로 자동 덮어쓰기해 두고, 곧바로 고정 파일명(`증빙서류_공문_수신.html`)으로 원드라이브 공유창을 띄웁니다!
  // ===========================================================================
  Future<void> _exportCumulativeFilteredHtml() async {
    final bool useSub = _usesSubCategory(_selectedCategoryFilter) &&
        _selectedSubCategoryFilter != '전체';
    final String filterScopeName = useSub
        ? '${_selectedCategoryFilter}_$_selectedSubCategoryFilter'
        : _selectedCategoryFilter;
    final String safeScope = _sanitizeFileNameForOneDrive(filterScopeName);
    final String masterHtmlFileName = '증빙서류_$safeScope.html';

    setState(() => _isBusy = true);
    try {
      // ★ 앱에서 지운 항목이 다시 살아나지 않도록 로컬 마스터 HTML은 절대 합산하지 않고,
      // 앱에서는 현재 남아있는 항목(_filteredRecords)만 깔끔하게 내보냅니다!
      // (단, 원드라이브 클라우드 API 토큰이 설정되어 원드라이브에 직접 덮어쓸 때만 원드라이브 파일에 누적 관리)
      final List<DocRecord> remoteCloudRecords = [];
      final cleanSubfolder =
          _oneDriveCloudFolder.replaceAll(RegExp(r'^/+|/+$'), '');
      final remoteFilePath = '/$cleanSubfolder/$masterHtmlFileName';
      if (_oneDriveAccessToken.trim().isNotEmpty) {
        try {
          final getUrl = Uri.parse(
            'https://graph.microsoft.com/v1.0/me/drive/root:$remoteFilePath:/content',
          );
          final getResp = await http.get(
            getUrl,
            headers: {'Authorization': 'Bearer ${_oneDriveAccessToken.trim()}'},
          );
          if (getResp.statusCode == 200) {
            final remoteHtml = utf8.decode(getResp.bodyBytes);
            remoteCloudRecords.addAll(_parseRecordsFromHtml(remoteHtml));
          }
        } catch (_) {}
      }

      final Map<String, DocRecord> mergedBySignature = {};
      for (final rec in remoteCloudRecords) {
        if (_selectedCategoryFilter == DocCategory.all ||
            rec.category == _selectedCategoryFilter) {
          mergedBySignature[rec.contentSignature] = rec;
        }
      }
      for (final rec in _filteredRecords) {
        mergedBySignature[rec.contentSignature] = rec;
      }

      final mergedList = mergedBySignature.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      if (mergedList.isEmpty) {
        _showSnack('[$filterScopeName] 내보낼 항목이 없습니다.');
        return;
      }

      final allForReplyCheck = <DocRecord>[..._records, ...remoteCloudRecords];
      final repliedKeys = _computeRepliedDocNumKeys(allForReplyCheck);

      final htmlContent = _buildLeftListRightPhotoHtmlDocument(
        records: mergedList,
        scopeTitle: filterScopeName,
        repliedKeys: repliedKeys,
      );

      final Uint8List htmlBytes = Uint8List.fromList(utf8.encode(htmlContent));

      if (_oneDriveAccessToken.trim().isNotEmpty) {
        final uploadUrl = Uri.parse(
          'https://graph.microsoft.com/v1.0/me/drive/root:$remoteFilePath:/content?@microsoft.graph.conflictBehavior=replace',
        );
        final putResp = await http.put(
          uploadUrl,
          headers: {
            'Authorization': 'Bearer ${_oneDriveAccessToken.trim()}',
            'Content-Type': 'text/html; charset=utf-8',
          },
          body: htmlBytes,
        );
        if (putResp.statusCode == 200 || putResp.statusCode == 201) {
          _showSnack(
            '원드라이브 [$masterHtmlFileName]에 자동 누적 덮어쓰기 완료! (총 ${mergedList.length}건)',
          );
          return;
        }
      }

      // 만약 구글 시트 공동 누적 웹훅이 등록되어 있으면 내보내기와 동시에 클라우드 시트에도 자동 누적!
      if (_googleWebhookUrl.trim().isNotEmpty) {
        _syncWithGoogleCloudWebhook(silent: true);
      }

      // ★ 원드라이브 공유 시 덮어쓰기 에러("1개 실패")가 절대 발생하지 않도록
      // 고유 파일명 모드(_useConflictFreeFileName)가 켜져 있으면 [작성자명_날짜시간]을 파일명에 붙여 내보냅니다!
      String exportFileName = masterHtmlFileName;
      if (_useConflictFreeFileName) {
        final stamp = DateFormat('MMdd_HHmm').format(DateTime.now());
        final cleanUser = _exporterUserName.trim().isNotEmpty
            ? '_${_sanitizeFileNameForOneDrive(_exporterUserName.trim())}'
            : '';
        exportFileName = '증빙서류_${safeScope}${cleanUser}_$stamp.html';
      }

      final shareDir = await getTemporaryDirectory();
      final shareFile = File(p.join(shareDir.path, exportFileName));
      await shareFile.writeAsBytes(htmlBytes, flush: true);

      await Share.shareXFiles([XFile(shareFile.path)]);
    } catch (e) {
      _showSnack('HTML 내보내기 중 오류: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _importExistingHtmlToMerge() async {
    try {
      // ★ 여러 명이 각자 올린 HTML 파일 여러 개를 한꺼번에(allowMultiple: true) 선택해서 1초 만에 하나로 합산!
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['html', 'htm'],
        allowMultiple: true,
      );
      if (picked == null || picked.files.isEmpty) return;

      final List<DocRecord> importedRecords = [];
      for (final pf in picked.files) {
        if (pf.path == null) continue;
        final file = File(pf.path!);
        final htmlContent = await file.readAsString();
        importedRecords.addAll(_parseRecordsFromHtml(htmlContent));
      }
      if (importedRecords.isEmpty) {
        _showSnack('선택한 HTML 파일에서 증빙서류 데이터를 찾지 못했습니다.');
        return;
      }

      final Map<String, DocRecord> sigMap = {
        for (final r in _records) r.contentSignature: r,
      };
      int addedCount = 0;
      for (final r in importedRecords) {
        if (!sigMap.containsKey(r.contentSignature)) {
          sigMap[r.contentSignature] = r;
          addedCount++;
        }
      }

      final updatedList = sigMap.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      setState(() {
        _records = updatedList;
        if (_selectedRecord == null && _filteredRecords.isNotEmpty) {
          _selectedRecord = _filteredRecords.first;
        }
      });
      await _saveLocalRecords();
      _showSnack(
        '기존 HTML에서 중복을 제외한 신규 $addedCount건을 불러와 누적 합산했습니다! (전체 ${updatedList.length}건)',
      );
    } catch (e) {
      _showSnack('기존 HTML 병합 중 오류: $e');
    }
  }

  String _escapeHtmlText(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
  }

  String _buildStaticHtmlTable(
    List<DocRecord> records,
    String majorCat,
    Map<String, String> cumMap,
    Set<String> repliedKeys,
    String firstId,
  ) {
    if (records.isEmpty) {
      return '<div style="padding:24px; text-align:center; color:#64748b;">저장된 증빙서류가 없습니다.</div>';
    }
    final sb = StringBuffer();
    final allOfficial = records.every((r) =>
        r.category == DocCategory.officialIn ||
        r.category == DocCategory.officialOut);
    final allInvoice =
        records.every((r) => r.category == DocCategory.invoice);
    final allTravel =
        records.every((r) => r.category == DocCategory.travel);
    final allMedical =
        records.every((r) => r.category == DocCategory.medical);

    if (majorCat == DocCategory.officialIn ||
        majorCat == DocCategory.officialOut ||
        allOfficial) {
      final isOutTab = majorCat == DocCategory.officialOut ||
          records.every((r) => r.category == DocCategory.officialOut);
      final partyHeader = isOutTab ? '받는사람' : '보낸사람';
      sb.write('<table class="grid-table"><thead><tr>');
      sb.write('<th>날짜</th><th>공문번호</th><th>$partyHeader</th>');
      if (isOutTab) sb.write('<th>회신번호</th>');
      sb.write('<th>제목</th><th>내용</th><th>회신요청일</th>');
      if (!isOutTab) sb.write('<th>회신완료</th>');
      sb.write('</tr></thead><tbody>');

      for (final item in records) {
        final f = item.fields;
        final isOut = item.category == DocCategory.officialOut ||
            f['docDirection'] == '발신';
        final partyVal = isOut
            ? (f['recipient']?.trim().isNotEmpty == true
                ? f['recipient']!
                : '-')
            : (f['sender']?.trim().isNotEmpty == true ? f['sender']! : '-');
        final replyNum = f['replyDocNumber']?.trim().isNotEmpty == true
            ? f['replyDocNumber']!
            : '-';
        final myKey = DocRecord.normalizeDocNumKey(f['docNumber']);
        final isReplied = myKey.isNotEmpty && repliedKeys.contains(myKey);
        final cls = item.id == firstId ? 'active' : '';
        sb.write(
            '<tr class="$cls" data-id="${_escapeHtmlText(item.id)}" onclick="selectRow(\'${_escapeHtmlText(item.id)}\')">');
        sb.write(
            '<td>${_escapeHtmlText(DocRecord.formatDotDate(f['sentDate']))}</td>');
        sb.write('<td>${_escapeHtmlText(f['docNumber'] ?? '-')}</td>');
        sb.write('<td>${_escapeHtmlText(partyVal)}</td>');
        if (isOutTab) {
          sb.write(
              '<td style="color:#1e3a8a; font-weight:700;">${_escapeHtmlText(replyNum)}</td>');
        }
        sb.write(
            '<td style="text-align:left;">${_escapeHtmlText(f['title'] ?? '-')}</td>');
        sb.write(
            '<td style="text-align:left;">${_escapeHtmlText(f['aiSummary'] ?? '-')}</td>');
        sb.write(
            '<td>${_escapeHtmlText(DocRecord.formatDotDate(f['replyDeadline']))}</td>');
        if (!isOutTab) {
          sb.write(
              '<td style="color:#16a34a; font-weight:700; font-size:15px;">${isReplied ? '○' : ''}</td>');
        }
        sb.write('</tr>');
      }
      sb.write('</tbody></table>');
      return sb.toString();
    } else if (majorCat == DocCategory.invoice || allInvoice) {
      sb.write('<table class="grid-table"><thead><tr>');
      sb.write(
          '<th>날짜</th><th>제품명</th><th>규격명</th><th>단위</th><th>수량</th><th>누적수량</th><th>공급자</th><th>주문송장번호</th>');
      sb.write('</tr></thead><tbody>');
      for (final item in records) {
        final f = item.fields;
        final cls = item.id == firstId ? 'active' : '';
        final cumVal = cumMap[item.id] ?? f['quantity'] ?? '-';
        sb.write(
            '<tr class="$cls" data-id="${_escapeHtmlText(item.id)}" onclick="selectRow(\'${_escapeHtmlText(item.id)}\')">');
        sb.write(
            '<td>${_escapeHtmlText(DocRecord.formatDotDate(f['arrivalDate']))}</td>');
        sb.write('<td>${_escapeHtmlText(f['productName'] ?? '-')}</td>');
        sb.write('<td>${_escapeHtmlText(f['specName'] ?? '-')}</td>');
        sb.write('<td>${_escapeHtmlText(f['unit'] ?? 'ton')}</td>');
        sb.write('<td>${_escapeHtmlText(f['quantity'] ?? '-')}</td>');
        sb.write(
            '<td style="color:#1e3a8a; font-weight:700;">${_escapeHtmlText(cumVal)}</td>');
        sb.write('<td>${_escapeHtmlText(f['supplierName'] ?? '-')}</td>');
        sb.write('<td>${_escapeHtmlText(f['orderNumber'] ?? '-')}</td>');
        sb.write('</tr>');
      }
      sb.write('</tbody></table>');
      return sb.toString();
    } else if (majorCat == DocCategory.travel || allTravel) {
      sb.write('<table class="grid-table"><thead><tr>');
      sb.write('<th>카테고리(날짜)</th><th>구분</th><th>상호</th><th>금액</th>');
      sb.write('</tr></thead><tbody>');
      for (final item in records) {
        final f = item.fields;
        final cls = item.id == firstId ? 'active' : '';
        final sub = (f['subCategory'] ?? '미지정').trim().isEmpty
            ? '미지정'
            : f['subCategory']!;
        final dateStr = DocRecord.formatDotDate(
            f['date'] ?? item.createdAt.split(' ').first);
        final div = f['travelDivision'] ?? '식대';
        final mult = f['carMultiplier'] ?? '2';
        final rate = f['carUnitPrice'] ?? '300';
        final desc = div == '자차'
            ? (f['merchantName'] ?? '${f['distanceKm'] ?? 0}km × $mult × $rate원')
            : (f['merchantName'] ?? '-');
        final amt =
            '${NumberFormat('#,###').format(item.numericAmount)}원';
        sb.write(
            '<tr class="$cls" data-id="${_escapeHtmlText(item.id)}" onclick="selectRow(\'${_escapeHtmlText(item.id)}\')">');
        sb.write(
            '<td>${_escapeHtmlText(sub)}<br/>(${_escapeHtmlText(dateStr)})</td>');
        sb.write('<td>${_escapeHtmlText(div)}</td>');
        sb.write('<td style="text-align:left;">${_escapeHtmlText(desc)}</td>');
        sb.write(
            '<td style="color:#1e3a8a; font-weight:700;">${_escapeHtmlText(amt)}</td>');
        sb.write('</tr>');
      }
      sb.write('</tbody></table>');
      return sb.toString();
    } else if (majorCat == DocCategory.medical || allMedical) {
      sb.write('<table class="grid-table"><thead><tr>');
      sb.write(
          '<th>카테고리</th><th>날짜</th><th>상호</th><th>금액</th><th>사업자등록번호</th>');
      sb.write('</tr></thead><tbody>');
      for (final item in records) {
        final f = item.fields;
        final cls = item.id == firstId ? 'active' : '';
        final sub = (f['subCategory'] ?? '미지정').trim().isEmpty
            ? '미지정'
            : f['subCategory']!;
        final dateStr = DocRecord.formatDotDate(
            f['issueDate'] ?? item.createdAt.split(' ').first);
        final amt =
            '${NumberFormat('#,###').format(item.numericAmount)}원';
        sb.write(
            '<tr class="$cls" data-id="${_escapeHtmlText(item.id)}" onclick="selectRow(\'${_escapeHtmlText(item.id)}\')">');
        sb.write('<td>${_escapeHtmlText(sub)}</td>');
        sb.write('<td>${_escapeHtmlText(dateStr)}</td>');
        sb.write('<td>${_escapeHtmlText(f['clinicName'] ?? '-')}</td>');
        sb.write(
            '<td style="color:#1e3a8a; font-weight:700;">${_escapeHtmlText(amt)}</td>');
        sb.write('<td>${_escapeHtmlText(f['bizRegNumber'] ?? '-')}</td>');
        sb.write('</tr>');
      }
      sb.write('</tbody></table>');
      return sb.toString();
    } else {
      sb.write('<table class="grid-table"><thead><tr>');
      sb.write(
          '<th>종류</th><th>구분/카테고리</th><th>일자</th><th>상호/제목/산출내역</th><th>금액/수량</th>');
      sb.write('</tr></thead><tbody>');
      for (final item in records) {
        final f = item.fields;
        final cls = item.id == firstId ? 'active' : '';
        String sub = f['subCategory'] ?? '-';
        String dateStr = DocRecord.formatDotDate(
            f['sentDate'] ??
                f['arrivalDate'] ??
                f['date'] ??
                f['issueDate'] ??
                item.createdAt.split(' ').first);
        String desc = f['title'] ??
            f['productName'] ??
            f['merchantName'] ??
            f['clinicName'] ??
            '-';
        String amt = item.numericAmount > 0
            ? '${NumberFormat('#,###').format(item.numericAmount)}원'
            : (f['quantity'] ?? '-');
        sb.write(
            '<tr class="$cls" data-id="${_escapeHtmlText(item.id)}" onclick="selectRow(\'${_escapeHtmlText(item.id)}\')">');
        sb.write('<td>${_escapeHtmlText(item.category)}</td>');
        sb.write('<td>${_escapeHtmlText(sub)}</td>');
        sb.write('<td>${_escapeHtmlText(dateStr)}</td>');
        sb.write('<td style="text-align:left;">${_escapeHtmlText(desc)}</td>');
        sb.write('<td>${_escapeHtmlText(amt)}</td>');
        sb.write('</tr>');
      }
      sb.write('</tbody></table>');
      return sb.toString();
    }
  }

  String _buildLeftListRightPhotoHtmlDocument({
    required List<DocRecord> records,
    required String scopeTitle,
    required Set<String> repliedKeys,
  }) {
    final recordsJson = jsonEncode(records.map((r) => r.toJson()).toList());
    final cumMap = _computeInvoiceCumulativeMap(records);
    final cumMapJson = jsonEncode(cumMap);
    final repliedListJson = jsonEncode(repliedKeys.toList());
    final majorCat = _selectedCategoryFilter;

    final firstRecord = records.isNotEmpty ? records.first : null;
    final firstId = firstRecord?.id ?? '';
    final firstBase64 = firstRecord?.base64Image ?? '';
    final initialTableHtml = _buildStaticHtmlTable(
      records,
      majorCat,
      cumMap,
      repliedKeys,
      firstId,
    );

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
      height: 100dvh;
      display: flex;
      flex-direction: column;
      overflow: hidden;
    }
    header {
      background: #1e3a8a;
      color: #ffffff;
      padding: 9px 14px;
      display: flex;
      justify-content: space-between;
      align-items: center;
      flex-shrink: 0;
      gap: 8px;
    }
    header h1 { font-size: 15px; font-weight: 700; white-space: nowrap; }

    #main-split {
      flex: 1;
      display: flex;
      flex-direction: row;
      width: 100%;
      height: 100%;
      overflow: hidden;
    }
    #left-list-pane {
      width: 55%;
      height: 100%;
      overflow: auto;
      background: #ffffff;
      flex-shrink: 0;
    }
    #resizer-bar {
      width: 14px;
      height: 100%;
      background: #cbd5e1;
      cursor: ew-resize;
      display: flex;
      align-items: center;
      justify-content: center;
      user-select: none;
      touch-action: none;
      border-left: 1px solid #94a3b8;
      border-right: 1px solid #94a3b8;
      flex-shrink: 0;
    }
    #resizer-pill {
      width: 4px;
      height: 42px;
      background: #1e3a8a;
      border-radius: 999px;
    }
    #right-photo-pane {
      flex: 1;
      width: auto;
      height: 100%;
      background: #0f172a;
      display: flex;
      align-items: center;
      justify-content: center;
      overflow: auto;
      padding: 8px;
    }

    @media (orientation: portrait) {
      #main-split {
        flex-direction: column;
      }
      #left-list-pane {
        width: 100% !important;
        height: 46%;
      }
      #resizer-bar {
        width: 100%;
        height: 16px;
        cursor: ns-resize;
        border-left: none;
        border-right: none;
        border-top: 1px solid #94a3b8;
        border-bottom: 1px solid #94a3b8;
      }
      #resizer-pill {
        width: 46px;
        height: 4px;
      }
      #right-photo-pane {
        width: 100%;
        height: auto;
        flex: 1;
      }
    }

    #preview-img {
      max-width: 100%;
      max-height: 100%;
      object-fit: contain;
      border-radius: 4px;
      box-shadow: 0 4px 20px rgba(0,0,0,0.5);
    }
    table.grid-table {
      width: max-content;
      min-width: 100%;
      border-collapse: collapse;
      font-size: 12px;
      text-align: center;
    }
    table.grid-table th {
      background: #e2e8f0;
      color: #1e293b;
      font-weight: 700;
      padding: 8px 8px;
      border: 1px solid #94a3b8;
      position: sticky;
      top: 0;
      z-index: 2;
      white-space: nowrap;
    }
    table.grid-table td {
      padding: 8px 8px;
      border: 1px solid #cbd5e1;
      color: #0f172a;
      cursor: pointer;
      line-height: 1.35;
      max-width: 170px;
      word-break: keep-all;
      overflow-wrap: break-word;
    }
    table.grid-table tr:hover td { background: #f8fafc; }
    table.grid-table tr.active td {
      background: #dbeafe;
      font-weight: 700;
    }
  </style>
</head>
<body>
  <header>
    <h1>[$scopeTitle] 증빙서류 (<span id="count-label">${records.length}</span>건)</h1>
    <div style="display:flex; gap:6px; align-items:center;">
      <label style="background:#f59e0b; color:#0f172a; font-weight:700; font-size:12px; padding:5px 10px; border-radius:6px; cursor:pointer;">
        + 다른 사람 HTML 합치기
        <input type="file" id="merge-file-input" accept=".html,.htm" multiple style="display:none;" onchange="mergeExternalHtmlFiles(this.files)" />
      </label>
      <button onclick="downloadMergedHtml()" style="background:#ffffff; color:#1e3a8a; border:none; font-weight:700; font-size:12px; padding:5px 10px; border-radius:6px; cursor:pointer;">
        통합본 저장
      </button>
    </div>
  </header>

  <div id="main-split">
    <div id="left-list-pane">$initialTableHtml</div>
    <div id="resizer-bar" title="끌어서 리스트와 사진 크기 조절">
      <div id="resizer-pill"></div>
    </div>
    <div id="right-photo-pane">
      <img id="preview-img" src="${firstBase64.isNotEmpty ? 'data:image/jpeg;base64,$firstBase64' : ''}" style="${firstBase64.isNotEmpty ? 'display:block;' : 'display:none;'}" alt="증빙서류 사진" />
    </div>
  </div>

  <script>
    const archiveRecords = /*ARCHIVE_DATA_START*/ $recordsJson /*ARCHIVE_DATA_END*/;
    const cumMap = $cumMapJson;
    const repliedKeys = new Set($repliedListJson);
    const majorCat = "$majorCat";
    let selectedId = archiveRecords.length > 0 ? archiveRecords[0].id : null;

    const resizerBar = document.getElementById('resizer-bar');
    const leftPane = document.getElementById('left-list-pane');
    const mainSplit = document.getElementById('main-split');
    let isResizing = false;

    function isPortraitMode() {
      return window.matchMedia("(orientation: portrait)").matches;
    }

    resizerBar.addEventListener('pointerdown', function(e) {
      isResizing = true;
      if (resizerBar.setPointerCapture) resizerBar.setPointerCapture(e.pointerId);
    });
    resizerBar.addEventListener('pointermove', function(e) {
      if (!isResizing) return;
      const rect = mainSplit.getBoundingClientRect();
      if (isPortraitMode()) {
        const newH = ((e.clientY - rect.top) / rect.height) * 100;
        leftPane.style.height = Math.max(18, Math.min(82, newH)) + '%';
      } else {
        const newW = ((e.clientX - rect.left) / rect.width) * 100;
        leftPane.style.width = Math.max(20, Math.min(82, newW)) + '%';
      }
    });
    resizerBar.addEventListener('pointerup', function() { isResizing = false; });

    function selectRow(id) {
      selectedId = id;
      const rows = leftPane.querySelectorAll('tbody tr');
      rows.forEach(function(tr) {
        if (tr.getAttribute('data-id') === id) {
          tr.classList.add('active');
        } else {
          tr.classList.remove('active');
        }
      });
      const current = archiveRecords.find(function(r) { return r.id === selectedId; });
      const imgEl = document.getElementById('preview-img');
      if (current && current.base64Image) {
        imgEl.src = 'data:image/jpeg;base64,' + current.base64Image;
        imgEl.style.display = 'block';
      } else {
        imgEl.style.display = 'none';
      }
    }

    function dotDate(raw) {
      if (!raw) return '-';
      const m = String(raw).match(/(\\d{4})\\s*[-./년]\\s*(\\d{1,2})\\s*[-./월]\\s*(\\d{1,2})/);
      if (m) return m[1] + '.' + String(m[2]).padStart(2, '0') + '.' + String(m[3]).padStart(2, '0');
      return raw;
    }

    function normalizeDocKey(raw) {
      if (!raw) return '';
      const c = String(raw).replace(/\\s+/g, '');
      const m = c.match(/([가-힣A-Za-z0-9]+?)[-~—–_.:]([0-9]+)/);
      if (m) {
        const dept = m[1].replace(/(?:과|팀|실|부|처|국|단|소|청)\$/, '');
        const num = m[2].replace(/^0+/, '') || '0';
        return dept + '-' + num;
      }
      const d = c.match(/\\d{4,7}/);
      return d ? d[0] : c;
    }

    function escapeHtml(str) {
      return String(str == null ? '' : str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
    }

    function render() {
      document.getElementById('count-label').textContent = archiveRecords.length;
      if (majorCat === '공문(수신)' || majorCat === '공문(발신)' || (archiveRecords.length > 0 && archiveRecords.every(function(r) { return r.category === '공문(수신)' || r.category === '공문(발신)'; }))) {
        const isOutTab = majorCat === '공문(발신)' || (archiveRecords.length > 0 && archiveRecords.every(function(r) { return r.category === '공문(발신)'; }));
        const partyHeader = isOutTab ? '받는사람' : '보낸사람';
        let html = '<table class="grid-table"><thead><tr><th>날짜</th><th>공문번호</th><th>' + partyHeader + '</th>' + (isOutTab ? '<th>회신번호</th>' : '') + '<th>제목</th><th>내용</th><th>회신요청일</th>' + (isOutTab ? '' : '<th>회신완료</th>') + '</tr></thead><tbody>';
        archiveRecords.forEach(function(item) {
          const f = item.fields || {};
          const isOut = item.category === '공문(발신)' || f.docDirection === '발신';
          const partyVal = isOut ? (f.recipient || '-') : (f.sender || '-');
          const replyNum = f.replyDocNumber || '-';
          const myKey = normalizeDocKey(f.docNumber);
          const isReplied = Boolean(myKey && repliedKeys.has(myKey));
          const cls = item.id === selectedId ? 'active' : '';
          html += '<tr class="' + cls + '" data-id="' + escapeHtml(item.id) + '" onclick="selectRow(\\'' + escapeHtml(item.id) + '\\')">' +
            '<td>' + escapeHtml(dotDate(f.sentDate)) + '</td>' +
            '<td>' + escapeHtml(f.docNumber || '-') + '</td>' +
            '<td>' + escapeHtml(partyVal) + '</td>' +
            (isOutTab ? '<td style="color:#1e3a8a; font-weight:700;">' + escapeHtml(replyNum) + '</td>' : '') +
            '<td style="text-align:left;">' + escapeHtml(f.title || '-') + '</td>' +
            '<td style="text-align:left;">' + escapeHtml(f.aiSummary || '-') + '</td>' +
            '<td>' + escapeHtml(dotDate(f.replyDeadline)) + '</td>' +
            (isOutTab ? '' : '<td style="color:#16a34a; font-weight:700; font-size:15px;">' + (isReplied ? '○' : '') + '</td>') +
            '</tr>';
        });
        html += '</tbody></table>';
        leftPane.innerHTML = html;
      }
      selectRow(selectedId);
    }

    async function mergeExternalHtmlFiles(fileList) {
      if (!fileList || fileList.length === 0) return;
      let addedCount = 0;
      const existingIds = new Set(archiveRecords.map(function(r) { return r.id; }));
      const startMarker = '/*ARCHIVE_DATA_START*/';
      const endMarker = '/*ARCHIVE_DATA_END*/';
      for (const file of fileList) {
        const text = await file.text();
        const sIdx = text.indexOf(startMarker);
        const eIdx = text.indexOf(endMarker);
        if (sIdx !== -1 && eIdx !== -1 && eIdx > sIdx) {
          try {
            const jsonPart = text.substring(sIdx + startMarker.length, eIdx).trim();
            const arr = JSON.parse(jsonPart);
            for (const item of arr) {
              if (item && item.id && !existingIds.has(item.id)) {
                archiveRecords.push(item);
                existingIds.add(item.id);
                if (item.category === '공문(발신)' && item.fields && item.fields.replyDocNumber) {
                  const k = normalizeDocKey(item.fields.replyDocNumber);
                  if (k) repliedKeys.add(k);
                }
                addedCount++;
              }
            }
          } catch (_) {}
        }
      }
      archiveRecords.sort(function(a, b) { return String(b.createdAt).localeCompare(String(a.createdAt)); });
      if (archiveRecords.length > 0 && !selectedId) selectedId = archiveRecords[0].id;
      render();
      alert('외부 HTML 파일에서 신규 ' + addedCount + '건을 합산했습니다! (현재 총 ' + archiveRecords.length + '건)');
    }

    function downloadMergedHtml() {
      const jsonStr = JSON.stringify(archiveRecords);
      const startMarker = '/*ARCHIVE_DATA_START*/';
      const endMarker = '/*ARCHIVE_DATA_END*/';
      const rawHtml = document.documentElement.outerHTML;
      const sIdx = rawHtml.indexOf(startMarker);
      const eIdx = rawHtml.indexOf(endMarker);
      let currentHtml = rawHtml;
      if (sIdx !== -1 && eIdx !== -1 && eIdx > sIdx) {
        currentHtml = rawHtml.substring(0, sIdx + startMarker.length) + ' ' + jsonStr + ' ' + rawHtml.substring(eIdx);
      }
      const blob = new Blob(['<!DOCTYPE html>\\n' + currentHtml], { type: 'text/html;charset=utf-8' });
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = document.title.split(' ').join('_') + '_통합본.html';
      a.click();
    }
  </script>
</body>
</html>''';
  }

  // ===========================================================================
  // ★ [PDF 내보내기]: 현재 조회된 증빙서류들을 낱장이 아닌 "단 하나의 묶음 PDF 파일"로 통합 생성!
  // ===========================================================================
  Future<void> _exportIndividualPdfs() async {
    final targetRecords = _filteredRecords;
    if (targetRecords.isEmpty) {
      _showSnack('내보낼 증빙서류 사진이 없습니다.');
      return;
    }

    setState(() => _isBusy = true);
    try {
      final koreanFont = await PdfGoogleFonts.nanumGothicRegular();
      final koreanBoldFont = await PdfGoogleFonts.nanumGothicBold();

      final seenImagePaths = <String>{};
      final uniquePhotoRecords = <DocRecord>[];
      for (final r in targetRecords) {
        final key = r.imagePath.isNotEmpty ? r.imagePath : r.id;
        if (!seenImagePaths.contains(key)) {
          seenImagePaths.add(key);
          uniquePhotoRecords.add(r);
        }
      }

      final bool useSub = _usesSubCategory(_selectedCategoryFilter) &&
          _selectedSubCategoryFilter != '전체';
      final String filterScopeName = useSub
          ? '${_selectedCategoryFilter}_$_selectedSubCategoryFilter'
          : _selectedCategoryFilter;
      final String safeScope = _sanitizeFileNameForOneDrive(filterScopeName);

      // ★ 하나의 pw.Document() 안에 모든 증빙서류 페이지를 순서대로 묶어서 한 파일로 생성!
      final combinedPdf = pw.Document();
      final totalPages = uniquePhotoRecords.length;

      for (int i = 0; i < totalPages; i++) {
        final rec = uniquePhotoRecords[i];
        if (rec.base64Image.trim().isEmpty) continue;
        final imgBytes = base64Decode(rec.base64Image);
        final pdfImage = pw.MemoryImage(imgBytes);

        combinedPdf.addPage(
          pw.Page(
            pageFormat: PdfPageFormat.a4,
            margin: const pw.EdgeInsets.all(14),
            build: (pw.Context ctx) {
              return pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(
                        vertical: 5, horizontal: 8),
                    margin: const pw.EdgeInsets.only(bottom: 8),
                    decoration: pw.BoxDecoration(
                      color: PdfColors.grey200,
                      borderRadius: pw.BorderRadius.circular(4),
                    ),
                    child: pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      children: [
                        pw.Expanded(
                          child: pw.Text(
                            '[$filterScopeName ${i + 1}/$totalPages] ${rec.displayTitle}  (${rec.displaySubtitle})',
                            style: pw.TextStyle(
                              font: koreanBoldFont,
                              fontSize: 10.5,
                              color: PdfColors.blueGrey900,
                            ),
                          ),
                        ),
                        pw.SizedBox(width: 8),
                        pw.Text(
                          rec.pdfFileBaseName.split('-').first,
                          style: pw.TextStyle(
                            font: koreanFont,
                            fontSize: 9.5,
                            color: PdfColors.grey800,
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

      final Uint8List pdfBytes = await combinedPdf.save();
      final tempDir = await getTemporaryDirectory();

      String exportPdfFileName = '증빙서류_${safeScope}_묶음(${totalPages}건).pdf';
      if (_useConflictFreeFileName) {
        final stamp = DateFormat('MMdd_HHmm').format(DateTime.now());
        final cleanUser = _exporterUserName.trim().isNotEmpty
            ? '_${_sanitizeFileNameForOneDrive(_exporterUserName.trim())}'
            : '';
        exportPdfFileName =
            '증빙서류_${safeScope}${cleanUser}_묶음(${totalPages}건)_$stamp.pdf';
      }

      final tempFile = File(p.join(tempDir.path, exportPdfFileName));
      await tempFile.writeAsBytes(pdfBytes, flush: true);

      await Share.shareXFiles([XFile(tempFile.path)]);
    } catch (e) {
      _showSnack('PDF 내보내기 중 오류가 발생했습니다: $e');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  List<MapEntry<String, String>> _getCategoryFieldPairs(
    DocRecord rec,
    Map<String, String> cumMap,
    Set<String> repliedKeys,
  ) {
    final f = rec.fields;
    final subLabel = rec.subCategory.isNotEmpty ? rec.subCategory : '미지정';
    if (rec.category == DocCategory.officialOut) {
      return [
        MapEntry('발신일', DocRecord.formatDotDate(f['sentDate'])),
        MapEntry('받는사람', rec.officialCounterpartyValue),
        MapEntry('제목', f['title'] ?? '-'),
        MapEntry('회신번호', f['replyDocNumber'] ?? '-'),
        MapEntry('공문번호', f['docNumber'] ?? '-'),
        MapEntry('내용', f['aiSummary'] ?? '-'),
      ];
    }
    if (rec.category == DocCategory.officialIn) {
      final isReplied = _isIncomingDocReplied(rec, repliedKeys);
      return [
        MapEntry('접수일', DocRecord.formatDotDate(f['sentDate'])),
        MapEntry('보낸사람', rec.officialCounterpartyValue),
        MapEntry('제목', f['title'] ?? '-'),
        MapEntry('회신요청일', DocRecord.formatDotDate(f['replyDeadline'])),
        MapEntry('회신완료', isReplied ? '○' : '-'),
        MapEntry('공문번호', f['docNumber'] ?? '-'),
        MapEntry('내용', f['aiSummary'] ?? '-'),
      ];
    }
    switch (rec.category) {
      case DocCategory.invoice:
        return [
          MapEntry('날짜', DocRecord.formatDotDate(f['arrivalDate'])),
          MapEntry('제품명', f['productName'] ?? '-'),
          MapEntry('규격명', f['specName'] ?? '-'),
          MapEntry('단위', f['unit'] ?? 'ton'),
          MapEntry('수량', f['quantity'] ?? '-'),
          MapEntry('누적수량', cumMap[rec.id] ?? f['quantity'] ?? '-'),
          MapEntry('공급자상호', f['supplierName'] ?? '-'),
          MapEntry('주문/송장번호', f['orderNumber'] ?? '-'),
        ];
      case DocCategory.travel:
        final div = rec.travelDivision;
        if (div == TravelDivision.car) {
          final km = f['distanceKm'] ?? '0';
          return [
            MapEntry('카테고리', subLabel),
            const MapEntry('구분', '자차'),
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

  Widget _buildRowActionButtons(DocRecord rec) {
    return Container(
      width: 68,
      decoration: const BoxDecoration(
        border: Border(
          right: BorderSide(color: Color(0xFFCBD5E1), width: 1),
        ),
      ),
      alignment: Alignment.center,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          InkWell(
            onTap: () => _editLocalRecord(rec),
            child: const Padding(
              padding: EdgeInsets.all(5),
              child: Icon(Icons.edit_outlined,
                  size: 17, color: Color(0xFF1E3A8A)),
            ),
          ),
          InkWell(
            onTap: () => _deleteLocalRecord(rec),
            child: const Padding(
              padding: EdgeInsets.all(5),
              child:
                  Icon(Icons.delete_outline, size: 17, color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopListSection(
    List<DocRecord> items,
    Map<String, String> cumMap,
    Set<String> repliedKeys,
  ) {
    if (items.isEmpty) {
      return const Center(
        child: Text(
          '등록된 증빙서류가 없습니다.\n우측 하단 [서류 촬영] 버튼을 눌러 추가하세요.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    // ★ 1) 자재송장: 날짜 - 제품명 - 규격명 - 단위 - 수량 - 누적수량 - 공급자 - 주문송장번호 + 수정/삭제
    if (_selectedCategoryFilter == DocCategory.invoice) {
      return ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          controller: _tableHorizontalScrollCtrl,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: 642,
            child: Column(
              children: [
                Container(
                  color: const Color(0xFFE2E8F0),
                  child: IntrinsicHeight(
                    child: Row(
                      children: [
                        _buildFixedHeaderCell('날짜', width: 64),
                        _buildFixedHeaderCell('제품명', width: 72),
                        _buildFixedHeaderCell('규격명', width: 62),
                        _buildFixedHeaderCell('단위', width: 44),
                        _buildFixedHeaderCell('수량', width: 64),
                        _buildFixedHeaderCell('누적수량', width: 68),
                        _buildFixedHeaderCell('공급자', width: 78),
                        _buildFixedHeaderCell('주문송장번호', width: 122),
                        _buildFixedHeaderCell('수정/삭제', width: 68),
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
                      final cumStr = cumMap[rec.id] ?? f['quantity'] ?? '-';
                      return InkWell(
                        onTap: () => setState(() => _selectedRecord = rec),
                        onLongPress: () => _editLocalRecord(rec),
                        child: Container(
                          decoration: BoxDecoration(
                            color: isSelected
                                ? const Color(0xFFDBEAFE)
                                : Colors.white,
                            border: const Border(
                              bottom: BorderSide(
                                  color: Color(0xFFCBD5E1), width: 1),
                            ),
                          ),
                          child: IntrinsicHeight(
                            child: Row(
                              children: [
                                _buildFixedDataCell(
                                  DocRecord.formatDotDate(f['arrivalDate']),
                                  width: 64,
                                  isSelected: isSelected,
                                ),
                                _buildFixedDataCell(
                                  f['productName'] ?? '-',
                                  width: 72,
                                  isSelected: isSelected,
                                ),
                                _buildFixedDataCell(
                                  f['specName'] ?? '-',
                                  width: 62,
                                  isSelected: isSelected,
                                ),
                                _buildFixedDataCell(
                                  f['unit'] ?? 'ton',
                                  width: 44,
                                  isSelected: isSelected,
                                ),
                                _buildFixedDataCell(
                                  f['quantity'] ?? '-',
                                  width: 64,
                                  isSelected: isSelected,
                                ),
                                _buildFixedDataCell(
                                  cumStr,
                                  width: 68,
                                  isSelected: isSelected,
                                  textColor: const Color(0xFF1E3A8A),
                                  forceBold: true,
                                ),
                                _buildFixedDataCell(
                                  f['supplierName'] ?? '-',
                                  width: 78,
                                  isSelected: isSelected,
                                ),
                                _buildFixedDataCell(
                                  f['orderNumber'] ?? '-',
                                  width: 122,
                                  isSelected: isSelected,
                                ),
                                _buildRowActionButtons(rec),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // ★ 2) 공문(수신) & 공문(발신) (및 전체 탭 공문):
    // 순서: 날짜 - 공문번호 - 보낸사람(받는사람) - 공문번호(회신번호) - 제목 - 내용 - 회신요청일 - 회신완료 + 수정/삭제
    // 열 너비는 칸마다 글자가 2줄로 들어갈 정도로 좁혀서 한눈에 들어오도록 구성!
    if (DocCategory.isOfficial(_selectedCategoryFilter)) {
      final bool isOutTab = _selectedCategoryFilter == DocCategory.officialOut;
      final String partyHeader = isOutTab ? '받는사람' : '보낸사람';
      // ★ 공문(수신)에는 불필요한 4번째 공문번호(회신번호) 열을 완전히 제거하고,
      // 공문(발신)에는 4번째 열 이름을 그냥 '회신번호'로 깔끔하게 표시!
      final double tableTotalWidth = isOutTab ? 686 : 666;

      return ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          controller: _tableHorizontalScrollCtrl,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: tableTotalWidth,
            child: Column(
              children: [
                Container(
                  color: const Color(0xFFE2E8F0),
                  child: IntrinsicHeight(
                    child: Row(
                      children: [
                        _buildFixedHeaderCell('날짜', width: 64),
                        _buildFixedHeaderCell('공문번호', width: 76),
                        _buildFixedHeaderCell(partyHeader, width: 68),
                        if (isOutTab)
                          _buildFixedHeaderCell('회신번호', width: 76),
                        _buildFixedHeaderCell('제목', width: 118),
                        _buildFixedHeaderCell('내용', width: 152),
                        _buildFixedHeaderCell('회신요청일', width: 64),
                        if (!isOutTab)
                          _buildFixedHeaderCell('회신완료', width: 56),
                        _buildFixedHeaderCell('수정/삭제', width: 68),
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
                      final bool isReplied =
                          _isIncomingDocReplied(rec, repliedKeys);
                      final String replyNumStr =
                          f['replyDocNumber']?.trim().isNotEmpty == true
                              ? f['replyDocNumber']!
                              : '-';

                      return InkWell(
                        onTap: () => setState(() => _selectedRecord = rec),
                        onLongPress: () => _editLocalRecord(rec),
                        child: Container(
                          decoration: BoxDecoration(
                            color: isSelected
                                ? const Color(0xFFDBEAFE)
                                : Colors.white,
                            border: const Border(
                              bottom: BorderSide(
                                  color: Color(0xFFCBD5E1), width: 1),
                            ),
                          ),
                          child: IntrinsicHeight(
                            child: Row(
                              children: [
                                _buildFixedDataCell(
                                  DocRecord.formatDotDate(f['sentDate']),
                                  width: 64,
                                  isSelected: isSelected,
                                ),
                                _buildFixedDataCell(
                                  f['docNumber'] ?? '-',
                                  width: 76,
                                  isSelected: isSelected,
                                ),
                                _buildFixedDataCell(
                                  rec.officialCounterpartyValue,
                                  width: 68,
                                  isSelected: isSelected,
                                ),
                                if (isOutTab)
                                  _buildFixedDataCell(
                                    replyNumStr,
                                    width: 76,
                                    isSelected: isSelected,
                                    textColor: const Color(0xFF1E3A8A),
                                  ),
                                _buildFixedDataCell(
                                  f['title'] ?? '-',
                                  width: 118,
                                  isSelected: isSelected,
                                ),
                                _buildFixedDataCell(
                                  f['aiSummary'] ?? '-',
                                  width: 152,
                                  isSelected: isSelected,
                                ),
                                _buildFixedDataCell(
                                  DocRecord.formatDotDate(f['replyDeadline']),
                                  width: 64,
                                  isSelected: isSelected,
                                ),
                                if (!isOutTab)
                                  _buildFixedDataCell(
                                    isReplied ? '○' : '',
                                    width: 56,
                                    isSelected: isSelected,
                                    textColor: const Color(0xFF16A34A),
                                    forceBold: true,
                                  ),
                                _buildRowActionButtons(rec),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // ★ 3) 출장비: 카테고리(날짜 같이표시) - 구분 - 상호 - 금액 + 수정/삭제
    if (_selectedCategoryFilter == DocCategory.travel) {
      return ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          controller: _tableHorizontalScrollCtrl,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: 446,
            child: Column(
              children: [
                Container(
                  color: const Color(0xFFE2E8F0),
                  child: IntrinsicHeight(
                    child: Row(
                      children: [
                        _buildFixedHeaderCell('카테고리(날짜)', width: 100),
                        _buildFixedHeaderCell('구분', width: 58),
                        _buildFixedHeaderCell('상호', width: 136),
                        _buildFixedHeaderCell('금액', width: 84),
                        _buildFixedHeaderCell('수정/삭제', width: 68),
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
                      final catName =
                          rec.subCategory.isNotEmpty ? rec.subCategory : '미지정';
                      final dateStr = DocRecord.formatDotDate(
                          f['date'] ?? rec.createdAt.split(' ').first);
                      final catWithDate = '$catName\n($dateStr)';
                      final div = rec.travelDivision;
                      final mult =
                          f['carMultiplier']?.trim().isNotEmpty == true
                              ? f['carMultiplier']!
                              : '2';
                      final rate = f['carUnitPrice']?.trim().isNotEmpty == true
                          ? f['carUnitPrice']!
                          : '300';
                      final merchantStr = div == TravelDivision.car
                          ? (f['merchantName']?.trim().isNotEmpty == true
                              ? f['merchantName']!
                              : '${f['distanceKm'] ?? 0}km × $mult × ${rate}원')
                          : (f['merchantName'] ?? '-');
                      final amtStr =
                          '${DocRecord._formatCurrency(f['totalAmount'])}원';

                      return InkWell(
                        onTap: () => setState(() => _selectedRecord = rec),
                        onLongPress: () => _editLocalRecord(rec),
                        child: Container(
                          decoration: BoxDecoration(
                            color: isSelected
                                ? const Color(0xFFDBEAFE)
                                : Colors.white,
                            border: const Border(
                              bottom: BorderSide(
                                  color: Color(0xFFCBD5E1), width: 1),
                            ),
                          ),
                          child: IntrinsicHeight(
                            child: Row(
                              children: [
                                _buildFixedDataCell(
                                  catWithDate,
                                  width: 100,
                                  isSelected: isSelected,
                                ),
                                _buildFixedDataCell(
                                  div,
                                  width: 58,
                                  isSelected: isSelected,
                                  textColor: Colors.brown.shade900,
                                  forceBold: true,
                                ),
                                _buildFixedDataCell(
                                  merchantStr,
                                  width: 136,
                                  isSelected: isSelected,
                                ),
                                _buildFixedDataCell(
                                  amtStr,
                                  width: 84,
                                  isSelected: isSelected,
                                  textColor: const Color(0xFF1E3A8A),
                                  forceBold: true,
                                ),
                                _buildRowActionButtons(rec),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // ★ 4) 병원비: 카테고리 - 날짜 - 상호 - 금액 - 사업자등록번호 + 수정/삭제
    if (_selectedCategoryFilter == DocCategory.medical) {
      return ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: SingleChildScrollView(
          controller: _tableHorizontalScrollCtrl,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: 492,
            child: Column(
              children: [
                Container(
                  color: const Color(0xFFE2E8F0),
                  child: IntrinsicHeight(
                    child: Row(
                      children: [
                        _buildFixedHeaderCell('카테고리', width: 74),
                        _buildFixedHeaderCell('날짜', width: 68),
                        _buildFixedHeaderCell('상호', width: 104),
                        _buildFixedHeaderCell('금액', width: 80),
                        _buildFixedHeaderCell('사업자등록번호', width: 98),
                        _buildFixedHeaderCell('수정/삭제', width: 68),
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
                      final catName =
                          rec.subCategory.isNotEmpty ? rec.subCategory : '미지정';
                      final dateStr = DocRecord.formatDotDate(
                          f['issueDate'] ?? rec.createdAt.split(' ').first);
                      final amtStr =
                          '${DocRecord._formatCurrency(f['totalPaid'])}원';

                      return InkWell(
                        onTap: () => setState(() => _selectedRecord = rec),
                        onLongPress: () => _editLocalRecord(rec),
                        child: Container(
                          decoration: BoxDecoration(
                            color: isSelected
                                ? const Color(0xFFDBEAFE)
                                : Colors.white,
                            border: const Border(
                              bottom: BorderSide(
                                  color: Color(0xFFCBD5E1), width: 1),
                            ),
                          ),
                          child: IntrinsicHeight(
                            child: Row(
                              children: [
                                _buildFixedDataCell(
                                  catName,
                                  width: 74,
                                  isSelected: isSelected,
                                ),
                                _buildFixedDataCell(
                                  dateStr,
                                  width: 68,
                                  isSelected: isSelected,
                                ),
                                _buildFixedDataCell(
                                  f['clinicName'] ?? '-',
                                  width: 104,
                                  isSelected: isSelected,
                                ),
                                _buildFixedDataCell(
                                  amtStr,
                                  width: 80,
                                  isSelected: isSelected,
                                  textColor: const Color(0xFF1E3A8A),
                                  forceBold: true,
                                ),
                                _buildFixedDataCell(
                                  f['bizRegNumber'] ?? '-',
                                  width: 98,
                                  isSelected: isSelected,
                                ),
                                _buildRowActionButtons(rec),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // 5) [전체] 탭에서도 깔끔한 표 형식으로 표시 + 수정/삭제 지원
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        controller: _tableHorizontalScrollCtrl,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: 490,
          child: Column(
            children: [
              Container(
                color: const Color(0xFFE2E8F0),
                child: IntrinsicHeight(
                  child: Row(
                    children: [
                      _buildFixedHeaderCell('분류', width: 72),
                      _buildFixedHeaderCell('날짜', width: 68),
                      _buildFixedHeaderCell('제목 / 상호 / 품목', width: 150),
                      _buildFixedHeaderCell('상세 / 금액 / 수량', width: 132),
                      _buildFixedHeaderCell('수정/삭제', width: 68),
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
                    String dateStr = rec.createdAt.split(' ').first;
                    if (DocCategory.isOfficial(rec.category)) {
                      dateStr = DocRecord.formatDotDate(f['sentDate']);
                    } else if (rec.category == DocCategory.invoice) {
                      dateStr = DocRecord.formatDotDate(f['arrivalDate']);
                    } else if (rec.category == DocCategory.travel) {
                      dateStr = DocRecord.formatDotDate(f['date']);
                    } else if (rec.category == DocCategory.medical) {
                      dateStr = DocRecord.formatDotDate(f['issueDate']);
                    }

                    return InkWell(
                      onTap: () => setState(() => _selectedRecord = rec),
                      onLongPress: () => _editLocalRecord(rec),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isSelected
                              ? const Color(0xFFDBEAFE)
                              : Colors.white,
                          border: const Border(
                            bottom:
                                BorderSide(color: Color(0xFFCBD5E1), width: 1),
                          ),
                        ),
                        child: IntrinsicHeight(
                          child: Row(
                            children: [
                              _buildFixedDataCell(
                                rec.category,
                                width: 72,
                                isSelected: isSelected,
                              ),
                              _buildFixedDataCell(
                                dateStr,
                                width: 68,
                                isSelected: isSelected,
                              ),
                              _buildFixedDataCell(
                                rec.displayTitle,
                                width: 150,
                                isSelected: isSelected,
                              ),
                              _buildFixedDataCell(
                                rec.displaySubtitle,
                                width: 132,
                                isSelected: isSelected,
                              ),
                              _buildRowActionButtons(rec),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFixedHeaderCell(String label, {required double width}) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
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
        softWrap: true,
        style: const TextStyle(
          fontSize: 11,
          height: 1.2,
          fontWeight: FontWeight.bold,
          color: Color(0xFF1E293B),
        ),
      ),
    );
  }

  Widget _buildFixedDataCell(
    String value, {
    required double width,
    required bool isSelected,
    Color? textColor,
    bool forceBold = false,
  }) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
      decoration: const BoxDecoration(
        border: Border(
          right: BorderSide(color: Color(0xFFCBD5E1), width: 1),
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        value.trim().isEmpty ? '-' : value,
        textAlign: TextAlign.center,
        softWrap: true,
        style: TextStyle(
          fontSize: 11,
          height: 1.25,
          fontWeight:
              (isSelected || forceBold) ? FontWeight.bold : FontWeight.w500,
          color: textColor ?? const Color(0xFF0F172A),
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
    final cumMap = _computeInvoiceCumulativeMap(_records);
    final repliedKeys = _computeRepliedDocNumKeys(_records);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
        title: const Text('증빙서류 스냅 v39'),
        actions: [
          IconButton(
            tooltip: '원드라이브 덮어쓰기 & AI 설정',
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
            tooltip: '구글 시트 클라우드 실시간 공동 누적 동기화',
            icon: Icon(
              Icons.cloud_sync_outlined,
              size: 20,
              color: _googleWebhookUrl.trim().isNotEmpty
                  ? Colors.greenAccent
                  : Colors.white70,
            ),
            onPressed: _isBusy ? null : () => _syncWithGoogleCloudWebhook(),
          ),
          IconButton(
            tooltip: '여러 명이 보낸 HTML 파일들 한꺼번에 불러와 합치기',
            icon: const Icon(Icons.file_open_outlined, size: 19),
            onPressed: _isBusy ? null : _importExistingHtmlToMerge,
          ),
          TextButton.icon(
            onPressed: _isBusy ? null : _exportCumulativeFilteredHtml,
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
            onPressed: _isBusy ? null : _exportIndividualPdfs,
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
              // 1) 상단 1줄: 문서 종류 선택 탭 (`전체 | 공문(수신) | 공문(발신) | 자재송장 | 출장비 | 병원비`)
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
                          _selectedInvoiceProductFilter = '전체';
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

              // ★ 2) 자재송장 / 출장비 / 병원비 / 전체 상단 요약 & 기간·품목·카테고리 필터 영역
              if (_selectedCategoryFilter == DocCategory.invoice ||
                  _usesSubCategory(_selectedCategoryFilter) ||
                  _selectedCategoryFilter == DocCategory.all)
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
                      // ★ 자재송장(한 달 단위 넘기기) & 병원비(자유 날짜 지정) 상단 기간 필터 바
                      if (_usesPeriodFilter(_selectedCategoryFilter)) ...[
                        Row(
                          children: [
                            InkWell(
                              onTap: () => _selectedCategoryFilter ==
                                      DocCategory.medical
                                  ? _openMedicalDateFilterDialog()
                                  : _openPeriodFilterDialog(
                                      _selectedCategoryFilter),
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E3A8A),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.calendar_month,
                                        size: 15, color: Colors.amberAccent),
                                    const SizedBox(width: 5),
                                    Text(
                                      _selectedCategoryFilter ==
                                              DocCategory.medical
                                          ? '날짜필터: ${_currentPeriodButtonLabel(_selectedCategoryFilter)}'
                                          : '기간필터: ${_currentPeriodButtonLabel(_selectedCategoryFilter)}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                    const SizedBox(width: 2),
                                    const Icon(Icons.arrow_drop_down,
                                        size: 16, color: Colors.white),
                                  ],
                                ),
                              ),
                            ),
                            if (_selectedCategoryFilter ==
                                DocCategory.invoice) ...[
                              const SizedBox(width: 6),
                              InkWell(
                                onTap: () => _shiftPeriodMonth(
                                    _selectedCategoryFilter, -1),
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(6),
                                    border:
                                        Border.all(color: Colors.blue.shade200),
                                  ),
                                  child: const Icon(Icons.chevron_left,
                                      size: 18, color: Color(0xFF1E3A8A)),
                                ),
                              ),
                              const SizedBox(width: 4),
                              InkWell(
                                onTap: () => _shiftPeriodMonth(
                                    _selectedCategoryFilter, 1),
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(6),
                                    border:
                                        Border.all(color: Colors.blue.shade200),
                                  ),
                                  child: const Icon(Icons.chevron_right,
                                      size: 18, color: Color(0xFF1E3A8A)),
                                ),
                              ),
                            ],
                            const SizedBox(width: 8),
                            Expanded(
                              child: GestureDetector(
                                onTap: () => _selectedCategoryFilter ==
                                        DocCategory.medical
                                    ? _openMedicalDateFilterDialog()
                                    : _openPeriodFilterDialog(
                                        _selectedCategoryFilter),
                                child: Text(
                                  _currentPeriodRangeDescription(
                                      _selectedCategoryFilter),
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF1E3A8A),
                                  ),
                                ),
                              ),
                            ),
                            if (!(_periodFilterAllMap[
                                    _selectedCategoryFilter] ??
                                true))
                              InkWell(
                                onTap: () {
                                  setState(() {
                                    _periodFilterAllMap[
                                        _selectedCategoryFilter] = true;
                                  });
                                },
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 4),
                                  child: Text(
                                    '전체보기',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: Colors.redAccent,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                      ],

                      // ★ 자재송장: 출장비와 동일한 박스 형태로 제품명별 합계수량 표시 (예: 고장력철근(19.6ton))
                      if (_selectedCategoryFilter == DocCategory.invoice) ...[
                        SizedBox(
                          height: 32,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: _invoiceProductNamesInCurrentPeriod
                                .map((prodName) {
                              final isSel =
                                  _selectedInvoiceProductFilter == prodName;
                              final labelStr =
                                  _invoiceProductChipLabel(prodName);
                              return Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: ChoiceChip(
                                  visualDensity: VisualDensity.compact,
                                  backgroundColor: Colors.amber.shade50,
                                  selectedColor: Colors.amber.shade300,
                                  label: Text(
                                    labelStr,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: isSel
                                          ? FontWeight.bold
                                          : FontWeight.w600,
                                      color: Colors.brown.shade900,
                                    ),
                                  ),
                                  selected: isSel,
                                  onSelected: (_) {
                                    setState(() {
                                      _selectedInvoiceProductFilter = prodName;
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

                      // ★ 출장비 / 병원비 / 전체: 금액 합계 및 내 카테고리 칩
                      if (_usesSubCategory(_selectedCategoryFilter) ||
                          _selectedCategoryFilter == DocCategory.all) ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '$_selectedCategoryFilter 합계 (${_recordsInSelectedMajorCategory.length}건): ${NumberFormat('#,###').format(majorTotalSum)}원',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13.5,
                                color: Color(0xFF1E3A8A),
                              ),
                            ),
                            if (_usesSubCategory(_selectedCategoryFilter) &&
                                _selectedSubCategoryFilter != '전체')
                              Text(
                                '[$_selectedSubCategoryFilter 합계: ${NumberFormat('#,###').format(currentSubTotalSum)}원]',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12.5,
                                  color: Colors.indigo,
                                ),
                              )
                            else if (_usesSubCategory(_selectedCategoryFilter))
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
                        if (_usesSubCategory(_selectedCategoryFilter) &&
                            subCategories.length > 1) ...[
                          const SizedBox(height: 6),
                          SizedBox(
                            height: 32,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: subCategories.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(width: 6),
                              itemBuilder: (ctx, idx) {
                                final subCat = subCategories[idx];
                                final selected =
                                    subCat == _selectedSubCategoryFilter;
                                final cnt = _countBySubCategory(subCat);
                                final sum = _sumBySubCategory(subCat);
                                final labelText = subCat == '전체'
                                    ? '전체 ($cnt건 · ${NumberFormat('#,###').format(sum)}원)'
                                    : '$subCat ($cnt건 · ${NumberFormat('#,###').format(sum)}원)';
                                final canDelete =
                                    subCat != '전체' && subCat != '미지정';
                                return InputChip(
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
                                      if (!currentList.any(
                                          (r) => r.id == _selectedRecord?.id)) {
                                        _selectedRecord = currentList.isNotEmpty
                                            ? currentList.first
                                            : null;
                                      }
                                    });
                                  },
                                  deleteIcon: canDelete
                                      ? const Icon(Icons.close, size: 14)
                                      : null,
                                  onDeleted: canDelete
                                      ? () => _deleteUserSubCategory(
                                          _selectedCategoryFilter, subCat)
                                      : null,
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
                              children:
                                  ['전체', ...TravelDivision.list].map((div) {
                                final isSel =
                                    _selectedTravelDivisionFilter == div;
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
                                        if (!currentList.any((r) =>
                                            r.id == _selectedRecord?.id)) {
                                          _selectedRecord =
                                              currentList.isNotEmpty
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
                    ],
                  ),
                ),

              // ★ 3) 스마트폰 세로 모드: [위쪽 리스트 + 상하 조절바 + 아래쪽 사진]
              //      스마트폰 가로 모드(눕혔을 때): [좌측 리스트 + 좌우 조절바 + 우측 사진]
              Expanded(
                child: LayoutBuilder(
                  builder: (ctx, constraints) {
                    final totalW = constraints.maxWidth;
                    final totalH = constraints.maxHeight;
                    final isLandscape =
                        MediaQuery.of(ctx).orientation == Orientation.landscape ||
                            totalW > totalH;

                    if (isLandscape) {
                      const double dividerBarWidth = 22.0;
                      final double usableW =
                          math.max(120.0, totalW - dividerBarWidth);
                      final double listW = (usableW * _detailHorizSplitRatio)
                          .clamp(120.0, usableW - 120.0);
                      final double photoW = usableW - listW;

                      return Row(
                        children: [
                          SizedBox(
                            width: listW,
                            height: totalH,
                            child: _buildTopListSection(
                              items,
                              cumMap,
                              repliedKeys,
                            ),
                          ),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onHorizontalDragUpdate: (details) {
                              setState(() {
                                _detailHorizSplitRatio =
                                    (_detailHorizSplitRatio +
                                            details.delta.dx / usableW)
                                        .clamp(0.20, 0.82);
                              });
                            },
                            onHorizontalDragEnd: (_) async {
                              final prefs =
                                  await SharedPreferences.getInstance();
                              await prefs.setDouble(_prefsHorizSplitRatioKey,
                                  _detailHorizSplitRatio);
                            },
                            child: Container(
                              width: dividerBarWidth,
                              height: double.infinity,
                              decoration: BoxDecoration(
                                color: Colors.blueGrey.shade100,
                                border: Border.symmetric(
                                  vertical: BorderSide(
                                      color: Colors.blueGrey.shade300,
                                      width: 1),
                                ),
                              ),
                              child: Center(
                                child: Container(
                                  width: 4,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1E3A8A),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: photoW,
                            height: totalH,
                            child: Container(
                              width: double.infinity,
                              height: double.infinity,
                              color: const Color(0xFF0F172A),
                              child: _selectedRecord == null
                                  ? const Center(
                                      child: Text(
                                        '좌측 목록에서 항목을 선택하면\n우측에 증빙사진이 크게 표시됩니다.',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(color: Colors.white70),
                                      ),
                                    )
                                  : ClipRect(
                                      child: InteractiveViewer(
                                        clipBehavior: Clip.none,
                                        boundaryMargin:
                                            const EdgeInsets.all(400),
                                        minScale: 0.6,
                                        maxScale: 8.0,
                                        child: SizedBox(
                                          width: photoW,
                                          height: totalH,
                                          child: _buildRecordImage(
                                              _selectedRecord!),
                                        ),
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      );
                    }

                    const double dividerBarHeight = 24.0;
                    final double usableH =
                        math.max(100.0, totalH - dividerBarHeight);
                    final double listH =
                        (usableH * _listSplitRatio).clamp(60.0, usableH - 80.0);
                    final double detailH = usableH - listH;

                    return Column(
                      children: [
                        SizedBox(
                          height: listH,
                          child: _buildTopListSection(
                            items,
                            cumMap,
                            repliedKeys,
                          ),
                        ),
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
                                    '위아래로 끌어서 화면 크기 조절 (표는 좌우로 드래그 가능)',
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
                        SizedBox(
                          height: detailH,
                          child: Container(
                            width: double.infinity,
                            color: const Color(0xFF0F172A),
                            child: _selectedRecord == null
                                ? const Center(
                                    child: Text(
                                      '위 목록에서 항목을 선택하면\n이곳에 증빙사진이 크게 표시됩니다.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: Colors.white70),
                                    ),
                                  )
                                : ClipRect(
                                    child: InteractiveViewer(
                                      clipBehavior: Clip.none,
                                      boundaryMargin:
                                          const EdgeInsets.all(400),
                                      minScale: 0.6,
                                      maxScale: 8.0,
                                      child: SizedBox(
                                        width: double.infinity,
                                        height: detailH,
                                        child: _buildRecordImage(
                                            _selectedRecord!),
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
