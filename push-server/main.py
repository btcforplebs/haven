import logging
import re
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from fastapi import FastAPI, Depends, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, field_validator
from typing import Optional, Dict
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from slowapi import Limiter
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded

from database import init_db, get_session, DeviceRegistration
from apns_client import apns_client
from nostr_monitor import nostr_monitor
from config import SERVER_HOST, SERVER_PORT, API_KEY

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Rate limiter
limiter = Limiter(key_func=get_remote_address)

# Hex pattern for input validation
_HEX_RE = re.compile(r'^[0-9a-fA-F]+$')

# Lifespan context manager for startup/shutdown
@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    logger.info("Starting Nostr Vault Push Server")
    if not API_KEY:
        logger.warning("API_KEY is not set — all authenticated endpoints will reject requests")
    await init_db()
    await apns_client.connect()
    await nostr_monitor.start()
    yield
    # Shutdown
    logger.info("Shutting down")
    await nostr_monitor.stop()
    await apns_client.close()

app = FastAPI(
    title="Nostr Vault Push Server",
    description="Push notification server for Nostr Vault",
    version="1.0.0",
    lifespan=lifespan,
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)
app.state.limiter = limiter

@app.exception_handler(RateLimitExceeded)
async def rate_limit_handler(request: Request, exc: RateLimitExceeded):
    return JSONResponse(status_code=429, content={"detail": "Rate limit exceeded"})

# Track server start time for uptime reporting
_start_time = datetime.now(timezone.utc)


# --- Auth dependency ---

def verify_api_key(request: Request):
    """Verify the X-API-Key header matches the configured API key."""
    if not API_KEY:
        raise HTTPException(status_code=503, detail="Server not configured")
    key = request.headers.get("X-API-Key", "")
    if key != API_KEY:
        raise HTTPException(status_code=401, detail="Unauthorized")


# --- Request/Response Models ---

class RegisterDeviceRequest(BaseModel):
    device_token: str
    user_hex_pubkey: str
    enabled_notifications: Optional[Dict[str, bool]] = {
        "mentions": True,
        "replies": True,
        "dms": True,
        "zaps": True,
        "reactions": False,
        "reposts": False
    }
    custom_relays: Optional[list[str]] = None

    @field_validator('device_token')
    @classmethod
    def validate_device_token(cls, v: str) -> str:
        if not (64 <= len(v) <= 200) or not _HEX_RE.match(v):
            raise ValueError('device_token must be a 64-200 character hex string')
        return v

    @field_validator('user_hex_pubkey')
    @classmethod
    def validate_pubkey(cls, v: str) -> str:
        if len(v) != 64 or not _HEX_RE.match(v):
            raise ValueError('user_hex_pubkey must be a 64-character hex string')
        return v

class RegisterDeviceResponse(BaseModel):
    success: bool
    message: str

class UnregisterDeviceRequest(BaseModel):
    device_token: str

    @field_validator('device_token')
    @classmethod
    def validate_device_token(cls, v: str) -> str:
        if not (64 <= len(v) <= 200) or not _HEX_RE.match(v):
            raise ValueError('device_token must be a 64-200 character hex string')
        return v

class BadgeResetRequest(BaseModel):
    device_token: str

    @field_validator('device_token')
    @classmethod
    def validate_device_token(cls, v: str) -> str:
        if not (64 <= len(v) <= 200) or not _HEX_RE.match(v):
            raise ValueError('device_token must be a 64-200 character hex string')
        return v


# --- API Endpoints ---

@app.get("/")
async def root():
    return {
        "service": "Nostr Vault Push Server",
        "status": "running",
    }

