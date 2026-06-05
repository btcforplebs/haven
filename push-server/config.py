import os
from pathlib import Path
from dotenv import load_dotenv

load_dotenv()

# APNs Configuration
APNS_CERT_PATH = os.getenv("APNS_CERT_PATH", "./certs/apns_cert.pem")
APNS_KEY_PATH = os.getenv("APNS_KEY_PATH", "./certs/apns_key.pem")
APNS_KEY_ID = os.getenv("APNS_KEY_ID")
APNS_TEAM_ID = os.getenv("APNS_TEAM_ID")
APNS_TOPIC = os.getenv("APNS_TOPIC", "com.havenapp.relay")
APNS_USE_SANDBOX = os.getenv("APNS_USE_SANDBOX", "false").lower() == "true"

# Server Configuration
SERVER_HOST = os.getenv("SERVER_HOST", "0.0.0.0")
SERVER_PORT = int(os.getenv("SERVER_PORT", "7766"))
DATABASE_URL = os.getenv("DATABASE_URL", "sqlite+aiosqlite:///./push_server.db")

# API Authentication
API_KEY = os.getenv("API_KEY", "")

# Nostr Configuration
# LOCAL_RELAY is checked first for fastest response (sub-ms on same machine)
LOCAL_RELAY = os.getenv("LOCAL_RELAY_URL", "")
_remote_relays = [
    "wss://relay.damus.io",
    "wss://relay.primal.net",
    "wss://nos.lol",
    "wss://nostr.wine",
    "wss://relay.snort.social"
]
DEFAULT_RELAYS = ([LOCAL_RELAY] if LOCAL_RELAY else []) + _remote_relays

# Notification Types to Monitor
MONITOR_EVENT_KINDS = [
    1,     # Text notes (for mentions/replies)
    4,     # NIP-04 DMs (legacy)
    6,     # Reposts
    7,     # Reactions
    1059,  # NIP-17 Gift Wraps
    9735,  # Zaps
]

# Rate Limiting
MAX_NOTIFICATIONS_PER_USER_PER_HOUR = 100
