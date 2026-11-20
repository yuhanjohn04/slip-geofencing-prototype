"""
Slip Geofencing & Attendance Prototype — FastAPI backend.

In-memory store shaped for easy later migration to PostgreSQL/SQLite.
"""

from __future__ import annotations

import math
import uuid
from datetime import datetime, timezone
from enum import Enum
from typing import Any

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field


# ---------------------------------------------------------------------------
# Domain models (DB-ready shapes)
# ---------------------------------------------------------------------------


class AttendanceStatus(str, Enum):
    IN_BRANCH = "IN_BRANCH"
    GRACE_PERIOD = "GRACE_PERIOD"
    OUTSIDE = "OUTSIDE"


class Branch(BaseModel):
    id: str
    name: str
    latitude: float
    longitude: float
    radius_meters: float = 30.0


class BranchCreate(BaseModel):
    name: str = "Main Branch"
    latitude: float
    longitude: float
    radius_meters: float = 30.0


class BranchUpdate(BaseModel):
    name: str | None = None
    latitude: float | None = None
    longitude: float | None = None
    radius_meters: float | None = None


class StaffState(BaseModel):
    staff_id: str
    status: AttendanceStatus = AttendanceStatus.OUTSIDE
    active_branch_id: str | None = None
    grace_started_at: datetime | None = None
    grace_period_seconds: int = 15
    last_ping_at: datetime | None = None
    last_lat: float | None = None
    last_lng: float | None = None
    last_accuracy: float | None = None


class ActivityLog(BaseModel):
    id: str
    timestamp: datetime
    event: str
    staff_id: str | None = None
    status: str | None = None
    distance_meters: float | None = None
    accuracy_meters: float | None = None
    latitude: float | None = None
    longitude: float | None = None


class AttendancePingRequest(BaseModel):
    staff_id: str = "demo-staff"
    latitude: float
    longitude: float
    accuracy_meters: float | None = None
    recorded_at: datetime | None = None
    is_mock_outside: bool = False
    grace_period_seconds: int | None = Field(
        default=None,
        description="Optional override for this staff's grace window (seconds).",
    )


class NearestBranchInfo(BaseModel):
    id: str
    name: str
    latitude: float
    longitude: float
    radius_meters: float
    distance_meters: float


class AttendancePingResponse(BaseModel):
    status: AttendanceStatus
    active_branch_name: str | None
    distance_meters: float | None
    grace_seconds_remaining: float | None
    nearest_branch: NearestBranchInfo | None
    staff: StaffState


# ---------------------------------------------------------------------------
# In-memory store
# ---------------------------------------------------------------------------

DEFAULT_BRANCH_ID = "branch-sample"

