# Plan: AdiumSwift — Estado y Deuda Post-MVP

Fecha de actualización: 2026-08-02 (Post-ejecución de plan MVP con agentes Gemini 3.6 Flash)

## Contexto y Estado Actual

El proyecto es un paquete **SwiftPM**: ejecutable `AdiumSwift` (SwiftUI, macOS 14+, Swift 6) + target C `CLibpurple` que enlaza contra libpurple/glib de Homebrew y carga dinámicamente plugins de protocolo (`Plugins/*/*.so`).

### Status MVP: ALCANZADO (validado 2026-08-02)
Todos los bloqueantes críticos, bugs del bridge C, seguridad con Keychain, persistencia de cuentas, historial de chats indizable, notificaciones entrantes, selección de UI sincronizada y la infraestructura de plugins (con plantilla y plugin nativo `purple-whatsapp`) se han implementado y verificado.
- **Suite de tests:** 17/17 tests pasando limpiamente en Swift 6 strict concurrency mode.
- **Bundle App:** `make app` compila los plugins (`make -C Plugins/*`) y genera `build/Adium.app` firmado con los `.so` empaquetados en `Contents/PlugIns/`.
- **Validación independiente (2026-08-02):** se confirmó con un harness C contra libpurple que `libteams.so` (`prpl-eionrobb-msteams`) y `libwhatsapp.so` (`prpl-adium-whatsapp`) cargan y quedan registrados como protocolos vía el search path de `Contents/PlugIns`. Se corrigió un bug bloqueante: la UI usaba el ID `prpl-teams`, que no coincide con el ID real del plugin (`prpl-eionrobb-msteams`), por lo que las cuentas Teams jamás habrían conectado. Ojo: `libwhatsapp.so` sigue enlazado contra el **stub** (`whatsmeow_bridge_stub.c`) — simula conexión y pareo; no hay conectividad real de WhatsApp aún.

---

## Tareas Pendientes y Deuda Post-MVP

### 0. Revisión de código 2026-08-03 (post-implementación de paridad)
Se ejecutó una revisión completa del diff de paridad y se corrigieron ~30 hallazgos, incluyendo: decodificación retrocompatible de `Account`/`Contact` (evita pérdida de cuentas/contactos al actualizar), ciclo de vida seguro de request handles y `PurpleXfer` en el bridge C (doble-free/use-after-free), marshalling correcto al hilo de libpurple, prompts interactivos reales (NSAlert) en vez de auto-respuesta, enrutamiento de mensajes/archivos por `accountUsername`, bloqueo real vía privacy de libpurple, join real de chats grupales (`serv_join_chat`), badge/sonidos sin duplicar, sanitización del formatter (entidades HTML, anti-spoofing de links markdown), matching estricto en Contactos de macOS, respaldos atómicos con `accounts.xml` sanitizado, y aislamiento de los tests del entorno real del usuario.
- [ ] QA manual de lo NO cubrible por tests unitarios: estabilidad del bridge C bajo desconexiones con requests/xfers pendientes (los fixes de memoria/hilos requieren libpurple en vivo), diálogos NSAlert de input/acción (incl. campos enmascarados), comportamiento de ⌘W (cerrar pestaña vs ventana), y flujo completo de chats grupales contra un servidor real.
- [x] `FileTransferManager.lastErrorMessage` aún no se muestra en `FileTransferView` — decidir cómo surfacearlo. (RESUELTO 2026-08-03)
- [x] `chat-buddy-joined`/`chat-buddy-left` están conectados pero solo loguean; falta sincronizar el roster de participantes hacia Swift. (RESUELTO 2026-08-03)

### 1. QA Manual con Cuentas Reales
- [ ] Realizar login manual en vivo con un tenant real de Microsoft Teams (verificar flujo OAuth completo desde `build/Adium.app`).
- [ ] Verificar conexión interactiva con servidores XMPP / Jabber reales.
- [ ] Vincular cuenta WhatsApp real escaneando QR/código de emparejamiento desde `build/Adium.app` (ya es posible: la app usa `prpl-hehoe-whatsmeow` de purple-gowhatsapp, con whatsmeow real).

### 2. Deuda de Build & Distribución
- [x] **`Package.swift` Portabilidad:** Migrar de `unsafeFlags` con `/opt/homebrew` a `pkgConfig("purple")` o detección dinámica del prefijo Homebrew/macOS Intel (`/usr/local`). (RESUELTO 2026-08-03)
- [x] **`PurpleRequestUiOps` & `PurpleConnectionUiOps`:** Implementar callbacks para desplegar prompts interactivos de certificados SSL no válidos o diálogos de autenticación avanzada en SwiftUI. (RESUELTO 2026-08-03)
- [x] **Notificaciones de Escritura & Sincronización:** Conectar señales `buddy-typing`, `buddy-typing-stopped` y `buddy-removed` para actualizar presencia en tiempo real y limpiar la lista cuando un contacto es eliminado en el servidor. (RESUELTO 2026-08-03)

