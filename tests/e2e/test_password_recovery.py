import os
import urllib.request
import urllib.error
import json
import time
import subprocess

def http_post(url, data_dict):
    req = urllib.request.Request(
        url,
        data=json.dumps(data_dict).encode('utf-8'),
        headers={'Content-Type': 'application/json'}
    )
    try:
        with urllib.request.urlopen(req) as response:
            return response.status, json.loads(response.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode('utf-8'))

# Iniciar servidor backend
backend_proc = subprocess.Popen(
    ["/Users/ludwin/Developer/ironlink_workspace/backend/target/debug/backend"],
    cwd="/Users/ludwin/Developer/ironlink_workspace/backend"
)

BASE_URL = "http://127.0.0.1:8080"
EMAIL = "tester_qa@ironlink.dev"
DB_URL = os.environ.get("DATABASE_URL", "postgres://postgres:password@localhost:5432/IronLink")

# Esperar a que el servidor esté listo
for _ in range(15):
    try:
        urllib.request.urlopen(f"{BASE_URL}/nodos")
        break
    except urllib.error.HTTPError as e:
        if e.code == 401: # El servidor está respondiendo
            break
    except Exception:
        time.sleep(0.5)

print("Servidor backend de Rust listo y escuchando en puerto 8080.")

try:
    # 1. Solicitar código de recuperación
    print("\n[PASO 1] Solicitando código de recuperación (POST /forgot-password)...")
    status1, data1 = http_post(f"{BASE_URL}/forgot-password", {"email": EMAIL})
    print(f"✔ Respuesta status: {status1}, data: {data1}")
    assert status1 == 200, "Fallo al solicitar código"

    # 2. Consultar código de 6 dígitos generado en PostgreSQL
    print("\n[PASO 2] Consultando código OTP en base de datos PostgreSQL...")
    psql_out = subprocess.check_output([
        "psql",
        DB_URL,
        "-t", "-A", "-c",
        f"SELECT code FROM verification_tokens vt JOIN users u ON vt.user_id = u.id WHERE u.email = '{EMAIL}' AND vt.method = 'reset_code' ORDER BY vt.created_at DESC LIMIT 1;"
    ]).decode().strip()
    
    print(f"✔ Código OTP de recuperación obtenido de BD: '{psql_out}'")
    assert len(psql_out) == 6, "El código OTP debe ser de 6 dígitos"

    # 3. Restablecer contraseña con el código
    print("\n[PASO 3] Restableciendo contraseña (POST /reset-password)...")
    status2, data2 = http_post(f"{BASE_URL}/reset-password", {
        "email": EMAIL,
        "code": psql_out,
        "new_password": "NewSecretPassword123!"
    })
    print(f"✔ Respuesta status: {status2}, data: {data2}")
    assert status2 == 200, "Fallo al restablecer contraseña"

    # 4. Probar Login con la nueva contraseña
    print("\n[PASO 4] Probando Login con la NUEVA contraseña (POST /login)...")
    status3, data3 = http_post(f"{BASE_URL}/login", {
        "email": EMAIL,
        "password": "NewSecretPassword123!"
    })
    print(f"✔ Respuesta status: {status3}, data: {data3}")
    assert status3 == 200 and data3.get("success") == True, "Fallo al autenticar con nueva contraseña"
    print(f"✔ Login exitoso! Token recibido para usuario: {data3.get('user', {}).get('name')}")

    # 5. Restaurar contraseña estándar Password123!
    print("\n[PASO 5] Restaurando clave estándar Password123! para el usuario...")
    http_post(f"{BASE_URL}/forgot-password", {"email": EMAIL})
    psql_out2 = subprocess.check_output([
        "psql",
        DB_URL,
        "-t", "-A", "-c",
        f"SELECT code FROM verification_tokens vt JOIN users u ON vt.user_id = u.id WHERE u.email = '{EMAIL}' AND vt.method = 'reset_code' ORDER BY vt.created_at DESC LIMIT 1;"
    ]).decode().strip()
    status4, data4 = http_post(f"{BASE_URL}/reset-password", {
        "email": EMAIL,
        "code": psql_out2,
        "new_password": "Password123!"
    })
    assert status4 == 200, "Fallo al restaurar contraseña estándar"
    print("✔ Contraseña restaurada a Password123! exitosamente.")

    print("\n=========================================================================")
    print("🎉 PRUEBA DE RECUPERACIÓN DE CONTRASEÑA COMPLETADA AL 100% CON ÉXITO")
    print("=========================================================================")

finally:
    backend_proc.terminate()
    backend_proc.kill()
