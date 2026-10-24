# Renovación de sesión

`POST /refresh` recibe `{"refresh_token":"UUID"}` y devuelve `success`,
`access_token` y `refresh_token`. El token anterior se consume una sola vez,
de forma transaccional. La renovación conserva el vencimiento absoluto original
de siete días. Cuenta suspendida, token vencido, desconocido o reutilizado: 401.
Error de persistencia: 503, sin confirmar la rotación. Se usa el rol actual
de la base de datos al emitir el nuevo JWT.

`POST /logout` acepta el mismo cuerpo y revoca el refresh token presentado.
Es idempotente (204). No precisa un JWT vigente, ya que un usuario debe poder
cerrar una sesión cuyo token de acceso haya caducado. Además incrementa
`users.version_sesion` (migración 019): cada JWT lleva en `ver` la versión
vigente al emitirse y el middleware rechaza con `invalid_access_token` todo
JWT cuya versión no coincida, aunque se haya emitido en el mismo segundo del
cierre (la marca `tokens_validos_desde` de la migración 014, con resolución de
un segundo, ya no se usa). Un JWT anterior sin `ver` también recibe 401. Los
demás dispositivos de la cuenta renuevan una vez con su propio refresh token y
siguen trabajando; una copia del acceso de la sesión cerrada deja de servir al
instante.

Cambiar o recuperar la contraseña revoca todos los refresh tokens del usuario
e invalida los accesos emitidos, en la misma transacción de actualización de
la clave. `PUT /users/me/password` devuelve además `access_token` y
`refresh_token` nuevos para el dispositivo que hizo el cambio; antes ese
dispositivo también perdía la sesión, sin aviso, en la siguiente renovación.

El middleware distingue el rechazo del JWT con `code: invalid_access_token`.
El cliente renueva únicamente ante ese error, coordina las solicitudes
concurrentes y reintenta cada petición una sola vez. Un 401 por contraseña
incorrecta no dispara renovación. Los fallos de red o 5xx no borran tokens.
Una generación de sesión evita reintentar solicitudes de una cuenta anterior.

El cliente conserva perfil y Recordarme, y escribe la pareja renovada en un
solo registro de almacenamiento seguro. Las sesiones con claves antiguas se
leen de forma compatible hasta su primera renovación. Al cerrar sesión se
espera una renovación en curso y se intenta revocar el token resultante.
Sin conexión se limpia el almacenamiento local y se informa que la revocación
remota no fue confirmada.

## Límites

El JWT solo prueba la identidad: en cada petición el middleware lee el rol y el
estado actuales en la base de datos. Degradar a un administrador o suspender una
cuenta surte efecto en la siguiente petición; una cuenta no activa recibe 401
`invalid_access_token` y su renovación también falla. No existe una lista de
revocación de tokens individuales: la versión de sesión es por cuenta, así
que cerrar una sesión obliga a renovar a todas. La sala RTC revalida
membresía/baneo en cada evento y cada cinco segundos, y renueva la conexión a
los quince minutos (el cliente se reconecta solo).

## Pases y WebSockets abiertos

Los pases de `/live/ticket` y RTC (60 s, un solo uso) guardan la versión de
sesión del JWT con que se pidieron (migración 020): no se emiten si esa versión
ya no es la vigente y no se canjean si cambió después. Al incrementarse la
versión (cerrar sesión, cambiar o restablecer la contraseña) se avisa por un
canal en memoria (`session::revocations`) y los WebSockets abiertos de esa
cuenta en `/live/ws` y `/rtc/ws` se cierran con el código 4401
(`session_revoked`); el de RTC envía antes `session_renew`. Los medios de una
llamada siguen por P2P: los demás dispositivos piden un pase nuevo con su JWT
renovado y vuelven a la sala; el que perdió la sesión ya no puede. Para no
perder un aviso entre el canje del pase y la suscripción, cada socket compara
la versión ya suscrito. El aviso vive en el proceso: con varias instancias del
backend, las demás cortarían esas conexiones en su siguiente revalidación.

## Correos

Las rutas que envían correo (`/request-verification`, `/forgot-password`)
tienen, además del límite de 3 por hora y propósito, un tope por IP (10 cada
15 min) y otro de envíos fallidos por dirección (5 cada 15 min), con 429 y
`Retry-After` (`auth::mail_guard`). La IP es la de la conexión o, con
`TRUST_PROXY=1`, la última entrada de `X-Forwarded-For`. Con el SMTP caído,
`/forgot-password` responde el mismo 503 a una dirección desconocida que a una
registrada, para no revelar qué cuentas existen.

Si el servidor confirma una rotación y la respuesta se pierde, el token anterior
ya no puede reutilizarse: una siguiente renovación devuelve 401 y exige login.
La implementación no conserva familias de tokens para detectar y revocar
descendientes tras el robo de un refresh token.

La prueba de integración está ignorada por defecto. Ejecutarla solamente con
una base desechable: crea tablas y un trigger temporal de fallo para comprobar
rollback. Configurar `IRONLINK_TEST_DATABASE_URL` y ejecutar desde backend:

`cargo test --locked isolated_rotation_and_revocation_lifecycle -- --ignored`

Pruebas del cliente: `flutter test test/session_interceptor_test.dart
test/secure_vault_session_test.dart`. La URL puede configurarse con
`--dart-define=API_BASE_URL=https://servidor`; no incluir credenciales en esa URL.
