import { useEffect, useMemo, useRef } from 'react';
import {
  Circle,
  MapContainer,
  Marker,
  TileLayer,
  useMap,
  useMapEvents,
} from 'react-leaflet';
import L from 'leaflet';

const FENCE_COLORS = {
  IN_BRANCH: { color: '#1a8055', fill: '#22a06b' },
  GRACE_PERIOD: { color: '#c4840f', fill: '#e09b1a' },
  OUTSIDE: { color: '#c0392b', fill: '#e04a40' },
  WAITING: { color: '#64748b', fill: '#94a3b8' },
};

function makePinIcon(kind) {
  return L.divIcon({
    className: '',
    html: `<div class="map-pin map-pin-${kind}"><span>${kind === 'branch' ? 'B' : 'S'}</span></div>`,
    iconSize: [28, 28],
    iconAnchor: [14, 28],
    popupAnchor: [0, -28],
  });
}

function MapClickHandler({ onMapClick }) {
  useMapEvents({
    click(e) {
      onMapClick?.(e.latlng.lat, e.latlng.lng);
    },
  });
  return null;
}

function FitBounds({ branch, staff, radius }) {
  const map = useMap();
  const fitted = useRef(false);

  useEffect(() => {
    if (!branch) return;
    const points = [[branch.latitude, branch.longitude]];
    if (staff) points.push([staff.lat, staff.lng]);
    const bounds = L.latLngBounds(points);
    // Expand roughly by geofence radius
    const pad = Math.max(0.0003, (radius || 30) / 111320);
    bounds.extend([branch.latitude + pad, branch.longitude + pad]);
    bounds.extend([branch.latitude - pad, branch.longitude - pad]);
    map.fitBounds(bounds.pad(0.4));
    fitted.current = true;
  }, [map, branch?.id, branch?.latitude, branch?.longitude, radius]);

  return null;
}

function InvalidateSize() {
  const map = useMap();
  useEffect(() => {
    const t = setTimeout(() => map.invalidateSize(), 80);
    const onResize = () => map.invalidateSize();
    window.addEventListener('resize', onResize);
    return () => {
      clearTimeout(t);
      window.removeEventListener('resize', onResize);
    };
  }, [map]);
  return null;
}

export default function GeofenceMap({
  branch,
  staff,
  status,
  baseLayer,
  onBaseLayerChange,
  onMapClick,
  onStaffDragEnd,
  followGps,
  onFollowGps,
}) {
  const branchIcon = useMemo(() => makePinIcon('branch'), []);
  const staffIcon = useMemo(() => makePinIcon('staff'), []);
  const fence = FENCE_COLORS[status] || FENCE_COLORS.WAITING;
  const center = branch
    ? [branch.latitude, branch.longitude]
    : staff
      ? [staff.lat, staff.lng]
      : [10.0159, 76.3419];

  return (
    <section className="rounded-2xl border border-ink-200 bg-white overflow-hidden shadow-sm">
      <div className="relative">
        <MapContainer
          id="map"
          center={center}
          zoom={17}
          scrollWheelZoom
          className="rounded-t-2xl"
          style={{ height: 350, width: '100%' }}
        >
          {baseLayer === 'sat' ? (
            <TileLayer
              url="https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"
              attribution="Tiles &copy; Esri"
              maxZoom={19}
            />
          ) : (
            <TileLayer
              url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
              attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
              maxZoom={19}
            />
          )}

          <MapClickHandler onMapClick={onMapClick} />
          <InvalidateSize />
          {branch && (
            <FitBounds branch={branch} staff={staff} radius={branch.radius_meters} />
          )}

          {branch && (
            <>
              <Marker position={[branch.latitude, branch.longitude]} icon={branchIcon} />
              <Circle
                center={[branch.latitude, branch.longitude]}
                radius={branch.radius_meters}
                pathOptions={{
                  color: fence.color,
                  fillColor: fence.fill,
                  fillOpacity: 0.18,
                  weight: 2,
                  opacity: 0.9,
                }}
              />
            </>
          )}

          {staff && (
            <>
              <Marker
                position={[staff.lat, staff.lng]}
                icon={staffIcon}
                draggable
                eventHandlers={{
                  dragend: (e) => {
                    const p = e.target.getLatLng();
                    onStaffDragEnd?.(p.lat, p.lng, staff.accuracy ?? 10);
                  },
                }}
              />
              <Circle
                center={[staff.lat, staff.lng]}
                radius={staff.accuracy > 0 ? staff.accuracy : 10}
                pathOptions={{
                  color: '#2563eb',
                  fillColor: '#3b82f6',
                  fillOpacity: 0.08,
                  weight: 1,
                  opacity: 0.35,
                }}
                interactive={false}
              />
            </>
          )}
        </MapContainer>

        <div className="absolute top-3 right-3 z-[1000] flex flex-col gap-2 items-end">
          <div className="inline-flex rounded-lg overflow-hidden border border-ink-200 bg-white/95 shadow-sm text-xs font-medium">
            <button
              type="button"
              onClick={() => onBaseLayerChange('street')}
              className={
                baseLayer === 'street'
                  ? 'px-3 py-1.5 bg-ink-800 text-white'
                  : 'px-3 py-1.5 text-ink-700 hover:bg-ink-50'
              }
            >
              Street
            </button>
            <button
              type="button"
              onClick={() => onBaseLayerChange('sat')}
              className={
                baseLayer === 'sat'
                  ? 'px-3 py-1.5 bg-ink-800 text-white'
                  : 'px-3 py-1.5 text-ink-700 hover:bg-ink-50'
              }
            >
              Satellite
            </button>
          </div>
          {!followGps && (
            <button
              type="button"
              onClick={onFollowGps}
              className="rounded-lg border border-ink-200 bg-white/95 shadow-sm px-3 py-1.5 text-xs font-medium text-ink-800 hover:bg-ink-50"
            >
              Follow GPS
            </button>
          )}
        </div>

        <p className="absolute bottom-3 left-3 right-3 z-[1000] pointer-events-none text-[10px] sm:text-xs text-ink-800/80 bg-white/85 backdrop-blur-sm rounded-lg px-2.5 py-1.5 shadow-sm">
          Click map = set branch · Drag blue pin = walk to tea stall
        </p>
      </div>

      <div className="flex items-center gap-4 px-4 py-2.5 border-t border-ink-100 text-[11px] text-ink-700/60">
        <span className="inline-flex items-center gap-1.5">
          <span className="h-2.5 w-2.5 rounded-full bg-ink-800" /> Branch
        </span>
        <span className="inline-flex items-center gap-1.5">
          <span className="h-2.5 w-2.5 rounded-full bg-blue-600" /> Staff (drag me)
        </span>
        <span className="inline-flex items-center gap-1.5">
          <span className="h-2.5 w-2.5 rounded-full bg-leaf-500/40 ring-1 ring-leaf-500" /> Geofence
        </span>
      </div>
    </section>
  );
}
