#include "CLibpurple.h"
#include <purple.h>
#include <glib.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netdb.h>

static bool g_initialized = false;
static pthread_mutex_t g_status_mutex = PTHREAD_MUTEX_INITIALIZER;
static char g_status_buffer[512] = "Libpurple Idle";
static GMainLoop *g_loop = NULL;
static int adium_signal_handle = 0;

static adium_purple_on_contact_cb g_contact_cb = NULL;
static adium_purple_on_message_cb g_message_cb = NULL;
static adium_purple_on_status_cb g_status_cb = NULL;
static adium_purple_on_account_state_cb g_account_state_cb = NULL;

static adium_purple_on_request_input_cb g_request_input_cb = NULL;
static adium_purple_on_request_action_cb g_request_action_cb = NULL;
static adium_purple_on_request_close_cb g_request_close_cb = NULL;
static adium_purple_on_connection_progress_cb g_connection_progress_cb = NULL;
static adium_purple_on_typing_cb g_typing_cb = NULL;
static adium_purple_on_buddy_removed_cb g_buddy_removed_cb = NULL;
static adium_purple_on_notify_message_cb g_notify_message_cb = NULL;

static adium_purple_on_xfer_new_cb g_xfer_new_cb = NULL;
static adium_purple_on_xfer_update_cb g_xfer_update_cb = NULL;
static adium_purple_on_xfer_cancel_cb g_xfer_cancel_cb = NULL;
static adium_purple_on_xfer_destroyed_cb g_xfer_destroyed_cb = NULL;

static adium_purple_on_chat_joined_cb g_chat_joined_cb = NULL;
static adium_purple_on_chat_left_cb g_chat_left_cb = NULL;
static adium_purple_on_chat_message_cb g_chat_message_cb = NULL;
static adium_purple_on_chat_buddy_joined_cb g_chat_buddy_joined_cb = NULL;
static adium_purple_on_chat_buddy_left_cb g_chat_buddy_left_cb = NULL;
static adium_purple_on_chat_listed_cb g_chat_listed_cb = NULL;
static adium_purple_on_chat_unlisted_cb g_chat_unlisted_cb = NULL;

/* This set holds live PurpleXfer pointers, touched only on the purple thread.
 * libpurple calls the new_xfer and destroy UI ops on that thread. do_xfer_accept
 * and do_xfer_cancel reach the set through g_idle_add. The set stops Swift from
 * holding a raw pointer to a transfer libpurple already freed. */
static GHashTable *g_live_xfers = NULL;

static void ensure_live_xfers_table(void) {
    if (!g_live_xfers) {
        g_live_xfers = g_hash_table_new(NULL, NULL);
    }
}

/* --- File Transfer UI Ops --- */

static void adium_xfer_new_xfer(PurpleXfer *xfer) {
    if (!xfer) return;
    /* Take a reference so the xfer cannot be freed while Swift holds its address.
     * adium_xfer_destroy releases the reference. This mirrors Pidgin's gtkft.c
     * ref/unref pairing. */
    purple_xfer_ref(xfer);
    ensure_live_xfers_table();
    g_hash_table_add(g_live_xfers, xfer);

    PurpleXferType type = purple_xfer_get_type(xfer);
    bool is_incoming = (type == PURPLE_XFER_RECEIVE);
    const char *who = purple_xfer_get_remote_user(xfer);
    const char *filename = purple_xfer_get_filename(xfer);
    size_t size = purple_xfer_get_size(xfer);
    if (g_xfer_new_cb) {
        g_xfer_new_cb((void*)xfer, who ? who : "", filename ? filename : "", size, is_incoming);
    }
}

static void adium_xfer_destroy(PurpleXfer *xfer) {
    if (!xfer) return;
    if (g_live_xfers) {
        g_hash_table_remove(g_live_xfers, xfer);
    }
    if (g_xfer_destroyed_cb) {
        g_xfer_destroyed_cb((void*)xfer);
    }
    purple_xfer_unref(xfer);
}

static void adium_xfer_update_progress(PurpleXfer *xfer, double percent) {
    (void)percent;
    if (!xfer) return;
    size_t bytes_sent = purple_xfer_get_bytes_sent(xfer);
    size_t size = purple_xfer_get_size(xfer);
    PurpleXferStatusType status = purple_xfer_get_status(xfer);
    if (g_xfer_update_cb) {
        g_xfer_update_cb((void*)xfer, bytes_sent, size, (int)status);
    }
}

static void adium_xfer_cancel_local(PurpleXfer *xfer) {
    if (!xfer) return;
    if (g_xfer_cancel_cb) {
        g_xfer_cancel_cb((void*)xfer, true);
    }
}

static void adium_xfer_cancel_remote(PurpleXfer *xfer) {
    if (!xfer) return;
    if (g_xfer_cancel_cb) {
        g_xfer_cancel_cb((void*)xfer, false);
    }
}

static PurpleXferUiOps xfer_ui_ops = {
    .new_xfer = adium_xfer_new_xfer,
    .destroy = adium_xfer_destroy,
    .add_xfer = NULL,
    .update_progress = adium_xfer_update_progress,
    .cancel_local = adium_xfer_cancel_local,
    .cancel_remote = adium_xfer_cancel_remote,
    .ui_write = NULL,
    .ui_read = NULL,
    .data_not_sent = NULL,
    .add_thumbnail = NULL
};

/* --- GLib Eventloop UI Ops --- */

static guint glib_timeout_add(guint interval, GSourceFunc function, gpointer data) {
    return g_timeout_add(interval, function, data);
}

static gboolean glib_timeout_remove(guint handle) {
    return g_source_remove(handle);
}

typedef struct {
    PurpleInputFunction function;
    gpointer data;
} PurpleGLibIOClosure;

static gboolean glib_io_cb(GIOChannel *source, GIOCondition condition, gpointer data) {
    PurpleGLibIOClosure *closure = (PurpleGLibIOClosure *)data;
    PurpleInputCondition purple_cond = 0;
    if (condition & (G_IO_IN | G_IO_HUP | G_IO_ERR)) {
        purple_cond |= PURPLE_INPUT_READ;
    }
    if (condition & (G_IO_OUT | G_IO_HUP | G_IO_ERR)) {
        purple_cond |= PURPLE_INPUT_WRITE;
    }
    closure->function(closure->data, g_io_channel_unix_get_fd(source), purple_cond);
    return TRUE;
}

static guint glib_input_add(int fd, PurpleInputCondition condition, PurpleInputFunction function, gpointer data) {
    PurpleGLibIOClosure *closure = g_new0(PurpleGLibIOClosure, 1);
    closure->function = function;
    closure->data = data;
    GIOCondition cond = 0;
    if (condition & PURPLE_INPUT_READ) cond |= (G_IO_IN | G_IO_HUP | G_IO_ERR);
    if (condition & PURPLE_INPUT_WRITE) cond |= (G_IO_OUT | G_IO_HUP | G_IO_ERR);
    GIOChannel *channel = g_io_channel_unix_new(fd);
    guint id = g_io_add_watch_full(channel, G_PRIORITY_DEFAULT, cond, glib_io_cb, closure, g_free);
    g_io_channel_unref(channel);
    return id;
}

static gboolean glib_input_remove(guint handle) {
    return g_source_remove(handle);
}

static guint glib_timeout_add_seconds(guint interval, GSourceFunc function, gpointer data) {
    return g_timeout_add_seconds(interval, function, data);
}

static PurpleEventLoopUiOps eventloop_ops = {
    .timeout_add = glib_timeout_add,
    .timeout_remove = glib_timeout_remove,
    .input_add = glib_input_add,
    .input_remove = glib_input_remove,
    .input_get_error = NULL,
    .timeout_add_seconds = glib_timeout_add_seconds,
    ._purple_reserved2 = NULL,
    ._purple_reserved3 = NULL,
    ._purple_reserved4 = NULL
};

/* --- Core UI Ops & Debug --- */

static void adium_ui_init(void) {}
static void adium_ui_quit(void) {}

static PurpleCoreUiOps core_ui_ops = {
    .ui_prefs_init = NULL,
    .debug_ui_init = NULL,
    .ui_init = adium_ui_init,
    .quit = adium_ui_quit,
    .get_ui_info = NULL,
    ._purple_reserved1 = NULL,
    ._purple_reserved2 = NULL,
    ._purple_reserved3 = NULL
};

static void adium_debug_print(PurpleDebugLevel level, const char *category, const char *arg) {
    if (arg) {
        printf("[libpurple %d][%s] %s", level, category ? category : "core", arg);
    }
}

static PurpleDebugUiOps debug_ui_ops = {
    .print = adium_debug_print,
    .is_enabled = NULL,
    ._purple_reserved1 = NULL,
    ._purple_reserved2 = NULL,
    ._purple_reserved3 = NULL,
    ._purple_reserved4 = NULL
};

static void* adium_notify_uri(const char *uri) {
    if (uri && uri[0] != '\0') {
        char cmd[2048];
        snprintf(cmd, sizeof(cmd), "open \"%s\"", uri);
        system(cmd);
    }
    return NULL;
}

static void* adium_notify_message(PurpleNotifyMsgType type, const char *title, const char *primary, const char *secondary) {
    if (g_notify_message_cb) {
        g_notify_message_cb((int)type, title, primary, secondary);
    }
    return NULL;
}

