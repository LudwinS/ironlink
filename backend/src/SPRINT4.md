# Estado de implementación del Sprint 4

Referencia: sección 3 de `Sprint_3_Planificacion_P2P_Videollamadas_IronLink.docx`, carpeta académica Sprint 3. Actualizado el 30 de septiembre de 2026. No se encontró un documento independiente del Sprint 4 en la carpeta consultada.

## Historias y secuencia de desarrollo

| Historia | Funcionalidad | Estado |
| --- | --- | --- |
| IRL-WKS-US-05 | Calendario global de reuniones | Implementado; QA pendiente |
| IRL-WKS-US-06 | Compartir enlace directo de reunión | Implementado; QA pendiente |
| IRL-SEC-US-01 | Asistencia con entrada/salida y CSV | Implementado; QA pendiente |
| IRL-SEC-US-02 | Tiempo total y participación | Implementado; QA pendiente |
| IRL-NTF-US-01 | Recordatorios 15 y 5 minutos antes | Implementado; QA pendiente |
| IRL-NTF-US-03 | Panel de notificaciones del día | Implementado; QA pendiente |
| IRL-RTC-US-07 | Salas de trabajo | Implementado con la capacidad actual (3 por canal); QA pendiente |
| IRL-RTC-US-08 | Pizarra interactiva | Implementado; QA pendiente |

Esta secuencia prioriza la agenda y los datos persistentes antes de añadir la división de salas y el lienzo. No cambia las ocho historias del plan ni declara el sprint completado.

## Calendario global

- Nuevo destino «Agenda» en escritorio y móvil; atajo Alt+5. Calendario mensual, días con reuniones, filtro por día/nodo, «Hoy», «Todo el mes» y actualización manual.
- Muestra reuniones programadas, en curso y finalizadas según su fecha programada de inicio. Horas en la zona local del dispositivo; los límites de mes se calculan en hora local y se envían en UTC. El intervalo del servidor es `[from, to)`.
- `GET /calendar/meetings?from=<RFC3339>&to=<RFC3339>&node_id=<UUID opcional>`, bajo middleware JWT. Revalida cuenta activa y solo devuelve reuniones de nodos activos de los que el usuario sigue siendo miembro y no está baneado.
- Intervalo máximo de 93 días, orden por inicio/UUID y máximo de 500 resultados. Se devuelve `truncated` y se informa al usuario; filtrar por nodo permite reducir el intervalo consultado. No es una API de exportación completa ni incluye reuniones cuya fecha programada comienza fuera del intervalo.
- «Unirse ahora» usa la reunión real y los permisos calculados por servidor. No concede membresía, no inicia reuniones programadas y no ofrece entrada a expulsados. El endpoint RTC vuelve a comprobar autorización y disponibilidad; no se garantiza un cupo por figurar en el calendario.
- No se abre otra llamada si la presencia local indica «En llamada». Los permisos de moderación no provienen de valores introducidos por el usuario.
- Descarta respuestas tardías al cambiar mes/nodo, ocultar la agenda o cerrar la pantalla. Recarga al volver a la agenda, cambiar membresías visibles, actualizar manualmente o regresar de una llamada. No afirma actualización continua por WebSocket de la agenda: la revalidación final se hace al entrar a RTC.
- Errores explícitos, reintento, lista vacía y límite de resultados visibles. Adaptación probada a 320/390/800/1280 px y texto al 130 %.
- Migración aditiva `007_calendar_index.sql` para búsquedas por inicio/ID, aplicada al reiniciar el backend actualizado. Durante desarrollo solo se aplica a PostgreSQL desechable; la base del usuario no se modifica.

## Enlace directo de reunión (IRL-WKS-US-06)

- En la Agenda, quien puede moderar la reunión ve «Compartir enlace»: copia `<web>/#/reunion/<id>` o lo publica en el canal general del nodo. No se comparte una reunión finalizada.
- El enlace solo contiene el ID de la reunión, nunca tokens. `GET /reuniones/{id}` (bajo JWT) aplica la misma autorización que el calendario: cuenta activa, miembro del nodo activo y sin baneo. Sin acceso o si no existe responde el mismo 404, para no revelar su existencia.
- En canales y chats privados, un mensaje con un enlace de reunión muestra una tarjeta con título, nodo, fecha y estado; si está en curso y el usuario puede entrar, «Unirse» abre la llamada con un clic. Programadas o finalizadas lo explican sin botón. Al volver de la llamada se consulta de nuevo el estado.
- En la web, abrir el enlace lleva a `/reunion/<id>`; sin sesión pasa por el inicio de sesión y vuelve a la reunión. El parámetro `from` solo acepta rutas de reunión.
- Base del enlace: `--dart-define=APP_WEB_URL=https://...`; si no se define, en web se usa el propio origen y en escritorio el host de `API_BASE_URL` con el puerto 3000 de `start_web_release.sh`. Si el cliente usa `127.0.0.1`, el enlace solo sirve en esa máquina: definir `APP_WEB_URL` o usar la IP de la red.
- Entrar a la llamada sigue pasando por el ticket RTC, que revalida acceso y cupo.

