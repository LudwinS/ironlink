# Estado de implementación del Sprint 3

Referencia: «Sprint_3_Planificacion_P2P_Videollamadas_IronLink», carpeta académica del Sprint 3. Actualizado el 30 de septiembre de 2026.

| Historia | Implementación actual | Validación o trabajo restante |
| --- | --- | --- |
| RTC-US-01 Cámara | Captura, cámara activable y mosaicos mesh de tres dispositivos; estado remoto de cámara | Prueba audiovisual en tres dispositivos y redes reales |
| RTC-US-02 Audio | Pista local silenciable, indicador de voz, estado remoto y selector de micrófono/salida en caliente para macOS/Windows | QA nativo de auriculares, desconexión de dispositivos y audio real; selector web/móvil fuera de este bloque |
| RTC-US-03 Pantalla | Selector explícito de pantalla/ventana en escritorio, reemplazo de pista en ambos pares, modo presentador adaptable y restauración de cámara | QA de permisos/captura nativa, tres dispositivos, distintas redes y cierre de fuente compartida |
| RTC-US-04 Mano | Levantar/bajar, badge remoto, actualización al conectar otro par y turnos por recepción local | QA real; no hay cola global autoritativa/persistente |
| RTC-US-05 Reacciones | Seis reacciones sincronizadas, efímeras durante tres segundos y validadas en servidor | QA real de los mosaicos y de la interacción en tres dispositivos |
| RTC-US-06 Moderación | Silenciar participantes, permitir/bloquear micrófono o video/pantalla y expulsión persistente de la reunión; roles verificados en servidor y restricciones en emisores/receptores | QA real de controles y medición del objetivo de 500 ms; revisión de seguridad y staging |
| NTF-US-02 Inicio | Aviso automático de reunión iniciada para miembros autorizados, con «Unirse ahora», selección y descarte | QA real de inicio, reconexión y permisos; revisión y staging |
| IAM-US-03 Presencia | Presencia automática fuera de la sala: En llamada, Disponible, Ocupado y Desconectado; indicadores en perfiles y chats | QA real de varias sesiones, pérdida de red y salida de la llamada |

No se declaran las historias como Done: el plan exige también revisión, QA en staging y fusión a develop. Tampoco se ha configurado TURN ni probado medios en redes NAT/firewall distintas.

La prueba física con tres dispositivos queda aplazada por petición del usuario hasta completar las funciones. Las pruebas automatizadas continúan; aplazar el QA físico no equivale a superarlo.

## Cambios de este bloque

- Nuevos eventos `hand_state`, `reaction` y `microphone_state`, con identidad de origen derivada de la sesión y la misma revalidación de autorización que SDP/ICE.
- Payloads tipados: booleanos reales, reacciones de lista cerrada y rechazo de campos extra.
- Reacciones con un solo temporizador por participante; limpieza al desconectar. El rate limit general del servidor permanece vigente.
- El mute comunicado anula el indicador de voz remoto para evitar que una muestra anterior mantenga encendido el borde.
- Los nombres largos de mosaicos ya no desbordan el espacio disponible.
- Se corrigieron tres advertencias preexistentes de Clippy mediante simplificación de condiciones, sin alterar las políticas de autenticación o membresía.

## Evidencia

- `rtc_participation_test.dart`: estados de mano/micrófono, orden estable ante eventos duplicados, duración y frecuencia de reacciones, aislamiento entre participantes y rechazo de valores inválidos.
- Tests Rust de protocolo: identidad autenticada, booleanos estrictos, lista cerrada de reacciones y rechazo de campos extra.
- Integración `isolated_membership_ticket_replay_and_latency`: tres sockets, rechazo del cuarto, pases de un uso, envío de mano/micrófono/reacción a ambos pares y cierre de un emisor baneado.
- La integración se ejecuta sobre PostgreSQL desechable, nunca sobre la base del usuario. Mide el relay de señalización en localhost, no la latencia de audio/vídeo ni un resultado comparable directamente con Discord/Teams.

Para habilitar estas nuevas señales hay que reiniciar el backend con esta versión y usar el cliente recompilado. El protocolo mantiene la versión 1 y la bienvenida anuncia `capabilities`. Cuando un backend antiguo no anuncia estas capacidades, el cliente mantiene las funciones de video/audio existentes y no envía señales nuevas. Mano/reacciones y pantalla requieren sus capacidades respectivas; el botón de pantalla permanece desactivado en servidores anteriores.

## Compartición de pantalla (RTC-US-03)

