# Chat persistente

Este módulo contiene los modelos JSON (`models.rs`) y los controladores de
mensajería y estado de lectura (`service.rs`). `direct.rs` implementa mensajes
privados e invitaciones a reuniones activas entre dos miembros del mismo nodo.
El módulo `nodos` conserva la
gestión de espacios, membresías, moderación, subgrupos y reuniones.

Las rutas continúan registradas en `main.rs`, dentro del grupo protegido por
el middleware JWT. Se conservan las URLs, métodos HTTP, respuestas y consultas
existentes, incluidos los alias `/api/node/{id}/unread-count` y
`/api/node/{id}/check_read_status`.

Esta separación permite evolucionar la mensajería sin agregar responsabilidades
al servicio de nodos. La bandeja directa se consulta periódicamente; no usa
WebSocket ni notificaciones push. La señalización WebRTC vive en `rtc`.

Desde `backend/`, ejecutar `cargo test --locked` para verificar los contratos en
`src/chat_contract_tests.rs`: deserialización, campos opcionales de las respuestas,
rechazo de contenido vacío y errores de persistencia del estado de lectura.
Estas pruebas usan un pool cerrado, sin conectarse a PostgreSQL ni enviar correo.
Los permisos con datos reales y los flujos completos requieren pruebas de
integración adicionales sobre una base aislada.
