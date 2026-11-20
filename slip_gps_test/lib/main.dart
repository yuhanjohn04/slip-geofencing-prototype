import 'dart:async';

import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import 'geofence_map.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SlipGpsTestApp());
}

enum AttendanceState { waiting, inBranch, gracePeriod, outside }

class SlipGpsTestApp extends StatelessWidget {
  const SlipGpsTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Slip Field Test',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF22A06B)),
        useMaterial3: true,
      ),
      home: const FieldTestPage(),
    );
  }
}

class FieldTestPage extends StatefulWidget {
  const FieldTestPage({super.key});

  @override
  State<FieldTestPage> createState() => _FieldTestPageState();
}

class _FieldTestPageState extends State<FieldTestPage> {
  final _branchLatCtrl = TextEditingController();
  final _branchLngCtrl = TextEditingController();
  final _checkInCtrl = TextEditingController(text: '25');
  final _checkOutCtrl = TextEditingController(text: '35');
  final _graceCtrl = TextEditingController(text: '60');
  final _logScroll = ScrollController();
  final _mapController = MapController();

  StreamSubscription<Position>? _posSub;
  Timer? _graceTicker;

  Position? _position;
  double? _distanceM;
  AttendanceState _state = AttendanceState.waiting;
  DateTime? _graceDeadline;
  int _graceSecondsLeft = 0;
  bool _streaming = false;
  bool _calibrating = false;
  String _streamStatus = 'Start tracking to begin field test';
  final List<_LogEntry> _logs = [];

  /// Prefer fixes better than this (meters) when calibrating.
  static const double _goodAccuracyM = 15;

  /// Soft reject for geofence decisions when worse than this.
  static const double _usableAccuracyM = 35;

  AndroidSettings get _preciseSettings => AndroidSettings(
    accuracy: LocationAccuracy.bestForNavigation,
    distanceFilter: 0,
    intervalDuration: const Duration(seconds: 1),
    // Fused provider + GPS; better outdoor lock on Realme/OPPO.
    forceLocationManager: false,
  );

  /// Enter / stay checked-in when distance <= this.
  double get _checkInRadius {
    final v = double.tryParse(_checkInCtrl.text.trim());
    return (v == null || v < 1) ? 25 : v;
  }

  /// Leave / start grace when distance > this (hysteresis band).
  double get _checkOutRadius {
    final v = double.tryParse(_checkOutCtrl.text.trim());
    final out = (v == null || v < 1) ? 35.0 : v;
    // Check-out must be >= check-in
    return out < _checkInRadius ? _checkInRadius : out;
  }

  int get _graceSeconds {
    final v = int.tryParse(_graceCtrl.text.trim());
    return (v == null || v < 1) ? 60 : v;
  }

  double? get _branchLat => double.tryParse(_branchLatCtrl.text.trim());
  double? get _branchLng => double.tryParse(_branchLngCtrl.text.trim());
  bool get _hasBranch => _branchLat != null && _branchLng != null;

  Color get _fenceColor => switch (_state) {
    AttendanceState.inBranch => const Color(0xFF22A06B),
    AttendanceState.gracePeriod => const Color(0xFFE09B1A),
    AttendanceState.outside => const Color(0xFFE04A40),
    AttendanceState.waiting => const Color(0xFF64748B),
  };

  @override
  void dispose() {
    _posSub?.cancel();
    _graceTicker?.cancel();
    _branchLatCtrl.dispose();
    _branchLngCtrl.dispose();
    _checkInCtrl.dispose();
    _checkOutCtrl.dispose();
    _graceCtrl.dispose();
    _logScroll.dispose();
    _mapController.dispose();
    super.dispose();
  }

  void _addLog(String event, {double? distance, double? accuracy}) {
    final entry = _LogEntry(
      time: DateTime.now(),
      event: event,
      distance: distance,
      accuracy: accuracy,
    );
    setState(() {
      _logs.insert(0, entry);
      if (_logs.length > 200) {
        _logs.removeRange(200, _logs.length);
      }
    });
  }