static PurpleNotifyUiOps notify_ui_ops = {
    .notify_message = adium_notify_message,
    .notify_email = NULL,
    .notify_emails = NULL,
    .notify_formatted = NULL,
    .notify_searchresults = NULL,
    .notify_searchresults_new_rows = NULL,
    .notify_userinfo = NULL,
    .notify_uri = adium_notify_uri,
    .close_notify = NULL,
    ._purple_reserved1 = NULL,
    ._purple_reserved2 = NULL,
    ._purple_reserved3 = NULL,
    ._purple_reserved4 = NULL
};

/* --- Request & Connection UI Ops --- */

typedef struct {
    PurpleRequestType type;
    GCallback ok_cb;
    GCallback cancel_cb;
    void *user_data;
    PurpleAccount *account;
    size_t action_count;
    GCallback *action_cbs;
} AdiumRequestHandle;

/* This set holds live AdiumRequestHandle pointers. adium_close_request is the
 * only place that frees a handle. A stale respond op can queue before libpurple
 * closes the handle, for example purple_request_close_with_handle on disconnect.
 * The set lets that op detect the closed handle and become a no-op instead of
 * touching freed memory. Only the purple thread touches the set. request_input,
 * request_action, and close_request run there directly. The respond entry
 * points below reach the set through g_idle_add. */
static GHashTable *g_live_requests = NULL;

static void ensure_live_requests_table(void) {
    if (!g_live_requests) {
        g_live_requests = g_hash_table_new(NULL, NULL);
    }
}

static void *adium_request_input(const char *title, const char *primary,
                               const char *secondary, const char *default_value,
                               gboolean multiline, gboolean masked, gchar *hint,
                               const char *ok_text, GCallback ok_cb,
                               const char *cancel_text, GCallback cancel_cb,
                               PurpleAccount *account, const char *who,
                               PurpleConversation *conv, void *user_data) {
    (void)multiline; (void)ok_text; (void)cancel_text; (void)who; (void)conv;
    AdiumRequestHandle *handle = g_new0(AdiumRequestHandle, 1);
    handle->type = PURPLE_REQUEST_INPUT;
    handle->ok_cb = ok_cb;
    handle->cancel_cb = cancel_cb;
    handle->user_data = user_data;
    handle->account = account;

    if (g_request_input_cb) {
        ensure_live_requests_table();
        g_hash_table_add(g_live_requests, handle);
        g_request_input_cb((void*)handle, title, primary, secondary, default_value, masked, hint);
    } else {
        if (ok_cb) {
            ((PurpleRequestInputCb)ok_cb)(user_data, default_value ? default_value : "");
        }
        g_free(handle);
        return NULL;
    }
    return (void*)handle;
}

static void *adium_request_action(const char *title, const char *primary,
                                const char *secondary, int default_action,
                                PurpleAccount *account, const char *who,
                                PurpleConversation *conv, void *user_data,
                                size_t action_count, va_list actions) {
    (void)who; (void)conv;
    AdiumRequestHandle *handle = g_new0(AdiumRequestHandle, 1);
    handle->type = PURPLE_REQUEST_ACTION;
    handle->user_data = user_data;
    handle->account = account;
    handle->action_count = action_count;

    const char **action_titles = g_new0(const char*, action_count + 1);
    handle->action_cbs = g_new0(GCallback, action_count);

    for (size_t i = 0; i < action_count; i++) {
        const char *title = va_arg(actions, const char *);
        /* Button labels carry a GTK mnemonic marker, for example "_Aceptar". The
         * code drops the first underscore. Adium's UI has no mnemonic concept. */
        gchar *clean = g_strdup(title ? title : "");
        char *underscore = strchr(clean, '_');
        if (underscore) {
            memmove(underscore, underscore + 1, strlen(underscore + 1) + 1);
        }
        action_titles[i] = clean;
        handle->action_cbs[i] = va_arg(actions, GCallback);
    }

    if (g_request_action_cb) {
        ensure_live_requests_table();
        g_hash_table_add(g_live_requests, handle);
        /* The Swift callback copies the titles synchronously, so they can be
         * released as soon as it returns. */
        g_request_action_cb((void*)handle, title, primary, secondary, default_action, action_titles, (int)action_count);
        for (size_t i = 0; i < action_count; i++) {
            g_free((gpointer)action_titles[i]);
        }
        g_free(action_titles);
        return (void*)handle;
    } else {
        if (default_action >= 0 && (size_t)default_action < action_count && handle->action_cbs[default_action]) {
            ((PurpleRequestActionCb)handle->action_cbs[default_action])(user_data, default_action);
        }
        for (size_t i = 0; i < action_count; i++) {
            g_free((gpointer)action_titles[i]);
        }
        g_free(action_titles);
        g_free(handle->action_cbs);
        g_free(handle);
        return NULL;
    }
}

static void *adium_request_action_with_icon(const char *title, const char *primary,
                                          const char *secondary, int default_action,
                                          PurpleAccount *account, const char *who,
                                          PurpleConversation *conv,
                                          gconstpointer icon_data, gsize icon_size,
                                          void *user_data,
                                          size_t action_count, va_list actions) {
    (void)icon_data; (void)icon_size;
    return adium_request_action(title, primary, secondary, default_action, account, who, conv, user_data, action_count, actions);
}

static void adium_close_request(PurpleRequestType type, void *ui_handle) {
    (void)type;
    if (!ui_handle) return;
    /* This is the only place that removes a handle from the live set and frees it.
     * The respond ops below can reach it, or libpurple can close the request first,
     * for example purple_request_close_with_handle on disconnect. A handle that is
     * already gone is a lost race, not a double free. */
    if (!g_live_requests || !g_hash_table_contains(g_live_requests, ui_handle)) {
        return;
    }
    g_hash_table_remove(g_live_requests, ui_handle);
    AdiumRequestHandle *handle = (AdiumRequestHandle *)ui_handle;
    if (g_request_close_cb) {
        g_request_close_cb((void*)handle);
    }
    if (handle->action_cbs) {
        g_free(handle->action_cbs);
    }
    g_free(handle);
}

static PurpleRequestUiOps request_ui_ops = {
    .request_input = adium_request_input,
    .request_choice = NULL,
    .request_action = adium_request_action,
    .request_fields = NULL,
    .request_file = NULL,
    .close_request = adium_close_request,
    .request_folder = NULL,
    .request_action_with_icon = adium_request_action_with_icon,
    ._purple_reserved1 = NULL,
    ._purple_reserved2 = NULL
};

static void update_status(const char* fmt, ...);

static void adium_connection_connect_progress(PurpleConnection *gc, const char *text, size_t step, size_t step_count) {
    if (!gc) return;
    PurpleAccount *account = purple_connection_get_account(gc);
    if (!account) return;
    const char *username = purple_account_get_username(account);
    const char *proto_id = purple_account_get_protocol_id(account);

    update_status("Connecting %s (%s): %s (%zu/%zu)", username ? username : "", proto_id ? proto_id : "", text ? text : "", step, step_count);
    if (g_connection_progress_cb && username && proto_id) {
        g_connection_progress_cb(username, proto_id, text ? text : "", step, step_count);
    }
}

/* connected, disconnected, and report_disconnect_reason stay unset on purpose.
 * The account-signed-on, account-signed-off, and account-connection-error
 * signals in adium_purple_init already cover the same events. Wiring both
 * paths fires every connection state change twice into Swift. */
static PurpleConnectionUiOps connection_ui_ops = {
    .connect_progress = adium_connection_connect_progress,
    .connected = NULL,
    .disconnected = NULL,
    .notice = NULL,
    .report_disconnect = NULL,
    .network_connected = NULL,
    .network_disconnected = NULL,
    .report_disconnect_reason = NULL,
    ._purple_reserved1 = NULL,
    ._purple_reserved2 = NULL,
    ._purple_reserved3 = NULL
};

/* --- Signal Handlers --- */

static void update_status(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    pthread_mutex_lock(&g_status_mutex);
    vsnprintf(g_status_buffer, sizeof(g_status_buffer), fmt, args);
    pthread_mutex_unlock(&g_status_mutex);
    va_end(args);
    if (g_status_cb) {
        char status_copy[512];
        pthread_mutex_lock(&g_status_mutex);
        g_strlcpy(status_copy, g_status_buffer, sizeof(status_copy));
        pthread_mutex_unlock(&g_status_mutex);
        g_status_cb(status_copy);
    }
}

/* Resolve the imgstore image referenced by an inline <img id="N"> tag, if any.
 * Only valid while the referenced image is still referenced in the imgstore,
 * i.e. synchronously within the signal callback. */
static void extract_inline_image(const char *message, PurpleMessageFlags flags, const void **image_data, size_t *image_size) {
    (void)flags;
    *image_data = NULL;
    *image_size = 0;
    if (!message) return;
    /* purple-teams writes <img id='N'> without PURPLE_MESSAGE_IMAGES.
     * gowhatsapp writes <img id="N"> with the flag. Accept both. */
    char *img_tag = strstr(message, "<img id=\"");
    if (!img_tag) img_tag = strstr(message, "<img id='");
    if (!img_tag) return;
    int img_id = atoi(img_tag + 9);
    if (img_id <= 0) return;
    PurpleStoredImage *img = purple_imgstore_find_by_id(img_id);
    if (img) {
        *image_size = purple_imgstore_get_size(img);
        *image_data = purple_imgstore_get_data(img);
    }
}

/* Conversation ui op. Every IM write lands here with the real message time.
 * The conversation signals do not carry mtime, so this is the only capture
 * point that keeps history timestamps. serv_got_im routes received messages
 * here, and common_send routes the local echo of a send here. */
