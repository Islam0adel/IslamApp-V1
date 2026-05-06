FROM python:3.12

# تحديد مكان العمل داخل الحاوية
WORKDIR /code

# 1. نسخ ملف المكتبات (بما أنه الآن داخل backend)
COPY ./requirements.txt /code/requirements.txt

# 2. تثبيت المكتبات
RUN pip install --no-cache-dir --upgrade -r /code/requirements.txt

# 3. نسخ محتويات فولدر backend بالكامل إلى داخل /code
COPY ./backend /code/

# 4. إضافة المسار لبيئة بايثون عشان يشوف الموديولات صح
ENV PYTHONPATH=/code

# 5. تشغيل السيرفر
# بما أننا نسخنا محتويات backend جوه /code، فالسيرفر هيلاقي فولدر app جواه مباشرة
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "7860"]