store: dict[str, Any] = {
    "branches": {
        DEFAULT_BRANCH_ID: Branch(
            id=DEFAULT_BRANCH_ID,
            name="Sample Branch",
            latitude=10.0159,
            longitude=76.3419,
            radius_meters=30.0,
        )
    },
    "staff": {},  # staff_id -> StaffState
    "logs": [],  # list[ActivityLog], newest first
}


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def ensure_aware(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt


def haversine_meters(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance between two WGS84 points in meters."""
    r = 6_371_000.0
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    d_phi = math.radians(lat2 - lat1)
    d_lambda = math.radians(lon2 - lon1)
    a = (
        math.sin(d_phi / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    )
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def append_log(
    event: str,
    *,
    staff_id: str | None = None,
    status: str | None = None,
    distance_meters: float | None = None,
    accuracy_meters: float | None = None,
    latitude: float | None = None,
    longitude: float | None = None,
) -> ActivityLog:
    entry = ActivityLog(
        id=str(uuid.uuid4()),
        timestamp=utcnow(),
        event=event,
        staff_id=staff_id,
        status=status,
        distance_meters=distance_meters,
        accuracy_meters=accuracy_meters,
        latitude=latitude,
        longitude=longitude,
    )
    store["logs"].insert(0, entry)
    # Cap memory
    if len(store["logs"]) > 500:
        store["logs"] = store["logs"][:500]
    return entry


def get_or_create_staff(staff_id: str) -> StaffState:
    staff_map: dict[str, StaffState] = store["staff"]
    if staff_id not in staff_map:
        staff_map[staff_id] = StaffState(staff_id=staff_id)
        append_log(f"Staff registered: {staff_id}", staff_id=staff_id)
    return staff_map[staff_id]


def find_nearest_and_containing(
    lat: float, lng: float
) -> tuple[NearestBranchInfo | None, Branch | None, float | None]:
    """Return (nearest info, containing branch if any, nearest distance)."""
    branches: dict[str, Branch] = store["branches"]
    if not branches:
        return None, None, None

    nearest: NearestBranchInfo | None = None
    containing: Branch | None = None
    best_dist = float("inf")

    for branch in branches.values():
        dist = haversine_meters(lat, lng, branch.latitude, branch.longitude)
        info = NearestBranchInfo(
            id=branch.id,
            name=branch.name,
            latitude=branch.latitude,
            longitude=branch.longitude,
            radius_meters=branch.radius_meters,
            distance_meters=round(dist, 2),
        )
        if dist < best_dist:
            best_dist = dist
            nearest = info
        if dist <= branch.radius_meters:
            if containing is None or dist < haversine_meters(
                lat, lng, containing.latitude, containing.longitude
            ):
                containing = branch

    return nearest, containing, (round(best_dist, 2) if nearest else None)


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

app = FastAPI(title="Slip Geofencing & Attendance Prototype", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:5173",
        "http://127.0.0.1:5173",
        "http://localhost:3000",
        "http://127.0.0.1:3000",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/api/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


# ——— Branches ———


@app.get("/api/branches", response_model=list[Branch])
def list_branches() -> list[Branch]:
    return list(store["branches"].values())


@app.get("/api/branches/{branch_id}", response_model=Branch)
def get_branch(branch_id: str) -> Branch:
    branch = store["branches"].get(branch_id)
    if not branch:
        raise HTTPException(status_code=404, detail="Branch not found")
    return branch


@app.post("/api/branches", response_model=Branch, status_code=201)
def create_branch(body: BranchCreate) -> Branch:
    branch_id = f"branch-{uuid.uuid4().hex[:8]}"
    branch = Branch(id=branch_id, **body.model_dump())
    store["branches"][branch_id] = branch
    append_log(
        f"Branch created: {branch.name}",
        latitude=branch.latitude,
        longitude=branch.longitude,
    )
    return branch


@app.put("/api/branches/{branch_id}", response_model=Branch)
def update_branch(branch_id: str, body: BranchUpdate) -> Branch:
    branch = store["branches"].get(branch_id)
    if not branch:
        raise HTTPException(status_code=404, detail="Branch not found")
    data = branch.model_dump()
    updates = body.model_dump(exclude_unset=True)
    data.update(updates)
    updated = Branch(**data)
    store["branches"][branch_id] = updated
    append_log(
        f"Branch updated: {updated.name}",
        latitude=updated.latitude,
        longitude=updated.longitude,
    )
    return updated


# ——— Staff ———


@app.get("/api/staff/{staff_id}", response_model=StaffState)
def get_staff(staff_id: str) -> StaffState:
    return get_or_create_staff(staff_id)


@app.get("/api/staff", response_model=list[StaffState])
def list_staff() -> list[StaffState]:
    return list(store["staff"].values())


# ——— Logs ———


@app.get("/api/logs", response_model=list[ActivityLog])
def get_logs(limit: int = 100) -> list[ActivityLog]:
    return store["logs"][: max(1, min(limit, 500))]


@app.delete("/api/logs")
def clear_logs() -> dict[str, str]:
    store["logs"].clear()
    return {"status": "cleared"}


# ——— Attendance ping (core state machine) ———


@app.post("/api/attendance/ping", response_model=AttendancePingResponse)
def attendance_ping(body: AttendancePingRequest) -> AttendancePingResponse:
    staff = get_or_create_staff(body.staff_id)
    recorded_at = ensure_aware(body.recorded_at or utcnow())

    if body.grace_period_seconds is not None and body.grace_period_seconds > 0:
        staff.grace_period_seconds = body.grace_period_seconds

    staff.last_ping_at = recorded_at
    staff.last_lat = body.latitude
    staff.last_lng = body.longitude
    staff.last_accuracy = body.accuracy_meters

    nearest, containing, nearest_dist = find_nearest_and_containing(
        body.latitude, body.longitude
    )

    # Mock: force "outside" distance for desk demos
    if body.is_mock_outside:
        containing = None
        if nearest is not None:
            forced = nearest.radius_meters + 50.0
            nearest = nearest.model_copy(update={"distance_meters": round(forced, 2)})
            nearest_dist = round(forced, 2)

    prev_status = staff.status
    distance_meters = nearest_dist
    grace_remaining: float | None = None
    active_branch_name: str | None = None

    if containing is not None:
        # Inside a branch geofence → IN_BRANCH, reset grace
        staff.status = AttendanceStatus.IN_BRANCH
        staff.active_branch_id = containing.id
        staff.grace_started_at = None
        distance_meters = round(
            haversine_meters(
                body.latitude, body.longitude, containing.latitude, containing.longitude
            ),
            2,
        )
        active_branch_name = containing.name
    else:
        # Outside all branch radii
        if prev_status == AttendanceStatus.IN_BRANCH:
            staff.status = AttendanceStatus.GRACE_PERIOD
            staff.grace_started_at = recorded_at
        elif prev_status == AttendanceStatus.GRACE_PERIOD:
            started = ensure_aware(staff.grace_started_at or recorded_at)
            staff.grace_started_at = started
            elapsed = (recorded_at - started).total_seconds()
            if elapsed >= staff.grace_period_seconds:
                staff.status = AttendanceStatus.OUTSIDE
            else:
                staff.status = AttendanceStatus.GRACE_PERIOD
        else:
            # OUTSIDE (or first ping away from any branch)
            staff.status = AttendanceStatus.OUTSIDE

        if staff.active_branch_id:
            active = store["branches"].get(staff.active_branch_id)
            active_branch_name = active.name if active else None
        elif nearest:
            active_branch_name = nearest.name

        if staff.status == AttendanceStatus.GRACE_PERIOD and staff.grace_started_at:
            elapsed = (recorded_at - ensure_aware(staff.grace_started_at)).total_seconds()
            grace_remaining = max(0.0, staff.grace_period_seconds - elapsed)

    store["staff"][staff.staff_id] = staff

    if prev_status != staff.status:
        append_log(
            f"State: {prev_status.value} → {staff.status.value}",
            staff_id=staff.staff_id,
            status=staff.status.value,
            distance_meters=distance_meters,
            accuracy_meters=body.accuracy_meters,
            latitude=body.latitude,
            longitude=body.longitude,
        )
    else:
        label = "GPS ping (mock outside)" if body.is_mock_outside else "GPS ping"
        append_log(
            label,
            staff_id=staff.staff_id,
            status=staff.status.value,
            distance_meters=distance_meters,
            accuracy_meters=body.accuracy_meters,
            latitude=body.latitude,
            longitude=body.longitude,
        )

    return AttendancePingResponse(
        status=staff.status,
        active_branch_name=active_branch_name,
        distance_meters=distance_meters,
        grace_seconds_remaining=grace_remaining,
        nearest_branch=nearest,
        staff=staff,
    )


@app.on_event("startup")
def on_startup() -> None:
    append_log("Backend started — in-memory store ready")
