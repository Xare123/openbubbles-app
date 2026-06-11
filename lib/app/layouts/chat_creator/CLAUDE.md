# chat_creator/ — New Chat Creation

## Pages

### New (iOS-native, preferred)
- `new_chat_creator.dart` — `NewChatCreator` widget; drop-in replacement for `ChatCreator`
- `chat_creator_controller.dart` — `ChatCreatorController extends StatefulController`; owns all state and logic
- `chat_service_type.dart` — `ChatServiceType` enum (`iMessage`, `sms`, `rcs`); set `isVisible: false` to hide a type

### Legacy
- `chat_creator.dart` — original multi-skin implementation; kept as reference

## Widgets (`widgets/`)
- `service_type_picker.dart` — `CupertinoSegmentedControl` for visible service types
- `recipient_chips_row.dart` — "To:" label + selected contact chips + address text field
- `search_results_list.dart` — scrollable list: "Conversations" section + "Contacts" section
- `search_contact_tile.dart` — per phone/email row for a `ContactV2`
- `chat_creator_tile.dart` — contact/chat row (shared by legacy and new)
- `selected_contact_chip.dart` — removable chip for each selected contact (shared)
- `chat_list_section.dart` — chat+contact list used by legacy creator
- `message_type_toggle.dart` — SMS vs iMessage toggle used by legacy creator

## Drop-in swap
When ready to replace the legacy creator, update these two call sites:
- `lib/services/backend_ui_interop/intents.dart` — `OpenNewChatCreatorAction`
- `lib/services/ui/chat/chats_service.dart` — deep link handler

## NewChatCreator Flow
1. User sees `CupertinoSegmentedControl` (iMessage / SMS) at top
2. User types in the "To:" field → 250ms debounce search updates "Conversations" + "Contacts" lists
3. User selects a chat or contact → chip appears; iMessage status fetched async for chip color
4. If selected handles match an existing chat → `MessagesView` replaces the search list (embedded preview)
5. User types a message in the text field at the bottom; replies + attachments work for existing chats
6. On send to existing chat: header collapses (AnimatedSize + AnimatedOpacity), then navigates to `ConversationView` with `fromChatCreator: true` and the same `customService`; message is sent in `ConversationView.onInit`
7. On send to new contact set: `HttpSvc.createChat(...)` → progress dialog → save → navigate
