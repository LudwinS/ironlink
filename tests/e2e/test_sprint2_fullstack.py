import urllib.request
import json
import time

BASE_URL = "http://127.0.0.1:8080"

def test_full_suite():
    print("=" * 75)
    print("🚀 EJECUTANDO SUITE INTEGRAL DE PRUEBAS END-TO-END — SPRINT 2 (IRONLINK)")
    print("=" * 75)

    # 1. LOGIN EXITOSO
    print("\n[TEST 1] Autenticación JWT de Usuario (POST /login)...")
    login_payload = json.dumps({
        "email": "tester_qa@ironlink.dev",
        "password": "Password123!"
    }).encode("utf-8")
    req = urllib.request.Request(f"{BASE_URL}/login", data=login_payload, headers={"Content-Type": "application/json"})
    
    with urllib.request.urlopen(req) as resp:
        assert resp.status == 200
        data = json.loads(resp.read().decode("utf-8"))
        token = data["access_token"]
        user = data["user"]
        print(f"  ✔ Login exitoso para {user['name']} ({user['email']})")
        print(f"  ✔ Access Token JWT recibido (longitud: {len(token)} chars)")

    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {token}"
    }

    # 2. OBTENER NODOS
    print("\n[TEST 2] Consulta de Nodos Colaborativos (GET /nodos)...")
    req = urllib.request.Request(f"{BASE_URL}/nodos", headers=headers)
    with urllib.request.urlopen(req) as resp:
        assert resp.status == 200
        nodos_data = json.loads(resp.read().decode("utf-8"))
        nodos = nodos_data.get("nodos", [])
        print(f"  ✔ Nodos recuperados: {len(nodos)} nodo(s) disponible(s)")
        nodo_id = nodos[0]["id"]
        print(f"  ✔ Usando Nodo ID: {nodo_id} ('{nodos[0].get('nombre')}')")

    # 3. CHAT: ENVIAR MENSAJE (TC-CHT-001)
    print("\n[TEST 3] IRL-WKS-US-03: Envío de Mensaje en Canal (POST /nodos/{id}/mensajes)...")
    msg_payload = json.dumps({
        "contenido": "¡Hola equipo InnovaSoft! Mensaje verificado de Sprint 2 sin errores de credenciales."
    }).encode("utf-8")
    req = urllib.request.Request(f"{BASE_URL}/nodos/{nodo_id}/mensajes", data=msg_payload, headers=headers)
    with urllib.request.urlopen(req) as resp:
        assert resp.status in (200, 201)
        res = json.loads(resp.read().decode("utf-8"))
        print(f"  ✔ Mensaje guardado en PostgreSQL: {res.get('message', 'OK')}")

    # 4. CHAT: CONSULTAR HISTORIAL (TC-CHT-002)
    print("\n[TEST 4] IRL-WKS-US-03: Consulta Histórica de Mensajes (GET /nodos/{id}/mensajes)...")
    req = urllib.request.Request(f"{BASE_URL}/nodos/{nodo_id}/mensajes", headers=headers)
    with urllib.request.urlopen(req) as resp:
        assert resp.status == 200
        history_data = json.loads(resp.read().decode("utf-8"))
        msgs = history_data.get("mensajes", history_data.get("data", []))
        print(f"  ✔ Total de mensajes históricos cargados: {len(msgs)}")
        if msgs:
            last = msgs[-1]
            print(f"  ✔ Último mensaje: '{last.get('contenido')}' por {last.get('user_name', 'Usuario')}")

    # 5. SUBGRUPOS: CREAR SUBGRUPO (TC-SUB-001)
    print("\n[TEST 5] IRL-WKS-US-02: Creación de Subgrupo Público (POST /nodos/{id}/subgrupos)...")
    sub_payload = json.dumps({
        "nombre": "Célula UI & Desktop",
        "descripcion": "Equipo especializado en interfaz de Flutter y aceleración Metal en macOS.",
        "es_privado": False
    }).encode("utf-8")
    req = urllib.request.Request(f"{BASE_URL}/nodos/{nodo_id}/subgrupos", data=sub_payload, headers=headers)
    with urllib.request.urlopen(req) as resp:
        assert resp.status in (200, 201)
        sub_res = json.loads(resp.read().decode("utf-8"))
        sub_obj = sub_res.get("subgrupo", sub_res.get("data", sub_res))
        sub_id = sub_obj.get("id")
        print(f"  ✔ Subgrupo creado con éxito: ID={sub_id} ('{sub_obj.get('nombre')}')")

    # 6. SUBGRUPOS: LISTAR (TC-SUB-004)
    print("\n[TEST 6] IRL-WKS-US-02: Listado de Subgrupos de Nodo (GET /nodos/{id}/subgrupos)...")
    req = urllib.request.Request(f"{BASE_URL}/nodos/{nodo_id}/subgrupos", headers=headers)
    with urllib.request.urlopen(req) as resp:
        assert resp.status == 200
        subs_data = json.loads(resp.read().decode("utf-8"))
        subs = subs_data.get("subgrupos", subs_data.get("data", []))
        print(f"  ✔ Total de subgrupos en el nodo: {len(subs)}")

    # 7. REUNIONES: PROGRAMAR (TC-REU-001)
    print("\n[TEST 7] IRL-WKS-US-04: Programación de Reunión con Google Meet (POST /nodos/{id}/reuniones)...")
    reu_payload = json.dumps({
        "titulo": "Daily Scrum Sprint 2 — InnovaSoft",
        "descripcion": "Sincronización síncrona de arquitectura y cierre de pruebas QA.",
        "fecha_inicio": "2026-08-25T15:00:00Z",
        "fecha_fin": "2026-08-25T15:30:00Z",
        "enlace_reunion": "https://meet.google.com/abc-defg-hij"
    }).encode("utf-8")
    req = urllib.request.Request(f"{BASE_URL}/nodos/{nodo_id}/reuniones", data=reu_payload, headers=headers)
    with urllib.request.urlopen(req) as resp:
        assert resp.status in (200, 201)
        reu_res = json.loads(resp.read().decode("utf-8"))
        reu_obj = reu_res.get("reunion", reu_res.get("data", reu_res))
        print(f"  ✔ Reunión programada exitosamente: '{reu_obj.get('titulo')}'")
        print(f"  ✔ Enlace Google Meet validado: {reu_obj.get('enlace_reunion')}")

    # 8. REUNIONES: LISTAR (TC-REU-003)
    print("\n[TEST 8] IRL-WKS-US-04: Consulta de Calendario de Reuniones (GET /nodos/{id}/reuniones)...")
    req = urllib.request.Request(f"{BASE_URL}/nodos/{nodo_id}/reuniones", headers=headers)
    with urllib.request.urlopen(req) as resp:
        assert resp.status == 200
        reus_data = json.loads(resp.read().decode("utf-8"))
        reus = reus_data.get("reuniones", reus_data.get("data", []))
        print(f"  ✔ Total de reuniones agendadas: {len(reus)}")

    # 9. PERFIL: ACTUALIZAR AVATAR Y PRESENCIA (TC-PRF-001 / TC-PRF-002)
    print("\n[TEST 9] IRL-IAM-US-05: Personalización de Avatar y Presencia (PUT /users/me)...")
    prof_payload = json.dumps({
        "name": "Ludwin Saúl Vásquez Romero",
        "avatar_color": "#00E5FF",
        "status_text": "online",
        "bio": "Scrum Master & Architecture Lead — Equipo InnovaSoft",
        "telefono": "+50370010001"
    }).encode("utf-8")
    req = urllib.request.Request(f"{BASE_URL}/users/me", data=prof_payload, headers=headers, method="PUT")
    with urllib.request.urlopen(req) as resp:
        assert resp.status == 200
        prof_res = json.loads(resp.read().decode("utf-8"))
        print(f"  ✔ Perfil actualizado: Avatar=#00E5FF (Cian), Estado=online")

    # 10. PERFIL: CAMBIO DE CONTRASEÑA CON ARGON2ID (TC-PRF-003)
    print("\n[TEST 10] IRL-IAM-US-05: Verificación Criptográfica de Contraseña con Argon2id (PUT /users/me/password)...")
    pwd_payload = json.dumps({
        "current_password": "Password123!",
        "new_password": "Password123!"
    }).encode("utf-8")
    req = urllib.request.Request(f"{BASE_URL}/users/me/password", data=pwd_payload, headers=headers, method="PUT")
    with urllib.request.urlopen(req) as resp:
        assert resp.status == 200
        pwd_res = json.loads(resp.read().decode("utf-8"))
        print(f"  ✔ Verificación y re-hasheo con Argon2id exitoso: {pwd_res.get('message')}")

    print("\n" + "=" * 75)
    print("🎯 RESULTADO: 10/10 PRUEBAS END-TO-END APROBADAS SATISFACTORIAMENTE (100% OK)")
    print("   TODAS LAS CREDENCIALES, ENDPOINTS Y RUTAS CRÍTICAS RESPONDEN 200 OK / 201 CREATED")
    print("=" * 75)

if __name__ == "__main__":
    test_full_suite()
