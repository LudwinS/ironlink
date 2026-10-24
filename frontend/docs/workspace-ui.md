# Interfaz de colaboración

Referencia: exportación «IronLink Prototipo», «IronLink Acceso» y «Diagnóstico y Wireframes» (versión «Conflicto de paleta Nocturne»), recibida el 30 de septiembre de 2026. La implementación es Flutter nativo; no ejecuta scripts del prototipo ni incorpora sus datos simulados.

## Implementado

- Chats, Nodos, Buscar y Tú: navegación inferior bajo 600 px y rail de 64 px en escritorio/tablet. Los nodos conservan su identidad hexagonal.
- Chats privados como destino principal. Contactos e historial proceden de los servicios autenticados existentes. Cada conversación conserva su nodo de origen: no se amplían permisos ni se mezclan historiales de distintos nodos.
- Nuevo chat, filtros Todos/No leídos, fijación durante la sesión, burbujas, hora y estados Enviado/Leído. Responder con cita utiliza texto real, no un hilo inexistente en el servidor.
- Los borradores se conservan en memoria al cambiar de conversación/canal. Un fallo de envío no borra el texto; el reintento es explícito. No se afirma que exista una cola offline durable ni envío exactamente una vez.
- Invitaciones a videollamadas enlazadas con el flujo WebRTC existente.
- Canales públicos/privados, reuniones y gestión en una columna de 230 px cuando el ancho es de al menos 1100 px; panel emergente en tamaños menores. Integrantes opcionales en escritorio y panel móvil con las acciones autorizadas existentes.
- Confirmación identificando al integrante antes de expulsar o bloquear.
- Crear/unirse bajo «+», sin botón flotante sobre el editor.
- Búsqueda entre nodos autorizados y mensajes ya cargados del canal abierto; no consulta historiales ajenos ni los marca como leídos para indexarlos.
- Perfil real, ajustes locales por cuenta de tamaño de texto/densidad/movimiento. Atajos Cmd/Ctrl K y Alt 1–4.
- Paleta Nocturne (`core/theme/app_colors.dart`): fondo azul grisáceo y un único acento morado #9184D9, usado como línea y no como relleno. Temas Oscuro, AMOLED y Claro con el contraste medido del prototipo; el tema se elige en «Tú» y se guarda en el dispositivo (`theme_provider.dart`), así que también aplica a las pantallas de acceso. Los colores se leen con nombres semánticos (`AppColors.bg`, `surface`, `accent`, `accentText`…); solo los colores de estado (error, éxito, aviso) son fijos.
- Al cambiar de tema se vuelve a montar el navegador para que todos los widgets tomen la nueva paleta. Borradores, fijados y sesión viven en providers y se conservan.
- Fondo del chat Liso/Malla/Degradado para todos los chats privados y canales, guardado por cuenta.
- Logos `logo-nocturne.png` (acceso) y `logo-mark.png` (navegación); en tema claro `IronLogo` oscurece los grises del logo para que no se pierdan sobre el fondo.
- Acceso según «IronLink Acceso»: panel de marca desde 900 px, avisos con acción (cuenta sin verificar → «Verificar ahora»; credenciales incorrectas → «Restablecer contraseña»), barra de seguridad de contraseña, código de 6 dígitos que admite pegar el código completo y espera de 30 s para reenviar. Diferencias deliberadas con el prototipo, por coherencia con el backend: el registro pide teléfono con prefijo internacional y la contraseña exige mayúscula, minúscula, número y símbolo; la verificación por enlace sigue disponible como alternativa al código.
- Fotos de perfil: el destino «Tú» (barra lateral y barra inferior móvil) muestra la foto de la cuenta, o sus iniciales si no tiene. Pulsar un avatar en «Tú», el editor de perfil, la cabecera de un chat privado, los mensajes de un canal o las listas de integrantes abre la foto en grande con zoom y «Descargar» (`core/widgets/avatar_viewer.dart`); la descarga usa el diálogo de guardado del sistema mediante `file_picker`. La lista de chats no abre el visor, porque pulsar ahí abre la conversación.
- Se eliminó el indicador de VPN conectada que no estaba respaldado por datos del sistema.
- El historial de una conversación oculta no se consulta periódicamente: evita marcar como leídos mensajes no vistos. Las consultas a contactos se espacian a 15 segundos y a integrantes a 20 segundos. No es aún una sustitución de polling por WebSocket.

## Pendiente para reproducir todas las funciones del prototipo

- Carpetas persistentes y fondo distinto por conversación (el prototipo lo ofrece desde Detalles).
- Adjuntos, notas de voz, reacciones, hilos, búsqueda global indexada y actividad/menciones.
- Presencia estructurada y detección real del túnel VPN.
- Preferencias sincronizadas, silencio por conversación, cola offline persistente y entrega idempotente.
- Unificación de conversaciones entre distintos nodos: requiere una decisión de producto y cambios de autorización/API.

No hay botones activos que afirmen ofrecer estas capacidades. No se reemplazó la autenticación, la autorización del servidor ni el motor de videollamadas.

## Validación

`nocturne_design_test.dart` comprueba las cinco pantallas de acceso a 320, 390 y 1280 px con texto al 130 % en los tres temas, los avisos de inicio de sesión, el envío automático del código, pegar el código, las reglas de contraseña, el contraste mínimo de cada paleta y que tema y fondo del chat se apliquen y guarden. `profile_photo_test.dart` cubre la foto en la navegación, el visor y la decodificación de la imagen guardada.

`workspace_design_test.dart` comprueba anchos de 320, 390, 800 y 1280 px con texto al 130 %, sin suprimir errores de desbordamiento. Incluye conservación/reintento de borradores, texto escrito durante un envío, cambio de conversación, citas y suspensión de lecturas en segundo plano.

La vista previa opcional (`IRONLINK_RENDER_PREVIEW=true`) usa cuentas de prueba y produce una imagen de componentes realmente renderizados; no es una captura de una sesión de usuarios reales. Esta opción de revisión visual está preparada para macOS y carga fuentes locales del sistema. Los tests ordinarios no dependen de esas rutas.

Las pruebas de widgets no sustituyen una prueba de cámara/micrófono en tres dispositivos ni verifican tiempos reales de red. Esas verificaciones siguen siendo necesarias para aceptar el sprint completo.
