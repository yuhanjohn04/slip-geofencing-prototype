# Slip · Geofencing & Attendance Prototype

Full-stack prototype: **FastAPI (Python 3.12.16)** backend + **React (Vite + Tailwind)** frontend with an interactive Leaflet map.

## Structure

```
backend/          # FastAPI + in-memory store
  .venv/          # Python 3.12.16 virtualenv
  main.py
  requirements.txt
frontend/         # Vite + React + Tailwind + Leaflet
index.html        # Legacy single-file prototype (optional)
```

## Run (two terminals)

### Backend — http://localhost:8000

```bash
cd backend
source .venv/bin/activate
uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

API docs: http://localhost:8000/docs

### Frontend — http://localhost:5173

```bash
cd frontend
npm run dev
```

Vite proxies `/api` → `http://127.0.0.1:8000`.

## Quick demo

1. Open http://localhost:5173
2. Click **Load Sample Location** → status should be **IN BRANCH**
3. Drag the blue staff pin outside the geofence → **TEA STALL / GRACE PERIOD**
4. Wait for the countdown → **OUTSIDE / IN TRANSIT**
5. Toggle **Satellite** to inspect nearby buildings / tea stalls
