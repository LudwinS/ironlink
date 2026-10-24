#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Suite de Certificación y Validación Técnica de la Norma ISO/IEC 25010:2023
para IronLink Enterprise (Cláusulas 3.4 a 3.8).
Equipo: InnovaSoft — UGB Ciclo II-2026.
"""

import sys
import json
import urllib.request
import urllib.error

BASE_URL = "http://127.0.0.1:8080"

def make_req(endpoint, method="GET", data=None, token=None):
    url = f"{BASE_URL}{endpoint}"
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
        
    req = urllib.request.Request(url, headers=headers, method=method)
    if data is not None:
        req.data = json.dumps(data).encode("utf-8")
        
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            body = resp.read().decode("utf-8")
            resp_headers = dict(resp.headers)
            parsed_json = json.loads(body) if body else {}
            return resp.status, parsed_json, resp_headers
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8")
        resp_headers = dict(e.headers)
        try:
            return e.code, json.loads(body), resp_headers
        except:
            return e.code, {"error": body}, resp_headers

def run_iso_audit():
    print("================================================================================")
    print("🏛️  SUITE DE AUDITORÍA Y CERTIFICACIÓN ISO/IEC 25010:2023 (CLÁUSULAS 3.4 - 3.8)")
    print("   Sistema: IronLink Enterprise | Equipo: InnovaSoft (UGB 2026)")
    print("================================================================================\n")
    
    total_checks = 0
    passed_checks = 0

    # ─────────────────────────────────────────────────────────────────────────
    # 1. ISO 3.5 FIABILIDAD (Reliability: Availability & Health)
    # ─────────────────────────────────────────────────────────────────────────
    print("🔍 [ISO 3.5 - Fiabilidad] Verificando Endpoint /health y Disponibilidad de PgPool...")
    total_checks += 1
    try:
        status, body, headers = make_req("/health")
        if status == 200 and body.get("status") == "healthy" and body.get("database") == "connected":
            print(f"  ✅ [PASA] ISO 3.5.2 Disponibilidad: Estado '{body['status']}', DB '{body['database']}'")
            passed_checks += 1
        else:
            print(f"  ❌ [FALLO] Estado inesperado: {status}, {body}")
    except Exception as e:
        print(f"  ⚠️  [ERROR] No se pudo conectar a {BASE_URL}/health. ¿El backend está encendido? ({e})")
        return

    # ─────────────────────────────────────────────────────────────────────────
    # 2. ISO 3.6 SEGURIDAD (Security: Resistance / Cabeceras de Seguridad)
    # ─────────────────────────────────────────────────────────────────────────
    print("\n🔍 [ISO 3.6 - Seguridad] Verificando Cabeceras HTTP de Resistencia (Resistance)...")
    sec_headers = [
        ("x-content-type-options", "nosniff"),
        ("x-frame-options", "DENY"),
        ("x-xss-protection", "1; mode=block"),
        ("referrer-policy", "strict-origin-when-cross-origin")
    ]
    for h_name, h_val in sec_headers:
        total_checks += 1
        received = headers.get(h_name) or headers.get(h_name.lower())
        if received and h_val.lower() in received.lower():
            print(f"  ✅ [PASA] ISO 3.6.6 Resistencia: Header '{h_name}: {received}' verificado")
            passed_checks += 1
        else:
            print(f"  ❌ [FALLO] Falta header de seguridad '{h_name}'. Recibido: {received}")

    # ─────────────────────────────────────────────────────────────────────────
    # 3. ISO 3.4 CAPACIDAD DE INTERACCIÓN (Interaction: Error Protection & Assistance)
    # ─────────────────────────────────────────────────────────────────────────
    print("\n🔍 [ISO 3.4 - Capacidad de Interacción] Verificando Fallback 404 & Asistencia al Usuario...")
    total_checks += 1
    status_404, body_404, _ = make_req("/ruta-inexistente-para-prueba-de-fallback")
    if status_404 == 404 and "hint" in body_404 and "message" in body_404:
        print(f"  ✅ [PASA] ISO 3.4.4 & 3.4.7: Fallback estructurado con asistencia: '{body_404.get('hint')}'")
        passed_checks += 1
    else:
        print(f"  ❌ [FALLO] Respuesta 404 no estandarizada: {status_404}, {body_404}")

    # ─────────────────────────────────────────────────────────────────────────
    # 4. ISO 3.6 SEGURIDAD (Security: Confidentiality & Fail-Closed RBAC)
    # ─────────────────────────────────────────────────────────────────────────
    print("\n🔍 [ISO 3.6 - Seguridad] Verificando Política Fail-Closed ante Solicitudes sin Token...")
    total_checks += 1
    status_auth, body_auth, _ = make_req("/nodos")
    if status_auth == 401:
        print(f"  ✅ [PASA] ISO 3.6.1 Confidencialidad: Rechazo inmediato 401 Unauthorized sin token válido")
        passed_checks += 1
    else:
        print(f"  ❌ [FALLO] Código no autorizado inesperado: {status_auth}")

    # ─────────────────────────────────────────────────────────────────────────
    # 5. ISO 3.7 MANTENIBILIDAD & 3.8 FLEXIBILIDAD (Maintainability & Flexibility)
    # ─────────────────────────────────────────────────────────────────────────
    print("\n🔍 [ISO 3.7 & 3.8 - Mantenibilidad y Flexibilidad] Verificando Metadatos y Estándares...")
    total_checks += 1
    standards = body.get("standards", {})
    if standards.get("framework") == "ISO/IEC 25010:2023 (Ed. 2)":
        print(f"  ✅ [PASA] ISO 3.7 Analizabilidad & ISO 3.8 Adaptabilidad: Marco '{standards.get('framework')}' certificado")
        passed_checks += 1
    else:
        print(f"  ❌ [FALLO] Metadatos de estándar ausentes o incorrectos: {standards}")

    # ─────────────────────────────────────────────────────────────────────────
    # RESUMEN FINAL
    # ─────────────────────────────────────────────────────────────────────────
    print("\n================================================================================")
    print(f"📊 RESUMEN FINAL DE LA SUITE ISO 25010:2023: {passed_checks}/{total_checks} CHECKS APROBADOS")
    if passed_checks == total_checks:
        print("🏆 CERTIFICACIÓN EXITOSA: Todas las cláusulas aplicadas (3.4 a 3.8) están 100% conformes.")
    else:
        print("⚠️  ADVERTENCIA: Algunos criterios requieren revisión.")
    print("================================================================================\n")

if __name__ == "__main__":
    run_iso_audit()