static void adium_write_im(PurpleConversation *conv, const char *who, const char *message, PurpleMessageFlags flags, time_t mtime) {
    if (!g_message_cb || !conv || !message) return;

    bool is_send = (flags & PURPLE_MESSAGE_SEND) != 0;
    bool is_recv = (flags & PURPLE_MESSAGE_RECV) != 0;
    bool is_notice = (flags & (PURPLE_MESSAGE_SYSTEM | PURPLE_MESSAGE_ERROR)) && !is_send && !is_recv;
    if (!is_send && !is_recv && !is_notice) return;

    PurpleAccount *account = purple_conversation_get_account(conv);
    const char *protocol_id = account ? purple_account_get_protocol_id(account) : "";
    const char *account_username = account ? purple_account_get_username(account) : "";
    /* The conversation name is the remote peer's handle. `who` holds the
     * sender, which for SEND writes is the local user. */
    const char *handle = purple_conversation_get_name(conv);
    if (!handle) handle = who;
    if (!handle) return;

    const void *image_data = NULL;
    size_t image_size = 0;
    extract_inline_image(message, flags, &image_data, &image_size);

    bool is_system = (flags & (PURPLE_MESSAGE_SYSTEM | PURPLE_MESSAGE_ERROR)) != 0;
    g_message_cb(handle, message, is_send, is_system, protocol_id, account_username, (long long)mtime, image_data, image_size);
}


static void cb_buddy_typing(PurpleAccount *account, const char *name, void *data) {
    (void)account; (void)data;
    if (g_typing_cb && name) {
        g_typing_cb(name, true);
    }
}

static void cb_buddy_typing_stopped(PurpleAccount *account, const char *name, void *data) {
    (void)account; (void)data;
    if (g_typing_cb && name) {
        g_typing_cb(name, false);
    }
}

static void cb_buddy_removed(PurpleBuddy *buddy, void *data) {
    (void)data;
    if (!buddy || !g_buddy_removed_cb) return;
    const char *handle = purple_buddy_get_name(buddy);
    if (handle) {
        g_buddy_removed_cb(handle);
    }
}

static void cb_buddy_signed_on_off(PurpleBuddy *buddy, void *data) {
    (void)data;
    if (!buddy || !g_contact_cb) return;
    const char *name = purple_buddy_get_alias(buddy);
    if (!name) name = purple_buddy_get_name(buddy);
    const char *handle = purple_buddy_get_name(buddy);
    PurplePresence *presence = purple_buddy_get_presence(buddy);
    PurpleStatus *status = presence ? purple_presence_get_active_status(presence) : NULL;
    const char *status_id = status ? purple_status_get_id(status) : "offline";
    const char *status_name = status ? purple_status_get_name(status) : "Offline";
    PurpleGroup *group = purple_buddy_get_group(buddy);
    const char *group_name = group ? purple_group_get_name(group) : "General";
    PurpleAccount *account = purple_buddy_get_account(buddy);
    const char *proto_id = account ? purple_account_get_protocol_id(account) : "";

    g_contact_cb(name, handle, status_id, status_name, group_name, proto_id);
}

static void cb_buddy_status_changed(PurpleBuddy *buddy, PurpleStatus *old_status, PurpleStatus *status, void *data) {
    (void)old_status; (void)status;
    cb_buddy_signed_on_off(buddy, data);
}

/* The room identifier lives in the chat components. The component key
 * differs per protocol: teams uses "chatname", most other prpls use "room". */
static const char* chat_node_room_name(PurpleChat *chat) {
    GHashTable *components = purple_chat_get_components(chat);
    if (!components) return NULL;
    const char *room = g_hash_table_lookup(components, "chatname");
    if (!room) room = g_hash_table_lookup(components, "room");
    if (!room) room = g_hash_table_lookup(components, "channel");
    return room;
}

static void emit_chat_listed(PurpleChat *chat) {
    if (!chat || !g_chat_listed_cb) return;
    const char *room = chat_node_room_name(chat);
    if (!room || !*room) return;
    const char *title = purple_chat_get_name(chat);
    PurpleGroup *group = purple_chat_get_group(chat);
    const char *group_name = group ? purple_group_get_name(group) : "General";
    PurpleAccount *account = purple_chat_get_account(chat);
    const char *username = account ? purple_account_get_username(account) : "";
    const char *proto_id = account ? purple_account_get_protocol_id(account) : "";
    g_chat_listed_cb(room, (title && *title) ? title : room, group_name, username, proto_id);
}

/* Protocol plugins add chat and buddy nodes after the account connects.
 * These signals surface those late additions. The initial enumeration in
 * do_load_accounts only covers nodes persisted in blist.xml. */
static void cb_blist_node_added(PurpleBlistNode *node, void *data) {
    (void)data;
    if (!node) return;
    if (PURPLE_BLIST_NODE_IS_CHAT(node)) {
        emit_chat_listed((PurpleChat *)node);
    } else if (PURPLE_BLIST_NODE_IS_BUDDY(node)) {
        cb_buddy_signed_on_off((PurpleBuddy *)node, NULL);
    }
}

static void cb_blist_node_removed(PurpleBlistNode *node, void *data) {
    (void)data;
    /* Buddy removals arrive through the "buddy-removed" signal. */
    if (!node || !PURPLE_BLIST_NODE_IS_CHAT(node) || !g_chat_unlisted_cb) return;
    PurpleChat *chat = (PurpleChat *)node;
    const char *room = chat_node_room_name(chat);
    if (!room || !*room) return;
    PurpleAccount *account = purple_chat_get_account(chat);
    g_chat_unlisted_cb(room,
                       account ? purple_account_get_username(account) : "",
                       account ? purple_account_get_protocol_id(account) : "");
}

static void cb_blist_node_aliased(PurpleBlistNode *node, const char *old_alias, void *data) {
    (void)old_alias;
    /* An alias change carries the chat title or the buddy display name. */
    cb_blist_node_added(node, data);
}

static void cb_account_signed_on(PurpleAccount *account, void *data) {
    (void)data;
    if (!account) return;
    const char *username = purple_account_get_username(account);
    const char *proto_id = purple_account_get_protocol_id(account);
    /* The UI renders inline images in the chat itself. These options make
     * purple-gowhatsapp download images and stickers to a temporary location
     * and display them inline. Without them, every sticker raises a
     * file-transfer request dialog. The options also drop status broadcasts
     * (stories), which follows the user preference. */
    if (proto_id && strcmp(proto_id, "prpl-hehoe-whatsmeow") == 0) {
        purple_account_set_string(account, "handle-images", "inline");
        purple_account_set_bool(account, "ignore-status-broadcast", TRUE);
    }
    update_status("Account connected: %s (%s)", username, proto_id);
    if (g_account_state_cb) {
        g_account_state_cb(username, proto_id, true, "Connected");
    }
}

static void cb_account_signed_off(PurpleAccount *account, void *data) {
    (void)data;
    if (!account) return;
    const char *username = purple_account_get_username(account);
    const char *proto_id = purple_account_get_protocol_id(account);
    update_status("Account disconnected: %s (%s)", username, proto_id);
    if (g_account_state_cb) {
        g_account_state_cb(username, proto_id, false, "Disconnected");
    }
}

static void cb_account_connection_error(PurpleAccount *account, PurpleConnectionError err, const char *desc, void *data) {
    (void)err; (void)data;
    if (!account) return;
    const char *username = purple_account_get_username(account);
    const char *proto_id = purple_account_get_protocol_id(account);
    update_status("Connection error (%s): %s", username, desc ? desc : "Unknown");
    if (g_account_state_cb) {
        g_account_state_cb(username, proto_id, false, desc ? desc : "Connection error");
    }
}

static void cb_chat_joined(PurpleConversation *conv, void *data) {
    (void)data;
    if (!conv) return;
    PurpleAccount *account = purple_conversation_get_account(conv);
    if (!account) return;
    const char *room_name = purple_conversation_get_name(conv);
    const char *username = purple_account_get_username(account);
    const char *proto_id = purple_account_get_protocol_id(account);
    if (g_chat_joined_cb && room_name && username && proto_id) {
        g_chat_joined_cb(room_name, username, proto_id);
    }
}

static void cb_chat_left(PurpleConversation *conv, void *data) {
    (void)data;
    if (!conv) return;
    PurpleAccount *account = purple_conversation_get_account(conv);
    if (!account) return;
    const char *room_name = purple_conversation_get_name(conv);
    const char *username = purple_account_get_username(account);
    const char *proto_id = purple_account_get_protocol_id(account);
    if (g_chat_left_cb && room_name && username && proto_id) {
        g_chat_left_cb(room_name, username, proto_id);
    }
}

/* This syncs the roster of a joined chat. On join, libpurple fires this once
 * per existing occupant with new_arrival=FALSE. A later joiner fires it with
 * new_arrival=TRUE. The code forwards both cases with new_arrival, so Swift
 * can decide whether to surface a join notification. */
static void cb_chat_buddy_joined(PurpleConversation *conv, const char *name, PurpleConvChatBuddyFlags flags, gboolean new_arrival, void *data) {
    (void)flags; (void)data;
    if (!conv || !name) return;
    const char *room_name = purple_conversation_get_name(conv);
    if (g_chat_buddy_joined_cb && room_name) {
        g_chat_buddy_joined_cb(room_name, name, (bool)new_arrival);
    }
}

