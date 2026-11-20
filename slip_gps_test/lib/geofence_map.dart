import 'dart:ui' as ui;

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

/// Interactive OSM map: current location, branch marker, check-in / check-out radii.
class GeofenceMapPanel extends StatelessWidget {
  const GeofenceMapPanel({
    super.key,
    required this.mapController,
    required this.fenceColor,
    this.branchLat,
    this.branchLng,
    this.currentLat,
    this.currentLng,
    this.accuracyM,
    required this.checkInRadiusM,
    required this.checkOutRadiusM,
    this.onMapTap,
    this.onRecenter,
  });

  final MapController mapController;
  final Color fenceColor;
  final double? branchLat;
  final double? branchLng;
  final double? currentLat;
  final double? currentLng;
  final double? accuracyM;
  final double checkInRadiusM;
  final double checkOutRadiusM;
  final void Function(LatLng latLng)? onMapTap;
  final VoidCallback? onRecenter;

  bool get _hasBranch => branchLat != null && branchLng != null;
  bool get _hasCurrent => currentLat != null && currentLng != null;

  @override
  Widget build(BuildContext context) {
    final center = _hasBranch
        ? LatLng(branchLat!, branchLng!)
        : _hasCurrent
        ? LatLng(currentLat!, currentLng!)
        : const LatLng(10.0159, 76.3419);

    final circles = <CircleMarker>[];
    final markers = <Marker>[];

    if (_hasBranch) {
      final branch = LatLng(branchLat!, branchLng!);

      // Check-out radius (outer) — red-ish ring
      circles.add(
        CircleMarker(
          point: branch,
          radius: checkOutRadiusM,
          useRadiusInMeter: true,
          color: const Color(0xFFE04A40).withValues(alpha: 0.08),
          borderStrokeWidth: 2,
          borderColor: const Color(0xFFE04A40).withValues(alpha: 0.7),
        ),
      );

      // Check-in radius (inner) — state-colored
      circles.add(
        CircleMarker(
          point: branch,
          radius: checkInRadiusM,
          useRadiusInMeter: true,
          color: fenceColor.withValues(alpha: 0.18),
          borderStrokeWidth: 2.5,
          borderColor: fenceColor,
        ),
      );

      markers.add(
        Marker(
          point: branch,
          width: 40,
          height: 40,
          alignment: Alignment.topCenter,
          child: const _Pin(color: Color(0xFF1A2824), label: 'B'),
        ),
      );
    }

    if (_hasCurrent) {
      final me = LatLng(currentLat!, currentLng!);
      if (accuracyM != null && accuracyM! > 0) {
        circles.add(
          CircleMarker(
            point: me,
            radius: accuracyM!,
            useRadiusInMeter: true,
            color: const Color(0xFF2563EB).withValues(alpha: 0.1),
            borderStrokeWidth: 1,
            borderColor: const Color(0xFF2563EB).withValues(alpha: 0.4),
          ),
        );
      }
      markers.add(
        Marker(
          point: me,
          width: 40,
          height: 40,
          alignment: Alignment.topCenter,
          child: const _Pin(color: Color(0xFF2563EB), label: 'You'),
        ),
      );
    }

    final mapHeight = (MediaQuery.sizeOf(context).height * 0.55).clamp(
      360.0,
      640.0,
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: mapHeight,
        child: Stack(
          children: [
            FlutterMap(
              mapController: mapController,
              options: MapOptions(
                initialCenter: center,
                initialZoom: 17,
                onTap: (_, latLng) => onMapTap?.call(latLng),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.slip.slip_gps_test',
                  maxZoom: 19,
                ),
                CircleLayer(circles: circles),
                MarkerLayer(markers: markers),
                const RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution('OpenStreetMap contributors'),
                  ],
                ),
              ],
            ),
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Tap map = set branch · Green = check-in · Red = check-out',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.black.withValues(alpha: 0.65),
                    ),
                  ),
                ),
              ),
            ),
            if (onRecenter != null)
              Positioned(
                right: 8,
                bottom: 28,
                child: Material(
                  color: Colors.white,
                  elevation: 2,
                  shape: const CircleBorder(),
                  child: IconButton(
                    tooltip: 'Recenter',
                    icon: const Icon(Icons.my_location, size: 20),
                    onPressed: onRecenter,
                  ),
                ),
              ),
            Positioned(
              left: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _legendDot(const Color(0xFF22A06B)),
                    const Text(' In ', style: TextStyle(fontSize: 10)),
                    _legendDot(const Color(0xFFE04A40)),
                    const Text(' Out ', style: TextStyle(fontSize: 10)),
                    _legendDot(const Color(0xFF2563EB)),
                    const Text(' You', style: TextStyle(fontSize: 10)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _legendDot(Color c) => Container(
    width: 8,
    height: 8,
    margin: const EdgeInsets.only(right: 2),
    decoration: BoxDecoration(color: c, shape: BoxShape.circle),
  );
}

class _Pin extends StatelessWidget {
  const _Pin({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white, width: 1.5),
            boxShadow: const [
              BoxShadow(blurRadius: 4, color: Color(0x44000000)),
            ],
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        CustomPaint(size: const Size(10, 8), painter: _TrianglePainter(color)),
      ],
    );
  }
}

class _TrianglePainter extends CustomPainter {
  _TrianglePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = ui.Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _TrianglePainter oldDelegate) =>
      oldDelegate.color != color;
}
