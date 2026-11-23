---
title: Islam App API
emoji: 🚀
colorFrom: blue
colorTo: purple
sdk: docker
app_file: backend/app/main.py
pinned: false
---

# IslamApp

Private source test package. Read [DELIVERY.md](DELIVERY.md) first for the current scope, test results and known limits. Historical review-stage notes are excluded from this archive; DELIVERY.md is the current package status.

Install Python requirements from the repository root. The API entry point is `app.main:app` from `backend/`, as used by Dockerfile. For an isolated trial, configure separate test PostgreSQL and Firebase services. This is a recommendation for testing these changes, not a change to the existing shared development setup. No private service credentials or test user accounts are included.

```bash
python -m pip install -r requirements.txt
cd backend
uvicorn app.main:app --host 127.0.0.1 --port 7860
```

An isolated trial is recommended to reduce risk to existing data. For that trial, redirect existing frontend service URLs and Firebase public configuration to the test project before launching the app. The source package does not itself create or configure that test project.
