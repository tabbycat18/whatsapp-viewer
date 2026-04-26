# iOS WhatsApp Archive Viewer

This is a new native SwiftUI app for local, read-only inspection of an extracted iOS WhatsApp archive. It is isolated from the original Windows/C++ Android `msgstore.db` viewer.

Private WhatsApp data must not be committed. Keep `ChatStorage.sqlite`, `ContactsV2.sqlite`, `Media/`, `Message/`, and generated exports under ignored local data folders.

## Development Data

For simulator development, copy a local development copy of `ChatStorage.sqlite` into the app container's Documents folder as:

```text
Documents/ChatStorage.sqlite
```

If sidecar files are present, copy them next to it too:

```text
Documents/ChatStorage.sqlite-wal
Documents/ChatStorage.sqlite-shm
Documents/ChatStorage.sqlite-journal
```

The app also has an Open Archive action that can select either an extracted archive folder containing `ChatStorage.sqlite` or the database file directly. Picking the containing folder is preferred because iOS grants access to SQLite sidecar files as well. The app copies `ChatStorage.sqlite` and any sidecars into its own Application Support folder, then opens that local copy with read-only flags and `PRAGMA query_only = ON`.

## Current Scope

### Milestone 1 Validated

- Opens a real extracted iPhone `ChatStorage.sqlite`.
- Loads the chat list and large chats.
- Preserves message order, dates, and sender direction.
- Keeps the app responsive by loading only the latest 500 messages per selected chat.

### Milestone 2 Media Metadata Discovery

- Loads chat sessions from `ZWACHATSESSION`.
- Loads messages for the selected chat from `ZWAMESSAGE`.
- Discovers available `ZWAMEDIAITEM` columns at runtime and joins media metadata when possible.
- Shows chat title, message count, latest message date, sender direction, message date, and `ZTEXT`.
- Shows clearer placeholders for empty-text media messages, such as photo, video, audio, or generic media attachments.
- Attempts safe relative media path resolution under the selected archive root without loading media files.
- Loads only the latest 500 messages per selected chat, sorted ascending in the message view.

## Limitations

- Media rendering is not implemented yet.
- Thumbnails and binary media are not loaded into memory yet.
- There is no full import flow or persistent archive bookmark yet.
- `ContactsV2.sqlite` is not used in this milestone.
- Build validation requires full Xcode, not only Command Line Tools.