## Asistencia y participación (IRL-SEC-US-01 y US-02)

- El servidor RTC registra cada conexión admitida en `reunion_asistencia` (migración aditiva `008_attendance.sql`): entrada, salida y motivo (`salio`, `conexion_perdida`, `expulsado`, `reunion_finalizada`, `reemplazada`, `sin_autorizacion`, `limite_sesion`, `servidor_reiniciado`). El cliente no puede escribir ni declarar su asistencia.
- Cada latido de 5 s actualiza `last_seen_at`. Al arrancar, las sesiones abiertas (ninguna conexión sobrevive a un reinicio) se cierran con ese último latido, no con la hora del reinicio. Finalizar la reunión cierra todas las sesiones a la misma hora.
- `GET /nodos/{id}/reuniones/{reunion_id}/asistencia` y `.../asistencia.csv`, bajo JWT y solo para quien puede moderar la reunión; los demás reciben 404.
- Tiempo por participante = unión de sus intervalos: reconectarse o entrar desde dos dispositivos no cuenta dos veces. Porcentaje sobre la duración real (inicio a fin, o hasta ahora si sigue en curso).
- CSV en UTF-8 con BOM, una fila por sesión con el total del participante; campos entre comillas y valores que empiezan por = + - @ prefijados con ' para que Excel no los ejecute como fórmulas.
- En la Agenda, «Asistencia» aparece para moderadores en reuniones en curso o finalizadas: resumen por persona, detalle de entradas y salidas, actualización y exportación.
- Límites: el registro empieza con este despliegue (no hay datos de reuniones anteriores) y la conexión RTC se renueva a los 15 min, lo que aparece como una nueva entrada con motivo «Límite de sesión».

## Recordatorios y panel de notificaciones (IRL-NTF-US-01 y US-03)

- Migración aditiva `009_notifications.sql`. Una tarea del servidor corre cada 20 s y crea, para cada miembro activo y no baneado, el recordatorio de 15 min y el de 5 min de las reuniones programadas. Si la reunión ya está a 5 min o menos solo se envía el de 5; una reunión iniciada no genera recordatorios.
- `dedupe_key` única (tipo, reunión, usuario y hora de inicio): no hay duplicados aunque la tarea corra varias veces o el servidor se reinicie, y reprogramar la reunión genera los recordatorios de la nueva hora.
- Al iniciar una reunión se guarda «Reunión iniciada» para los demás miembros, así queda en el panel aunque no estuvieran conectados (complementa el aviso en vivo de IRL-NTF-US-02).
- El contador de no leídas (24 h) viaja en la instantánea del canal en vivo; tras crear recordatorios se fuerza un envío inmediato. El cliente anuncia con un aviso emergente solo las notificaciones nuevas, no las que ya existían al abrir.
- `GET /notificaciones?desde=<inicio del día local en UTC>` (hasta 48 h y 200 avisos) y `POST /notificaciones/leidas` con `ids` o `todas`. Solo devuelven y modifican notificaciones propias de nodos donde el usuario sigue siendo miembro y no está baneado.
- Campana con contador en la cabecera (escritorio) y en una barra superior (móvil). El panel agrupa por nodo, filtra no leídas, marca todas como leídas y abre la tarjeta de la reunión para unirse.
- Límites: los recordatorios se ven dentro de IronLink; no hay notificaciones del sistema operativo ni correo. Si el servidor estuvo apagado durante la ventana de 15 min, el recordatorio se crea al volver si la reunión aún no empieza; su texto indica la hora real de inicio.

## Salas de trabajo (IRL-RTC-US-07)

- Migración aditiva `010_breakout_rooms.sql`: salas por reunión, asignaciones, sala del pase RTC y sala en la asistencia.
- El hub RTC separa el canal de medios (sala principal = ID de la reunión, o una sala de trabajo) de la reunión. Una persona ocupa un solo canal por reunión; al cambiar, la sala anterior recibe `peer_left`. La señalización solo se reenvía dentro del mismo canal. Moderación, expulsión, fin de reunión y asistencia actúan sobre la reunión completa, esté donde esté cada persona.
- `GET/PUT/DELETE /nodos/{id}/reuniones/{reunion_id}/salas`. `PUT` (solo moderadores, reunión en curso) reemplaza las salas abiertas: 1 a 10 salas, nombres de 1 a 60 caracteres distintos, cada persona en una sola sala, integrantes activos del nodo sin baneo ni expulsión, y como máximo la capacidad del canal por sala. `DELETE` cierra todas. Finalizar la reunión también las cierra.
- Tras crear o cerrar salas, el servidor envía `{"type":"breakout","sala":...}` a cada persona conectada. El pase `rtc-ticket?sala_id=` solo se emite si la sala está abierta y la persona está asignada o modera; el latido de 5 s vuelve a comprobarlo y corta la conexión si la sala se cerró o hubo reasignación.
- Cliente: el moderador abre «Salas de trabajo» en la llamada, elige el número de salas, reparte automáticamente o a mano (sin superar la capacidad), visita cualquier sala y las cierra. Los asignados ven un aviso y entran en 10 s (o al pulsar «Ir ahora»; pueden posponerlo); al cerrarse vuelven a la principal en 3 s. Dentro de una sala pueden volver a la principal.
- Límite actual: cada canal (principal o sala) admite 3 dispositivos porque la videollamada es mesh P2P. Ver la sección de capacidad en `rtc/SPRINT3.md`.

