# Darb Taxi Backend (Windows & Docker Setup)

Node.js + TypeScript + Express + PostgreSQL/PostGIS + Socket.IO + Firebase Cloud Messaging (FCM).

## 1. Prerequisites on Windows

- **Node.js 20+** (verified: `node -v`)
- **Docker Desktop for Windows** (or local **PostgreSQL 16 + PostGIS 3.4**)
- Note for PowerShell: if `npm` is blocked by execution policy (`npm.ps1 cannot be loaded`), use `npm.cmd` instead.

## 2. Start PostgreSQL 16 + PostGIS (Docker Compose)

```powershell
cd backend
Copy-Item .env.example .env
docker compose up -d
```

## 3. Install Dependencies, Run Migrations & Seed Data

```powershell
npm.cmd install
npm.cmd run migrate
npm.cmd run seed
```

> `npm.cmd run migrate` tracks applied files in `schema_migrations` so migrations are never executed twice.

## 4. Run Server & Open Swagger Docs

```powershell
npm.cmd run dev
```

Swagger UI: `http://localhost:3000/api-docs`  
OpenAPI JSON: `http://localhost:3000/api-docs.json`

## 5. Run Automated Tests

```powershell
# Unit + Express + Socket.IO tests (MemoryStore)
npm.cmd run typecheck
npm.cmd test

# Real PostgreSQL + PostGIS integration tests (requires running DB)
$env:DATABASE_URL="postgres://darb_user:darb_local_dev_pw@localhost:5432/darb_taxi"
npm.cmd test
```
