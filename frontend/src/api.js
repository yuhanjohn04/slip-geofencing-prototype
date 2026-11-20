const API_BASE = import.meta.env.VITE_API_BASE || '';

async function request(path, options = {}) {
  const res = await fetch(`${API_BASE}${path}`, {
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
    ...options,
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(text || `HTTP ${res.status}`);
  }
  if (res.status === 204) return null;
  return res.json();
}

export const api = {
  health: () => request('/api/health'),
  listBranches: () => request('/api/branches'),
  getBranch: (id) => request(`/api/branches/${id}`),
  createBranch: (body) =>
    request('/api/branches', { method: 'POST', body: JSON.stringify(body) }),
  updateBranch: (id, body) =>
    request(`/api/branches/${id}`, { method: 'PUT', body: JSON.stringify(body) }),
  getStaff: (staffId) => request(`/api/staff/${staffId}`),
  ping: (body) =>
    request('/api/attendance/ping', { method: 'POST', body: JSON.stringify(body) }),
  getLogs: (limit = 100) => request(`/api/logs?limit=${limit}`),
  clearLogs: () => request('/api/logs', { method: 'DELETE' }),
};

export const STAFF_ID = 'demo-staff';
export const SAMPLE = { lat: 10.0159, lng: 76.3419 };
export const GEO_OPTS = {
  enableHighAccuracy: false,
  timeout: 20000,
  maximumAge: 30000,
};
