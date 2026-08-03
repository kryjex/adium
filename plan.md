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

### 1. QA Manual con Cuentas Reales
- [ ] Realizar login manual en vivo con un tenant real de Microsoft Teams (verificar flujo OAuth completo desde `build/Adium.app`).
- [ ] Verificar conexión interactiva con servidores XMPP / Jabber reales.
- [ ] Vincular cuenta WhatsApp real escaneando QR/código de emparejamiento desde `build/Adium.app` (ya es posible: la app usa `prpl-hehoe-whatsmeow` de purple-gowhatsapp, con whatsmeow real).

### 2. Deuda de Build & Distribución
- [ ] **`Package.swift` Portabilidad:** Migrar de `unsafeFlags` con `/opt/homebrew` a `pkgConfig("purple")` o detección dinámica del prefijo Homebrew/macOS Intel (`/usr/local`).
- [ ] **`PurpleRequestUiOps` & `PurpleConnectionUiOps`:** Implementar callbacks para desplegar prompts interactivos de certificados SSL no válidos o diálogos de autenticación avanzada en SwiftUI.
- [ ] **Notificaciones de Escritura & Sincronización:** Conectar señales `buddy-typing`, `buddy-typing-stopped` y `buddy-removed` para actualizar presencia en tiempo real y limpiar la lista cuando un contacto es eliminado en el servidor.

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
- [ ] Mensajes de estado personalizados (texto de away/status, no solo el enum).
- [ ] Iconos de contacto / avatares (buddy icons propios y de contactos).
- [ ] UI de opciones avanzadas por servicio (exponer los `PurpleAccountOption` de cada prpl: servidor, puerto, resource XMPP, etc.).

### Lista de contactos
- [x] Lista con indicador de estado por contacto.
- [ ] Grupos de contactos (crear, renombrar, colapsar; hoy la lista es plana).
- [ ] Combinar contactos (metacontactos: una persona con varias cuentas/servicios).
- [ ] Ordenamiento y filtrado (por estado, alfabético, manual; ocultar desconectados).
- [ ] Bloquear / desbloquear contactos.
- [ ] Alias locales (renombrar contactos).

### Mensajería
- [x] Chat 1:1 con burbujas y envío.
- [x] Historial persistente e indizable (`ChatLogStore`).
- [ ] Chat en grupo (MUC de XMPP, grupos de WhatsApp, canales/hilos de Teams — los plugins ya lo soportan del lado prpl; falta UI).
- [ ] Mensajería en pestañas (tabbed messaging).
- [ ] Visor de transcripciones (navegador/buscador dedicado del historial).
- [ ] Fuentes, colores y formato (render de HTML/markdown de libpurple, emoticonos).
- [ ] Notificaciones de escritura ("está escribiendo…") — ver §2.

### Eventos y notificaciones
- [x] Notificación de mensaje entrante (UserNotifications de macOS).
- [ ] Sistema de eventos configurable (por evento: sonido, bounce del Dock, badge, ejecutar acción — el "Events" de Adium).
- [ ] Sonidos personalizables por evento.

### Funciones avanzadas
- [ ] Transferencia de archivos (`PurpleXfer` + UI de progreso; purple-gowhatsapp ya maneja adjuntos/media del lado del plugin).
- [ ] Integración con Contactos de macOS (equivalente moderno del Address Book: nombres y fotos).
- [ ] Cifrado OTR (evaluar pertinencia: WhatsApp ya es E2E nativo; aplicaría a XMPP/IRC vía libotr).
- [ ] Sistema de temas/Xtras (message styles, packs de iconos y sonidos) — decidir si se porta el concepto o se simplifica.

### Misceláneo
- [ ] Atajos de teclado completos (navegación entre chats, envío, búsqueda).
- [ ] Respaldo / exportación de datos (`~/.adium-swift`: cuentas, historial, sesiones).
- [ ] Scripting (el Adium original exponía AppleScript; decidir si se ofrece AppleScript/Shortcuts o nada).

### Fuera de alcance (servicios/funciones muertas del Adium original)
AIM/ICQ (Direct Connect, búsqueda por email), Twitter, Bonjour, Sametime, protección por contraseña de la app, soporte OS 9/Windows/iOS. No se portan: los servicios ya no existen o no aplican.