### 3. WhatsApp vía `purple-gowhatsapp` (RESUELTO 2026-08-02, queda QA)
En lugar de completar el bridge Go propio, se adoptó [hoehermann/purple-gowhatsapp](https://github.com/hoehermann/purple-gowhatsapp) (whatsmeow real, mantenido activamente) como submódulo en `Plugins/purple-gowhatsapp`. Se instaló Go 1.26.5 y `opusfile` (Homebrew). Compila en macOS arm64 con su Makefile de referencia + flags extra de link (`-framework CoreFoundation -framework Security -lresolv`, ya integrados en el Makefile raíz). Verificado: `libwhatsmeow.so` carga en libpurple y registra `prpl-hehoe-whatsmeow`; la UI ya usa ese ID.
- [ ] Probar persistencia de sesión (whatsmeow la guarda vía su store SQLite) tras reinicios.
- [x] Plugin stub propio `Plugins/purple-whatsapp` eliminado (2026-08-02); la UI usa `prpl-hehoe-whatsmeow`.

### 4. Empaquetado (RESUELTO 2026-08-02)
- [x] `libtemplate.so` excluido del bundle (`make app` omite `Plugins/template/`; la plantilla se sigue compilando como referencia para desarrollo). El bundle empaqueta: `libteams.so`, `libteams-personal.so`, `libwhatsmeow.so`.

---

## 5. Paridad de Funcionalidades con Adium Clásico

Catálogo derivado de la [documentación oficial de Adium](https://adium.im/help/pgs/AdiumDocumentation.html) (2026-08-02), contrastado con el estado real de AdiumSwift. La UI actual es mínima: lista de contactos, chat 1:1 y preferencias con alta de cuentas.

### Cuentas
- [x] Multi-cuenta y multi-protocolo (Teams Work/School, Teams Personal, WhatsApp, XMPP, más los prpl que trae libpurple: IRC, Gadu-Gadu, SIMPLE, GroupWise, Zephyr).
- [x] Estado propio (disponible / ausente / ocupado / desconectado).
- [x] Mensajes de estado personalizados (texto de away/status, no solo el enum). (RESUELTO 2026-08-03)
- [x] Iconos de contacto / avatares (buddy icons propios y de contactos). (RESUELTO 2026-08-03)
- [x] UI de opciones avanzadas por servicio (exponer los `PurpleAccountOption` de cada prpl: servidor, puerto, resource XMPP, etc.). (RESUELTO 2026-08-03)

### Lista de contactos
- [x] Lista con indicador de estado por contacto.
- [x] Grupos de contactos (crear, renombrar, colapsar). (RESUELTO 2026-08-03)
- [x] Combinar contactos (metacontactos: una persona con varias cuentas/servicios). (RESUELTO 2026-08-03)
- [x] Ordenamiento y filtrado (por estado, alfabético, manual; ocultar desconectados). (RESUELTO 2026-08-03)
- [x] Bloquear / desbloquear contactos. (RESUELTO 2026-08-03)
- [x] Alias locales (renombrar contactos). (RESUELTO 2026-08-03)

### Mensajería
- [x] Chat 1:1 con burbujas y envío.
- [x] Historial persistente e indizable (`ChatLogStore`).
- [x] Chat en grupo (MUC de XMPP, grupos de WhatsApp, canales/hilos de Teams — lista de participantes y cabecera grupal). (RESUELTO 2026-08-03)
- [x] Mensajería en pestañas (`TabbedChatContainerView`). (RESUELTO 2026-08-03)
- [x] Visor de transcripciones (`TranscriptView` / `TranscriptViewerWindow`). (RESUELTO 2026-08-03)
- [x] Fuentes, colores y formato (`RichTextFormatter`: render de HTML/markdown, auto-links y emoticonos). (RESUELTO 2026-08-03)
- [x] Notificaciones de escritura ("está escribiendo…") — ver §2. (RESUELTO 2026-08-03)

### Eventos y notificaciones
- [x] Notificación de mensaje entrante (UserNotifications de macOS).
- [x] Sistema de eventos configurable (`EventManager`: sonidos, bounce del Dock, badge y notificaciones). (RESUELTO 2026-08-03)
- [x] Sonidos personalizables por evento (`NSSound` con catálogo del sistema). (RESUELTO 2026-08-03)

### Funciones avanzadas
- [x] Transferencia de archivos (`PurpleXfer` + UI de progreso; purple-gowhatsapp ya maneja adjuntos/media del lado del plugin). (RESUELTO 2026-08-03)
- [x] Integración con Contactos de macOS (`Contacts.framework`: auto-vinculación de nombres reales y foto de perfil). (RESUELTO 2026-08-03)
- [ ] Cifrado OTR (evaluar pertinencia: WhatsApp ya es E2E nativo; aplicaría a XMPP/IRC vía libotr).
- [ ] Sistema de temas/Xtras (message styles, packs de iconos y sonidos) — decidir si se porta el concepto o se simplifica.

### Misceláneo
- [x] Atajos de teclado completos (Cmd+N nueva conversación, Cmd+F buscar contactos, Cmd+W cerrar pestaña, Cmd+Option+T / Cmd+Shift+T visor transcripciones, Cmd+Shift+A añadir cuenta, Cmd+, preferencias). (RESUELTO 2026-08-03)
- [x] Respaldo / exportación de datos (`BackupManager` en .zip y .tar.gz). (RESUELTO 2026-08-03)
- [ ] Scripting (el Adium original exponía AppleScript; decidir si se ofrece AppleScript/Shortcuts o nada).

### Fuera de alcance (servicios/funciones muertas del Adium original)
AIM/ICQ (Direct Connect, búsqueda por email), Twitter, Bonjour, Sametime, protección por contraseña de la app, soporte OS 9/Windows/iOS. No se portan: los servicios ya no existen o no aplican.