- Captura solo tras pulsar el botón y seleccionar una fuente explícita en escritorio; cancelar no inicia captura. En web se usa el selector del navegador. No se habilita emisión desde móvil en este bloque.
- La fuente sustituye la pista de cámara con `replaceTrack`, manteniendo las pistas de audio y el estado de silencio. No se captura audio del sistema. En escritorio se solicita 15 fps; no se afirma un límite de resolución ni de ancho de banda.
- Al detener o recibir `onEnded`, se restaura la pista original sin activar una cámara previamente apagada. Si falla la restauración se cierra la llamada para evitar un emisor oculto.
- Nuevos participantes y cambios de fuente se serializan. Cerrar mientras se espera permiso revoca cualquier stream que llegue tarde. Se detienen y liberan las pistas de captura al salir.
- `screen_state` tiene payload booleano estricto, origen autenticado, límite general de eventos y revalidación de membresía. No transmite nombres de ventanas, IDs de captura ni contenido de pantalla al servidor.
- Vista principal de presentación con tira de participantes; si hay varios presentadores se puede elegir cuál visualizar. El presentador aparece como avatar en la tira: cámara y pantalla no se transmiten simultáneamente.
- Pruebas de ciclo de captura con medios simulados y layout a 320/390/800/1280 px; relay del evento a ambos pares en la integración aislada. Esto no sustituye la comprobación de captura nativa ni audiovisual real.

### QA manual pendiente

1. Reiniciar backend actualizado y abrir tres clientes recompilados con cuentas autorizadas.
2. Compartir una ventana y una pantalla completa; confirmar imagen legible en los otros dos dispositivos y micrófono silenciado sin cambios.
3. Entrar con el tercer cliente mientras ya se comparte; confirmar que recibe la fuente actual.
4. Detener con el botón y cerrar la fuente; confirmar retorno a cámara o avatar según su estado previo.
5. Cancelar o denegar permisos, salir durante el selector y repetir compartir/detener; verificar que no queda captura activa.
6. Probar ancho móvil, múltiples presentadores, redes distintas y CPU/memoria/ancho de banda bajo captura real. TURN sigue pendiente.

## Audio en caliente (RTC-US-02)

- Selector de dispositivos reales, actualización manual de lista y errores explícitos; se evitan acciones simultáneas. No se inventa el dispositivo por defecto: hasta una selección confirmada se muestra la ruta actual del sistema.
- macOS/Windows usan el enrutamiento nativo de WebRTC, sin renegociación ni cambio de pista de cámara/pantalla. Se reaplica el estado actual de silencio al cambiar entrada. La ruta afecta al módulo de audio de IronLink en este equipo.
- Cambios exitosos se reflejan tras confirmación nativa; un fallo conserva la selección anterior. Al desconectar un dispositivo se limpia la selección visual al actualizar, sin afirmar qué fallback eligió el sistema.
- Pruebas de enumeración, selección independiente, dispositivos desaparecidos, fallo/reintento, cierre pendiente y layout a 320/390/1280 px con texto al 130 %. No se ha probado hardware físico ni Bluetooth.

## Moderación (RTC-US-06)

- Endpoint autenticado `POST /nodos/{id}/reuniones/{reunion_id}/moderation`, JSON tipado y límite de 1 KiB. Solo creador de reunión/nodo, ADMIN o MODERATOR activo y conectado; nunca se confía en el rol enviado por el cliente.
- Diez acciones/segundo por moderador conectado, con contadores acotados al ciclo de vida del peer. Los otros moderadores están protegidos y no se permite actuar sobre uno mismo.
- `mute_all` bloquea los micrófonos de los participantes conectados no moderadores. `microphone` y `camera` cambian permisos; conceder permiso no activa la captura. Bloquear video también detiene la pantalla, incluso si la captura estaba esperando autorización.
- Migración aditiva `005_rtc_moderation.sql`: controles por reunión/usuario. Un `kick` invalida pases emitidos, desconecta y deniega futuros pases para esa reunión sin eliminar membresía del nodo. Las restricciones sobreviven a reconexiones/reinicio del servidor.
- Bienvenida y eventos exclusivos del servidor transmiten permisos. El cliente oficial deshabilita pistas locales; los receptores también deshabilitan las pistas remotas restringidas y ocultan el video. Las nuevas señales de activación prohibidas no se retransmiten.
- La salida se notifica inmediatamente al resto. Si no se puede encolar la salida se cierra la sala afectada para no dejar receptores conectados al expulsado. La base de datos se confirma antes de publicar las acciones.
- Limitación de mesh P2P: el servidor no inspecciona ni filtra los paquetes de medios; la aplicación oficial aplica las restricciones en ambos extremos. No se garantiza el comportamiento de clientes modificados que ignoren controles. El objetivo de menos de 500 ms requiere medición real, no se declara satisfecho por tests localhost.
- La integración aislada verifica usuario sin rol, autoacción rechazada, protección de otro moderador, mute y permisos, rechazo de reactivación de audio/pantalla, expulsión, pases pendientes invalidados y membresía conservada. No se aplicaron migraciones a la base de datos del usuario durante estas pruebas.

## Avisos de inicio y presencia (NTF-US-02 / IAM-US-03)