static void cb_chat_buddy_left(PurpleConversation *conv, const char *name, const char *reason, void *data) {
    (void)reason; (void)data;
    if (!conv || !name) return;
    const char *room_name = purple_conversation_get_name(conv);
    if (g_chat_buddy_left_cb && room_name) {
        g_chat_buddy_left_cb(room_name, name);
    }
}

/* Conversation ui op. serv_got_chat_in routes every chat message here with
 * the real message time. History replays keep their original timestamps.
 * The server echo of an own send arrives here with PURPLE_MESSAGE_SEND. */
static void adium_write_chat(PurpleConversation *conv, const char *who, const char *message, PurpleMessageFlags flags, time_t mtime) {
    if (!g_chat_message_cb || !conv || !message) return;
    bool is_send = (flags & PURPLE_MESSAGE_SEND) != 0;
    bool is_recv = (flags & PURPLE_MESSAGE_RECV) != 0;
    bool is_notice = (flags & (PURPLE_MESSAGE_SYSTEM | PURPLE_MESSAGE_ERROR)) && !is_send && !is_recv;
    if (!is_send && !is_recv && !is_notice) return;
    const char *room_name = purple_conversation_get_name(conv);
    if (!room_name) return;
    bool is_system = (flags & (PURPLE_MESSAGE_SYSTEM | PURPLE_MESSAGE_ERROR)) != 0;
    g_chat_message_cb(room_name, who ? who : "", message, is_send, is_system, (long long)mtime);
}

/* Conversation ui op for direct purple_conversation_write calls, which
 * bypass write_im and write_chat: prpl notices, error presentation
 * (purple_conv_present_error), inline image writes, and echoes of
 * messages sent from another device. */
static void adium_write_conv(PurpleConversation *conv, const char *name, const char *alias, const char *message, PurpleMessageFlags flags, time_t mtime) {
    (void)alias;
    if (!conv) return;
    if (purple_conversation_get_type(conv) == PURPLE_CONV_TYPE_CHAT) {
        adium_write_chat(conv, name, message, flags, mtime);
    } else {
        adium_write_im(conv, name, message, flags, mtime);
    }
}

/* libpurple does not echo own chat sends locally. The server echo can lag,
 * so this signal shows the message at send time. The Swift layer
 * deduplicates the later echo from adium_write_chat. */
static void cb_sent_chat_msg(PurpleAccount *account, const char *message, int id, void *data) {
    (void)data;
    if (!account || !message) return;
    PurpleConnection *gc = purple_account_get_connection(account);
    PurpleConversation *conv = gc ? purple_find_chat(gc, id) : NULL;
    const char *room_name = conv ? purple_conversation_get_name(conv) : NULL;
    const char *username = purple_account_get_username(account);
    if (g_chat_message_cb && room_name) {
        g_chat_message_cb(room_name, username ? username : "", message, true, false, 0);
    }
}

/* --- DNS resolution ui ops ----------------------------------------------
 * The default libpurple resolver forks a child process for getaddrinfo.
 * On macOS the forked child of this multi-threaded process aborts inside
 * getaddrinfo ("os_once_t is corrupt"). These ops resolve on a thread.
 * resolve_host, dns_deliver, and dns_destroy run on the purple thread.
 * The worker thread only touches its own copies. */

static GHashTable *g_live_dns = NULL;   /* PurpleDnsQueryData* -> sequence */
static gsize g_dns_seq = 0;

typedef struct {
    PurpleDnsQueryData *query;
    gsize seq;
    char *hostname;
    int port;
    PurpleDnsQueryResolvedCallback resolved_cb;
    PurpleDnsQueryFailedCallback failed_cb;
    GSList *hosts;   /* pairs of addrlen and heap sockaddr, dnsquery format */
    char *error;
} DnsRequest;

static void dns_request_free(DnsRequest *req) {
    GSList *l = req->hosts;
    while (l) {
        l = g_slist_delete_link(l, l);   /* addrlen entry */
        if (l) {
            g_free(l->data);             /* sockaddr copy */
            l = g_slist_delete_link(l, l);
        }
    }
    g_free(req->hostname);
    g_free(req->error);
    g_free(req);
}

/* This runs on the purple thread. The sequence check drops a late result
 * when the query died, or when a new query reuses the same address. */
static gboolean dns_deliver(gpointer user_data) {
    DnsRequest *req = (DnsRequest *)user_data;
    gpointer stored = g_live_dns ? g_hash_table_lookup(g_live_dns, req->query) : NULL;
    if (stored && GPOINTER_TO_SIZE(stored) == req->seq) {
        g_hash_table_remove(g_live_dns, req->query);
        if (req->error) {
            req->failed_cb(req->query, req->error);
        } else {
            /* The resolved callback takes ownership of the hosts list. */
            GSList *hosts = req->hosts;
            req->hosts = NULL;
            req->resolved_cb(req->query, hosts);
        }
    }
    dns_request_free(req);
    return G_SOURCE_REMOVE;
}

static gpointer dns_worker(gpointer user_data) {
    DnsRequest *req = (DnsRequest *)user_data;
    struct addrinfo hints;
    struct addrinfo *res = NULL;
    char service[16];

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_ADDRCONFIG;
    snprintf(service, sizeof(service), "%d", req->port);

    int rc = getaddrinfo(req->hostname, service, &hints, &res);
    if (rc == 0) {
        for (struct addrinfo *ai = res; ai != NULL; ai = ai->ai_next) {
            req->hosts = g_slist_append(req->hosts, GINT_TO_POINTER(ai->ai_addrlen));
            req->hosts = g_slist_append(req->hosts, g_memdup2(ai->ai_addr, ai->ai_addrlen));
        }
        freeaddrinfo(res);
        if (!req->hosts) {
            req->error = g_strdup_printf("No addresses found for %s", req->hostname);
        }
    } else {
        req->error = g_strdup_printf("Could not resolve %s: %s", req->hostname, gai_strerror(rc));
    }

    g_idle_add(dns_deliver, req);
    return NULL;
}

static gboolean adium_dns_resolve_host(PurpleDnsQueryData *query_data,
                                       PurpleDnsQueryResolvedCallback resolved_cb,
                                       PurpleDnsQueryFailedCallback failed_cb) {
    if (!g_live_dns) {
        g_live_dns = g_hash_table_new(g_direct_hash, g_direct_equal);
    }
    DnsRequest *req = g_new0(DnsRequest, 1);
    req->query = query_data;
    req->seq = ++g_dns_seq;
    req->hostname = g_strdup(purple_dnsquery_get_host(query_data));
    req->port = purple_dnsquery_get_port(query_data);
    req->resolved_cb = resolved_cb;
    req->failed_cb = failed_cb;
    g_hash_table_insert(g_live_dns, query_data, GSIZE_TO_POINTER(req->seq));

    GThread *thread = g_thread_try_new("adium-dns", dns_worker, req, NULL);
    if (!thread) {
        /* FALSE hands the query back to the core resolver. */
        g_hash_table_remove(g_live_dns, query_data);
        dns_request_free(req);
        return FALSE;
    }
    g_thread_unref(thread);
    return TRUE;
}

/* libpurple frees the query after this call. A worker still in flight
 * finds the entry gone and only frees its own data. */
static void adium_dns_destroy(PurpleDnsQueryData *query_data) {
    if (g_live_dns) {
        g_hash_table_remove(g_live_dns, query_data);
    }
}

static PurpleDnsQueryUiOps dnsquery_ui_ops = {
    .resolve_host = adium_dns_resolve_host,
    .destroy = adium_dns_destroy,
    ._purple_reserved1 = NULL,
    ._purple_reserved2 = NULL,
    ._purple_reserved3 = NULL,
    ._purple_reserved4 = NULL
};

static PurpleConversationUiOps conversation_ui_ops = {
    .create_conversation = NULL,
    .destroy_conversation = NULL,
    .write_chat = adium_write_chat,
    .write_im = adium_write_im,
    .write_conv = adium_write_conv,
    .chat_add_users = NULL,
    .chat_rename_user = NULL,
    .chat_remove_users = NULL,
    .chat_update_user = NULL,
    .present = NULL,
    .has_focus = NULL,
    .custom_smiley_add = NULL,
    .custom_smiley_write = NULL,
    .custom_smiley_close = NULL,
    .send_confirm = NULL,
    ._purple_reserved1 = NULL,
    ._purple_reserved2 = NULL,
    ._purple_reserved3 = NULL,
    ._purple_reserved4 = NULL
};

/* --- GLib Main Loop Thread --- */

static void* event_loop_thread(void* arg) {
    (void)arg;
    g_loop = g_main_loop_new(NULL, FALSE);
    g_main_loop_run(g_loop);
    return NULL;
}

void adium_purple_start_event_loop(void) {
    if (g_loop) return;
    pthread_t thread;
    int rc = pthread_create(&thread, NULL, event_loop_thread, NULL);
    if (rc != 0) {
        update_status("Could not create the event loop thread: %d", rc);
        fprintf(stderr, "[CLibpurple] pthread_create failed: %d\n", rc);
        return;
    }
    pthread_detach(thread);
}

/* --- Public API --- */

