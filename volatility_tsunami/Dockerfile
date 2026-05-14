FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY vol_tsunami ./vol_tsunami
COPY app.py ./app.py
COPY scripts ./scripts

ENV PORT=8054
EXPOSE 8054

CMD ["sh", "-c", "gunicorn -b 0.0.0.0:${PORT} --workers 1 --threads 4 --timeout 120 app:server"]