- Canal de aplicación independiente del socket RTC: `POST /live/ticket` autenticado y `/live/ws` con pase de un uso que caduca en 60 segundos. El JWT no se envía en la URL. Usar HTTPS/WSS fuera del entorno local.
- Migración aditiva `006_live_updates.sql`, aplicada al iniciar el backend actualizado. Las pruebas usan PostgreSQL desechable; no se migró la base del usuario durante este bloque.
- El inicio de una reunión y la entrada/salida RTC notifican al canal inmediatamente. Cada snapshot vuelve a verificar usuario activo, nodos compartidos, membresías y baneos. Los expulsados no reciben una opción de unirse a esa reunión.
- Revalidación y heartbeat cada cinco segundos; los cambios de autorización externos se concilian en ese ciclo. El cliente elimina presencia y opciones de unirse si pasan 20 segundos sin un mensaje válido. Reconexión con espera progresiva, renovación de socket a los 15 minutos y escrituras del servidor limitadas a cinco segundos.
- Hasta cuatro conexiones de aplicación por usuario. Cerrar una ventana no desconecta las demás; estar en cualquier sala RTC prevalece como «En llamada». El texto de estado manual no se modifica; «Ocupado» solo se deriva de la opción manual explícita mientras está conectado.
- Indicadores reactivos en avatares de perfiles, contactos, mensajes y miembros; estado textual en miembros del nodo. Sin conexión se muestra «Sin sincronizar», nunca un falso «Disponible».
- Banner adaptable con «Unirse ahora», selección de otra reunión y descarte. Los avisos descartados de reuniones aún activas no se repiten al reconectar; las terminadas o inaccesibles desaparecen. Entrar no concede permisos adicionales y no se habilita otra entrada si el usuario está en llamada.
- Snapshot acotado a 500 miembros más el propio usuario y 50 reuniones; se informa cuando la vista está truncada. No incluye historial de notificaciones, avisos del sistema operativo ni recordatorios del Sprint 4.
- La presencia vive en el proceso del backend: varios servidores necesitarían un registro compartido. No se declara presencia distribuida ni cumplimiento medido de objetivos de latencia audiovisual.
- Pruebas automatizadas de presencia multisesión, tickets de un uso, autorización, baneos, usuario suspendido y avisos reales por WebSocket al iniciar una reunión; además, descarte, cuenta cambiada, logout, heartbeat, silencio del canal y layouts a 320/390/1280 px con texto al 130 %.

Las funciones de las ocho historias están implementadas con las limitaciones documentadas. Para cerrar formalmente el Sprint 3 faltan QA físico y en staging, revisión y fusión a develop. TURN sigue pendiente para validar redes restrictivas.

Validación de este bloque: 153 pruebas Flutter y 22 pruebas Rust aprobadas (incluidas integraciones con PostgreSQL aislado), análisis Flutter sin incidencias, Clippy sin advertencias y compilación del backend y cliente macOS Debug. Estos resultados no sustituyen QA audiovisual ni mediciones de rendimiento en dispositivos reales.

## Capacidad de las videollamadas (análisis para 20 personas)

La llamada es mesh P2P: cada dispositivo abre una conexión con cada uno de los demás y codifica y envía su cámara (640×480) una vez por destinatario. Con N personas, cada una sube N−1 videos, baja N−1 y mantiene N−1 codificadores. Por eso `MAX_PEERS = 3` por canal (sala principal o sala de trabajo).

| Personas | Videos que sube cada una | Subida aprox. por persona (≈0,8 Mbps por video) | Conexiones en total |
| --- | --- | --- | --- |
| 3 | 2 | ≈1,6 Mbps | 3 |
| 6 | 5 | ≈4 Mbps | 15 |
| 20 | 19 | ≈15 Mbps | 190 |

Con 20 en mesh, cada equipo tendría que subir unos 15 Mbps (más de lo que da una red doméstica o el Wi-Fi compartido de la universidad) y codificar 19 videos a la vez, lo que satura la CPU de una laptop. Subir solo `MAX_PEERS` no lo hace viable.

Para 20 o más se necesita un servidor de medios SFU (recomendado: LiveKit, código abierto y autoalojable). Cada persona sube su video una sola vez (≈1,5–2 Mbps con simulcast) y baja solo lo que ve en pantalla; el servidor reenvía sin recodificar. Para 20 personas: unos 2–4 vCPU, 4 GB de RAM y ≈40–50 Mbps de salida.

Impacto en IronLink si se adopta:

- Infraestructura: un servicio más (contenedor Docker) con un rango de puertos UDP abierto y TURN integrado; fuera de la red local necesita dominio y TLS. Variables nuevas en el backend (URL, clave y secreto del SFU).
- Backend: tras la autorización actual se emite el token del SFU en lugar del pase de medios. El canal de control actual se conserva para moderación, salas, asistencia y presencia, y la moderación también se aplica en el SFU para que un cliente no pueda ignorarla. Cada sala de trabajo pasa a ser una sala del SFU.
- Cliente: se reemplaza el motor mesh (`rtc_call_controller.dart`) por el SDK del SFU: cámara, micrófono, pantalla, dispositivos y detección de quién habla. La vista necesita una cuadrícula paginada o con orador activo, porque la actual está pensada para 3.
- Pruebas: se rehacen las del cliente RTC; las del canal de control, salas, asistencia y permisos siguen valiendo.
- Esfuerzo estimado: 3 a 5 días de desarrollo más QA en varios dispositivos y redes.
