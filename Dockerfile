FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ .

USER 10001:10001

EXPOSE 8080

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--worker-class", "gthread", "--workers", "2", "--threads", "8", "--worker-tmp-dir", "/dev/shm", "--timeout", "30", "--access-logfile", "-", "--error-logfile", "-", "main:app"]
