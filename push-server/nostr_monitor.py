import asyncio
import json
import logging
import time
from typing import Set, Dict
from datetime import datetime, timedelta
from nostr_sdk import Client, Filter, Kind, PublicKey, Timestamp, RelayUrl, SingleLetterTag, Alphabet
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from database import DeviceRegistration, NotificationLog, async_session_maker
from apns_client import apns_client
from config import DEFAULT_RELAYS, MONITOR_EVENT_KINDS, MAX_NOTIFICATIONS_PER_USER_PER_HOUR

logger = logging.getLogger(__name__)

class NostrMonitor:
    def __init__(self):
        self.client = Client()
        self.monitored_pubkeys: Set[str] = set()
        self.seen_event_ids: Set[str] = set()
        self.running = False
        # Profile display name cache: hex_pubkey -> (display_name, fetched_at)
        self.profile_cache: Dict[str, tuple] = {}

    async def start(self):
        """Start monitoring Nostr relays for registered users"""
        self.running = True

        # Add relays
        for relay in DEFAULT_RELAYS:
            await self.client.add_relay(RelayUrl.parse(relay))

        await self.client.connect()
        logger.info(f"✅ Connected to {len(DEFAULT_RELAYS)} Nostr relays")

        # Load registered users
        await self.load_registered_users()

        # Start monitoring loop
        asyncio.create_task(self.monitor_loop())
        asyncio.create_task(self.refresh_users_loop())

    async def stop(self):
        """Stop monitoring"""
        self.running = False
        await self.client.disconnect()
        logger.info("🛑 Nostr monitor stopped")

    async def load_registered_users(self):
        """Load all registered user pubkeys from database"""
        async with async_session_maker() as session:
            result = await session.execute(
                select(DeviceRegistration.user_hex_pubkey).distinct()
            )
            pubkeys = result.scalars().all()
            self.monitored_pubkeys = set(pubkeys)
            logger.info(f"📋 Monitoring {len(self.monitored_pubkeys)} users")

    async def refresh_users_loop(self):
        """Periodically reload registered users"""
        while self.running:
            await asyncio.sleep(300)  # Every 5 minutes
            await self.load_registered_users()

    async def monitor_loop(self):
        """Main monitoring loop"""
        while self.running:
            if not self.monitored_pubkeys:
                await asyncio.sleep(10)
                continue

            try:
                # Build filter for all monitored users
                # Monitor mentions (#p tags) and authored events
                filters = []

                # Chunk users into groups of 100 (relay filter limits)
                pubkey_list = list(self.monitored_pubkeys)
                since_ts = Timestamp.from_secs(int(time.time()) - 300)

                for i in range(0, len(pubkey_list), 100):
                    chunk = pubkey_list[i:i+100]
                    parsed_pks = [PublicKey.parse(pk) for pk in chunk]

                    # Filter for events authored by monitored users
                    filters.append(
                        Filter()
                        .kinds([Kind(k) for k in MONITOR_EVENT_KINDS])
                        .pubkeys(parsed_pks)
                        .since(since_ts)
                    )

                    # Filter for events targeting monitored users via p-tags
                    # (reactions, reposts, zaps, replies, DMs)
                    filters.append(
                        Filter()
                        .kinds([Kind(k) for k in MONITOR_EVENT_KINDS])
                        .custom_tag(SingleLetterTag.lowercase(Alphabet.P), chunk)
                        .since(since_ts)
                    )

                # Fetch events per filter and merge results
                logger.info(f"🔄 Fetching with {len(filters)} filters")
                all_events = None
                for f in filters:
                    events = await self.client.fetch_events(f, timedelta(seconds=10))
                    if all_events is None:
                        all_events = events
                    else:
                        all_events = all_events.merge(events)

                if all_events is not None:
                    for event in all_events.to_vec():
                        await self.process_event(event)

                await asyncio.sleep(30)  # Poll every 30 seconds

            except Exception as e:
                logger.error(f"❌ Error in monitor loop: {e}")
                await asyncio.sleep(60)

    async def process_event(self, event):
        """Process incoming Nostr event and send notifications"""
        event_id = event.id().to_hex()

        # Deduplicate
        if event_id in self.seen_event_ids:
            return
        self.seen_event_ids.add(event_id)

        # Limit seen events cache size
        if len(self.seen_event_ids) > 10000:
            self.seen_event_ids = set(list(self.seen_event_ids)[-5000:])

        event_kind = event.kind().as_u16()
        author_pubkey = event.author().to_hex()

        # Determine affected users
        affected_users = set()

        is_reply = False
        if event_kind == 1:  # Text note
            # Determine if this is a reply (has "e" tag) or a mention-only
            is_reply = any(
                tag.as_vec()[0] == "e" for tag in event.tags().to_vec()
            )
            # Check for mentions/replies in tags
            for tag in event.tags().to_vec():
                if tag.as_vec()[0] == "p":
                    mentioned_pubkey = tag.as_vec()[1]
                    if mentioned_pubkey in self.monitored_pubkeys:
                        affected_users.add(mentioned_pubkey)

        elif event_kind == 1059:  # NIP-17 Gift Wrap
            # Extract recipient from p tag
            for tag in event.tags().to_vec():
                if tag.as_vec()[0] == "p":
                    recipient_pubkey = tag.as_vec()[1]
                    if recipient_pubkey in self.monitored_pubkeys:
                        affected_users.add(recipient_pubkey)

        elif event_kind == 4:  # NIP-04 DM
            # Recipient in p tag
            for tag in event.tags().to_vec():
                if tag.as_vec()[0] == "p":
                    recipient_pubkey = tag.as_vec()[1]
                    if recipient_pubkey in self.monitored_pubkeys:
                        affected_users.add(recipient_pubkey)

        elif event_kind == 7:  # Reaction
            # Check who's being reacted to
            for tag in event.tags().to_vec():
                if tag.as_vec()[0] == "p":
                    target_pubkey = tag.as_vec()[1]
                    if target_pubkey in self.monitored_pubkeys:
                        affected_users.add(target_pubkey)

        elif event_kind == 6:  # Repost
            for tag in event.tags().to_vec():
                if tag.as_vec()[0] == "p":
                    reposted_pubkey = tag.as_vec()[1]
                    if reposted_pubkey in self.monitored_pubkeys:
                        affected_users.add(reposted_pubkey)

        elif event_kind == 9735:  # Zap
            # Find zap recipient
            for tag in event.tags().to_vec():
                if tag.as_vec()[0] == "p":
                    zapped_pubkey = tag.as_vec()[1]
                    if zapped_pubkey in self.monitored_pubkeys:
                        affected_users.add(zapped_pubkey)

        # Don't notify the author about their own events
        affected_users.discard(author_pubkey)

        # Send notifications to affected users
        for user_pubkey in affected_users:
            await self.send_notification_for_event(user_pubkey, event, event_kind, author_pubkey, is_reply=is_reply)

    @staticmethod
    def _npub_short(hex_pubkey: str) -> str:
        """Convert a hex pubkey to a shortened npub display string."""
        try:
            npub = PublicKey.parse(hex_pubkey).to_bech32()
            return npub[:8] + "…" + npub[-4:]
        except Exception:
            return hex_pubkey[:8] + "…"

    async def _resolve_display_name(self, hex_pubkey: str) -> str:
        """Resolve a pubkey to a display name, using cache. Falls back to shortened npub."""
        # Check cache (valid for 1 hour)
        if hex_pubkey in self.profile_cache:
            name, fetched_at = self.profile_cache[hex_pubkey]
            if time.time() - fetched_at < 3600:
                return name

        # Fetch kind-0 metadata from relays
        try:
            pk = PublicKey.parse(hex_pubkey)
            profile_filter = Filter().kinds([Kind(0)]).authors([pk]).limit(1)
            events = await self.client.fetch_events(profile_filter, timedelta(seconds=5))
            for event in events.to_vec():
                metadata = json.loads(event.content())
                display_name = metadata.get("display_name", "").strip()
                if not display_name:
                    display_name = metadata.get("name", "").strip()
                if display_name:
                    self.profile_cache[hex_pubkey] = (display_name, time.time())
                    return display_name
        except Exception as e:
            logger.debug(f"Profile fetch failed for {hex_pubkey[:8]}: {e}")

        # Fallback to shortened npub
        fallback = self._npub_short(hex_pubkey)
        self.profile_cache[hex_pubkey] = (fallback, time.time())
        return fallback

    async def send_notification_for_event(self, user_pubkey: str, event, event_kind: int, author_pubkey: str, is_reply: bool = False):
        """Send push notification to user's registered devices"""
        async with async_session_maker() as session:
            # Get user's devices
            result = await session.execute(
                select(DeviceRegistration)
                .where(DeviceRegistration.user_hex_pubkey == user_pubkey)
            )
            devices = result.scalars().all()

            for device in devices:
                # Check if already notified for this event
                log_exists = await session.execute(
                    select(NotificationLog)
                    .where(
                        NotificationLog.event_id == event.id().to_hex(),
                        NotificationLog.device_token == device.device_token
                    )
                )
                if log_exists.scalar():
                    continue

                # Check rate limiting
                if device.rate_limit_reset_at < datetime.utcnow():
                    device.notification_count_hour = 0
                    device.rate_limit_reset_at = datetime.utcnow() + timedelta(hours=1)

                if device.notification_count_hour >= MAX_NOTIFICATIONS_PER_USER_PER_HOUR:
                    logger.warning(f"⏸️ Rate limit reached for {device.device_token[:16]}")
                    continue

                # Check user preferences
                prefs = device.enabled_notifications
                should_notify = False
                author_short = await self._resolve_display_name(author_pubkey)

                if event_kind == 1 and is_reply and prefs.get("replies"):
                    should_notify = True
                    title = f"{author_short} replied to your note"
                    preview = event.content()[:100].strip()
                    body = preview if preview else "Tap to view the reply"
                elif event_kind == 1 and not is_reply and prefs.get("mentions"):
                    should_notify = True
                    title = f"{author_short} mentioned you"
                    preview = event.content()[:100].strip()
                    body = preview if preview else "You were mentioned in a note"
                elif event_kind == 1059 and prefs.get("dms"):
                    should_notify = True
                    title = "New Direct Message"
                    body = "You have a new encrypted message"
                elif event_kind == 4 and prefs.get("dms"):
                    should_notify = True
                    title = f"DM from {author_short}"
                    body = "You have a new message"
                elif event_kind == 7 and prefs.get("reactions"):
                    should_notify = True
                    reaction = event.content().strip()
                    if reaction == "+" or reaction == "":
                        title = f"{author_short} liked your note"
                    elif reaction == "-":
                        title = f"{author_short} disliked your note"
                    else:
                        title = f"{author_short} reacted {reaction} to your note"
                    body = "Tap to view"
                elif event_kind == 6 and prefs.get("reposts"):
                    should_notify = True
                    title = f"{author_short} reposted your note"
                    body = "Tap to view"
                elif event_kind == 9735 and prefs.get("zaps"):
                    should_notify = True
                    title = f"⚡ Zap from {author_short}"
                    body = "You received a zap"
                else:
                    continue

                if not should_notify:
                    continue

                # Increment badge count for this device
                device.pending_badge_count += 1

                # Send notification
                success = await apns_client.send_notification(
                    device_token=device.device_token,
                    title=title,
                    body=body,
                    badge=device.pending_badge_count,
                    category="nostr_event",
                    extra_data={
                        "event_id": event.id().to_hex(),
                        "event_kind": event_kind,
                        "author_pubkey": author_pubkey,
                        "recipient_pubkey": user_pubkey
                    }
                )

                # Log notification
                log = NotificationLog(
                    device_token=device.device_token,
                    user_hex_pubkey=user_pubkey,
                    event_id=event.id().to_hex(),
                    event_kind=event_kind,
                    success=success
                )
                session.add(log)

                # Update device stats
                device.last_notification_at = datetime.utcnow()
                device.notification_count_hour += 1

                await session.commit()

# Singleton instance
nostr_monitor = NostrMonitor()
