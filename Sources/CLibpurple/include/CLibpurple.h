#ifndef CLIBPURPLE_H
#define CLIBPURPLE_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Callback function signatures for real libpurple events
typedef void (*adium_purple_on_contact_cb)(const char* name, const char* handle, const char* status_id, const char* status_name, const char* group, const char* protocol_id);
typedef void (*adium_purple_on_message_cb)(const char* sender_handle, const char* message_text, bool is_from_me);
typedef void (*adium_purple_on_status_cb)(const char* status_text);
typedef void (*adium_purple_on_account_state_cb)(const char* username, const char* protocol_id, bool is_connected, const char* status_msg);

// Extended callback function signatures for interactive requests, connection progress, typing & buddy removal
typedef void (*adium_purple_on_request_input_cb)(void* request_handle, const char* title, const char* primary, const char* secondary, const char* default_value, bool masked, const char* hint);
typedef void (*adium_purple_on_request_action_cb)(void* request_handle, const char* title, const char* primary, const char* secondary, int default_action, const char* const* action_titles, int action_count);
typedef void (*adium_purple_on_request_close_cb)(void* request_handle);
typedef void (*adium_purple_on_connection_progress_cb)(const char* username, const char* protocol_id, const char* text, size_t step, size_t step_count);
typedef void (*adium_purple_on_typing_cb)(const char* handle, bool is_typing);
typedef void (*adium_purple_on_buddy_removed_cb)(const char* handle);

// File transfer (PurpleXfer) callback signatures
typedef void (*adium_purple_on_xfer_new_cb)(void* xfer_handle, const char* who, const char* filename, size_t size, bool is_incoming);
typedef void (*adium_purple_on_xfer_update_cb)(void* xfer_handle, size_t bytes_sent, size_t bytes_total, int status);
typedef void (*adium_purple_on_xfer_cancel_cb)(void* xfer_handle, bool by_local);
// Called once libpurple is about to free the PurpleXfer; the raw pointer must not be used after this fires
typedef void (*adium_purple_on_xfer_destroyed_cb)(void* xfer_handle);

// Group chat (MUC) callback signatures
typedef void (*adium_purple_on_chat_joined_cb)(const char* room_name, const char* username, const char* protocol_id);
typedef void (*adium_purple_on_chat_left_cb)(const char* room_name, const char* username, const char* protocol_id);
typedef void (*adium_purple_on_chat_message_cb)(const char* room_name, const char* sender, const char* message_text, bool is_from_me);
// Fired for every occupant of a joined chat: existing occupants arrive with new_arrival=false
// as the roster is populated right after joining, later arrivals have new_arrival=true.
typedef void (*adium_purple_on_chat_buddy_joined_cb)(const char* room_name, const char* buddy_name, bool new_arrival);
typedef void (*adium_purple_on_chat_buddy_left_cb)(const char* room_name, const char* buddy_name);

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

// Register extended Swift callbacks (interactive requests, connection progress, typing, buddy removal)
void adium_purple_set_extended_event_callbacks(
    adium_purple_on_request_input_cb request_input_cb,
    adium_purple_on_request_action_cb request_action_cb,
    adium_purple_on_request_close_cb request_close_cb,
    adium_purple_on_connection_progress_cb connection_progress_cb,
    adium_purple_on_typing_cb typing_cb,
    adium_purple_on_buddy_removed_cb buddy_removed_cb
);

// Respond to interactive prompts from Swift
void adium_purple_request_input_respond(void* request_handle, const char* input_text, bool ok);
void adium_purple_request_action_respond(void* request_handle, int action_index);

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

// Set account options (server, resource, custom options)
bool adium_purple_set_account_option(const char* username, const char* protocol_id, const char* key, const char* value);
bool adium_purple_set_account_int_option(const char* username, const char* protocol_id, const char* key, int value);
bool adium_purple_set_account_bool_option(const char* username, const char* protocol_id, const char* key, bool value);

// Set overall user presence/status (available, away, busy, offline), with an optional
// custom status message (pass NULL or an empty string for none).
bool adium_purple_set_user_status(const char* status_id, const char* message);

// Block/unblock a contact at the protocol level (privacy deny list)
bool adium_purple_block_contact(const char* username, const char* protocol_id, const char* who);
bool adium_purple_unblock_contact(const char* username, const char* protocol_id, const char* who);

// File transfer (PurpleXfer) control API
void adium_purple_set_xfer_callbacks(
    adium_purple_on_xfer_new_cb xfer_new_cb,
    adium_purple_on_xfer_update_cb xfer_update_cb,
    adium_purple_on_xfer_cancel_cb xfer_cancel_cb,
    adium_purple_on_xfer_destroyed_cb xfer_destroyed_cb
);
bool adium_purple_xfer_accept(void* xfer_handle, const char* local_path);
bool adium_purple_xfer_cancel(void* xfer_handle);
bool adium_purple_send_file(const char* account_username, const char* protocol_id, const char* who, const char* filepath);

// Group chat (MUC) control API
void adium_purple_set_chat_callbacks(
    adium_purple_on_chat_joined_cb chat_joined_cb,
    adium_purple_on_chat_left_cb chat_left_cb,
    adium_purple_on_chat_message_cb chat_message_cb,
    adium_purple_on_chat_buddy_joined_cb chat_buddy_joined_cb,
    adium_purple_on_chat_buddy_left_cb chat_buddy_left_cb
);
bool adium_purple_join_chat(const char* username, const char* protocol_id, const char* room_name);
bool adium_purple_send_chat_message(const char* account_username, const char* protocol_id, const char* room_name, const char* message_text);

#ifdef __cplusplus
}
#endif

#endif /* CLIBPURPLE_H */

