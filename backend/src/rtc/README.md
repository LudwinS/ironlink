# Videollamada P2P de tres dispositivos (Sprint 3)

El backend mantiene el estado de la reunión y retransmite señalización; el
cliente Flutter captura y conecta audio/video con `flutter_webrtc`. Se admiten
tres participantes por sala mediante mesh P2P (cada dispositivo crea hasta dos
conexiones). No se retransmiten medios por el servidor.

Flujo: un organizador o moderador llama a
`POST /nodos/{nodo}/reuniones/{reunion}/start`; cada miembro llama a
`POST /nodos/{nodo}/reuniones/{reunion}/rtc-ticket` con su JWT y recibe un pase
de 60 segundos; abre `GET /rtc/ws?ticket=...`. El pase se consume al entrar y no
se reutiliza. `POST /nodos/{nodo}/reuniones/{reunion}/end` finaliza la sala.
Salir de la pantalla solo abandona la llamada, no finaliza la reunión.

Ejemplo de mensaje del cliente:

```json
{
  "version": 1,
  "event_id": "6eaec5ae-a89e-4dfa-bc76-40dc4bde44ce",
  "recipient": "871e2c53-6b59-4e7b-a862-0999b65424fa",
  "signal": {"type": "offer", "payload": {"sdp": "v=0\r\n..."}}
}
```

`signal.type` admite `offer`, `answer`, `ice_candidate`, `camera_state`,
`microphone_state`, `hand_state`, `reaction` y `screen_state`. Un candidato usa
`candidate`, `sdp_mid` y `sdp_m_line_index` dentro de `payload`. El servidor
añade `sender` usando la identidad autenticada; no acepta un `sender` enviado
por el cliente. El máximo es 16 KiB por mensaje, 12 KiB para SDP y 2 KiB para
el candidato ICE. Un número de versión desconocido se rechaza.
`camera_state` lleva `{"enabled":false}` para mostrar el avatar cuando alguien
apaga su cámara. Flutter consulta estadísticas WebRTC cada 350 ms para iluminar
el borde de quien habla, sin enviar audio adicional.

`microphone_state` lleva `{"enabled":false}`; el cliente silencia su pista local
y los otros mosaicos muestran el icono de micrófono apagado. `hand_state` lleva
`{"raised":true}` y puede bajarse de nuevo. El estado actual de mano/micrófono
se comparte también al conectar un nuevo par. La lista de turnos utiliza el
orden de recepción local, no una cola de moderación global persistente.

`reaction` lleva `{"emoji":"👏"}`. Solo se admiten 👏, 👍, ❤️, 🎉, 😀 y 😮;
se rechazan duración, emisor y campos adicionales proporcionados por el cliente.
El mosaico muestra la reacción durante tres segundos. El cliente limita su
envío a una reacción por segundo; el límite del servidor de 40 eventos/segundo
continúa aplicándose a toda la señalización. El cooldown específico del cliente
no sustituye la validación ni constituye un límite de reacciones separado en el servidor.
Los temporizadores son acotados a un participante y se cancelan al salir.
No se guarda un historial de reacciones ni se añaden tablas para estos eventos.
`screen_state` lleva `{"enabled":true}` cuando la fuente de video pasa a ser
la pantalla, y `false` al restaurar la cámara. Su payload es booleano estricto.
El cliente comparte una fuente elegida explícitamente, sin audio del sistema,
y sustituye la pista de video en los dos emisores; el servidor no recibe
contenido de pantalla ni nombres/identificadores de ventanas.
Consultar [SPRINT3.md](SPRINT3.md) para ciclo de captura, límites y QA pendiente.

La bienvenida `room_state` incluye `capabilities` con estos cuatro eventos.
El cliente no los envía si el servidor no los anuncia, para seguir utilizando
video/audio con un backend anterior sin provocar el rechazo del socket.

Antes de retransmitir, el servidor revalida membresía, estado activo y baneo de
emisor y destinatario. Cierra la conexión tras 40 señales en un segundo o si pierde autorización. A
los 15 minutos envía `session_renew` y cierra; el cliente pide un pase nuevo y se
reconecta solo. Si la persona abre la llamada en otro dispositivo, la conexión
anterior recibe `replaced` y no se reconecta. Ante una caída de red el cliente
intenta reconectar hasta tres veces (1, 2 y 4 s). El logger actual guarda solo la ruta, no
la consulta que contiene el pase. Configurar el proxy para no registrar esa
consulta y usar HTTPS/WSS fuera de localhost. SDP y candidatos ICE no deben
registrarse.

## Moderación de sala

La migración aditiva `005_rtc_moderation.sql` debe estar aplicada en el backend
actualizado. El arranque normal la incluye en su lista; no se modifica ninguna
migración anterior. La bienvenida anuncia `moderation`, permisos propios, permisos
de otros participantes y `can_moderate` calculado en servidor.

`POST /nodos/{id}/reuniones/{reunion_id}/moderation` acepta:

- `{"action":"mute_all"}` para bloquear micrófonos de participantes conectados.
- `{"action":"microphone","target":"UUID","allowed":false}`; `true` concede permiso sin encender el micrófono.
- `{"action":"camera","target":"UUID","allowed":false}` para bloquear cámara y pantalla; `true` concede permiso sin iniciar captura.
- `{"action":"kick","target":"UUID"}` para impedir el reingreso a esa reunión sin quitar membresía del nodo.

JSON estricto de máximo 1 KiB; rol/membresía/reunión activos comprobados en base de
datos, protección de otros moderadores y límite de diez acciones por segundo.
Los eventos `permissions`, `participant_permissions` y `removed` son exclusivos
del servidor, no tipos permitidos en `ClientEnvelope`. Emisores y receptores
oficiales aplican los bloqueos. En mesh P2P no existe filtrado central de medios:
consultar límites y QA pendiente en [SPRINT3.md](SPRINT3.md).

El cliente usa `RTC_STUN_URL` por `--dart-define` (por defecto un STUN público).
No hay TURN configurado: algunas redes NAT/firewall no podrán establecer medios.
Tampoco están implementadas las llamadas con más de tres personas por canal
(ver la sección de capacidad en `SPRINT3.md`). Las mediciones del
relay WebSocket en localhost **no** son latencia audiovisual extremo a extremo.
La prueba de integración con PostgreSQL desechable verifica tres conexiones,
rechazo de una cuarta, pases de un solo uso y señalización; la calidad real
de audio/vídeo debe probarse en tres dispositivos y redes diferentes.
