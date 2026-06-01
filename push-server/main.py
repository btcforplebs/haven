import logging
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from fastapi import FastAPI, Depends, HTTPException
from pydantic import BaseModel
from typing import Optional, Dict
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from database import init_db, get_session, DeviceRegistration
from apns_client import apns_client
from nostr_monitor import nostr_monitor
from config import SERVER_HOST, SERVER_PORT

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Lifespan context manager for startup/shutdown
@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    logger.info("🚀 Starting Nostr Vault Push Server")
    await init_db()
    await apns_client.connect()
    await nostr_monitor.start()
    yield
    # Shutdown
    logger.info("🛑 Shutting down")
    await nostr_monitor.stop()
    await apns_client.close()

app = FastAPI(
    title="Nostr Vault Push Server",
    description="Push notification server for Nostr Vault",
    version="1.0.0",
    lifespan=lifespan
)

# Track server start time for uptime reporting
_start_time = datetime.now(timezone.utc)

# Request/Response Models
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

class RegisterDeviceResponse(BaseModel):
    success: bool
    message: str

class UnregisterDeviceRequest(BaseModel):
    device_token: str

class BadgeResetRequest(BaseModel):
    device_token: str

# API Endpoints
@app.get("/")
async def root():
    return {
        "service": "Nostr Vault Push Server",
        "status": "running",
        "monitored_users": len(nostr_monitor.monitored_pubkeys)
    }

@app.post("/register", response_model=RegisterDeviceResponse)
async def register_device(
    request: RegisterDeviceRequest,
    session: AsyncSession = Depends(get_session)
):
    """Register a device for push notifications"""
    try:
        # Check if this device+pubkey combo already registered
        result = await session.execute(
            select(DeviceRegistration)
            .where(
                DeviceRegistration.device_token == request.device_token,
                DeviceRegistration.user_hex_pubkey == request.user_hex_pubkey
            )
        )
        existing = result.scalar_one_or_none()

        if existing:
            # Update existing registration
            existing.enabled_notifications = request.enabled_notifications
            existing.custom_relays = request.custom_relays
            logger.info(f"📝 Updated device {request.device_token[:16]}... for {request.user_hex_pubkey[:16]}...")
        else:
            # Create new registration
            device = DeviceRegistration(
                device_token=request.device_token,
                user_hex_pubkey=request.user_hex_pubkey,
                enabled_notifications=request.enabled_notifications,
                custom_relays=request.custom_relays
            )
            session.add(device)
            logger.info(f"✅ Registered new device {request.device_token[:16]}... for {request.user_hex_pubkey[:16]}...")

        await session.commit()

        # Refresh monitor's user list
        await nostr_monitor.load_registered_users()

        return RegisterDeviceResponse(
            success=True,
            message="Device registered successfully"
        )

    except Exception as e:
        logger.error(f"❌ Registration failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/unregister", response_model=RegisterDeviceResponse)
async def unregister_device(
    request: UnregisterDeviceRequest,
    session: AsyncSession = Depends(get_session)
):
    """Unregister a device from push notifications"""
    try:
        result = await session.execute(
            select(DeviceRegistration)
            .where(DeviceRegistration.device_token == request.device_token)
        )
        device = result.scalar_one_or_none()

        if device:
            await session.delete(device)
            await session.commit()
            logger.info(f"🗑️ Unregistered device {request.device_token[:16]}...")

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
        logger.error(f"❌ Unregistration failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/badge/reset", response_model=RegisterDeviceResponse)
async def reset_badge(
    request: BadgeResetRequest,
    session: AsyncSession = Depends(get_session)
):
    """Reset the badge count for a device (called when the app opens)"""
    try:
        result = await session.execute(
            select(DeviceRegistration)
            .where(DeviceRegistration.device_token == request.device_token)
        )
        devices = result.scalars().all()

        for device in devices:
            device.pending_badge_count = 0

        await session.commit()
        logger.info(f"🔄 Badge reset for device {request.device_token[:16]}...")

        return RegisterDeviceResponse(
            success=True,
            message="Badge count reset"
        )

    except Exception as e:
        logger.error(f"❌ Badge reset failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/health")
async def health_check():
    return {
        "status": "healthy",
        "apns_connected": apns_client.apns is not None,
        "monitored_users": len(nostr_monitor.monitored_pubkeys),
        "seen_events": len(nostr_monitor.seen_event_ids)
    }

@app.get("/status")
async def status(session: AsyncSession = Depends(get_session)):
    """Detailed server status for debugging"""
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