bool adium_purple_init(const char* custom_plugin_dir, const char* user_dir) {
    if (g_initialized) return true;

    if (user_dir && user_dir[0] != '\0') {
        purple_util_set_user_dir(user_dir);
    }

    purple_eventloop_set_ui_ops(&eventloop_ops);
    purple_debug_set_ui_ops(&debug_ui_ops);
    purple_core_set_ui_ops(&core_ui_ops);
    purple_notify_set_ui_ops(&notify_ui_ops);
    purple_conversations_set_ui_ops(&conversation_ui_ops);
    purple_dnsquery_set_ui_ops(&dnsquery_ui_ops);
    purple_request_set_ui_ops(&request_ui_ops);
    purple_connections_set_ui_ops(&connection_ui_ops);
    purple_xfers_set_ui_ops(&xfer_ui_ops);

    if (custom_plugin_dir && custom_plugin_dir[0] != '\0') {
        purple_plugins_add_search_path(custom_plugin_dir);
    }

    if (!purple_core_init("adium-swift")) {
        update_status("Could not initialize purple_core");
        return false;
    }

    purple_set_blist(purple_blist_new());
    purple_blist_load();

    void *conv_handle = purple_conversations_get_handle();
    /* Message delivery lives in conversation_ui_ops. write_im and write_chat
     * cover serv_got_im / serv_got_chat_in and the local send echo.
     * write_conv covers direct purple_conversation_write calls: prpl
     * notices, error presentation, and multi-device echoes. All three
     * carry the real mtime, which no conversation signal does. */
    purple_signal_connect(conv_handle, "buddy-typing", &adium_signal_handle, PURPLE_CALLBACK(cb_buddy_typing), NULL);
    purple_signal_connect(conv_handle, "buddy-typing-stopped", &adium_signal_handle, PURPLE_CALLBACK(cb_buddy_typing_stopped), NULL);
    purple_signal_connect(conv_handle, "chat-joined", &adium_signal_handle, PURPLE_CALLBACK(cb_chat_joined), NULL);
    purple_signal_connect(conv_handle, "chat-left", &adium_signal_handle, PURPLE_CALLBACK(cb_chat_left), NULL);
    purple_signal_connect(conv_handle, "chat-buddy-joined", &adium_signal_handle, PURPLE_CALLBACK(cb_chat_buddy_joined), NULL);
    purple_signal_connect(conv_handle, "chat-buddy-left", &adium_signal_handle, PURPLE_CALLBACK(cb_chat_buddy_left), NULL);
    purple_signal_connect(conv_handle, "sent-chat-msg", &adium_signal_handle, PURPLE_CALLBACK(cb_sent_chat_msg), NULL);

    void *blist_handle = purple_blist_get_handle();
    purple_signal_connect(blist_handle, "buddy-signed-on", &adium_signal_handle, PURPLE_CALLBACK(cb_buddy_signed_on_off), NULL);
    purple_signal_connect(blist_handle, "buddy-signed-off", &adium_signal_handle, PURPLE_CALLBACK(cb_buddy_signed_on_off), NULL);
    purple_signal_connect(blist_handle, "buddy-status-changed", &adium_signal_handle, PURPLE_CALLBACK(cb_buddy_status_changed), NULL);
    purple_signal_connect(blist_handle, "buddy-removed", &adium_signal_handle, PURPLE_CALLBACK(cb_buddy_removed), NULL);
    purple_signal_connect(blist_handle, "blist-node-added", &adium_signal_handle, PURPLE_CALLBACK(cb_blist_node_added), NULL);
    purple_signal_connect(blist_handle, "blist-node-removed", &adium_signal_handle, PURPLE_CALLBACK(cb_blist_node_removed), NULL);
    purple_signal_connect(blist_handle, "blist-node-aliased", &adium_signal_handle, PURPLE_CALLBACK(cb_blist_node_aliased), NULL);

    void *accounts_handle = purple_accounts_get_handle();
    purple_signal_connect(accounts_handle, "account-signed-on", &adium_signal_handle, PURPLE_CALLBACK(cb_account_signed_on), NULL);
    purple_signal_connect(accounts_handle, "account-signed-off", &adium_signal_handle, PURPLE_CALLBACK(cb_account_signed_off), NULL);
    purple_signal_connect(accounts_handle, "account-connection-error", &adium_signal_handle, PURPLE_CALLBACK(cb_account_connection_error), NULL);

    update_status("Libpurple core ready");
    g_initialized = true;
    return true;
}

typedef struct {
    char *plugin_path;
} LoadPluginData;

static gboolean do_load_plugin(gpointer user_data) {
    LoadPluginData *data = (LoadPluginData *)user_data;
    if (!data || !data->plugin_path) return G_SOURCE_REMOVE;
    const char *plugin_path = data->plugin_path;

    PurplePlugin *plugin = purple_plugin_probe(plugin_path);
    if (!plugin) {
        purple_plugins_probe("so");
        gchar *basename = g_path_get_basename(plugin_path);
        plugin = purple_plugins_find_with_basename(basename);
        g_free(basename);
    }

    if (!plugin) {
        void* handle = dlopen(plugin_path, RTLD_NOW | RTLD_GLOBAL);
        if (handle) {
            update_status("Plugin loaded via dlopen: %s", plugin_path);
        } else {
            update_status("Could not load the plugin: %s", plugin_path);
        }
    } else if (purple_plugin_is_loaded(plugin)) {
        update_status("Plugin already active: %s", purple_plugin_get_name(plugin));
    } else if (purple_plugin_load(plugin)) {
        update_status("Plugin registered: %s (%s)", purple_plugin_get_name(plugin), purple_plugin_get_id(plugin));
    } else {
        update_status("Plugin load error: %s", purple_plugin_get_name(plugin));
    }

    g_free(data->plugin_path);
    g_free(data);
    return G_SOURCE_REMOVE;
}

bool adium_purple_load_plugin(const char* plugin_path) {
    if (!plugin_path) return false;
    LoadPluginData *data = g_new0(LoadPluginData, 1);
    data->plugin_path = g_strdup(plugin_path);
    g_idle_add(do_load_plugin, data);
    return true;
}

const char* adium_purple_get_status_info(void) {
    static _Thread_local char local_status[512];
    pthread_mutex_lock(&g_status_mutex);
    g_strlcpy(local_status, g_status_buffer, sizeof(local_status));
    pthread_mutex_unlock(&g_status_mutex);
    return local_status;
}

void adium_purple_set_event_callbacks(
    adium_purple_on_contact_cb contact_cb,
    adium_purple_on_message_cb message_cb,
    adium_purple_on_status_cb status_cb,
    adium_purple_on_account_state_cb account_state_cb
) {
    g_contact_cb = contact_cb;
    g_message_cb = message_cb;
    g_status_cb = status_cb;
    g_account_state_cb = account_state_cb;
}

void adium_purple_set_extended_event_callbacks(
    adium_purple_on_request_input_cb request_input_cb,
    adium_purple_on_request_action_cb request_action_cb,
    adium_purple_on_request_close_cb request_close_cb,
    adium_purple_on_connection_progress_cb connection_progress_cb,
    adium_purple_on_typing_cb typing_cb,
    adium_purple_on_buddy_removed_cb buddy_removed_cb,
    adium_purple_on_notify_message_cb notify_message_cb
) {
    g_request_input_cb = request_input_cb;
    g_request_action_cb = request_action_cb;
    g_request_close_cb = request_close_cb;
    g_connection_progress_cb = connection_progress_cb;
    g_typing_cb = typing_cb;
    g_buddy_removed_cb = buddy_removed_cb;
    g_notify_message_cb = notify_message_cb;
}

typedef struct {
    void *handle;
    char *input_text;
    bool ok;
} RequestInputRespondData;

/* This runs on the purple thread. It re-checks liveness here, not only at the
 * Swift call site. libpurple can close the handle after the respond call
 * starts and before this idle callback runs. */
static gboolean do_request_input_respond(gpointer user_data) {
    RequestInputRespondData *data = (RequestInputRespondData *)user_data;
    if (!data) return G_SOURCE_REMOVE;
    if (g_live_requests && g_hash_table_contains(g_live_requests, data->handle)) {
        AdiumRequestHandle *handle = (AdiumRequestHandle *)data->handle;
        if (data->ok && handle->ok_cb) {
            ((PurpleRequestInputCb)handle->ok_cb)(handle->user_data, data->input_text ? data->input_text : "");
        } else if (!data->ok && handle->cancel_cb) {
            ((PurpleRequestInputCb)handle->cancel_cb)(handle->user_data, NULL);
        }
        /* purple_request_close routes through adium_close_request, the single place
         * that removes the handle from the live set and frees it. */
        purple_request_close(handle->type, handle);
    }
    g_free(data->input_text);
    g_free(data);
    return G_SOURCE_REMOVE;
}

void adium_purple_request_input_respond(void* request_handle, const char* input_text, bool ok) {
    if (!request_handle) return;
    RequestInputRespondData *data = g_new0(RequestInputRespondData, 1);
    data->handle = request_handle;
    data->input_text = input_text ? g_strdup(input_text) : NULL;
    data->ok = ok;
    if (g_loop) {
        g_idle_add(do_request_input_respond, data);
    } else {
        do_request_input_respond(data);
    }
}

typedef struct {
    void *handle;
    int action_index;
} RequestActionRespondData;

