#include "CLibpurple.h"
#include <purple.h>
#include <glib.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

static bool g_initialized = false;
static pthread_mutex_t g_status_mutex = PTHREAD_MUTEX_INITIALIZER;
static char g_status_buffer[512] = "Libpurple Idle";
static GMainLoop *g_loop = NULL;
static int adium_signal_handle = 0;

static adium_purple_on_contact_cb g_contact_cb = NULL;
static adium_purple_on_message_cb g_message_cb = NULL;
static adium_purple_on_status_cb g_status_cb = NULL;
static adium_purple_on_account_state_cb g_account_state_cb = NULL;

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

static PurpleNotifyUiOps notify_ui_ops = {
    .notify_message = NULL,
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

static void cb_received_im_msg(PurpleAccount *account, char *sender, char *message, PurpleConversation *conv, PurpleMessageFlags flags, void *data) {
    (void)account; (void)conv; (void)flags; (void)data;
    if (g_message_cb && sender && message) {
        g_message_cb(sender, message, false);
    }
}

static void cb_sent_im_msg(PurpleAccount *account, const char *receiver, const char *message, void *data) {
    (void)account; (void)data;
    if (g_message_cb && receiver && message) {
        g_message_cb(receiver, message, true);
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

static void cb_account_signed_on(PurpleAccount *account, void *data) {
    (void)data;
    if (!account) return;
    const char *username = purple_account_get_username(account);
    const char *proto_id = purple_account_get_protocol_id(account);
    update_status("Cuenta conectada: %s (%s)", username, proto_id);
    if (g_account_state_cb) {
        g_account_state_cb(username, proto_id, true, "Conectado");
    }
}

static void cb_account_signed_off(PurpleAccount *account, void *data) {
    (void)data;
    if (!account) return;
    const char *username = purple_account_get_username(account);
    const char *proto_id = purple_account_get_protocol_id(account);
    update_status("Cuenta desconectada: %s (%s)", username, proto_id);
    if (g_account_state_cb) {
        g_account_state_cb(username, proto_id, false, "Desconectado");
    }
}

static void cb_account_connection_error(PurpleAccount *account, PurpleConnectionError err, const char *desc, void *data) {
    (void)err; (void)data;
    if (!account) return;
    const char *username = purple_account_get_username(account);
    const char *proto_id = purple_account_get_protocol_id(account);
    update_status("Error de conexión (%s): %s", username, desc ? desc : "Desconocido");
    if (g_account_state_cb) {
        g_account_state_cb(username, proto_id, false, desc ? desc : "Error de conexión");
    }
}

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
        update_status("Error al crear hilo de event loop: %d", rc);
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

    if (custom_plugin_dir && custom_plugin_dir[0] != '\0') {
        purple_plugins_add_search_path(custom_plugin_dir);
    }

    if (!purple_core_init("adium-swift")) {
        update_status("Error al inicializar purple_core");
        return false;
    }

    purple_set_blist(purple_blist_new());
    purple_blist_load();

    void *conv_handle = purple_conversations_get_handle();
    purple_signal_connect(conv_handle, "received-im-msg", &adium_signal_handle, PURPLE_CALLBACK(cb_received_im_msg), NULL);
    purple_signal_connect(conv_handle, "sent-im-msg", &adium_signal_handle, PURPLE_CALLBACK(cb_sent_im_msg), NULL);

    void *blist_handle = purple_blist_get_handle();
    purple_signal_connect(blist_handle, "buddy-signed-on", &adium_signal_handle, PURPLE_CALLBACK(cb_buddy_signed_on_off), NULL);
    purple_signal_connect(blist_handle, "buddy-signed-off", &adium_signal_handle, PURPLE_CALLBACK(cb_buddy_signed_on_off), NULL);
    purple_signal_connect(blist_handle, "buddy-status-changed", &adium_signal_handle, PURPLE_CALLBACK(cb_buddy_status_changed), NULL);

    void *accounts_handle = purple_accounts_get_handle();
    purple_signal_connect(accounts_handle, "account-signed-on", &adium_signal_handle, PURPLE_CALLBACK(cb_account_signed_on), NULL);
    purple_signal_connect(accounts_handle, "account-signed-off", &adium_signal_handle, PURPLE_CALLBACK(cb_account_signed_off), NULL);
    purple_signal_connect(accounts_handle, "account-connection-error", &adium_signal_handle, PURPLE_CALLBACK(cb_account_connection_error), NULL);

    update_status("Libpurple Core listo");
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
            update_status("Plugin cargado mediante dlopen: %s", plugin_path);
        } else {
            update_status("No se pudo cargar el plugin: %s", plugin_path);
        }
    } else if (purple_plugin_is_loaded(plugin)) {
        update_status("Plugin ya activo: %s", purple_plugin_get_name(plugin));
    } else if (purple_plugin_load(plugin)) {
        update_status("Plugin registrado: %s (%s)", purple_plugin_get_name(plugin), purple_plugin_get_id(plugin));
    } else {
        update_status("Error cargando plugin: %s", purple_plugin_get_name(plugin));
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
        update_status("Conectando %s (%s)...", data->username, data->protocol_id);
    } else {
        update_status("Error al crear cuenta para %s", data->username);
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
        purple_account_set_enabled(account, "adium-swift", FALSE);
        purple_accounts_remove(account);
        update_status("Cuenta eliminada: %s (%s)", data->username, data->protocol_id);
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
            update_status("Mensaje enviado a %s", data->recipient);
        } else {
            update_status("Error creando conversación con %s", data->recipient);
        }
    } else {
        update_status("Sin cuentas activas para enviar a %s", data->recipient);
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

static gboolean do_load_accounts(gpointer user_data) {
    (void)user_data;
    for (GList *l = purple_accounts_get_all(); l != NULL; l = l->next) {
        PurpleAccount *account = (PurpleAccount *)l->data;
        if (!account) continue;
        const char *username = purple_account_get_username(account);
        const char *proto_id = purple_account_get_protocol_id(account);
        gboolean is_connected = purple_account_is_connected(account);

        if (g_account_state_cb) {
            g_account_state_cb(username, proto_id, is_connected, is_connected ? "Conectado" : "Desconectado");
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

    update_status("Cuentas y contactos cargados");
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
    update_status("Libpurple apagado");
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
        purple_savedstatus_activate(status);
        update_status("Estado actualizado: %s", data->status_id);
    }

    g_free(data->status_id);
    g_free(data);
    return G_SOURCE_REMOVE;
}

bool adium_purple_set_user_status(const char* status_id) {
    if (!status_id) return false;
    SetStatusData *data = g_new0(SetStatusData, 1);
    data->status_id = g_strdup(status_id);
    if (g_loop) {
        g_idle_add(do_set_user_status, data);
    } else {
        do_set_user_status(data);
    }
    return true;
}

