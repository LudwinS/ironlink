# IronLink — Registro de Bugs y Fallos

> Última actualización: 2026-06-04 · Todos los bugs reportados han sido completamente solucionados en el Sprint 1.

---

## Resumen

| Severidad | Abiertos | Resueltos |
|---|---|---|
| 🔴 Crítico | 0 | 0 |
| 🟠 Alto | 0 | 4 |
| 🟡 Medio | 0 | 3 |
| 🟢 Bajo | 0 | 1 |
| **Total** | **0** | **8** |


---

## Bugs Registrados

### BUG-001: Error de Bloqueo de Login al no marcar "Recuérdame"

| Campo | Detalle |
|---|---|
| **Severidad** | 🟠 Alto |
| **Componente** | Frontend |
| **Archivo(s)** | [app_router.dart](file:///C:/Users/Ludwin/ironlink_workspace/frontend/lib/core/router/app_router.dart), [secure_vault.dart](file:///C:/Users/Ludwin/ironlink_workspace/frontend/lib/core/security/secure_vault.dart) |
| **Estado** | 🟢 Resuelto |

**Descripción:**
Cuando el usuario intentaba iniciar sesión con las credenciales correctas pero **sin** marcar la casilla de "Recordarme", el login fallaba y lo regresaba inmediatamente a la pantalla de `/login`.

**Causa:**
La función `SecureVault.hasSession()` comprobaba si la clave `remember_me` era `'true'` para validar la sesión. Al no marcar la casilla, `remember_me` se guardaba como `'false'`. El enrutador ejecutaba su redirección de seguridad, detectaba `hasSession() == false` y forzaba el retorno a `/login` a pesar de que el token JWT era válido y el inicio de sesión del backend había sido exitoso.

**Solución:**
Se separó la comprobación de sesión activa (que ahora solo verifica la existencia del token JWT en `secure_vault.dart`) de la comprobación de persistencia al arrancar la app. Si al arrancar la app `remember_me` es `'false'`, los tokens se limpian y se exige login; de lo contrario, se mantiene la navegación fluida.

---

### BUG-002: Error de Conteo de Participantes en Nodos

| Campo | Detalle |
|---|---|
| **Severidad** | 🟡 Medio |
| **Componente** | Backend |
| **Archivo(s)** | [service.rs](file:///C:/Users/Ludwin/ironlink_workspace/backend/src/nodos/service.rs) |
| **Estado** | 🟢 Resuelto |

**Descripción:**
Cuando un usuario creaba un nodo o cuando otro usuario se unía a él mediante el token de acceso de 32 caracteres, el contador de miembros en la interfaz no se actualizaba (mostraba siempre `0` o datos estáticos).

**Causa:**
El backend no estaba calculando la suma de registros en la tabla intermedia `nodo_miembros` durante las consultas SQL de listado, creación y unión de nodos.

**Solución:**
Se incorporó una subconsulta `miembros_count` en las consultas de base de datos del backend para que devuelva dinámicamente la cantidad real de participantes vinculados a cada nodo.

---

### BUG-003: Confusión de Token de Verificación Requerido

| Campo | Detalle |
|---|---|
| **Severidad** | 🟠 Alto |
| **Componente** | Backend / Frontend |
| **Archivo(s)** | [main.rs](file:///C:/Users/Ludwin/ironlink_workspace/backend/src/main.rs), [api_client.dart](file:///C:/Users/Ludwin/ironlink_workspace/frontend/lib/core/network/api_client.dart) |
| **Estado** | 🟢 Resuelto |

**Descripción:**
Al intentar crear un nodo o unirse a uno, el sistema mostraba un error que indicaba "Token de autenticación requerido" o errores de validación de token.

**Causa:**
Había una colisión y confusión de conceptos entre el token de verificación de cuenta de correo (OTP de 6 dígitos / enlace de correo) y el token JWT de acceso del usuario para peticiones HTTP autenticadas.

**Solución:**
Se reestructuraron los endpoints del backend para que el middleware de autenticación (`jwt_auth`) solo aplique a rutas protegidas (`/nodos`), mientras que las rutas de verificación (`/verify-email`, `/verify-link`) se mantengan completamente públicas. Además, se pulió el interceptor HTTP de Dio en el frontend para asegurar el envío consistente de la cabecera `Authorization: Bearer <token>`.

---

### BUG-004: Restos de Nomenclatura Antigua ("Aulas" y "UGB")

| Campo | Detalle |
|---|---|
| **Severidad** | 🟢 Bajo |
| **Componente** | Frontend |
| **Archivo(s)** | [login_screen.dart](file:///C:/Users/Ludwin/ironlink_workspace/frontend/lib/features/iam/presentation/login_screen.dart), [register_screen.dart](file:///C:/Users/Ludwin/ironlink_workspace/frontend/lib/features/iam/presentation/register_screen.dart), [dashboard_screen.dart](file:///C:/Users/Ludwin/ironlink_workspace/frontend/lib/features/nodos/presentation/dashboard_screen.dart) |
| **Estado** | 🟢 Resuelto |

**Descripción:**
Varias pantallas del frontend y variables mostraban referencias a "aulas virtuales", "salas", "calendarios" e identificadores institucionales de la universidad UGB.

**Causa:**
Copias y plantillas remanentes del sistema universitario previo.

**Solución:**
Se realizó una limpieza de código integral en los archivos de la interfaz renombrando todos los elementos a "Nodos" e "IronLink", eliminando por completo la sección de calendario institucional y desvinculando cualquier logotipo de la UGB.

---

### BUG-005: Fallo de Interceptor de Token JWT en Dio

| Campo | Detalle |
|---|---|
| **Severidad** | 🟠 Alto |
| **Componente** | Frontend |
| **Archivo(s)** | [api_client.dart](file:///C:/Users/Ludwin/ironlink_workspace/frontend/lib/core/network/api_client.dart) |
| **Estado** | 🟢 Resuelto |

**Descripción:**
Aleatoriamente las peticiones del frontend fallaban con código 401 Unauthorized en el backend debido a que no se inyectaba el token de acceso, obligando al usuario a re-autenticarse constantemente.

**Causa:**
La lista de interceptores del cliente HTTP (Dio) duplicaba instancias o se saltaba la inyección del token si se realizaban múltiples peticiones asíncronas concurrentes.

**Solución:**
Se modificó la inicialización en `api_client.dart` usando un patrón Singleton estricto con un flag de inicialización que garantiza que el interceptor de autorización se configure una única vez y tenga prioridad absoluta sobre las cabeceras HTTP.

---

### BUG-006: Error de correo duplicado fantasma tras retroceder en el registro

| Campo | Detalle |
|---|---|
| **Severidad** | 🟠 Alto |
| **Componente** | Backend / Lógica de Validación |
| **Archivo(s)** | [service.rs](file:///C:/Users/Ludwin/ironlink_workspace/backend/src/auth/service.rs) |
| **Estado** | 🟢 Resuelto |

**Descripción:**
Al no completar el registro (OTP) y volver a iniciar el proceso retrocediendo, el sistema bloqueaba el correo indicando que "ya está registrado" sin haber activado la cuenta.

**Causa:**
El backend realizaba una inserción directa y bloqueaba por unicidad de base de datos correos o teléfonos existentes de cuentas con estado `PENDING` que no habían finalizado la verificación de correo electrónico.

**Solución:**
Se modificó `register_user` en el backend para consultar si existen registros duplicados de correo o teléfono antes de la inserción. Si los usuarios duplicados encontrados están en estado `PENDING`, son eliminados automáticamente para permitir el re-registro libre de conflicto; si están en estado `ACTIVE` o `SUSPENDED`, se bloquea el registro arrojando errores específicos por campo.

---

### BUG-007: Falta de validación en campos de teléfono y nombre

| Campo | Detalle |
|---|---|
| **Severidad** | 🟡 Medio |
| **Componente** | Frontend / Validación de Formularios |
| **Archivo(s)** | [register_screen.dart](file:///C:/Users/Ludwin/ironlink_workspace/frontend/lib/features/iam/presentation/register_screen.dart) |
| **Estado** | 🟢 Resuelto |

**Descripción:**
El campo de teléfono aceptaba letras y caracteres especiales, y el campo de nombre se podía enviar vacío o con caracteres inválidos por falta de validaciones en el frontend.

**Causa:**
El campo de nombre carecía de restricciones de teclado o regex de validación de caracteres válidos, y el campo de teléfono carecía de formateadores limitantes e internacionalización.

**Solución:**
En `register_screen.dart`:
- Se agregó `FilteringTextInputFormatter.allow` para restringir el campo de nombre solo a letras, acentos y espacios, junto con una validación de regex y longitud mínima (2 caracteres).
- Se agregó `FilteringTextInputFormatter.digitsOnly` al campo de teléfono para evitar letras y caracteres especiales.
- Se implementó un selector de prefijos internacionales en un Dropdown (unión de código de país como +503, +502, +52, +1, etc.) y validación de longitud del número base.

---

### BUG-008: Falta de feedback y validaciones visuales al crear un Nodo con campos vacíos

| Campo | Detalle |
|---|---|
| **Severidad** | 🟡 Medio |
| **Componente** | Frontend / Gestión de Workspaces (Salas) |
| **Archivo(s)** | [dashboard_screen.dart](file:///C:/Users/Ludwin/ironlink_workspace/frontend/lib/features/nodos/presentation/dashboard_screen.dart) |
| **Estado** | 🟢 Resuelto |

**Descripción:**
Al intentar crear un Nodo con campos obligatorios vacíos, la interfaz no mostraba alertas visuales ni advertencias en rojo, dejando al usuario sin retroalimentación sobre la acción.

**Causa:**
Los diálogos de creación (`_CreateNodoDialog`) y unión (`_JoinNodoDialog`) usaban campos de texto planos `TextField` sin un contenedor de formulario (`Form`) ni validadores, limitándose a rechazar la acción de manera silenciosa en el código.

**Solución:**
Se envolvió el diseño interno de `_CreateNodoDialog` y `_JoinNodoDialog` en widgets `Form` con llaves globales de estado (`FormState`). Se adaptó el widget común `_DialogTextField` para usar `TextFormField` internamente, implementando validadores visuales para el nombre del nodo y el token de acceso, mostrando mensajes descriptivos y bordes rojos si se envían vacíos.

