# Fluorite Protocol Plugin Development Guide

This guide explains how to author libpurple 2 protocol plugins for Fluorite. Fluorite uses libpurple as its underlying messaging engine and dynamically discovers and loads protocol plugins (`.so` shared libraries) at runtime.

---

## 1. Architecture & Plugin Lifecycle

Fluorite interacts with libpurple through the Swift-C bridge (`CLibpurple` & `PurpleBridgeService`). When libpurple is initialized:

1. **Discovery**: `PurpleBridgeService` scans:
   - `Fluorite.app/Contents/PlugIns/*.so` (when running inside the macOS Application Bundle)
   - `Plugins/*/*.so` (during development in the workspace)
2. **Loading**: Each discovered plugin is loaded via `adium_purple_load_plugin` (`purple_plugins_load`).
3. **Registration**: The plugin executes its `PURPLE_INIT_PLUGIN` macro, registering a `PurplePluginInfo` and `PurplePluginProtocolInfo` structure under a unique protocol ID (e.g., `prpl-hehoe-whatsmeow`, `prpl-eionrobb-msteams`).
4. **Swift UI Integration**: `AccountProtocol` in `Models.swift` maps UI protocol options to matching `purpleProtocolID` strings.

---

## 2. Recommended Directory Structure

Protocol plugins reside under the `Plugins/` directory:

```
Plugins/your-protocol/
├── Makefile                  # Builds libyourprotocol.so
├── README.md                 # Documentation, auth instructions & TOS disclaimers
├── libyourprotocol.c         # Plugin registration & PURPLE_INIT_PLUGIN
├── libyourprotocol.h         # Headers & account struct definition
├── yourprotocol_login.c/.h   # Login, authentication & pairing callbacks
├── yourprotocol_connection.c/.h # Connection teardown & close logic
├── yourprotocol_contacts.c/.h   # Roster, buddy management & status types
├── yourprotocol_messages.c/.h   # IM send/receive callbacks
├── core/                     # (Optional) Native bridge code (e.g., Go whatsmeow c-archive)
└── icons/
    ├── 16/                   # 16x16 PNG protocol icons
    ├── 22/                   # 22x22 PNG protocol icons
    └── 48/                   # 48x48 PNG protocol icons
```

---

## 3. Core Protocol Callbacks (`PurplePluginProtocolInfo`)

Your plugin must populate a `PurplePluginProtocolInfo` struct with function pointers.

### Mandatory Callbacks

| Callback | Function Signature | Description |
|---|---|---|
| `list_icon` | `const char *(*list_icon)(PurpleAccount *acct, PurpleBuddy *buddy)` | Returns the icon name (e.g., `"whatsapp"`). Used by Fluorite to find icon assets. |
| `status_types` | `GList *(*status_types)(PurpleAccount *acct)` | Returns a `GList` of supported `PurpleStatusType` pointers (Available, Away, Offline, etc.). |
| `login` | `void (*login)(PurpleAccount *acct)` | Triggered when an account connects. Allocate protocol account struct, initialize network connection. |
| `close` | `void (*close)(PurpleConnection *pc)` | Triggered on disconnect. Terminate session, cancel timers, free memory. |
| `send_im` | `int (*send_im)(PurpleConnection *pc, const char *who, const char *msg, PurpleMessageFlags flags)` | Transmits an IM to destination handle `who`. |

### Optional / Recommended Callbacks

- `send_typing`: Notifies remote user of typing status.
- `add_buddy` / `remove_buddy`: Handles contact list additions and removals.
- `get_info`: Displays user profile info.

### Example Callback Implementations

```c
const char *
yourprotocol_list_icon(PurpleAccount *account, PurpleBuddy *buddy)
{
    return "yourprotocol"; // Matches icons/{16,22,48}/yourprotocol.png
}

GList *
yourprotocol_status_types(PurpleAccount *account)
{
    GList *types = NULL;
    types = g_list_append(types, purple_status_type_new(PURPLE_STATUS_AVAILABLE, "available", "Available", TRUE));
    types = g_list_append(types, purple_status_type_new(PURPLE_STATUS_AWAY, "away", "Away", TRUE));
    types = g_list_append(types, purple_status_type_new(PURPLE_STATUS_OFFLINE, "offline", "Offline", TRUE));
    return types;
}
```

