# settings/pages/server/ — Server Connection & Management

Settings panels for managing the BlueBubbles server connection, authentication, backup/restore, and iMessage statistics.

## Files (top-level)

| File | Purpose |
|------|---------|
| `server_management_panel.dart` | Main server settings panel: URL, QR scan, ping, restart server |
| `backup_restore_panel.dart` | JSON export/import of settings and chat themes |
| `oauth_panel.dart` | OAuth /Google sign-in for cloud relay connection |

## Subdirectories

### `connection_panel/` — Server Connection Setup
Platform-specific connection panels (URL input, QR scan, connection test):

| File | Platform |
|------|----------|
| `connection_panel.dart` | Entry point / shared logic |
| `connection_panel_helpers.dart` | Shared helper widgets (URL field, test button) |
| `cupertino_connection_panel.dart` | iOS skin |
| `material_connection_panel.dart` | Material skin |
| `samsung_connection_panel.dart` | Samsung skin |

### `imessage_stats/` — iMessage Account Statistics
Live stats fetched from the server (account status, active handles, relay info):

| File | Platform |
|------|----------|
| `imessage_stats_page.dart` | Entry point / shared logic |
| `imessage_stats_helpers.dart` | Shared helper widgets |
| `cupertino_imessage_stats_page.dart` | iOS skin |
| `material_imessage_stats_page.dart` | Material skin |
| `samsung_imessage_stats_page.dart` | Samsung skin |

## Related
- HTTP API calls: `lib/services/network/http_service.dart`
- Setup flow (first-run): `lib/app/layouts/setup/CLAUDE.md`
- Settings router: `../CLAUDE.md`
