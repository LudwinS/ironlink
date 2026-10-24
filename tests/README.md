# IronLink — Carpeta de Pruebas y Reportes de Fallos

## Estructura

```
tests/
├── integration/
│   └── api_tests.ps1   → Script PowerShell para pruebas de integración HTTP
├── reports/
│   ├── bugs.md         → Registro de bugs encontrados (todos resueltos)
│   └── test_results.md → Resultados detallados de las pruebas ejecutadas
└── README.md           → Este archivo con instrucciones de ejecución
```

---

## Cómo Ejecutar las Pruebas

### 1. Pruebas de Integración de API (Backend)

Las pruebas de integración realizan peticiones HTTP contra el servidor backend local y validan el registro, inicio de sesión, flujos de verificación (por código OTP y por enlace de verificación) y los endpoints para crear, listar y unirse a espacios de trabajo ("nodos").

#### Requisitos:
* Tener la base de datos PostgreSQL activa con las credenciales cargadas.
* Tener el servidor backend de Rust escuchando en el puerto `8080`.

#### Instrucciones de Ejecución:
Abre una terminal de PowerShell en la raíz del espacio de trabajo y ejecuta:

```powershell
# Ejecutar el script saltándose políticas de restricción de scripts temporales
powershell -ExecutionPolicy Bypass -File tests/integration/api_tests.ps1
```

### 2. Pruebas Unitarias y de Renderizado (Frontend)

Las pruebas unitarias y de widget en Flutter comprueban la correcta inicialización del árbol de widgets, el sistema de rutas dinámicas (con `GoRouter`), la integración con `flutter_riverpod` y la evasión de desbordamiento de renderizado.

#### Requisitos:
* Tener el SDK de Flutter instalado en el sistema.

#### Instrucciones de Ejecución:
Navega a la carpeta del frontend y corre las pruebas:

```bash
cd frontend
flutter test
```

---

## Cómo Reportar un Fallo

Cada fallo en `reports/bugs.md` debe incluir:
* **ID**: Identificador único (BUG-001, BUG-002, etc.)
* **Severidad**: 🔴 Crítico | 🟠 Alto | 🟡 Medio | 🟢 Bajo
* **Componente**: Backend / Frontend / Integración
* **Descripción**: Qué está fallando
* **Pasos para reproducir**: Cómo llegar al fallo
* **Resultado esperado**: Qué debería pasar
* **Resultado actual**: Qué pasa realmente
* **Archivo(s) afectado(s)**: Rutas de los archivos con problemas
* **Estado**: 🔴 Abierto | 🟡 En progreso | 🟢 Resuelto