---

## 4. Plugin Registration (`PURPLE_INIT_PLUGIN`)

Define the plugin initialization function and register it using libpurple's macro:

```c
#include <purple.h>

#define YOUR_PLUGIN_ID "prpl-adium-yourprotocol"

static void
plugin_init(PurplePlugin *plugin)
{
    PurplePluginInfo *info = g_new0(PurplePluginInfo, 1);
    PurplePluginProtocolInfo *prpl_info = g_new0(PurplePluginProtocolInfo, 1);

    info->magic = PURPLE_PLUGIN_MAGIC;
    info->major_version = PURPLE_MAJOR_VERSION;
    info->minor_version = PURPLE_MINOR_VERSION;
    info->type = PURPLE_PLUGIN_PROTOCOL;
    info->id = YOUR_PLUGIN_ID;
    info->name = "Your Protocol";
    info->version = "1.0.0";
    info->summary = "Plugin Summary";
    info->description = "Plugin Description";
    info->author = "Developer Name";
    info->homepage = "https://github.com/adium/adium";
    info->extra_info = prpl_info;

    prpl_info->struct_size = sizeof(PurplePluginProtocolInfo);
    prpl_info->options = OPT_PROTO_NO_PASSWORD;
    prpl_info->list_icon = yourprotocol_list_icon;
    prpl_info->status_types = yourprotocol_status_types;
    prpl_info->login = yourprotocol_login;
    prpl_info->close = yourprotocol_close;
    prpl_info->send_im = yourprotocol_send_im;

    plugin->info = info;
}

static PurplePluginInfo plugin_info_struct;
PURPLE_INIT_PLUGIN(yourprotocol, plugin_init, plugin_info_struct)
```

---

## 5. Makefile Conventions

Your `Makefile` should build a shared dynamic library `.so` linked against libpurple and glib-2.0.

```makefile
CC ?= gcc
CFLAGS ?= -O2 -g -pipe -fPIC
LDFLAGS ?= 

PKG_CONFIG ?= pkg-config
PURPLE_CFLAGS := $(shell $(PKG_CONFIG) --cflags purple glib-2.0 2>/dev/null || echo "-I/opt/homebrew/include/libpurple -I/opt/homebrew/include/glib-2.0 -I/opt/homebrew/lib/glib-2.0/include")
PURPLE_LIBS := $(shell $(PKG_CONFIG) --libs purple glib-2.0 2>/dev/null || echo "-L/opt/homebrew/lib -lpurple -lglib-2.0")

TARGET = libyourprotocol.so
C_FILES = libyourprotocol.c yourprotocol_login.c yourprotocol_connection.c yourprotocol_contacts.c yourprotocol_messages.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(C_FILES)
	$(CC) $(CFLAGS) -shared -o $@ $^ $(PURPLE_CFLAGS) $(PURPLE_LIBS) $(LDFLAGS)

clean:
	rm -f $(TARGET)
```

---

## 6. Icon Assets

Place PNG icon assets matching `list_icon`'s return string in 3 resolution subdirectories:

- `icons/16/yourprotocol.png` (16x16 px)
- `icons/22/yourprotocol.png` (22x22 px)
- `icons/48/yourprotocol.png` (48x48 px)

---

## 7. Connecting Custom Protocols in Swift

To make your custom protocol selectable in the Fluorite UI, add a case to `AccountProtocol` in `Sources/Fluorite/Models.swift`:

```swift
public enum AccountProtocol: String, Codable, CaseIterable {
    case yourprotocol = "Your Protocol"
    
    public var purpleProtocolID: String {
        switch self {
        case .yourprotocol: return "prpl-adium-yourprotocol"
        }
    }
}
```

Once built, placing `libyourprotocol.so` in `Plugins/yourprotocol/` will allow `make app` to automatically package it into `Fluorite.app/Contents/PlugIns/` and load it dynamically on launch.
