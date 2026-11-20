import { useCallback, useEffect, useRef, useState } from 'react';
import GeofenceMap from './components/GeofenceMap';
import { GEO_OPTS, SAMPLE, STAFF_ID, api } from './api';

const BADGE = {
  WAITING: {
    badge: 'border-ink-200',
    label: 'text-ink-700/50 bg-ink-100',
    text: 'WAITING FOR GPS…',
  },
  IN_BRANCH: {
    badge: 'border-leaf-400/40 bg-leaf-400/5',
    label: 'text-leaf-600 bg-leaf-400/15',
    text: 'IN BRANCH',
  },
  GRACE_PERIOD: {
    badge: 'border-amber-400/50 bg-amber-400/5',
    label: 'text-amber-500 bg-amber-400/15',
    text: 'TEA STALL / GRACE PERIOD',
  },
  OUTSIDE: {
    badge: 'border-coral-400/50 bg-coral-400/5',
    label: 'text-coral-500 bg-coral-400/15',
    text: 'OUTSIDE / IN TRANSIT',
  },
};

function formatTime(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  return (
    d.toLocaleTimeString('en-GB', { hour12: false }) +
    '.' +
    String(d.getMilliseconds()).padStart(3, '0')
  );
}

export default function App() {
  const [branch, setBranch] = useState(null);
  const [branchLat, setBranchLat] = useState('');
  const [branchLng, setBranchLng] = useState('');
  const [radius, setRadius] = useState(30);
  const [graceSeconds, setGraceSeconds] = useState(15);

  const [staffPos, setStaffPos] = useState(null);
  const [status, setStatus] = useState('WAITING');
  const [distance, setDistance] = useState(null);
  const [graceRemaining, setGraceRemaining] = useState(null);
  const [activeBranchName, setActiveBranchName] = useState(null);
  const [gpsStatus, setGpsStatus] = useState('Starting…');
  const [gpsAccuracy, setGpsAccuracy] = useState(null);
  const [lastPing, setLastPing] = useState(null);

  const [mockOutside, setMockOutside] = useState(false);
  const [followGps, setFollowGps] = useState(true);
  const [baseLayer, setBaseLayer] = useState('street');
  const [logs, setLogs] = useState([]);
  const [backendOk, setBackendOk] = useState(null);
  const [busy, setBusy] = useState(false);

  const watchIdRef = useRef(null);
  const liveGpsRef = useRef(null);
  const followGpsRef = useRef(true);
  const mockRef = useRef(false);
  const graceRef = useRef(15);
  const staffPosRef = useRef(null);
  const branchIdRef = useRef(null);
  const pingingRef = useRef(false);

  useEffect(() => {
    followGpsRef.current = followGps;
  }, [followGps]);
  useEffect(() => {
    mockRef.current = mockOutside;
  }, [mockOutside]);
  useEffect(() => {
    graceRef.current = graceSeconds;
  }, [graceSeconds]);
  useEffect(() => {
    staffPosRef.current = staffPos;
  }, [staffPos]);

  const refreshLogs = useCallback(async () => {
    try {
      const data = await api.getLogs(100);
      setLogs(data);
    } catch {
      /* ignore */
    }
  }, []);

  const applyPingResult = useCallback((result, pos) => {
    setStatus(result.status);
    setDistance(result.distance_meters);
    setGraceRemaining(result.grace_seconds_remaining);
    setActiveBranchName(result.active_branch_name);
    if (pos) {
      setStaffPos({
        lat: pos.latitude,
        lng: pos.longitude,
        accuracy: pos.accuracy_meters ?? pos.accuracy ?? 10,
      });
      setGpsAccuracy(pos.accuracy_meters ?? pos.accuracy ?? null);
    }
    setLastPing(new Date().toISOString());
  }, []);

  const sendPing = useCallback(
    async ({ latitude, longitude, accuracy_meters, is_mock_outside }) => {
      if (pingingRef.current) return null;
      pingingRef.current = true;
      try {
        const result = await api.ping({
          staff_id: STAFF_ID,
          latitude,
          longitude,
          accuracy_meters,
          recorded_at: new Date().toISOString(),
          is_mock_outside: Boolean(is_mock_outside),
          grace_period_seconds: graceRef.current,
        });
        applyPingResult(result, {
          latitude,
          longitude,
          accuracy_meters,
        });
        await refreshLogs();
        return result;
      } catch (err) {
        setGpsStatus(err.message || 'Ping failed');
        return null;
      } finally {
        pingingRef.current = false;
      }
    },
    [applyPingResult, refreshLogs]
  );

  const syncBranchFromForm = useCallback(
    async (lat, lng, rad) => {
      const latitude = parseFloat(lat);
      const longitude = parseFloat(lng);
      const radius_meters = parseFloat(rad) || 30;
      if (Number.isNaN(latitude) || Number.isNaN(longitude)) return null;

      try {
        let updated;
        if (branchIdRef.current) {
          updated = await api.updateBranch(branchIdRef.current, {
            latitude,
            longitude,
            radius_meters,
          });
        } else {
          updated = await api.createBranch({
            name: 'Demo Branch',
            latitude,
            longitude,
            radius_meters,
          });
          branchIdRef.current = updated.id;
        }
        setBranch(updated);
        setBranchLat(String(updated.latitude));
        setBranchLng(String(updated.longitude));
        setRadius(updated.radius_meters);
        await refreshLogs();
        return updated;
      } catch (err) {
        console.error(err);
        return null;
      }
    },
    [refreshLogs]
  );

  // Bootstrap: health + default branch
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        await api.health();
        if (cancelled) return;
        setBackendOk(true);
        const branches = await api.listBranches();
        if (cancelled) return;
        if (branches.length) {
          const b = branches[0];
          branchIdRef.current = b.id;
          setBranch(b);
          setBranchLat(String(b.latitude));
          setBranchLng(String(b.longitude));
          setRadius(b.radius_meters);
        }
        await refreshLogs();
      } catch {
        if (!cancelled) setBackendOk(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [refreshLogs]);

  // Live geolocation watch
  useEffect(() => {
    if (!navigator.geolocation) {
      setGpsStatus('Geolocation not supported');
      return undefined;
    }

    const onPos = async (pos) => {
      liveGpsRef.current = pos;
      if (!followGpsRef.current) return;

      const { latitude, longitude, accuracy } = pos.coords;
      setStaffPos({ lat: latitude, lng: longitude, accuracy });
      setGpsAccuracy(accuracy);
      setLastPing(new Date().toISOString());
      setGpsStatus('Tracking');

      await sendPing({
        latitude,
        longitude,
        accuracy_meters: accuracy,
        is_mock_outside: mockRef.current,
      });
    };

    const onErr = (err) => {
      if (err.code === 3) {
        setGpsStatus('Retrying (Wi-Fi)…');
        if (watchIdRef.current != null) {
          navigator.geolocation.clearWatch(watchIdRef.current);
        }
        watchIdRef.current = navigator.geolocation.watchPosition(onPos, (e2) => {
          setGpsStatus(e2.message || 'GPS error');
        }, GEO_OPTS);
        return;
      }
      setGpsStatus(err.message || 'GPS error');
    };

    watchIdRef.current = navigator.geolocation.watchPosition(onPos, onErr, GEO_OPTS);

    return () => {
      if (watchIdRef.current != null) {
        navigator.geolocation.clearWatch(watchIdRef.current);
      }
    };
  }, [sendPing]);

  // Local grace countdown tick (server is source of truth on each ping)
  useEffect(() => {
    if (status !== 'GRACE_PERIOD' || graceRemaining == null) return undefined;
    const id = setInterval(() => {
      setGraceRemaining((prev) => {
        if (prev == null) return prev;
        const next = Math.max(0, prev - 0.2);
        return next;
      });
    }, 200);
    return () => clearInterval(id);
  }, [status, graceRemaining != null]);

  // Re-ping when mock toggles (skip initial mount)
  const mockInitRef = useRef(true);
  useEffect(() => {
    if (mockInitRef.current) {
      mockInitRef.current = false;
      return;
    }
    const pos = staffPosRef.current;
    if (!pos) return;
    sendPing({
      latitude: pos.lat,
      longitude: pos.lng,
      accuracy_meters: pos.accuracy,
      is_mock_outside: mockOutside,
    });
  }, [mockOutside, sendPing]);

  const handleMapClick = async (lat, lng) => {
    setBranchLat(lat.toFixed(6));
    setBranchLng(lng.toFixed(6));
    await syncBranchFromForm(lat, lng, radius);
    if (staffPos) {
      await sendPing({
        latitude: staffPos.lat,
        longitude: staffPos.lng,
        accuracy_meters: staffPos.accuracy,
        is_mock_outside: mockOutside,
      });
    }
  };

  const handleStaffDragEnd = async (lat, lng, accuracy) => {
    setFollowGps(false);
    setStaffPos({ lat, lng, accuracy });
    setGpsStatus('Manual (dragged)');
    setGpsAccuracy(accuracy);
    await sendPing({
      latitude: lat,
      longitude: lng,
      accuracy_meters: accuracy,
      is_mock_outside: false,
    });
  };

  const handleFollowGps = () => {
    setFollowGps(true);
    setGpsStatus('Following GPS…');
    const pos = liveGpsRef.current;
    if (pos) {
      const { latitude, longitude, accuracy } = pos.coords;
      setStaffPos({ lat: latitude, lng: longitude, accuracy });
      sendPing({
        latitude,
        longitude,
        accuracy_meters: accuracy,
        is_mock_outside: mockOutside,
      });
    }
  };

  const handleUseCurrent = async () => {
    setBusy(true);
    try {
      const pos =
        liveGpsRef.current ||
        (await new Promise((resolve, reject) => {
          navigator.geolocation.getCurrentPosition(resolve, reject, GEO_OPTS);
        }));

      const { latitude, longitude, accuracy } = pos.coords;
      liveGpsRef.current = pos;
      setFollowGps(true);
      setBranchLat(latitude.toFixed(6));
      setBranchLng(longitude.toFixed(6));
      setStaffPos({ lat: latitude, lng: longitude, accuracy });
      setGpsAccuracy(accuracy);
      setGpsStatus('Tracking');

      await syncBranchFromForm(latitude, longitude, radius);
      await sendPing({
        latitude,
        longitude,
        accuracy_meters: accuracy,
        is_mock_outside: false,
      });
    } catch (err) {
      alert(err.message || 'Could not get your location.');
    } finally {
      setBusy(false);
    }
  };

  const handleSample = async () => {
    setBusy(true);
    try {
      setFollowGps(false);
      setBranchLat(SAMPLE.lat.toFixed(4));
      setBranchLng(SAMPLE.lng.toFixed(4));
      setStaffPos({ lat: SAMPLE.lat, lng: SAMPLE.lng, accuracy: 10 });
      setGpsAccuracy(10);
      setGpsStatus('Sample coords');

      await syncBranchFromForm(SAMPLE.lat, SAMPLE.lng, radius);
      await sendPing({
        latitude: SAMPLE.lat,
        longitude: SAMPLE.lng,
        accuracy_meters: 10,
        is_mock_outside: false,
      });
    } finally {
      setBusy(false);
    }
  };

  const handleRadiusBlur = async () => {
    if (!branchLat || !branchLng) return;
    await syncBranchFromForm(branchLat, branchLng, radius);
    if (staffPos) {
      await sendPing({
        latitude: staffPos.lat,
        longitude: staffPos.lng,
        accuracy_meters: staffPos.accuracy,
        is_mock_outside: mockOutside,
      });
    }
  };

  const handleClearLogs = async () => {
    await api.clearLogs();
    await refreshLogs();
  };

  const uiStatus = status === 'WAITING' && !staffPos ? 'WAITING' : status;
  const badge = BADGE[uiStatus] || BADGE.WAITING;

  return (
    <div className="max-w-3xl mx-auto px-4 py-6 sm:py-10 space-y-5">
      <header className="space-y-1">
        <p className="text-xs font-medium uppercase tracking-widest text-leaf-600">
          Slip · Attendance Geofence
        </p>
        <h1 className="text-2xl sm:text-3xl font-bold tracking-tight text-ink-900">
          Branch Test Lab
        </h1>
        <p className="text-sm text-ink-700/70">
          FastAPI · React · Leaflet · Tea-stall grace period
          {backendOk === false && (
            <span className="ml-2 text-coral-500">· Backend offline</span>
          )}
          {backendOk === true && (
            <span className="ml-2 text-leaf-600">· API connected</span>
          )}
        </p>
      </header>

      {/* Status banner */}
      <section
        className={`rounded-2xl border px-5 py-6 sm:px-8 sm:py-8 text-center transition-colors duration-300 ${badge.badge}`}
      >
        <p className="text-xs font-medium uppercase tracking-widest text-ink-700/50 mb-3">
          Attendance State
          {activeBranchName ? ` · ${activeBranchName}` : ''}
        </p>
        <div
          className={`inline-flex items-center gap-2 rounded-full px-5 py-2.5 text-sm sm:text-base font-semibold badge-pulse ${badge.label}`}
        >
          <span className="h-2.5 w-2.5 rounded-full bg-current" />
          <span>{badge.text}</span>
        </div>
        {uiStatus === 'GRACE_PERIOD' && graceRemaining != null && (
          <p className="mt-3 font-mono text-2xl sm:text-3xl font-medium text-amber-500 tabular-nums">
            {Math.ceil(graceRemaining)}
            <span className="text-base text-ink-700/40 ml-1">s remaining</span>
          </p>
        )}
      </section>

      <GeofenceMap
        branch={branch}
        staff={staffPos}
        status={uiStatus}
        baseLayer={baseLayer}
        onBaseLayerChange={setBaseLayer}
        onMapClick={handleMapClick}
        onStaffDragEnd={handleStaffDragEnd}
        followGps={followGps}
        onFollowGps={handleFollowGps}
      />

      {/* Branch setup */}
      <section className="rounded-2xl border border-ink-200 bg-white p-5 sm:p-6 space-y-4">
        <h2 className="text-sm font-semibold uppercase tracking-wider text-ink-700/60">
          Branch Setup
        </h2>
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
          <label className="block space-y-1.5">
            <span className="text-xs font-medium text-ink-700/70">Branch Latitude</span>
            <input
              type="number"
              step="any"
              value={branchLat}
              onChange={(e) => setBranchLat(e.target.value)}
              onBlur={() => syncBranchFromForm(branchLat, branchLng, radius)}
              placeholder="e.g. 12.9716"
              className="w-full rounded-lg border border-ink-200 bg-ink-50 px-3 py-2.5 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-leaf-500/40"
            />
          </label>
          <label className="block space-y-1.5">
            <span className="text-xs font-medium text-ink-700/70">Branch Longitude</span>
            <input
              type="number"
              step="any"
              value={branchLng}
              onChange={(e) => setBranchLng(e.target.value)}
              onBlur={() => syncBranchFromForm(branchLat, branchLng, radius)}
              placeholder="e.g. 77.5946"
              className="w-full rounded-lg border border-ink-200 bg-ink-50 px-3 py-2.5 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-leaf-500/40"
            />
          </label>
          <label className="block space-y-1.5">
            <span className="text-xs font-medium text-ink-700/70">Geofence Radius (m)</span>
            <input
              type="number"
              min={1}
              step={1}
              value={radius}
              onChange={(e) => setRadius(Number(e.target.value) || 30)}
              onBlur={handleRadiusBlur}
              className="w-full rounded-lg border border-ink-200 bg-ink-50 px-3 py-2.5 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-leaf-500/40"
            />
          </label>
        </div>

        <div className="flex flex-col gap-3">
          <label className="block space-y-1.5">
            <span className="text-xs font-medium text-ink-700/70">
              Tea Stall Grace Period (seconds)
            </span>
            <input
              type="number"
              min={1}
              step={1}
              value={graceSeconds}
              onChange={(e) => setGraceSeconds(Number(e.target.value) || 15)}
              className="w-full rounded-lg border border-ink-200 bg-ink-50 px-3 py-2.5 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-leaf-500/40"
            />
          </label>
          <div className="flex flex-col sm:flex-row gap-2">
            <button
              type="button"
              disabled={busy}
              onClick={handleUseCurrent}
              className="rounded-lg bg-ink-800 hover:bg-ink-900 disabled:opacity-60 text-white text-sm font-medium px-4 py-2.5 transition-colors"
            >
              Use My Current Location as Branch
            </button>
            <button
              type="button"
              disabled={busy}
              onClick={handleSample}
              className="rounded-lg border border-ink-200 bg-white hover:bg-ink-50 text-ink-800 text-sm font-medium px-4 py-2.5 transition-colors"
            >
              Load Sample Location
            </button>
          </div>
        </div>
      </section>

      {/* Live metrics */}
      <section className="rounded-2xl border border-ink-200 bg-white p-5 sm:p-6 space-y-4">
        <div className="flex items-center justify-between gap-3">
          <h2 className="text-sm font-semibold uppercase tracking-wider text-ink-700/60">
            Live Geolocation
          </h2>
          <span
            className={`text-xs font-medium ${
              gpsStatus === 'Tracking'
                ? 'text-leaf-600'
                : gpsStatus.includes('error') || gpsStatus.includes('failed')
                  ? 'text-coral-500'
                  : 'text-ink-700/40'
            }`}
          >
            {gpsStatus}
          </span>
        </div>

        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
          <Metric label="Current Lat" value={staffPos ? staffPos.lat.toFixed(6) : '—'} />
          <Metric label="Current Lng" value={staffPos ? staffPos.lng.toFixed(6) : '—'} />
          <Metric
            label="GPS Accuracy"
            value={gpsAccuracy != null ? `±${Math.round(gpsAccuracy)} m` : '—'}
          />
          <Metric
            label="Distance"
            value={
              distance != null
                ? `${Number(distance).toFixed(1)} m${mockOutside ? ' (mock)' : ''}`
                : '—'
            }
          />
        </div>

        <p className="text-xs text-ink-700/50">
          Last ping: <span className="font-mono text-ink-700">{formatTime(lastPing)}</span>
        </p>

        <div className="flex items-center justify-between gap-4 rounded-xl border border-ink-100 bg-ink-50/80 px-4 py-3">
          <div>
            <p className="text-sm font-medium text-ink-800">
              Simulate Walking Away (Mock Outside)
            </p>
            <p className="text-xs text-ink-700/50 mt-0.5">
              Forces distance beyond the geofence via API
            </p>
          </div>
          <button
            type="button"
            role="switch"
            aria-checked={mockOutside}
            onClick={() => setMockOutside((v) => !v)}
            className={`toggle-track relative h-7 w-12 shrink-0 rounded-full focus:outline-none focus:ring-2 focus:ring-leaf-500/40 ${
              mockOutside ? 'bg-amber-500' : 'bg-ink-200'
            }`}
          >
            <span
              className="toggle-knob absolute top-0.5 left-0.5 h-6 w-6 rounded-full bg-white shadow"
              style={{ transform: mockOutside ? 'translateX(1.25rem)' : 'translateX(0)' }}
            />
          </button>
        </div>
      </section>

      {/* Logs */}
      <section className="rounded-2xl border border-ink-200 bg-white p-5 sm:p-6 space-y-3">
        <div className="flex items-center justify-between gap-3">
          <h2 className="text-sm font-semibold uppercase tracking-wider text-ink-700/60">
            Live Activity Log
          </h2>
          <button
            type="button"
            onClick={handleClearLogs}
            className="text-xs font-medium text-ink-700/60 hover:text-coral-500 transition-colors"
          >
            Clear Logs
          </button>
        </div>
        <div className="log-scroll max-h-64 overflow-y-auto rounded-xl border border-ink-100">
          <table className="w-full text-left text-xs">
            <thead className="sticky top-0 bg-ink-50 text-ink-700/50 uppercase tracking-wider">
              <tr>
                <th className="px-3 py-2 font-medium">Time</th>
                <th className="px-3 py-2 font-medium">Event</th>
                <th className="px-3 py-2 font-medium hidden sm:table-cell">Dist</th>
                <th className="px-3 py-2 font-medium hidden sm:table-cell">Acc</th>
              </tr>
            </thead>
            <tbody className="font-mono divide-y divide-ink-100">
              {logs.length === 0 ? (
                <tr>
                  <td
                    colSpan={4}
                    className="px-3 py-6 text-center text-ink-700/40 font-sans"
                  >
                    No events yet
                  </td>
                </tr>
              ) : (
                logs.map((row) => (
                  <tr key={row.id} className="hover:bg-ink-50/80">
                    <td className="px-3 py-2 whitespace-nowrap text-ink-700/60">
                      {formatTime(row.timestamp)}
                    </td>
                    <td className="px-3 py-2 text-ink-800">{row.event}</td>
                    <td className="px-3 py-2 hidden sm:table-cell text-ink-700/70">
                      {row.distance_meters != null
                        ? `${Number(row.distance_meters).toFixed(1)} m`
                        : '—'}
                    </td>
                    <td className="px-3 py-2 hidden sm:table-cell text-ink-700/70">
                      {row.accuracy_meters != null
                        ? `±${Math.round(row.accuracy_meters)} m`
                        : '—'}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </section>

      <p className="text-center text-[11px] text-ink-700/40 pb-4">
        Backend <code className="font-mono">:8000</code> · Frontend{' '}
        <code className="font-mono">:5173</code>
      </p>
    </div>
  );
}

function Metric({ label, value }) {
  return (
    <div className="rounded-xl bg-ink-50 px-3 py-3 space-y-1">
      <p className="text-[10px] uppercase tracking-wider text-ink-700/50 font-medium">
        {label}
      </p>
      <p className="font-mono text-sm font-medium truncate">{value}</p>
    </div>
  );
}