static gboolean do_request_action_respond(gpointer user_data) {
    RequestActionRespondData *data = (RequestActionRespondData *)user_data;
    if (!data) return G_SOURCE_REMOVE;
    if (g_live_requests && g_hash_table_contains(g_live_requests, data->handle)) {
        AdiumRequestHandle *handle = (AdiumRequestHandle *)data->handle;
        if (data->action_index >= 0 && (size_t)data->action_index < handle->action_count && handle->action_cbs[data->action_index]) {
            ((PurpleRequestActionCb)handle->action_cbs[data->action_index])(handle->user_data, data->action_index);
        }
        purple_request_close(handle->type, handle);
    }
    g_free(data);
    return G_SOURCE_REMOVE;
}

void adium_purple_request_action_respond(void* request_handle, int action_index) {
    if (!request_handle) return;
    RequestActionRespondData *data = g_new0(RequestActionRespondData, 1);
    data->handle = request_handle;
    data->action_index = action_index;
    if (g_loop) {
        g_idle_add(do_request_action_respond, data);
    } else {
        do_request_action_respond(data);
    }
}

/* Thread-safe account addition */

typedef struct {
    char *username;
    char *protocol_id;
    char *password;
} AddAccountData;

static gboolean do_add_account(gpointer user_data) {
    AddAccountData *data = (AddAccountData *)user_data;
    PurpleAccount *account = purple_account_new(data->username, data->protocol_id);
    if (account) {
        if (data->password && data->password[0] != '\0') {
            purple_account_set_password(account, data->password);
        }
        purple_accounts_add(account);
        purple_account_set_enabled(account, "adium-swift", TRUE);
        update_status("Connecting %s (%s)...", data->username, data->protocol_id);
    } else {
        update_status("Could not create the account for %s", data->username);
    }
    g_free(data->username);
    g_free(data->protocol_id);
    g_free(data->password);
    g_free(data);
    return G_SOURCE_REMOVE;
}

bool adium_purple_add_account(const char* username, const char* protocol_id, const char* password) {
    if (!username || !protocol_id) return false;
    AddAccountData *data = g_new0(AddAccountData, 1);
    data->username = g_strdup(username);
    data->protocol_id = g_strdup(protocol_id);
    data->password = password ? g_strdup(password) : NULL;
    g_idle_add(do_add_account, data);
    return true;
}

/* Thread-safe account removal */

typedef struct {
    char *username;
    char *protocol_id;
} RemoveAccountData;

static gboolean do_remove_account(gpointer user_data) {
    RemoveAccountData *data = (RemoveAccountData *)user_data;
    if (!data) return G_SOURCE_REMOVE;

    PurpleAccount *account = purple_accounts_find(data->username, data->protocol_id);
    if (account) {
        /* purple_accounts_remove only unlinks the account: the object and
         * its settings (tokens, sync markers) survive and accounts.xml can
         * resurrect them. purple_accounts_delete tears down buddies, chats,
         * conversations, and destroys the account with its settings. */
        purple_accounts_delete(account);
        update_status("Account removed: %s (%s)", data->username, data->protocol_id);
    } else {
        update_status("Account to remove not found: %s (%s)", data->username, data->protocol_id);
    }

    g_free(data->username);
    g_free(data->protocol_id);
    g_free(data);
    return G_SOURCE_REMOVE;
}

bool adium_purple_remove_account(const char* username, const char* protocol_id) {
    if (!username || !protocol_id) return false;
    RemoveAccountData *data = g_new0(RemoveAccountData, 1);
    data->username = g_strdup(username);
    data->protocol_id = g_strdup(protocol_id);
    g_idle_add(do_remove_account, data);
    return true;
}

/* Thread-safe message sending */

typedef struct {
    char *account_username;
    char *protocol_id;
    char *recipient;
    char *message;
} SendMessageData;

static gboolean do_send_message(gpointer user_data) {
    SendMessageData *data = (SendMessageData *)user_data;
    if (!data) return G_SOURCE_REMOVE;

    PurpleAccount *account = NULL;
    if (data->account_username && data->protocol_id && data->account_username[0] != '\0' && data->protocol_id[0] != '\0') {
        account = purple_accounts_find(data->account_username, data->protocol_id);
    }
    if (!account && data->protocol_id && data->protocol_id[0] != '\0') {
        for (GList *l = purple_accounts_get_all(); l != NULL; l = l->next) {
            PurpleAccount *acc = (PurpleAccount *)l->data;
            if (acc && purple_account_get_protocol_id(acc) && strcmp(purple_account_get_protocol_id(acc), data->protocol_id) == 0) {
                account = acc;
                break;
            }
        }
    }
    if (!account) {
        GList *accs = purple_accounts_get_all();
        account = accs ? (PurpleAccount *)accs->data : NULL;
    }

    if (account) {
        PurpleConversation *conv = purple_find_conversation_with_account(PURPLE_CONV_TYPE_IM, data->recipient, account);
        if (!conv) {
            conv = purple_conversation_new(PURPLE_CONV_TYPE_IM, account, data->recipient);
        }
        if (conv) {
            purple_conv_im_send(PURPLE_CONV_IM(conv), data->message);
            update_status("Message sent to %s", data->recipient);
        } else {
            update_status("Could not create the conversation with %s", data->recipient);
        }
    } else {
        update_status("No active accounts to send to %s", data->recipient);
    }

    g_free(data->account_username);
    g_free(data->protocol_id);
    g_free(data->recipient);
    g_free(data->message);
    g_free(data);
    return G_SOURCE_REMOVE;
}

bool adium_purple_send_message(const char* account_username, const char* protocol_id, const char* recipient_handle, const char* message_text) {
    if (!recipient_handle || !message_text) return false;
    SendMessageData *data = g_new0(SendMessageData, 1);
    data->account_username = account_username ? g_strdup(account_username) : NULL;
    data->protocol_id = protocol_id ? g_strdup(protocol_id) : NULL;
    data->recipient = g_strdup(recipient_handle);
    data->message = g_strdup(message_text);
    g_idle_add(do_send_message, data);
    return true;
}

/* Thread-safe command execution (e.g. purple-teams' /call) */

typedef struct {
    char *account_username;
    char *protocol_id;
    char *conversation_name;
    char *command;
    bool is_chat;
} ExecCommandData;

static PurpleAccount *find_account_for(const char *account_username, const char *protocol_id) {
    PurpleAccount *account = NULL;
    if (account_username && protocol_id && account_username[0] != '\0' && protocol_id[0] != '\0') {
        account = purple_accounts_find(account_username, protocol_id);
    }
    if (!account && protocol_id && protocol_id[0] != '\0') {
        for (GList *l = purple_accounts_get_all(); l != NULL; l = l->next) {
            PurpleAccount *acc = (PurpleAccount *)l->data;
            if (acc && purple_account_get_protocol_id(acc) && strcmp(purple_account_get_protocol_id(acc), protocol_id) == 0) {
                account = acc;
                break;
            }
        }
    }
    return account;
}

static gboolean do_exec_command(gpointer user_data) {
    ExecCommandData *data = (ExecCommandData *)user_data;
    if (!data) return G_SOURCE_REMOVE;

    PurpleAccount *account = find_account_for(data->account_username, data->protocol_id);
    if (account) {
        PurpleConversationType type = data->is_chat ? PURPLE_CONV_TYPE_CHAT : PURPLE_CONV_TYPE_IM;
        PurpleConversation *conv = purple_find_conversation_with_account(type, data->conversation_name, account);
        if (!conv && !data->is_chat) {
            conv = purple_conversation_new(PURPLE_CONV_TYPE_IM, account, data->conversation_name);
        }
        if (conv) {
            gchar *error = NULL;
            PurpleCmdStatus status = purple_cmd_do_command(conv, data->command, data->command, &error);
            if (status != PURPLE_CMD_STATUS_OK) {
                update_status("Command /%s failed in %s (%d)", data->command, data->conversation_name, (int)status);
            }
            g_free(error);
        } else {
            update_status("No conversation %s for the command /%s", data->conversation_name, data->command);
        }
    } else {
        update_status("No active account for the command /%s", data->command);
    }

    g_free(data->account_username);
    g_free(data->protocol_id);
    g_free(data->conversation_name);
    g_free(data->command);
    g_free(data);
    return G_SOURCE_REMOVE;
}

bool adium_purple_exec_command(const char* account_username, const char* protocol_id, const char* conversation_name, const char* command, bool is_chat) {
    if (!conversation_name || !command) return false;
    ExecCommandData *data = g_new0(ExecCommandData, 1);
    data->account_username = account_username ? g_strdup(account_username) : NULL;
    data->protocol_id = protocol_id ? g_strdup(protocol_id) : NULL;
    data->conversation_name = g_strdup(conversation_name);
    data->command = g_strdup(command);
    data->is_chat = is_chat;
    g_idle_add(do_exec_command, data);
    return true;
}

static gboolean do_load_accounts(gpointer user_data) {
    (void)user_data;
    for (GList *l = purple_accounts_get_all(); l != NULL; l = l->next) {
        PurpleAccount *account = (PurpleAccount *)l->data;
        if (!account) continue;
        const char *username = purple_account_get_username(account);
        const char *proto_id = purple_account_get_protocol_id(account);
        gboolean is_connected = purple_account_is_connected(account);

        if (g_account_state_cb) {
            g_account_state_cb(username, proto_id, is_connected, is_connected ? "Connected" : "Disconnected");
        }
    }

    GSList *buddies = purple_blist_get_buddies();
    for (GSList *l = buddies; l != NULL; l = l->next) {
        PurpleBuddy *buddy = (PurpleBuddy *)l->data;
        if (buddy) {
            cb_buddy_signed_on_off(buddy, NULL);
        }
    }
    g_slist_free(buddies);

    /* Chat nodes persisted in blist.xml predate the signal connections.
     * This walk surfaces them once at startup. */
    for (PurpleBlistNode *node = purple_blist_get_root(); node != NULL; node = purple_blist_node_next(node, TRUE)) {
        if (PURPLE_BLIST_NODE_IS_CHAT(node)) {
            emit_chat_listed((PurpleChat *)node);
        }
    }

    update_status("Accounts and contacts loaded");
    return G_SOURCE_REMOVE;
}