@app.post("/register", response_model=RegisterDeviceResponse, dependencies=[Depends(verify_api_key)])
@limiter.limit("10/minute")
async def register_device(
    request: Request,
    body: RegisterDeviceRequest,
    session: AsyncSession = Depends(get_session)
):
    """Register a device for push notifications"""
    try:
        # Check if this device+pubkey combo already registered
        result = await session.execute(
            select(DeviceRegistration)
            .where(
                DeviceRegistration.device_token == body.device_token,
                DeviceRegistration.user_hex_pubkey == body.user_hex_pubkey
            )
        )
        existing = result.scalar_one_or_none()

        if existing:
            # Update existing registration
            existing.enabled_notifications = body.enabled_notifications
            existing.custom_relays = body.custom_relays
            logger.info(f"Updated device registration for {body.user_hex_pubkey[:16]}...")
        else:
            # Create new registration
            device = DeviceRegistration(
                device_token=body.device_token,
                user_hex_pubkey=body.user_hex_pubkey,
                enabled_notifications=body.enabled_notifications,
                custom_relays=body.custom_relays
            )
            session.add(device)
            logger.info(f"Registered new device for {body.user_hex_pubkey[:16]}...")

        await session.commit()

        # Refresh monitor's user list
        await nostr_monitor.load_registered_users()

        return RegisterDeviceResponse(
            success=True,
            message="Device registered successfully"
        )

    except Exception as e:
        logger.error(f"Registration failed: {e}")
        raise HTTPException(status_code=500, detail="Registration failed")

@app.post("/unregister", response_model=RegisterDeviceResponse, dependencies=[Depends(verify_api_key)])
@limiter.limit("10/minute")
async def unregister_device(
    request: Request,
    body: UnregisterDeviceRequest,
    session: AsyncSession = Depends(get_session)
):
    """Unregister a device from push notifications"""
    try:
        result = await session.execute(
            select(DeviceRegistration)
            .where(DeviceRegistration.device_token == body.device_token)
        )
        device = result.scalar_one_or_none()

        if device:
            await session.delete(device)
            await session.commit()
            logger.info(f"Unregistered device {body.device_token[:8]}...")

            # Refresh monitor's user list
            await nostr_monitor.load_registered_users()

            return RegisterDeviceResponse(
                success=True,
                message="Device unregistered successfully"
            )
        else:
            raise HTTPException(status_code=404, detail="Device not found")

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Unregistration failed: {e}")
        raise HTTPException(status_code=500, detail="Unregistration failed")

@app.post("/badge/reset", response_model=RegisterDeviceResponse, dependencies=[Depends(verify_api_key)])
@limiter.limit("10/minute")
async def reset_badge(
    request: Request,
    body: BadgeResetRequest,
    session: AsyncSession = Depends(get_session)
):
    """Reset the badge count for a device (called when the app opens)"""
    try:
        result = await session.execute(
            select(DeviceRegistration)
            .where(DeviceRegistration.device_token == body.device_token)
        )
        devices = result.scalars().all()

        for device in devices:
            device.pending_badge_count = 0

        await session.commit()

        return RegisterDeviceResponse(
            success=True,
            message="Badge count reset"
        )

    except Exception as e:
        logger.error(f"Badge reset failed: {e}")
        raise HTTPException(status_code=500, detail="Badge reset failed")

@app.get("/health")
async def health_check():
    return {
        "status": "healthy",
        "apns_connected": apns_client.apns is not None,
    }

@app.get("/status", dependencies=[Depends(verify_api_key)])
async def status(request: Request, session: AsyncSession = Depends(get_session)):
    """Detailed server status for debugging (requires API key)"""
    result = await session.execute(select(DeviceRegistration))
    devices = result.scalars().all()
    now = datetime.now(timezone.utc)
    uptime_seconds = int((now - _start_time).total_seconds())

    return {
        "status": "running",
        "uptime_seconds": uptime_seconds,
        "apns_connected": apns_client.apns is not None,
        "monitor": {
            "running": nostr_monitor.running,
            "monitored_users": len(nostr_monitor.monitored_pubkeys),
            "seen_events_cached": len(nostr_monitor.seen_event_ids),
        },
        "registrations": {
            "total_devices": len(devices),
            "unique_users": len(set(d.user_hex_pubkey for d in devices)),
        },
    }

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "main:app",
        host=SERVER_HOST,
        port=SERVER_PORT,
        reload=False,
        log_level="info"
    )
