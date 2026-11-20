import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:material_ui/material_ui.dart';

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
  final _radiusCtrl = TextEditingController(text: '25');
  final _graceCtrl = TextEditingController(text: '60');
  final _logScroll = ScrollController();

  StreamSubscription<Position>? _posSub;
  Timer? _graceTicker;

  Position? _position;
  double? _distanceM;
  AttendanceState _state = AttendanceState.waiting;
  DateTime? _graceDeadline;
  int _graceSecondsLeft = 0;
  bool _streaming = false;
  String _streamStatus = 'Start tracking to begin field test';
  final List<_LogEntry> _logs = [];

  double get _radius {
    final v = double.tryParse(_radiusCtrl.text.trim());
    return (v == null || v < 1) ? 25 : v;
  }

  int get _graceSeconds {
    final v = int.tryParse(_graceCtrl.text.trim());
    return (v == null || v < 1) ? 60 : v;
  }

  double? get _branchLat => double.tryParse(_branchLatCtrl.text.trim());
  double? get _branchLng => double.tryParse(_branchLngCtrl.text.trim());
  bool get _hasBranch => _branchLat != null && _branchLng != null;

  @override
  void dispose() {
    _posSub?.cancel();
    _graceTicker?.cancel();
    _branchLatCtrl.dispose();
    _branchLngCtrl.dispose();
    _radiusCtrl.dispose();
    _graceCtrl.dispose();
    _logScroll.dispose();
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
      setState(() => _streamStatus = 'Location services are disabled');
      _addLog('Location services disabled');
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
      setState(() => _streamStatus = 'Permission permanently denied — enable in Settings');
      _addLog('Permission permanently denied');
      return false;
    }

    return true;
  }

  Future<void> _setCurrentAsBranch() async {
    try {
      final ok = await _ensurePermission();
      if (!ok) return;

      final pos = _position ??
          await Geolocator.getCurrentPosition(
            locationSettings: AndroidSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: const Duration(seconds: 20),
            ),
          );

      setState(() {
        _branchLatCtrl.text = pos.latitude.toStringAsFixed(6);
        _branchLngCtrl.text = pos.longitude.toStringAsFixed(6);
        _position = pos;
      });
      _addLog(
        'Branch set to current spot',
        distance: 0,
        accuracy: pos.accuracy,
      );

      if (_streaming) {
        _evaluate(pos);
      } else {
        setState(() {
          _distanceM = 0;
          _setState(AttendanceState.inBranch, distance: 0, accuracy: pos.accuracy);
        });
      }
    } catch (e) {
      setState(() => _streamStatus = 'Could not set branch: $e');
      _addLog('Set branch failed: $e');
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

    await _posSub?.cancel();
    _posSub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 2,
        intervalDuration: const Duration(seconds: 3),
      ),
    ).listen(
      _onPosition,
      onError: (Object e) {
        setState(() => _streamStatus = 'GPS stream error: $e');
        _addLog('GPS error: $e');
      },
    );

    setState(() {
      _streaming = true;
      _streamStatus = 'Live tracking…';
    });
    _addLog('GPS stream started');
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
    setState(() {
      _position = pos;
      _streamStatus = 'Live tracking…';
    });
    _evaluate(pos);
  }

  void _evaluate(Position pos) {
    if (!_hasBranch) {
      setState(() {
        _distanceM = null;
        _state = AttendanceState.waiting;
      });
      _addLog(
        'GPS ping (set branch first)',
        accuracy: pos.accuracy,
      );
      return;
    }

    final dist = Geolocator.distanceBetween(
      pos.latitude,
      pos.longitude,
      _branchLat!,
      _branchLng!,
    );

    setState(() => _distanceM = dist);

    final inside = dist <= _radius;

    if (inside) {
      _graceTicker?.cancel();
      _graceTicker = null;
      _graceDeadline = null;
      _graceSecondsLeft = 0;
      if (_state == AttendanceState.gracePeriod) {
        _addLog('Returned inside during grace', distance: dist, accuracy: pos.accuracy);
      } else if (_state == AttendanceState.inBranch) {
        _addLog('GPS ping (in branch)', distance: dist, accuracy: pos.accuracy);
      }
      _setState(AttendanceState.inBranch, distance: dist, accuracy: pos.accuracy);
    } else {
      if (_state == AttendanceState.inBranch || _state == AttendanceState.waiting) {
        _startGrace(dist, pos.accuracy);
      } else if (_state == AttendanceState.gracePeriod) {
        _refreshGraceCountdown();
        _addLog('GPS ping (still in grace)', distance: dist, accuracy: pos.accuracy);
      } else {
        _addLog('GPS ping (outside)', distance: dist, accuracy: pos.accuracy);
      }
    }
  }

  void _startGrace(double dist, double accuracy) {
    final secs = _graceSeconds;
    _graceDeadline = DateTime.now().add(Duration(seconds: secs));
    _graceSecondsLeft = secs;
    _setState(AttendanceState.gracePeriod, distance: dist, accuracy: accuracy);
    _addLog('Grace period started (${secs}s)', distance: dist, accuracy: accuracy);

    _graceTicker?.cancel();
    _graceTicker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_graceDeadline == null) return;
      final left = _graceDeadline!.difference(DateTime.now()).inMilliseconds / 1000.0;
      if (left <= 0) {
        _graceTicker?.cancel();
        _graceTicker = null;
        _graceDeadline = null;
        setState(() => _graceSecondsLeft = 0);
        _setState(
          AttendanceState.outside,
          distance: _distanceM,
          accuracy: _position?.accuracy,
        );
        _addLog(
          'Grace expired → OUTSIDE',
          distance: _distanceM,
          accuracy: _position?.accuracy,
        );
      } else {
        setState(() => _graceSecondsLeft = left.ceil());
      }
    });
  }

  void _refreshGraceCountdown() {
    if (_graceDeadline == null) return;
    final left = _graceDeadline!.difference(DateTime.now()).inMilliseconds / 1000.0;
    setState(() => _graceSecondsLeft = left < 0 ? 0 : left.ceil());
  }

  void _setState(AttendanceState next, {double? distance, double? accuracy}) {
    if (next == _state) return;
    final prev = _state;
    setState(() => _state = next);
    _addLog(
      'State: ${_label(prev)} → ${_label(next)}',
      distance: distance,
      accuracy: accuracy,
    );
  }

  String _label(AttendanceState s) => switch (s) {
        AttendanceState.waiting => 'WAITING',
        AttendanceState.inBranch => 'IN_BRANCH',
        AttendanceState.gracePeriod => 'GRACE_PERIOD',
        AttendanceState.outside => 'OUTSIDE',
      };

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
                          controller: _radiusCtrl,
                          label: 'Geofence Radius (m)',
                          integer: true,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _numField(
                          controller: _graceCtrl,
                          label: 'Grace Period (s)',
                          integer: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: _setCurrentAsBranch,
                    icon: const Icon(Icons.my_location),
                    label: const Text('Set Current Spot as Branch'),
                  ),
                  const SizedBox(height: 16),
                  _sectionTitle('Live GPS'),
                  const SizedBox(height: 8),
                  _MetricsGrid(
                    lat: _position?.latitude,
                    lng: _position?.longitude,
                    accuracy: _position?.accuracy,
                    distance: _distanceM,
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _toggleStream,
                    icon: Icon(_streaming ? Icons.stop : Icons.play_arrow),
                    label: Text(_streaming ? 'Stop Live Tracking' : 'Start Live Tracking'),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      _sectionTitle('Event Log'),
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
                                'No events yet',
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
      keyboardType: TextInputType.numberWithOptions(decimal: !integer, signed: true),
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
  });

  final double? lat;
  final double? lng;
  final double? accuracy;
  final double? distance;

  @override
  Widget build(BuildContext context) {
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