void adium_purple_load_accounts(void) {
    if (!g_initialized) return;
    if (g_loop) {
        g_idle_add(do_load_accounts, NULL);
    } else {
        do_load_accounts(NULL);
    }
}

static gboolean do_uninit(gpointer user_data) {
    (void)user_data;
    if (!g_initialized) return G_SOURCE_REMOVE;
    purple_core_quit();
    if (g_loop) {
        g_main_loop_quit(g_loop);
        g_loop = NULL;
    }
    g_initialized = false;
    update_status("Libpurple stopped");
    return G_SOURCE_REMOVE;
}

void adium_purple_uninit(void) {
    if (!g_initialized) return;
    if (g_loop) {
        g_idle_add(do_uninit, NULL);
    } else {
        do_uninit(NULL);
    }
}

typedef struct {
    char *status_id;
    char *message;
} SetStatusData;

static gboolean do_set_user_status(gpointer user_data) {
    SetStatusData *data = (SetStatusData *)user_data;
    if (!data || !data->status_id) return G_SOURCE_REMOVE;

    PurpleStatusPrimitive type = PURPLE_STATUS_AVAILABLE;
    if (strcmp(data->status_id, "away") == 0) {
        type = PURPLE_STATUS_AWAY;
    } else if (strcmp(data->status_id, "busy") == 0 || strcmp(data->status_id, "dnd") == 0) {
        type = PURPLE_STATUS_UNAVAILABLE;
    } else if (strcmp(data->status_id, "offline") == 0) {
        type = PURPLE_STATUS_OFFLINE;
    } else {
        type = PURPLE_STATUS_AVAILABLE;
    }

    PurpleSavedStatus *status = purple_savedstatus_new(NULL, type);
    if (status) {
        if (data->message && data->message[0] != '\0') {
            purple_savedstatus_set_message(status, data->message);
        }
        purple_savedstatus_activate(status);
        update_status("Status updated: %s", data->status_id);
    }

    g_free(data->status_id);
    g_free(data->message);
    g_free(data);
    return G_SOURCE_REMOVE;
}

bool adium_purple_set_user_status(const char* status_id, const char* message) {
    if (!status_id) return false;
    SetStatusData *data = g_new0(SetStatusData, 1);
    data->status_id = g_strdup(status_id);
    data->message = (message && message[0] != '\0') ? g_strdup(message) : NULL;
    if (g_loop) {
        g_idle_add(do_set_user_status, data);
    } else {
        do_set_user_status(data);
    }
    return true;
}

typedef struct {
    char *username;
    char *protocol_id;
    char *key;
    char *value;
    int int_value;
    bool is_int;
    bool is_bool;
    bool bool_value;
    bool seed_if_missing;
} SetAccountOptionData;

/* libpurple has no "has setting" query. Two distinct fallbacks detect
 * the absent key: a stored value returns itself for both. */
static bool account_int_option_absent(PurpleAccount *account, const char *key) {
    return purple_account_get_int(account, key, G_MININT) == G_MININT
        && purple_account_get_int(account, key, G_MININT + 1) == G_MININT + 1;
}

static gboolean do_set_account_option(gpointer user_data) {
    SetAccountOptionData *data = (SetAccountOptionData *)user_data;
    if (!data || !data->username || !data->protocol_id || !data->key) return G_SOURCE_REMOVE;

    PurpleAccount *account = purple_accounts_find(data->username, data->protocol_id);
    if (account) {
        if (data->is_int) {
            if (!data->seed_if_missing || account_int_option_absent(account, data->key)) {
                purple_account_set_int(account, data->key, data->int_value);
            }
        } else if (data->is_bool) {
            purple_account_set_bool(account, data->key, data->bool_value);
        } else {
            purple_account_set_string(account, data->key, data->value);
        }
        update_status("Account option updated: %s [%s]", data->username, data->key);
    }

    g_free(data->username);
    g_free(data->protocol_id);
    g_free(data->key);
    g_free(data->value);
    g_free(data);
    return G_SOURCE_REMOVE;
}

bool adium_purple_set_account_option(const char* username, const char* protocol_id, const char* key, const char* value) {
    if (!username || !protocol_id || !key) return false;
    SetAccountOptionData *data = g_new0(SetAccountOptionData, 1);
    data->username = g_strdup(username);
    data->protocol_id = g_strdup(protocol_id);
    data->key = g_strdup(key);
    data->value = value ? g_strdup(value) : NULL;
    data->is_int = false;
    if (g_loop) {
        g_idle_add(do_set_account_option, data);
    } else {
        do_set_account_option(data);
    }
    return true;
}

bool adium_purple_set_account_int_option(const char* username, const char* protocol_id, const char* key, int value) {
    if (!username || !protocol_id || !key) return false;
    SetAccountOptionData *data = g_new0(SetAccountOptionData, 1);
    data->username = g_strdup(username);
    data->protocol_id = g_strdup(protocol_id);
    data->key = g_strdup(key);
    data->int_value = value;
    data->is_int = true;
    if (g_loop) {
        g_idle_add(do_set_account_option, data);
    } else {
        do_set_account_option(data);
    }
    return true;
}

bool adium_purple_seed_account_int_option(const char* username, const char* protocol_id, const char* key, int value) {
    if (!username || !protocol_id || !key) return false;
    SetAccountOptionData *data = g_new0(SetAccountOptionData, 1);
    data->username = g_strdup(username);
    data->protocol_id = g_strdup(protocol_id);
    data->key = g_strdup(key);
    data->int_value = value;
    data->is_int = true;
    data->seed_if_missing = true;
    /* Always schedule on the default main context. A direct call would
     * run libpurple on the caller thread during startup. */
    g_idle_add(do_set_account_option, data);
    return true;
}

bool adium_purple_set_account_bool_option(const char* username, const char* protocol_id, const char* key, bool value) {
    if (!username || !protocol_id || !key) return false;
    SetAccountOptionData *data = g_new0(SetAccountOptionData, 1);
    data->username = g_strdup(username);
    data->protocol_id = g_strdup(protocol_id);
    data->key = g_strdup(key);
    data->bool_value = value;
    data->is_bool = true;
    if (g_loop) {
        g_idle_add(do_set_account_option, data);
    } else {
        do_set_account_option(data);
    }
    return true;
}

/* Thread-safe protocol-level privacy (block/unblock) */

typedef struct {
    char *username;
    char *protocol_id;
    char *who;
} PrivacyData;

static gboolean do_block_contact(gpointer user_data) {
    PrivacyData *data = (PrivacyData *)user_data;
    if (!data || !data->username || !data->protocol_id || !data->who) return G_SOURCE_REMOVE;

    PurpleAccount *account = purple_accounts_find(data->username, data->protocol_id);
    if (account) {
        if (purple_account_get_privacy_type(account) == PURPLE_PRIVACY_ALLOW_ALL) {
            purple_account_set_privacy_type(account, PURPLE_PRIVACY_DENY_USERS);
        }
        purple_privacy_deny_add(account, data->who, FALSE);
        update_status("Contact blocked: %s", data->who);
    }

    g_free(data->username);
    g_free(data->protocol_id);
    g_free(data->who);
    g_free(data);
    return G_SOURCE_REMOVE;
}

bool adium_purple_block_contact(const char* username, const char* protocol_id, const char* who) {
    if (!username || !protocol_id || !who) return false;
    PrivacyData *data = g_new0(PrivacyData, 1);
    data->username = g_strdup(username);
    data->protocol_id = g_strdup(protocol_id);
    data->who = g_strdup(who);
    if (g_loop) {
        g_idle_add(do_block_contact, data);
    } else {
        do_block_contact(data);
    }
    return true;
}

static gboolean do_unblock_contact(gpointer user_data) {
    PrivacyData *data = (PrivacyData *)user_data;
    if (!data || !data->username || !data->protocol_id || !data->who) return G_SOURCE_REMOVE;

    PurpleAccount *account = purple_accounts_find(data->username, data->protocol_id);
    if (account) {
        purple_privacy_deny_remove(account, data->who, FALSE);
        update_status("Contact unblocked: %s", data->who);
    }

    g_free(data->username);
    g_free(data->protocol_id);
    g_free(data->who);
    g_free(data);
    return G_SOURCE_REMOVE;
}

bool adium_purple_unblock_contact(const char* username, const char* protocol_id, const char* who) {
    if (!username || !protocol_id || !who) return false;
    PrivacyData *data = g_new0(PrivacyData, 1);
    data->username = g_strdup(username);
    data->protocol_id = g_strdup(protocol_id);
    data->who = g_strdup(who);
    if (g_loop) {
        g_idle_add(do_unblock_contact, data);
    } else {
        do_unblock_contact(data);
    }
    return true;
}

