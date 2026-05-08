FROM python:3.11

WORKDIR /app

# نسخ requirements من root
COPY requirements.txt .

# تثبيت المكتبات
RUN pip install --no-cache-dir -r requirements.txt

# نسخ الباك اند فقط
COPY backend/ /app/backend/

# ندخل على backend ونشغل التطبيق
WORKDIR /app/backend

# لو FastAPI (عدّل الاسم لو مختلف)
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "7860"]