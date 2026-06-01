from datetime import datetime
from typing import Optional
from sqlalchemy import String, Integer, DateTime, JSON, Index, text
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column
from config import DATABASE_URL

# Database Models
class Base(DeclarativeBase):
    pass

class DeviceRegistration(Base):
    __tablename__ = "device_registrations"

    id: Mapped[int] = mapped_column(primary_key=True)
    device_token: Mapped[str] = mapped_column(String, index=True)
    user_hex_pubkey: Mapped[str] = mapped_column(String, index=True)

    # Optional: User preferences
    enabled_notifications: Mapped[dict] = mapped_column(JSON, default={
        "mentions": True,
        "replies": True,
        "dms": True,
        "zaps": True,
        "reactions": False,
        "reposts": False
    })

    # Custom relay list (optional, falls back to DEFAULT_RELAYS)
    custom_relays: Mapped[Optional[list]] = mapped_column(JSON, nullable=True)

    # Metadata
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    last_notification_at: Mapped[Optional[datetime]] = mapped_column(DateTime, nullable=True)

    # Badge tracking (cumulative unread count sent to APNs)
    pending_badge_count: Mapped[int] = mapped_column(Integer, default=0)

    # Rate limiting
    notification_count_hour: Mapped[int] = mapped_column(Integer, default=0)
    rate_limit_reset_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)

    __table_args__ = (
        Index('idx_pubkey_token', 'user_hex_pubkey', 'device_token', unique=True),
    )

class NotificationLog(Base):
    __tablename__ = "notification_logs"

    id: Mapped[int] = mapped_column(primary_key=True)
    device_token: Mapped[str] = mapped_column(String, index=True)
    user_hex_pubkey: Mapped[str] = mapped_column(String)
    event_id: Mapped[str] = mapped_column(String, index=True)
    event_kind: Mapped[int] = mapped_column(Integer)
    sent_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    success: Mapped[bool] = mapped_column(default=True)

    __table_args__ = (
        Index('idx_event_device', 'event_id', 'device_token', unique=True),
    )

# Database Engine
engine = create_async_engine(DATABASE_URL, echo=False)
async_session_maker = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

async def init_db():
    # Migrate: if old schemas have stale UNIQUE constraints,
    # SQLite can't ALTER TABLE to drop them — recreate with correct schema.
    async with engine.begin() as conn:
        try:
            # Check device_registrations for old unique constraint
            result = await conn.execute(text(
                "SELECT sql FROM sqlite_master WHERE type='table' AND name='device_registrations'"
            ))
            row = result.first()
            if row and row[0]:
                create_sql = row[0]
                needs_rebuild = (
                    "pending_badge_count" not in create_sql
                    or ("UNIQUE" in create_sql and "idx_pubkey_token" not in create_sql)
                )
                if needs_rebuild:
                    await conn.execute(text("DROP TABLE IF EXISTS device_registrations"))
                    await conn.execute(text("DROP TABLE IF EXISTS notification_logs"))

            # Check notification_logs for old unique constraint on event_id alone
            result = await conn.execute(text(
                "SELECT sql FROM sqlite_master WHERE type='table' AND name='notification_logs'"
            ))
            row = result.first()
            if row and row[0]:
                create_sql = row[0]
                if "UNIQUE" in create_sql and "idx_event_device" not in create_sql:
                    await conn.execute(text("DROP TABLE IF EXISTS notification_logs"))
        except Exception:
            pass  # First run or non-SQLite — let create_all handle it

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

async def get_session() -> AsyncSession:
    async with async_session_maker() as session:
        yield session