## Pizarra compartida (IRL-RTC-US-08)

- Migración aditiva `011_whiteboard.sql`. Hay una pizarra por canal: la sala principal y cada sala de trabajo tienen la suya.
- Los trazos terminados se guardan (puntos normalizados 0..1 sobre un lienzo 16:9, color de una paleta fija, grosor 1–24) y se reenvían en vivo a quienes están en ese canal por el WebSocket de la llamada. Al abrir la pizarra, reconectarse o cambiar de sala se recupera completa desde el servidor.
- Dibuja quien modera; puede activar «Todos pueden dibujar» por canal. Cada persona deshace o borra sus propios trazos; quien modera borra cualquiera y limpia la pizarra. Para dibujar hay que estar conectado a la llamada.
- Límites: 2000 puntos por trazo, 5000 trazos por pizarra, 10 operaciones por segundo por persona (compartido con la moderación) y coordenadas validadas en el servidor.
- `GET/DELETE /nodos/{id}/reuniones/{reunion_id}/pizarra?sala_id=`, `POST .../pizarra/trazos`, `DELETE .../pizarra/trazos/{id}` y `PUT .../pizarra/permisos`.
- Cliente: botón «Pizarra» en la llamada con aviso de trazos nuevos; lápiz, borrar trazo, seis colores, tres grosores, deshacer, permisos, limpiar con confirmación y exportar a PNG. El trazo propio se ve al instante y se revierte si el servidor lo rechaza.
- Límites: solo se dibuja un trazo cuando se termina (no se transmite mientras se dibuja) y la pizarra solo está disponible mientras la reunión está en curso; para conservarla hay que exportarla antes de finalizar.

## QA pendiente

1. Reiniciar el backend actualizado y abrir el cliente macOS recompilado.
2. Con dos cuentas en nodos diferentes, comprobar que la agenda nunca muestra un nodo ajeno. Repetir con ban, salida del nodo y cuenta suspendida.
3. Programar reuniones en límites de mes y comprobar horas en dispositivos con zonas horarias distintas, incluido cambio horario donde aplique.
4. Seleccionar nodo/día, navegar de mes, salir y regresar durante una carga lenta y probar fallo/reintento.
5. Iniciar y finalizar una reunión, entrar desde la agenda, volver y confirmar el estado actualizado. Probar una sala completa y un usuario expulsado: el backend debe denegar entrada aunque la agenda anterior estuviera abierta.
6. Ejecutar QA en staging, revisión del equipo y fusión a develop según el DoD. No sustituir estas comprobaciones por pruebas unitarias.

7. Enlace de reunión: compartir como moderador; abrirlo con otra cuenta del nodo, con una cuenta ajena (debe decir que no existe o no hay acceso), con un usuario baneado y sin sesión en la web (debe volver a la reunión tras iniciar sesión).
8. Asistencia: tres cuentas entran y salen (cerrar la app, perder la red, ser expulsada), reiniciar el backend con alguien conectado y finalizar la reunión; comprobar horas, motivos, tiempo total y que el CSV abra bien en Excel con nombres acentuados.
9. Notificaciones: programar reuniones a 20, 12 y 3 min con dos cuentas; comprobar los avisos a los 15 y 5 min, que no se dupliquen al reiniciar el backend, que al reprogramar llegue el de la nueva hora, que un baneado no los reciba y que el contador baje al leerlas desde otra ventana.
10. Salas: con tres cuentas, crear dos salas, comprobar el aviso y la entrada automática, que una cuenta no pueda entrar a una sala ajena, que el moderador pueda visitar ambas, expulsar a alguien que está en una sala y cerrar las salas con todos volviendo a la principal. Revisar en Asistencia la sala de cada conexión.
11. Pizarra: el moderador dibuja y los demás lo ven en vivo; activar «Todos pueden dibujar» y comprobar que cada quien solo deshace lo suyo; cambiar de sala y verificar que cada una tiene su pizarra; reconectarse y comprobar que se recupera; limpiar y exportar a PNG.

Los pendientes de QA y TURN del Sprint 3 permanecen documentados en `rtc/SPRINT3.md`; empezar Sprint 4 no los da por superados.
