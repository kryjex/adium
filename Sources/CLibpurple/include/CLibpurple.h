#ifndef CLIBPURPLE_H
#define CLIBPURPLE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Callback function signatures for real libpurple events
typedef void (*adium_purple_on_contact_cb)(const char* name, const char* handle, const char* status_id, const char* status_name, const char* group, const char* protocol_id);
typedef void (*adium_purple_on_message_cb)(const char* sender_handle, const char* message_text, bool is_from_me);
typedef void (*adium_purple_on_status_cb)(const char* status_text);
typedef void (*adium_purple_on_account_state_cb)(const char* username, const char* protocol_id, bool is_connected, const char* status_msg);

// Initialize core libpurple subsystems and register plugin search paths
bool adium_purple_init(const char* custom_plugin_dir, const char* user_dir);

// Start the GLib background event loop for network sockets
void adium_purple_start_event_loop(void);

// Probe and load a plugin dynamic library
bool adium_purple_load_plugin(const char* plugin_path);

// Get status string
const char* adium_purple_get_status_info(void);

// Register Swift callbacks to receive real live events from libpurple
void adium_purple_set_event_callbacks(
    adium_purple_on_contact_cb contact_cb,
    adium_purple_on_message_cb message_cb,
    adium_purple_on_status_cb status_cb,
    adium_purple_on_account_state_cb account_state_cb
);

// Add and connect a new libpurple account (e.g. protocol_id = "prpl-teams")
bool adium_purple_add_account(const char* username, const char* protocol_id, const char* password);

// Remove an account from libpurple
bool adium_purple_remove_account(const char* username, const char* protocol_id);

// Send real message via libpurple (with multi-account support)
bool adium_purple_send_message(const char* account_username, const char* protocol_id, const char* recipient_handle, const char* message_text);

// Load and emit existing accounts and buddies from libpurple to Swift
void adium_purple_load_accounts(void);

// Clean shutdown of libpurple
void adium_purple_uninit(void);

// Set overall user presence/status (available, away, busy, offline)
bool adium_purple_set_user_status(const char* status_id);

#ifdef __cplusplus
}
#endif

#endif /* CLIBPURPLE_H */

