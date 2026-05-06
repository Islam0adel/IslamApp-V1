FROM python:3.12

# تحديد مكان العمل
WORKDIR /code

# نسخ ملف المكتبات وتثبيتها
COPY ./requirements.txt /code/requirements.txt
RUN pip install --no-cache-dir --upgrade -r /code/requirements.txt

# نسخ الكود بالكامل
COPY . .

# تشغيل السيرفر على بورت 7860 (ده البورت اللي Hugging Face بيحبه)
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "7860"]