void adium_purple_set_xfer_callbacks(
    adium_purple_on_xfer_new_cb xfer_new_cb,
    adium_purple_on_xfer_update_cb xfer_update_cb,
    adium_purple_on_xfer_cancel_cb xfer_cancel_cb,
    adium_purple_on_xfer_destroyed_cb xfer_destroyed_cb
) {
    g_xfer_new_cb = xfer_new_cb;
    g_xfer_update_cb = xfer_update_cb;
    g_xfer_cancel_cb = xfer_cancel_cb;
    g_xfer_destroyed_cb = xfer_destroyed_cb;
}

typedef struct {
    void *xfer_handle;
    char *local_path;
} XferAcceptData;

static gboolean do_xfer_accept(gpointer user_data) {
    XferAcceptData *data = (XferAcceptData *)user_data;
    if (!data || !data->xfer_handle) return G_SOURCE_REMOVE;
    /* The handle crossed from Swift; libpurple may have already destroyed it. */
    if (!g_live_xfers || !g_hash_table_contains(g_live_xfers, data->xfer_handle)) {
        g_free(data->local_path);
        g_free(data);
        return G_SOURCE_REMOVE;
    }
    PurpleXfer *xfer = (PurpleXfer *)data->xfer_handle;
    if (data->local_path && data->local_path[0] != '\0') {
        purple_xfer_request_accepted(xfer, data->local_path);
    } else {
        purple_xfer_request_accepted(xfer, NULL);
    }
    g_free(data->local_path);
    g_free(data);
    return G_SOURCE_REMOVE;
}

bool adium_purple_xfer_accept(void* xfer_handle, const char* local_path) {
    if (!xfer_handle) return false;
    XferAcceptData *data = g_new0(XferAcceptData, 1);
    data->xfer_handle = xfer_handle;
    data->local_path = local_path ? g_strdup(local_path) : NULL;
    if (g_loop) {
        g_idle_add(do_xfer_accept, data);
    } else {
        do_xfer_accept(data);
    }
    return true;
}

typedef struct {
    void *xfer_handle;
} XferCancelData;

static gboolean do_xfer_cancel(gpointer user_data) {
    XferCancelData *data = (XferCancelData *)user_data;
    if (!data || !data->xfer_handle) return G_SOURCE_REMOVE;
    if (!g_live_xfers || !g_hash_table_contains(g_live_xfers, data->xfer_handle)) {
        g_free(data);
        return G_SOURCE_REMOVE;
    }
    PurpleXfer *xfer = (PurpleXfer *)data->xfer_handle;
    purple_xfer_cancel_local(xfer);
    g_free(data);
    return G_SOURCE_REMOVE;
}

bool adium_purple_xfer_cancel(void* xfer_handle) {
    if (!xfer_handle) return false;
    XferCancelData *data = g_new0(XferCancelData, 1);
    data->xfer_handle = xfer_handle;
    if (g_loop) {
        g_idle_add(do_xfer_cancel, data);
    } else {
        do_xfer_cancel(data);
    }
    return true;
}

typedef struct {
    char *account_username;
    char *protocol_id;
    char *who;
    char *filepath;
} SendFileData;

static gboolean do_send_file(gpointer user_data) {
    SendFileData *data = (SendFileData *)user_data;
    if (!data || !data->who || !data->filepath) return G_SOURCE_REMOVE;
    PurpleAccount *account = NULL;
    if (data->account_username && data->protocol_id && data->account_username[0] != '\0' && data->protocol_id[0] != '\0') {
        account = purple_accounts_find(data->account_username, data->protocol_id);
    }
    if (!account) {
        /* Do not fall back to an arbitrary account: sending a file from the wrong
         * account is worse than not sending it at all. */
        update_status("Could not send file: account %s not found", data->account_username ? data->account_username : "?");
        g_free(data->account_username);
        g_free(data->protocol_id);
        g_free(data->who);
        g_free(data->filepath);
        g_free(data);
        return G_SOURCE_REMOVE;
    }
    if (purple_account_get_connection(account)) {
        serv_send_file(purple_account_get_connection(account), data->who, data->filepath);
    }
    g_free(data->account_username);
    g_free(data->protocol_id);
    g_free(data->who);
    g_free(data->filepath);
    g_free(data);
    return G_SOURCE_REMOVE;
}

bool adium_purple_send_file(const char* account_username, const char* protocol_id, const char* who, const char* filepath) {
    if (!who || !filepath) return false;
    SendFileData *data = g_new0(SendFileData, 1);
    data->account_username = account_username ? g_strdup(account_username) : NULL;
    data->protocol_id = protocol_id ? g_strdup(protocol_id) : NULL;
    data->who = g_strdup(who);
    data->filepath = g_strdup(filepath);
    if (g_loop) {
        g_idle_add(do_send_file, data);
    } else {
        do_send_file(data);
    }
    return true;
}

void adium_purple_set_chat_callbacks(
    adium_purple_on_chat_joined_cb chat_joined_cb,
    adium_purple_on_chat_left_cb chat_left_cb,
    adium_purple_on_chat_message_cb chat_message_cb,
    adium_purple_on_chat_buddy_joined_cb chat_buddy_joined_cb,
    adium_purple_on_chat_buddy_left_cb chat_buddy_left_cb,
    adium_purple_on_chat_listed_cb chat_listed_cb,
    adium_purple_on_chat_unlisted_cb chat_unlisted_cb
) {
    g_chat_joined_cb = chat_joined_cb;
    g_chat_left_cb = chat_left_cb;
    g_chat_message_cb = chat_message_cb;
    g_chat_buddy_joined_cb = chat_buddy_joined_cb;
    g_chat_buddy_left_cb = chat_buddy_left_cb;
    g_chat_listed_cb = chat_listed_cb;
    g_chat_unlisted_cb = chat_unlisted_cb;
}

/* Thread-safe group chat (MUC) join */

typedef struct {
    char *username;
    char *protocol_id;
    char *room_name;
} JoinChatData;

static gboolean do_join_chat(gpointer user_data) {
    JoinChatData *data = (JoinChatData *)user_data;
    if (!data || !data->username || !data->protocol_id || !data->room_name) return G_SOURCE_REMOVE;

    PurpleAccount *account = purple_accounts_find(data->username, data->protocol_id);
    PurpleConnection *gc = account ? purple_account_get_connection(account) : NULL;
    if (gc) {
        PurplePlugin *prpl = purple_connection_get_prpl(gc);
        PurplePluginProtocolInfo *prpl_info = prpl ? PURPLE_PLUGIN_PROTOCOL_INFO(prpl) : NULL;
        GHashTable *components = NULL;
        if (prpl_info && prpl_info->chat_info_defaults) {
            components = prpl_info->chat_info_defaults(gc, data->room_name);
        }
        if (!components) {
            /* Fallback for protocols without chat_info_defaults: most prpls key their
             * default chat-name component "room". */
            components = g_hash_table_new_full(g_str_hash, g_str_equal, NULL, g_free);
            g_hash_table_replace(components, "room", g_strdup(data->room_name));
        }
        serv_join_chat(gc, components);
        g_hash_table_destroy(components);
        update_status("Joining the group %s", data->room_name);
    } else {
        update_status("Could not join the group %s: account not connected", data->room_name);
    }

    g_free(data->username);
    g_free(data->protocol_id);
    g_free(data->room_name);
    g_free(data);
    return G_SOURCE_REMOVE;
}

bool adium_purple_join_chat(const char* username, const char* protocol_id, const char* room_name) {
    if (!username || !protocol_id || !room_name) return false;
    JoinChatData *data = g_new0(JoinChatData, 1);
    data->username = g_strdup(username);
    data->protocol_id = g_strdup(protocol_id);
    data->room_name = g_strdup(room_name);
    /* Always schedule on the default main context. g_idle_add queues the
     * callback correctly even before the loop spins. A direct call here
     * would run serv_join_chat on the caller thread. */
    g_idle_add(do_join_chat, data);
    return true;
}

typedef struct {
    char *account_username;
    char *protocol_id;
    char *room_name;
    char *message;
} SendChatMessageData;

static gboolean do_send_chat_message(gpointer user_data) {
    SendChatMessageData *data = (SendChatMessageData *)user_data;
    if (!data || !data->room_name || !data->message) return G_SOURCE_REMOVE;

    PurpleAccount *account = NULL;
    if (data->account_username && data->protocol_id && data->account_username[0] != '\0' && data->protocol_id[0] != '\0') {
        account = purple_accounts_find(data->account_username, data->protocol_id);
    }
    if (account) {
        PurpleConversation *conv = purple_find_conversation_with_account(PURPLE_CONV_TYPE_CHAT, data->room_name, account);
        if (conv) {
            purple_conv_chat_send(PURPLE_CONV_CHAT(conv), data->message);
            update_status("Group message sent to %s", data->room_name);
        } else {
            update_status("Group conversation %s not found", data->room_name);
        }
    }

    g_free(data->account_username);
    g_free(data->protocol_id);
    g_free(data->room_name);
    g_free(data->message);
    g_free(data);
    return G_SOURCE_REMOVE;
}

bool adium_purple_send_chat_message(const char* account_username, const char* protocol_id, const char* room_name, const char* message_text) {
    if (!room_name || !message_text) return false;
    SendChatMessageData *data = g_new0(SendChatMessageData, 1);
    data->account_username = account_username ? g_strdup(account_username) : NULL;
    data->protocol_id = protocol_id ? g_strdup(protocol_id) : NULL;
    data->room_name = g_strdup(room_name);
    data->message = g_strdup(message_text);
    if (g_loop) {
        g_idle_add(do_send_chat_message, data);
    } else {
        do_send_chat_message(data);
    }
    return true;
}



