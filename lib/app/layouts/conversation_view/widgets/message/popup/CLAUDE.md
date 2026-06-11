# popup/ — Long-Press Context Menu

Handles the action sheet / context menu that appears when the user long-presses (or right-clicks on desktop) a message bubble.

## Files

| File | Purpose |
|------|---------|
| `message_popup_holder.dart` | `GestureDetector` wrapper placed inside every bubble Stack; triggers the popup |
| `message_popup.dart` | The full popup: action list (copy, react, reply, delete, unsend, etc.) |
| `details_menu_action.dart` | Individual menu action row widget |
| `reaction_picker_clipper.dart` | `CustomClipper` for the tapback emoji picker pill shape |

## How It Works

1. `MessagePopupHolder` is placed inside the bubble `Stack` in `MessageHolder`.
2. Long-press (or right-click) calls `showMessagePopup(context, message, ...)`.
3. `MessagePopup` builds its action list dynamically:
   - `"Unsend"` only if `message.isFromMe` and Private API enabled
   - `"Add Reaction"` only if Private API enabled
   - `"Delete"` always available
   - `"Edit"` only if `message.isFromMe` and editable (recent enough)
   - `"Copy"` only if the message has text

## Desktop Behavior

On desktop, right-click opens the popup instead of long-press. `MessagePopupHolder` checks `kIsDesktop` to register the correct gesture detector.

## Adding a New Popup Action

1. Add the action label and icon to the builder in `message_popup.dart`.
2. Guard with the appropriate condition (Private API check, ownership check, etc.).
3. The action callback should call the relevant interface method (e.g., `MessageInterface.deleteMessage()`).