  Future<bool> _ensurePermission() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      setState(() => _streamStatus = 'Location/GPS is off — turn it on');
      _addLog('Location services disabled — opening settings');
      await Geolocator.openLocationSettings();
      return false;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() => _streamStatus = 'Location permission denied');
        _addLog('Permission denied');
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      setState(
        () => _streamStatus =
            'Permission permanently denied — enable in Settings',
      );
      _addLog('Permission permanently denied');
      return false;
    }

    // Android 12+: Precise location must be on for useful GPS.
    try {
      final accuracy = await Geolocator.getLocationAccuracy();
      if (accuracy == LocationAccuracyStatus.reduced) {
        setState(
          () => _streamStatus =
              'Precise location is off — enable Precise for this app',
        );
        _addLog('Precise location reduced — open app permission settings');
        await Geolocator.openAppSettings();
        return false;
      }
    } catch (_) {
      // Some devices don't report accuracy status.
    }

    return true;
  }

  /// Wait outdoors for a stable GPS lock; pick the best sample.
  Future<Position?> _calibrateGps({
    Duration timeout = const Duration(seconds: 25),
  }) async {
    setState(() {
      _calibrating = true;
      _streamStatus = 'Calibrating GPS… stand still outdoors';
    });
    _addLog('GPS calibration started');

    Position? best;
    StreamSubscription<Position>? sub;
    final done = Completer<Position?>();

    final timeoutTimer = Timer(timeout, () {
      if (!done.isCompleted) done.complete(best);
    });

    try {
      try {
        best = await Geolocator.getCurrentPosition(
          locationSettings: _preciseSettings,
        );
        setState(() {
          _position = best;
          _streamStatus =
              'Calibrating… ±${best!.accuracy.round()} m (stand still)';
        });
        _moveMapTo(best.latitude, best.longitude);
        if (best.accuracy <= _goodAccuracyM) {
          timeoutTimer.cancel();
          return best;
        }
      } catch (_) {}

      sub = Geolocator.getPositionStream(locationSettings: _preciseSettings)
          .listen((pos) {
            if (best == null || pos.accuracy < best!.accuracy) {
              best = pos;
            }
            setState(() {
              _position = pos;
              _streamStatus = 'Calibrating… best ±${best!.accuracy.round()} m';
            });
            _moveMapTo(pos.latitude, pos.longitude);

            if (pos.accuracy <= _goodAccuracyM && !done.isCompleted) {
              timeoutTimer.cancel();
              done.complete(best);
            }
          });

      final result = await done.future;
      if (result != null) {
        _addLog(
          result.accuracy <= _goodAccuracyM
              ? 'GPS calibrated (good lock)'
              : 'GPS calibrated (best available — still noisy)',
          accuracy: result.accuracy,
        );
      }
      return result;
    } finally {
      timeoutTimer.cancel();
      await sub?.cancel();
      if (mounted) setState(() => _calibrating = false);
    }
  }

  Future<void> _setCurrentAsBranch() async {
    try {
      final ok = await _ensurePermission();
      if (!ok) return;

      final pos = await _calibrateGps();
      if (pos == null) {
        setState(() => _streamStatus = 'Could not get GPS fix');
        return;
      }

      setState(() {
        _branchLatCtrl.text = pos.latitude.toStringAsFixed(6);
        _branchLngCtrl.text = pos.longitude.toStringAsFixed(6);
        _position = pos;
        _streamStatus = pos.accuracy <= _goodAccuracyM
            ? 'Branch set (±${pos.accuracy.round()} m)'
            : 'Branch set with weak GPS (±${pos.accuracy.round()} m) — retake outdoors';
      });
      _addLog(
        'Branch set to current spot',
        distance: 0,
        accuracy: pos.accuracy,
      );

      _moveMapTo(pos.latitude, pos.longitude);

      if (_streaming) {
        _evaluate(pos);
      } else {
        setState(() {
          _distanceM = 0;
          _setState(AttendanceState.inBranch);
        });
        _addLog(
          'Check-in (entered location)',
          distance: 0,
          accuracy: pos.accuracy,
        );
      }
    } catch (e) {
      setState(() => _streamStatus = 'Could not set branch: $e');
      _addLog('Set branch failed: $e');
    }
  }

  void _onMapTapSetBranch(LatLng latLng) {
    setState(() {
      _branchLatCtrl.text = latLng.latitude.toStringAsFixed(6);
      _branchLngCtrl.text = latLng.longitude.toStringAsFixed(6);
    });
    _addLog(
      'Branch set by map tap (${latLng.latitude.toStringAsFixed(5)}, ${latLng.longitude.toStringAsFixed(5)})',
    );
    if (_position != null) {
      _evaluate(_position!);
    }
  }

  void _moveMapTo(double lat, double lng, {double zoom = 17}) {
    try {
      _mapController.move(LatLng(lat, lng), zoom);
    } catch (_) {
      // Map may not be ready yet
    }
  }

  void _recenterMap() {
    if (_hasBranch) {
      _moveMapTo(_branchLat!, _branchLng!);
    } else if (_position != null) {
      _moveMapTo(_position!.latitude, _position!.longitude);
    }
  }

  Future<void> _toggleStream() async {
    if (_streaming) {
      await _stopStream();
      return;
    }
    await _startStream();
  }

  Future<void> _startStream() async {
    final ok = await _ensurePermission();
    if (!ok) return;

    // Warm GPS before live decisions.
    final calibrated = await _calibrateGps();
    if (calibrated != null) {
      setState(() => _position = calibrated);
      _evaluate(calibrated);
    }

    await _posSub?.cancel();
    _posSub = Geolocator.getPositionStream(locationSettings: _preciseSettings)
        .listen(
          _onPosition,
          onError: (Object e) {
            setState(() => _streamStatus = 'GPS stream error: $e');
            _addLog('GPS error: $e');
          },
        );

    setState(() {
      _streaming = true;
      _streamStatus = calibrated == null
          ? 'Live tracking… (weak lock)'
          : 'Live tracking… ±${calibrated.accuracy.round()} m';
    });
    _addLog('GPS stream started', accuracy: calibrated?.accuracy);
  }

  Future<void> _stopStream() async {
    await _posSub?.cancel();
    _posSub = null;
    _graceTicker?.cancel();
    _graceTicker = null;
    setState(() {
      _streaming = false;
      _streamStatus = 'Tracking stopped';
    });
    _addLog('GPS stream stopped');
  }

  void _onPosition(Position pos) {
    final poor = pos.accuracy > _usableAccuracyM;
    setState(() {
      _position = pos;
      _streamStatus = poor
          ? 'Weak GPS ±${pos.accuracy.round()} m — move outdoors / wait'
          : 'Live tracking… ±${pos.accuracy.round()} m';
    });
    // Still show on map, but skip geofence flips on very noisy fixes.
    if (poor) {
      return;
    }
    _evaluate(pos);
  }

  void _evaluate(Position pos) {
    if (!_hasBranch) {
      setState(() {
        _distanceM = null;
        if (_state != AttendanceState.waiting) {
          _state = AttendanceState.waiting;
        }
      });
      return;
    }

    final dist = Geolocator.distanceBetween(
      pos.latitude,
      pos.longitude,
      _branchLat!,
      _branchLng!,
    );

    setState(() => _distanceM = dist);

    final withinCheckIn = dist <= _checkInRadius;
    final beyondCheckOut = dist > _checkOutRadius;

    if (withinCheckIn) {
      // CHECK-IN: inside inner radius
      _graceTicker?.cancel();
      _graceTicker = null;
      _graceDeadline = null;
      _graceSecondsLeft = 0;

      if (_state != AttendanceState.inBranch) {
        if (_state == AttendanceState.gracePeriod) {
          _addLog(
            'Check-in (returned during grace)',
            distance: dist,
            accuracy: pos.accuracy,
          );
        } else {
          _addLog(
            'Check-in (entered location)',
            distance: dist,
            accuracy: pos.accuracy,
          );
        }
        _setState(AttendanceState.inBranch);
      }
    } else if (_state == AttendanceState.inBranch && !beyondCheckOut) {
      // Hysteresis band: between check-in and check-out — stay checked in
      // Do nothing: keep state and do not log repeated pings.
    } else if (beyondCheckOut) {
      // CHECK-OUT: crossed outer radius
      if (_state == AttendanceState.inBranch) {
        _addLog(
          'Check-out (exited location)',
          distance: dist,
          accuracy: pos.accuracy,
        );
        _startGrace(dist, pos.accuracy);
      } else if (_state == AttendanceState.gracePeriod) {
        _refreshGraceCountdown();
      } else if (_state == AttendanceState.waiting) {
        _setState(AttendanceState.outside);
      }
    } else if (_state == AttendanceState.gracePeriod) {
      _refreshGraceCountdown();
    }
  }

  void _startGrace(double dist, double accuracy) {
    final secs = _graceSeconds;
    if (secs <= 0) {
      _setState(AttendanceState.outside);
      return;
    }
    _graceDeadline = DateTime.now().add(Duration(seconds: secs));
    _graceSecondsLeft = secs;
    _setState(AttendanceState.gracePeriod);

    _graceTicker?.cancel();
    _graceTicker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_graceDeadline == null) return;
      final left =
          _graceDeadline!.difference(DateTime.now()).inMilliseconds / 1000.0;
      if (left <= 0) {
        _graceTicker?.cancel();
        _graceTicker = null;
        _graceDeadline = null;
        setState(() => _graceSecondsLeft = 0);
        _setState(AttendanceState.outside);
      } else {
        setState(() => _graceSecondsLeft = left.ceil());
      }
    });
  }

  void _refreshGraceCountdown() {
    if (_graceDeadline == null) return;
    final left =
        _graceDeadline!.difference(DateTime.now()).inMilliseconds / 1000.0;
    setState(() => _graceSecondsLeft = left < 0 ? 0 : left.ceil());
  }

  void _setState(AttendanceState next) {
    if (next == _state) return;
    setState(() => _state = next);
  }

  void _clearLogs() => setState(() => _logs.clear());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Slip · Geofencing Field Test'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          TextButton(
            onPressed: _toggleStream,
            child: Text(_streaming ? 'Stop' : 'Start'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                children: [
                  _StatusBanner(
                    state: _state,
                    graceSecondsLeft: _graceSecondsLeft,
                    streamStatus: _streamStatus,
                    streaming: _streaming,
                  ),
                  const SizedBox(height: 12),
                  _sectionTitle('Map'),
                  const SizedBox(height: 8),
                  GeofenceMapPanel(
                    mapController: _mapController,
                    fenceColor: _fenceColor,
                    branchLat: _branchLat,
                    branchLng: _branchLng,
                    currentLat: _position?.latitude,
                    currentLng: _position?.longitude,
                    accuracyM: _position?.accuracy,
                    checkInRadiusM: _checkInRadius,
                    checkOutRadiusM: _checkOutRadius,
                    onMapTap: _onMapTapSetBranch,
                    onRecenter: _recenterMap,
                  ),
                  const SizedBox(height: 12),
                  _sectionTitle('Branch Setup'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _numField(
                          controller: _branchLatCtrl,
                          label: 'Branch Latitude',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _numField(
                          controller: _branchLngCtrl,
                          label: 'Branch Longitude',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _numField(
                          controller: _checkInCtrl,
                          label: 'Check-in Radius (m)',
                          integer: true,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _numField(
                          controller: _checkOutCtrl,
                          label: 'Check-out Radius (m)',
                          integer: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _numField(
                    controller: _graceCtrl,
                    label: 'Tea Stall Grace Period (s)',
                    integer: true,
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: _calibrating ? null : _setCurrentAsBranch,
                    icon: Icon(
                      _calibrating ? Icons.hourglass_top : Icons.my_location,
                    ),
                    label: Text(
                      _calibrating
                          ? 'Calibrating GPS…'
                          : 'Calibrate & Set Branch Here',
                    ),
                  ),
                  const SizedBox(height: 16),
                  _sectionTitle('Live GPS'),
                  const SizedBox(height: 8),
                  _MetricsGrid(
                    lat: _position?.latitude,
                    lng: _position?.longitude,
                    accuracy: _position?.accuracy,
                    distance: _distanceM,
                    checkInRadius: _checkInRadius,
                    checkOutRadius: _checkOutRadius,
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _toggleStream,
                    icon: Icon(_streaming ? Icons.stop : Icons.play_arrow),
                    label: Text(
                      _streaming ? 'Stop Live Tracking' : 'Start Live Tracking',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      _sectionTitle('Activity Log'),
                      const Spacer(),
                      TextButton(
                        onPressed: _logs.isEmpty ? null : _clearLogs,
                        child: const Text('Clear'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    height: 220,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.black12),
                        borderRadius: BorderRadius.circular(12),
                        color: Colors.white,
                      ),
                      child: _logs.isEmpty
                          ? const Center(
                              child: Text(
                                'No activity yet',
                                style: TextStyle(color: Colors.black45),
                              ),
                            )
                          : ListView.separated(
                              controller: _logScroll,
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              itemCount: _logs.length,
                              separatorBuilder: (context, index) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, i) {
                                final e = _logs[i];
                                return ListTile(
                                  dense: true,
                                  title: Text(
                                    e.event,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                  subtitle: Text(
                                    [
                                      _fmtTime(e.time),
                                      if (e.distance != null)
                                        '${e.distance!.toStringAsFixed(1)} m',
                                      if (e.accuracy != null)
                                        '±${e.accuracy!.round()} m',
                                    ].join(' · '),
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11,
                                    ),
                                  ),
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
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: Colors.black.withValues(alpha: 0.45),
      ),
    );
  }

  Widget _numField({
    required TextEditingController controller,
    required String label,
    bool integer = false,
  }) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.numberWithOptions(
        decimal: !integer,
        signed: true,
      ),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  String _fmtTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }
}

class _LogEntry {
  _LogEntry({
    required this.time,
    required this.event,
    this.distance,
    this.accuracy,
  });

  final DateTime time;
  final String event;
  final double? distance;
  final double? accuracy;
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.state,
    required this.graceSecondsLeft,
    required this.streamStatus,
    required this.streaming,
  });

  final AttendanceState state;
  final int graceSecondsLeft;
  final String streamStatus;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg, String label) = switch (state) {
      AttendanceState.waiting => (
        const Color(0xFFE8ECEA),
        const Color(0xFF5A6B66),
        'WAITING',
      ),
      AttendanceState.inBranch => (
        const Color(0xFFD8F5E7),
        const Color(0xFF1A8055),
        'IN BRANCH',
      ),
      AttendanceState.gracePeriod => (
        const Color(0xFFFFF0D1),
        const Color(0xFFC4840F),
        'TEA STALL / GRACE PERIOD',
      ),
      AttendanceState.outside => (
        const Color(0xFFFDE2DF),
        const Color(0xFFC0392B),
        'OUTSIDE / IN TRANSIT',
      ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: fg.withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          Text(
            'ATTENDANCE STATE',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
              color: fg.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: fg.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          if (state == AttendanceState.gracePeriod) ...[
            const SizedBox(height: 12),
            Text(
              '$graceSecondsLeft',
              style: TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.w600,
                color: fg,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            Text(
              's remaining',
              style: TextStyle(color: fg.withValues(alpha: 0.7)),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            streaming ? '● $streamStatus' : streamStatus,
            style: TextStyle(
              fontSize: 12,
              color: streaming ? const Color(0xFF1A8055) : Colors.black54,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricsGrid extends StatelessWidget {
  const _MetricsGrid({
    required this.lat,
    required this.lng,
    required this.accuracy,
    required this.distance,
    required this.checkInRadius,
    required this.checkOutRadius,
  });

  final double? lat;
  final double? lng;
  final double? accuracy;
  final double? distance;
  final double checkInRadius;
  final double checkOutRadius;

  @override
  Widget build(BuildContext context) {
    String zone = '—';
    if (distance != null) {
      if (distance! <= checkInRadius) {
        zone = 'INSIDE check-in';
      } else if (distance! <= checkOutRadius) {
        zone = 'Hysteresis band';
      } else {
        zone = 'OUTSIDE check-out';
      }
    }

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 2.2,
      children: [
        _metric('Current Lat', lat?.toStringAsFixed(6) ?? '—'),
        _metric('Current Lng', lng?.toStringAsFixed(6) ?? '—'),
        _metric(
          'GPS Accuracy',
          accuracy != null ? '±${accuracy!.toStringAsFixed(1)} m' : '—',
        ),
        _metric(
          'Distance to Branch',
          distance != null ? '${distance!.toStringAsFixed(1)} m' : '—',
        ),
        _metric(
          'Check-in / Out',
          '${checkInRadius.round()} / ${checkOutRadius.round()} m',
        ),
        _metric('Zone', zone),
      ],
    );
  }

  Widget _metric(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F6F5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
              color: Colors.black.withValues(alpha: 0.45),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}
